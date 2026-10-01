/**
 * The game backend: the OAuth client, and the only process holding secrets.
 *
 * It holds no game logic. It answers "may this player enter this world" and hands
 * out a ticket when the answer is yes. Sixteen routes, three callers:
 *
 *   client        /config /session /logout /player /playsafe/* /play /cancel /worlds
 *   game server   /match/redeem /match/leave /match/reset /match
 *   browser       /playsafe/callback /playsafe/scan/:code
 *
 * A standing appears in exactly one response, POST /play, so the client cannot
 * cache one and gate on it.
 *
 * Run it with: pnpm start
 */

import { createHash, timingSafeEqual } from "node:crypto";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";

import { decide } from "./admission.ts";
import {
  ALLOWED_ORIGIN,
  API_BASE,
  CALLBACK_PATH,
  ENVIRONMENT,
  GAME_SERVER_KEY,
  GAME_SERVER_URL,
  ISSUER,
  missingCredentials,
  PORT,
  PORTAL_URL,
  PRESETS,
  PUBLIC_BASE_URL,
  REDIRECT_URI,
  SCANNABLE,
  SESSION_SECONDS,
  TICKET_SECONDS,
} from "./config.ts";
import { completeSignIn, describeFailure, PlaySafeError, startSignIn } from "./playsafe.ts";
import { follow, hide, type InFlight, reveal, SCAN_PATH, signInInFlight } from "./scan.ts";
import {
  attachPsid,
  createSession,
  endSession,
  PresetRefused,
  putSignIn,
  type Session,
  sessionFor,
  takeSignIn,
} from "./session.ts";
import {
  isFull,
  issueTicket,
  kickAtIso,
  leave,
  occupancy,
  redeem,
  releaseFor,
  resetRedeemed,
  roster,
  worldFor,
  WORLDS,
} from "./worlds.ts";

function json(res: ServerResponse, status: number, body: unknown): void {
  const payload = JSON.stringify(body, null, 2);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(payload),
    "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
  });
  res.end(payload);
}

function noContent(res: ServerResponse): void {
  res.writeHead(204, { "Access-Control-Allow-Origin": ALLOWED_ORIGIN });
  res.end();
}

/**
 * The only HTML this backend serves, shown in the browser after a sign-in. It
 * says nothing about the outcome: the game is where the player finds out whether
 * they may play.
 *
 * Both strings are escaped. Every value reaching it today is a literal chosen in this
 * file, so nothing currently needs the escaping, and that is exactly why it is here:
 * the next line added is the one that interpolates something a caller supplied, and a
 * template that escapes nothing makes that line an injection with no warning attached.
 */
function page(res: ServerResponse, heading: string, detail: string, status = 200): void {
  const title = escapeHtml(heading);
  const body = escapeHtml(detail);

  res.writeHead(status, { "Content-Type": "text/html; charset=utf-8" });
  res.end(`<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
<style>
  body { margin: 0; min-height: 100vh; display: grid; place-items: center;
         background: #14161a; color: #e9ecf1;
         font: 16px/1.6 system-ui, -apple-system, sans-serif; }
  main { max-width: 26rem; padding: 2rem; text-align: center; }
  h1 { margin: 0 0 .5rem; font-size: 1.35rem; }
  p { margin: 0; color: #99a3b1; }
</style>
<main><h1>${title}</h1><p>${body}</p></main>
</html>`);
}

const ESCAPES: Record<string, string> = {
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;",
};

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (character) => ESCAPES[character] ?? character);
}

/** Nothing this backend accepts is large, and an unbounded read is a way to be killed. */
const MAX_BODY_BYTES = 16 * 1024;

async function readJson(req: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let size = 0;

  for await (const chunk of req) {
    const buffer = chunk as Buffer;
    size += buffer.length;
    // Abandoned rather than parsed. Every caller treats an unreadable body the
    // same way a malformed one is treated, so there is one shape to handle.
    if (size > MAX_BODY_BYTES) return {};
    chunks.push(buffer);
  }

  if (chunks.length === 0) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8")) as Record<string, unknown>;
  } catch {
    return {};
  }
}

function header(req: IncomingMessage, name: string): string | undefined {
  const value = req.headers[name];
  return Array.isArray(value) ? value[0] : value;
}

/** The session a request's bearer token names. */
function caller(req: IncomingMessage): Session | undefined {
  const authorisation = header(req, "authorization") ?? "";
  return sessionFor(authorisation.startsWith("Bearer ") ? authorisation.slice(7) : undefined);
}

/**
 * Compared the way session.ts compares a token signature, and for the same
 * reason: === returns on the first differing byte, so how long the comparison
 * takes says how much of the key was right.
 */
