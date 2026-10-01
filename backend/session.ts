/**
 * Sessions, and the signed token that identifies one.
 *
 * Everything here is in memory. A restart signs everyone out, which for a demo is
 * fine. A session holds the PSID if the player has one, and never a standing: a
 * standing is read live at admission and thrown away.
 */

import { createHmac, randomInt, randomUUID, timingSafeEqual } from "node:crypto";

import { IS_DEMO, PRESETS, SESSION_SECONDS, SESSION_SECRET } from "./config.ts";

export interface Session {
  playerId: string;
  displayName: string;
  /** Present once the player has signed in, or a preset supplied one. */
  psid?: string;
  /** Demo only. Which preset account this session stands in for. */
  presetId?: string;
  /** When the ceiling ends this session. Absent where there is no ceiling. */
  expiresAt?: number;
}

/**
 * An in-flight sign-in, stored under its state value.
 *
 * The browser arriving at the callback has no session with this backend, so state
 * is the only thing saying whose account the PSID belongs on. takeSignIn deletes
 * the record on read: one state, one use.
 */
export interface SignIn {
  playerId: string;
  /** The PKCE verifier. Only its hash goes to the authorisation server. */
  verifier: string;
  expiresAt: number;
}

const sessions = new Map<string, Session>();
const signIns = new Map<string, SignIn>();

/**
 * Token format: playerId.expiresAt.signature.
 *
 * Sending a bare player id and trusting it would let anyone claim to be anyone.
 * Signing it costs one HMAC. A session with no ceiling signs a 0; liveness is read
 * from the session itself, never from the token.
 */
function sign(playerId: string, expiresAt: number | undefined): string {
  const body = `${playerId}.${expiresAt ?? 0}`;
  const signature = createHmac("sha256", SESSION_SECRET).update(body).digest("base64url");
  return `${body}.${signature}`;
}

/** The session a bearer token names, if it is live. */
export function sessionFor(token: string | undefined): Session | undefined {
  if (token === undefined) return undefined;

  const parts = token.split(".");
  if (parts.length !== 3) return undefined;

  const [playerId, expiresAt, signature] = parts;
  const expected = createHmac("sha256", SESSION_SECRET)
    .update(`${playerId}.${expiresAt}`)
    .digest("base64url");

  const offered = Buffer.from(signature);
  if (offered.length !== expected.length) return undefined;
  if (!timingSafeEqual(offered, Buffer.from(expected))) return undefined;

  return liveSession(playerId);
}

/**
 * The ceiling is checked here rather than by a sweeper, so an expired session is
 * unusable the instant it expires. Deleting it on the way past keeps the map from
 * growing.
 */
function liveSession(playerId: string): Session | undefined {
  const session = sessions.get(playerId);
  if (!session) return undefined;

  if (session.expiresAt !== undefined && Date.now() >= session.expiresAt) {
    sessions.delete(playerId);
    return undefined;
  }
  return session;
}

export type Created = { session: Session; token: string };

export class PresetRefused extends Error {}

/**
 * Called at boot, since there is no login screen, and again to switch preset.
 *
 * In demo the display name is typed, so one person can run two tabs against one
 * preset account. In public it is generated: a name a stranger chose is
 * player-authored content, and this demo has no moderation.
 */
export function createSession(displayName: string, presetId: string | undefined): Created {
  const preset = choosePreset(presetId);

  const session: Session = {
    playerId: randomUUID(),
    displayName: IS_DEMO ? typedName(displayName) : generatedName(),
    expiresAt: ceilingFromNow(),
  };

  if (preset) {
    session.presetId = preset.id;
    session.psid = preset.psid;
  }

  sessions.set(session.playerId, session);
  return { session, token: sign(session.playerId, session.expiresAt) };
}