function isGameServer(req: IncomingMessage): boolean {
  return matches(header(req, "x-game-server-key"), GAME_SERVER_KEY);
}

/**
 * Hashed first, so both operands are 32 bytes and the comparison is always reached.
 * timingSafeEqual throws on a length mismatch, so the alternative is a length test in
 * front of it, and that test answers how long the key is without any of it having to
 * be right. session.ts needs no such step only because what it compares is already a
 * fixed-length digest.
 */
function matches(offered: string | undefined, expected: string): boolean {
  if (offered === undefined) return false;

  const a = createHash("sha256").update(offered).digest();
  const b = createHash("sha256").update(expected).digest();
  return timingSafeEqual(a, b);
}

/**
 * Fetched once, before a session exists. Every difference between the two
 * deployments arrives here, so one client build serves both.
 */
function config(res: ServerResponse): void {
  json(res, 200, {
    environment: ENVIRONMENT,
    sessionSeconds: SESSION_SECONDS > 0 ? SESSION_SECONDS : null,
    ticketSeconds: TICKET_SECONDS,
    portalUrl: PORTAL_URL === "" ? null : PORTAL_URL,
    scannable: SCANNABLE,
    worlds: WORLDS,
    presets: PRESETS.map(({ id, label }) => ({ id, label })),
  });
}

/**
 * Creates a session, at boot rather than at a login screen. Switching preset is
 * POST /logout then this again, never a swap in place: a swap would leave a ticket
 * and a world membership attached to an identity that never earned entry.
 */
async function newSession(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const body = await readJson(req);
  const displayName = typeof body.displayName === "string" ? body.displayName : "";
  const presetId = typeof body.presetId === "string" ? body.presetId : undefined;

  let created;
  try {
    created = createSession(displayName, presetId);
  } catch (error) {
    if (error instanceof PresetRefused) return json(res, 400, { error: error.message });
    throw error;
  }

  json(res, 200, {
    token: created.token,
    playerId: created.session.playerId,
    displayName: created.session.displayName,
    psid: created.session.psid ?? null,
    presetId: created.session.presetId ?? null,
  });
}

/** Ends the session, frees the slot, voids the ticket and any scan code. */
function logout(session: Session, res: ServerResponse): void {
  releaseFor(session.playerId);
  hide(session.playerId);
  endSession(session.playerId);
  noContent(res);
}

/**
 * Identity, and whether a PSID is held. The client polls this while a sign-in is
 * open in the browser. It never touches PlaySafe ID and never returns a standing.
 */
function player(session: Session, res: ServerResponse): void {
  json(res, 200, {
    playerId: session.playerId,
    displayName: session.displayName,
    psid: session.psid ?? null,
    presetId: session.presetId ?? null,
  });
}

/**
 * Admission and slot reservation in one call.
 *
 * Not matchmaking: the worlds are standing servers with a capacity, so the
 * questions are whether this player may enter and whether there is room. Both
 * outcomes are 200, because "may I play?" is a question with answers rather than
 * an operation that fails, and that keeps every outcome on one client code path.
 */
async function play(session: Session, req: IncomingMessage, res: ServerResponse): Promise<void> {
  const body = await readJson(req);
  const world = worldFor(body.world);
  if (!world) return json(res, 400, { error: "unknown world" });

  const decision = await decide(world, session.psid);
  if (!decision.admitted) {
    return json(res, 200, {
      admitted: false,
      reason: decision.reason,
      ageBand: decision.ageBand,
    });
  }

  // Checked last, so a player who would have been refused anyway hears the more
  // useful reason. A full lobby is worth retrying; a permanent ban is not.
  if (isFull(world)) {
    return json(res, 200, { admitted: false, reason: "FULL", ageBand: decision.ageBand });
  }

  const ticket = issueTicket(session, world);
  json(res, 200, {
    admitted: true,
    ticket: ticket.ticket,
    server: { url: GAME_SERVER_URL },
    kickAt: kickAtIso(ticket),
  });
}

/**
 * Gives up a held ticket without ending the session. A ticket holds a slot from
 * the moment it is issued, so a player who queued and changed their mind would
 * otherwise keep somebody out until it aged out. Idempotent.
 */
function cancel(session: Session, res: ServerResponse): void {
  releaseFor(session.playerId);
  noContent(res);
}

/** Live occupancy, polled while the server browser is on screen. */
function worlds(res: ServerResponse): void {
  json(
    res,
    200,
    WORLDS.map((world) => ({
      key: world.key,
      occupancy: occupancy(world.key),
      capacity: world.capacity,
    })),
  );
}

/**
 * Starts a sign-in and hands the game a URL. That is all the game gets: the
 * client id, the secret, the verifier and the state stay here.
 */