function choosePreset(presetId: string | undefined) {
  if (presetId === undefined) return undefined;

  // Refused rather than ignored: a client asking for a preset in public has
  // misunderstood something, and silently starting a real sign-in would hide that.
  if (!IS_DEMO) throw new PresetRefused("presets exist in the demo build only");

  const preset = PRESETS.find((candidate) => candidate.id === presetId);
  if (!preset) throw new PresetRefused(`no preset ${presetId}`);
  return preset;
}

/** When a ceiling starting now would end. Absent where there is no ceiling. */
export function ceilingFromNow(): number | undefined {
  return SESSION_SECONDS > 0 ? Date.now() + SESSION_SECONDS * 1000 : undefined;
}

/**
 * Starts the ceiling again, and answers when it now ends. Called as a player joins a
 * world, so time spent on the menus does not come out of time spent playing.
 *
 * The ceiling bounds how stale an admission may grow, and the admission was made a
 * moment ago, so a full term from here is the same bound and not a looser one. The
 * session is moved with the kick time so the backend does not stop recognising a
 * player the game server is still holding.
 */
export function restartCeiling(playerId: string): number | undefined {
  const expiresAt = ceilingFromNow();
  const session = liveSession(playerId);
  if (session) session.expiresAt = expiresAt;
  return expiresAt;
}

export function endSession(playerId: string): void {
  sessions.delete(playerId);
}

/**
 * Stores the PSID from a completed sign-in.
 *
 * In public one PSID may hold one live session, so an older session on the same
 * PSID ends here. Otherwise one account could sit in two worlds at once.
 */
export function attachPsid(playerId: string, psid: string): Session | undefined {
  const session = liveSession(playerId);
  if (!session) return undefined;

  if (!IS_DEMO) {
    for (const other of sessions.values()) {
      if (other.psid === psid && other.playerId !== playerId) sessions.delete(other.playerId);
    }
  }

  session.psid = psid;
  return session;
}

const ADJECTIVES = [
  "Swift", "Brave", "Quiet", "Bright", "Sharp", "Steady", "Bold", "Keen",
  "Calm", "Rapid", "Nimble", "Fierce",
];

const NOUNS = [
  "Falcon", "Otter", "Comet", "Badger", "Vector", "Piston", "Ranger", "Magpie",
  "Turbine", "Kestrel", "Bishop", "Marten",
];

/** Per session, and derived from nothing about the connection. */
function generatedName(): string {
  const pick = (list: string[]) => list[randomInt(list.length)];
  return `${pick(ADJECTIVES)}${pick(NOUNS)}${randomInt(100, 1000)}`;
}

/** Trimmed and bounded. Falls back to a generated name. */
function typedName(displayName: string): string {
  const trimmed = displayName.replace(/\s+/g, " ").trim().slice(0, 24);
  return trimmed === "" ? generatedName() : trimmed;
}

/**
 * Records a started sign-in, and drops any that can no longer be finished.
 *
 * Most sign-ins are abandoned rather than completed: the player closes the tab, or
 * never opens it. Nothing reads those records again, so unlike a session there is
 * no read to expire them on, and the only other place to do it is here.
 */
export function putSignIn(state: string, signIn: SignIn): void {
  const now = Date.now();
  for (const [key, started] of signIns) {
    if (now >= started.expiresAt) signIns.delete(key);
  }

  signIns.set(state, signIn);
}

export type Taken =
  | { taken: true; signIn: SignIn }
  | { taken: false; reason: "unknown" | "expired" };

/**
 * Reads a sign-in and deletes it, valid or not, so a replayed callback finds
 * nothing. One state, one use.
 *
 * The TTL is enforced here rather than by the caller, so the record cannot be used
 * past it by anything holding a state value. "unknown" and "expired" are separated
 * because they are different mistakes: one is a link used twice, the other a player
 * who took too long.
 */
export function takeSignIn(state: string): Taken {
  const signIn = signIns.get(state);
  signIns.delete(state);

  if (!signIn) return { taken: false, reason: "unknown" };
  if (Date.now() >= signIn.expiresAt) return { taken: false, reason: "expired" };
  return { taken: true, signIn };
}