async function signIn(session: Session, res: ServerResponse): Promise<void> {
  const started = await begin(session);
  json(res, 200, { authorisationUrl: started.authorisationUrl, expiresIn: started.expiresIn });
}

async function begin(session: Session): Promise<InFlight & { expiresIn: number }> {
  const started = await startSignIn();
  putSignIn(started.state, {
    playerId: session.playerId,
    verifier: started.verifier,
    expiresAt: started.expiresAt,
  });

  return {
    authorisationUrl: started.authorisationUrl,
    expiresAt: started.expiresAt,
    expiresIn: Math.round((started.expiresAt - Date.now()) / 1000),
  };
}

/**
 * Draws a QR code for a sign-in. Reuses the sign-in already in flight rather than
 * starting another, so a code expiring on the monitor never shortens the window
 * the phone is working in.
 */
async function scan(session: Session, res: ServerResponse): Promise<void> {
  const inFlight = signInInFlight(session.playerId) ?? (await begin(session));
  json(res, 200, reveal(session.playerId, inFlight.authorisationUrl, inFlight.expiresAt));
}

/** Drops the code, for a player who hid the QR or closed the modal. */
function unscan(session: Session, res: ServerResponse): void {
  hide(session.playerId);
  noContent(res);
}

/**
 * Where a scanned code lands. The code is spent here and the phone is redirected
 * to PlaySafe ID. The only redirect this backend performs, and only to a URL it
 * minted itself.
 */
function followScan(url: URL, res: ServerResponse): void {
  const scanned = follow(url.pathname.slice(SCAN_PATH.length));
  if (!scanned) {
    return page(
      res,
      "This code has expired",
      "Codes last a minute and work once. Show a fresh one in the game and scan that.",
      410,
    );
  }

  res.writeHead(302, { Location: scanned.authorisationUrl });
  res.end();
}

/**
 * Where the browser lands after the player consents. Nobody is logged in on this
 * request; state says which player it belongs to, and is consumed exactly once.
 */
async function callback(url: URL, res: ServerResponse): Promise<void> {
  // Sent when the player declines, if the client's redirection policy allows it.
  // Under the default PlaySafe ID renders its own page and this route is never
  // reached, so nothing here depends on seeing a decline.
  if (url.searchParams.get("error") !== null) {
    return page(res, "Sign-in cancelled", "You can close this tab and return to the game.");
  }

  const state = url.searchParams.get("state");
  if (state === null) {
    return page(res, "Something went wrong", "The sign-in link was incomplete.", 400);
  }

  const taken = takeSignIn(state);
  if (!taken.taken) {
    const heading =
      taken.reason === "expired" ? "This link has expired" : "This link has already been used";
    return page(res, heading, "Start again from the game.", 400);
  }
  const attempt = taken.signIn;

  try {
    const identity = await completeSignIn(url, state, attempt.verifier);

    if (!attachPsid(attempt.playerId, identity.psid)) {
      return page(res, "Your session has expired", "Start again from the game.", 400);
    }

    console.log(`[playsafe] linked player ${attempt.playerId}`);
    page(res, "You're signed in", "Return to the game to carry on.");
  } catch (error) {
    console.error(`[playsafe] sign-in failed: ${describeFailure(error)}`);
    page(res, "Sign-in failed", "Return to the game and try again.", 502);
  }
}

/** A player has arrived at the game server, presenting the ticket from the handshake. */
async function matchRedeem(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const body = await readJson(req);
  const redemption = redeem(body.ticket);

  if (!redemption.redeemed) {
    // 404 for a ticket nobody was issued, 410 for one already spent. A ticket too old
    // to use answers either, according to whether issueTicket has swept it out of the
    // map yet, which redeem's own note explains.
    const status = redemption.reason === "unknown" ? 404 : 410;
    return json(res, status, { error: redemption.reason });
  }

  const ticket = redemption.ticket;
  json(res, 200, {
    playerId: ticket.playerId,
    displayName: ticket.displayName,
    world: ticket.world,
    kickAt: kickAtIso(ticket),
  });
}

/** A player has gone, by disconnection or a local kick. Frees the slot. */
async function matchLeave(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const body = await readJson(req);
  leave(body.ticket);
  noContent(res);
}

/**
 * The game server has just started. Nobody can be connected yet, so any slot still
 * held by a redeemed ticket belongs to a player the previous process lost without
 * reporting, and would otherwise stay held until its kick time, or for good with no
 * ceiling.
 */
function matchReset(res: ServerResponse): void {
  const dropped = resetRedeemed();
  if (dropped > 0) console.log(`[match] game server restarted, freed ${dropped} slot(s)`);
  noContent(res);
}

/** Inspection endpoint. Nothing polls it. */
function match(url: URL, res: ServerResponse): void {
  const world = worldFor(url.searchParams.get("world"));
  if (!world) return json(res, 400, { error: "unknown world" });
  json(res, 200, roster(world));
}

const missing = missingCredentials();
if (missing.length > 0) {
  console.error(`Not configured. Missing: ${missing.join(", ")}`);
  console.error("Copy backend/.env.example to backend/.env and fill it in.");
  process.exit(1);
}

type Handler = (req: IncomingMessage, res: ServerResponse, url: URL) => unknown;
type ClientHandler = (session: Session, req: IncomingMessage, res: ServerResponse) => unknown;

/** No auth: called before a session exists, or by a browser that has none. */
const OPEN_ROUTES: Record<string, Handler> = {
  "GET /config": (_req, res) => config(res),
  "POST /session": (req, res) => newSession(req, res),
  [`GET ${CALLBACK_PATH}`]: (_req, res, url) => callback(url, res),
};

/** Authenticated with the shared game server key. */
const GAME_SERVER_ROUTES: Record<string, Handler> = {
  "POST /match/redeem": (req, res) => matchRedeem(req, res),
  "POST /match/leave": (req, res) => matchLeave(req, res),
  "POST /match/reset": (_req, res) => matchReset(res),
  "GET /match": (_req, res, url) => match(url, res),
};

/** Authenticated with a session token. Every route the player's game calls. */
const CLIENT_ROUTES: Record<string, ClientHandler> = {
  "POST /logout": (session, _req, res) => logout(session, res),
  "GET /player": (session, _req, res) => player(session, res),
  "POST /playsafe/sign-in": (session, _req, res) => signIn(session, res),
  "POST /playsafe/scan": (session, _req, res) => scan(session, res),
  "POST /playsafe/scan/void": (session, _req, res) => unscan(session, res),
  "POST /play": (session, req, res) => play(session, req, res),
  "POST /cancel": (session, _req, res) => cancel(session, res),
  "GET /worlds": (_session, _req, res) => worlds(res),
};

createServer((req, res) => {
  const url = new URL(req.url ?? "/", PUBLIC_BASE_URL);
  const route = `${req.method} ${url.pathname}`;

  // The client is served from a different origin, so the browser preflights.
  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Access-Control-Allow-Headers": "Authorization, Content-Type, X-Game-Server-Key",
      "Access-Control-Max-Age": "86400",
    });
    res.end();
    return;
  }

  const open = OPEN_ROUTES[route];
  if (open) return run(route, res, () => open(req, res, url));

  // The one route with a variable path segment. The code is in the path rather
  // than the query because a shorter string makes a smaller QR code.
  if (req.method === "GET" && url.pathname.startsWith(SCAN_PATH)) {
    return run(route, res, () => followScan(url, res));
  }

  const forGameServer = GAME_SERVER_ROUTES[route];
  if (forGameServer) {
    if (!isGameServer(req)) return json(res, 401, { error: "game server key required" });
    return run(route, res, () => forGameServer(req, res, url));
  }

  const forClient = CLIENT_ROUTES[route];
  if (!forClient) return json(res, 404, { error: `no route for ${route}` });

  // An expired session and a missing token get the same answer: create a session
  // and start again.
  const session = caller(req);
  if (!session) return json(res, 401, { error: "no live session" });

  run(route, res, () => forClient(session, req, res));
}).listen(PORT, () => {
  console.log(`game backend listening on ${PUBLIC_BASE_URL}`);
  console.log(`  environment:          ${ENVIRONMENT}`);
  console.log(`  session ceiling:      ${SESSION_SECONDS > 0 ? `${SESSION_SECONDS}s` : "none"}`);
  console.log(`  presets:              ${PRESETS.length}`);
  console.log(`  game server:          ${GAME_SERVER_URL}`);
  console.log(
    `  sign-in on a phone:   ${SCANNABLE ? "offered" : "not offered, PUBLIC_BASE_URL is loopback"}`,
  );
  console.log(`  callback to register: ${REDIRECT_URI}`);
  console.log(`  authorisation server: ${ISSUER.href}`);
  console.log(`  PlaySafe ID API:      ${API_BASE}`);
});

/**
 * Runs a handler and turns anything it throws into one logged line and one
 * response, so no route needs its own error handling.
 */
async function run(route: string, res: ServerResponse, handler: () => unknown): Promise<void> {
  try {
    await handler();
  } catch (error) {
    console.error(`${route}: ${describeFailure(error)}`);
    if (res.headersSent) return;

    // A PlaySafe ID error body is worth passing on: the code in it is what an
    // integrator would branch on.
    if (error instanceof PlaySafeError) {
      json(res, 502, { error: error.message, playsafe: error.body });
      return;
    }
    json(res, 500, { error: "backend error, see the log" });
  }
}
