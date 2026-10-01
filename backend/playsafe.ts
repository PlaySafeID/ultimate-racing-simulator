/**
 * Every call this backend makes to PlaySafe ID.
 *
 * The OAuth half uses openid-client, the OpenID Certified client for JavaScript
 * runtimes. Hand-rolling the code exchange means hand-rolling PKCE, state checking
 * and token endpoint authentication, and all three are easy to get subtly wrong.
 * The status lookup is not OAuth, so it is a plain fetch.
 */

import * as client from "openid-client";

import { API_BASE, API_KEY, CLIENT_ID, CLIENT_SECRET, ISSUER, REDIRECT_URI } from "./config.ts";

/**
 * Both scopes are required by GET /oauth/userinfo. No scope grants the age band:
 * that is granted on the partner account and arrives on the status lookup.
 *
 * An unrecognised scope is dropped rather than rejected, so a token can be issued
 * granting less than was asked for. completeSignIn logs what was granted.
 */
const SCOPES = "verification manage-games";

/**
 * Without this a token is still issued, but its aud claim is the client id and
 * the API refuses it. Nothing in the token response looks wrong.
 */
const AUDIENCE = "https://api.playsafeid.com/oauth";

/** How long a started sign-in stays completable. */
const SIGN_IN_TTL_MS = 5 * 60 * 1000;

/**
 * The two published enums. Arrays as well as types, so the runtime guard and the
 * compile-time type cannot disagree. What to do about a value is policy and lives
 * in admission.ts.
 */
export const ACCOUNT_STATUSES = [
  "ACTIVE", // no active penalties; the only member that is not a refusal
  "UNVERIFIED", // KYC not approved; the usual state for a new player
  "TEMP", // temporary penalty
  "PERM", // permanent penalty
  "LOCKED", // manual lock by PlaySafe ID staff
  "REAUTH", // locked pending re-authentication, which the player can clear
] as const;

export type AccountStatus = (typeof ACCOUNT_STATUSES)[number];

/** Every standing other than ACTIVE. */
export type AccountRefusal = Exclude<AccountStatus, "ACTIVE">;

/**
 * Returned only to a partner PlaySafe ID has granted it. null on the wire means
 * the partner is not granted the band at all, which says nothing about the player.
 */
export const AGE_BANDS = [
  "UNSET", // granted, but no date of birth recorded
  "ZERO_TO_FIVE",
  "SIX_TO_NINE",
  "TEN_TO_TWELVE",
  "THIRTEEN_TO_FIFTEEN",
  "SIXTEEN_TO_SEVENTEEN",
  "OVER_EIGHTEEN",
] as const;

export type AgeBand = (typeof AGE_BANDS)[number];

/**
 * There is no UNDER_EIGHTEEN member. Under 18 is any band that is neither
 * OVER_EIGHTEEN nor UNSET.
 */
export function verifiedUnderEighteen(ageBand: AgeBand): boolean {
  return ageBand !== "OVER_EIGHTEEN" && ageBand !== "UNSET";
}

/** PlaySafe ID answered with an error body. Carries it for the log. */
export class PlaySafeError extends Error {
  readonly httpStatus: number;
  readonly body: unknown;

  constructor(message: string, httpStatus: number, body: unknown) {
    super(message);
    this.name = "PlaySafeError";
    this.httpStatus = httpStatus;
    this.body = body;
  }
}

/**
 * Discovered once and reused. algorithm: "oauth2" reads RFC 8414 metadata from
 * /.well-known/oauth-authorization-server; this flow requests no openid scope and
 * gets no ID token, so OIDC discovery would add nothing.
 *
 * Resolved on first use rather than at boot, so a network blip while starting does
 * not stop the server.
 */
let discovered: Promise<client.Configuration> | undefined;

function oauthClient(): Promise<client.Configuration> {
  discovered ??= client.discovery(ISSUER, CLIENT_ID, CLIENT_SECRET, undefined, {
    algorithm: "oauth2",
  });
  return discovered;
}

export interface StartedSignIn {
  /** The only thing handed to the game. */
  authorisationUrl: string;
  state: string;
  verifier: string;
  expiresAt: number;
}

/**
 * Builds the authorisation URL and the two secrets to keep until the callback.
 *
 * state is always sent. On a website it is only CSRF protection and PKCE makes it
 * optional; here nobody is logged in at the callback, so state is the only thing
 * saying which player the code belongs to.
 */
export async function startSignIn(): Promise<StartedSignIn> {
  const verifier = client.randomPKCECodeVerifier();
  const challenge = await client.calculatePKCECodeChallenge(verifier);
  const state = client.randomState();

  const url = client.buildAuthorizationUrl(await oauthClient(), {
    redirect_uri: REDIRECT_URI,
    scope: SCOPES,
    audience: AUDIENCE,
    state,
    code_challenge: challenge,
    code_challenge_method: "S256",
    // Shows the consent screen even to a player who has approved before, so the
    // demo can be run repeatedly. Leave it out in production.
    prompt: "consent",
  });

  return {
    authorisationUrl: url.href,
    state,
    verifier,
    expiresAt: Date.now() + SIGN_IN_TTL_MS,
  };
}

/**
 * Redeems the code for an access token and spends it on userinfo.
 *
 * The token is not kept. It lasts an hour, no refresh token is issued, and once
 * the PSID is stored this backend never needs it again. userinfo also records the
 * player's consent for this application, which is what makes lookupStatus resolve
 * for them afterwards.
 *
 * userinfo returns accountStatus and ageBand too. They are not returned from here:
 * a standing read at sign-in is stale by the time anything would act on it, and
 * lookupStatus reads it live when it matters.
 */
export async function completeSignIn(
  callbackUrl: URL,
  state: string,
  verifier: string,
): Promise<{ psid: string }> {
  const config = await oauthClient();

  // The redirect_uri sent to the token endpoint is callbackUrl with its query
  // stripped, so it matches the authorisation request as long as PUBLIC_BASE_URL
  // is what was registered. A mismatch fails without saying which byte differs.
  const tokens = await client.authorizationCodeGrant(config, callbackUrl, {
    pkceCodeVerifier: verifier,
    expectedState: state,
  });

  console.log(`[playsafe] granted scopes: ${tokens.scope ?? "(none)"}`);

  // access_token, never id_token: an ID token's audience is the client id and the
  // API refuses it.
  const response = await client.fetchProtectedResource(
    config,
    tokens.access_token,
    new URL(`${API_BASE}/oauth/userinfo`),
    "GET",
  );
  const body = await readBody(response);

  if (!response.ok) {
    // PS_14022 scope not granted, PS_14026 consent withdrawn, PS_14027 client
    // unrecognised, PS_14029 token refused.
    throw new PlaySafeError(`userinfo answered ${response.status}`, response.status, body);
  }

  // Checked rather than coerced. String(undefined) is the literal string
  // "undefined", which would be stored as a PSID and then looked up forever.
  if (typeof body.psid !== "string" || body.psid === "") {
    throw new PlaySafeError("userinfo returned no psid", response.status, body);
  }

  return { psid: body.psid };
}

/**
 * The response body, whatever it turns out to be.
 *
 * Parsing before checking the status is the trap: an error from something between
 * here and PlaySafe ID is usually HTML or empty, so the parse throws first and the
 * status and body that say what happened are lost with it.
 */
async function readBody(response: Response): Promise<Record<string, unknown>> {
  const text = await response.text();
  try {
    const parsed: unknown = JSON.parse(text);
    return parsed !== null && typeof parsed === "object"
      ? (parsed as Record<string, unknown>)
      : { body: parsed };
  } catch {
    return { body: text.slice(0, 500) };
  }
}

/**
 * Three outcomes rather than two. A value neither enum contained when this was
 * written is neither an answer nor an absence, and admission.ts fails closed on it.
 */
export type StatusLookup =
  | { read: "ok"; status: AccountStatus; ageBand: AgeBand | null }
  /** A 404, which is deliberately opaque about why. */
  | { read: "not-found"; code: string }
  | { read: "unrecognised"; field: "status" | "ageBand"; value: string };

/**
 * The live status read, authenticated with the partner API key rather than a
 * player's token. No player needs to be present.
 *
 * PSID in the platform position addresses the player directly rather than through
 * a Steam or Xbox account.
 */
export async function lookupStatus(psid: string): Promise<StatusLookup> {
  const response = await fetch(`${API_BASE}/user/PSID/${encodeURIComponent(psid)}`, {
    headers: { "X-Api-Key": API_KEY },
  });
  const body = await readBody(response);

  // A 404 does not say whether the PSID is unknown, has never signed into this
  // partner, or withdrew consent, so nobody can probe for who holds a PlaySafe ID.
  // For a PSID this backend has stored, the realistic cause is withdrawn consent.
  if (response.status === 404) {
    return { read: "not-found", code: String(body.code ?? "PS_14015") };
  }

  if (!response.ok) {
    throw new PlaySafeError(`status lookup answered ${response.status}`, response.status, body);
  }

  // Absent is treated as unrecognised rather than coerced, so the value that
  // reaches the log is the one that arrived. admission.ts fails closed on it.
  const status = body.status;
  if (typeof status !== "string" || !isAccountStatus(status)) {
    return { read: "unrecognised", field: "status", value: describeValue(status) };
  }

  // ageBand is optional: absent or null means this partner is not granted it.
  const raw = body.ageBand ?? null;
  if (raw === null) {
    return { read: "ok", status, ageBand: null };
  }
  if (typeof raw !== "string" || !isAgeBand(raw)) {
    return { read: "unrecognised", field: "ageBand", value: describeValue(raw) };
  }

  return { read: "ok", status, ageBand: raw };
}

/** A value for a log line, where the point is what arrived rather than its type. */
function describeValue(value: unknown): string {
  if (value === undefined) return "(absent)";
  const json = JSON.stringify(value);
  return json === undefined ? String(value) : json;
}

function isAccountStatus(value: string): value is AccountStatus {
  return (ACCOUNT_STATUSES as readonly string[]).includes(value);
}

function isAgeBand(value: string): value is AgeBand {
  return (AGE_BANDS as readonly string[]).includes(value);
}

/**
 * One line for the log. openid-client's errors carry the error and
 * error_description the authorisation server sent, which is what says whether the
 * cause is a wrong secret, a mismatched redirect URI or a code already spent.
 */
export function describeFailure(error: unknown): string {
  if (error instanceof PlaySafeError) {
    return `${error.message} ${JSON.stringify(error.body)}`;
  }
  if (
    error instanceof client.ResponseBodyError ||
    error instanceof client.AuthorizationResponseError
  ) {
    return `${error.error}: ${error.error_description ?? "(no description given)"}`;
  }
  return error instanceof Error ? error.message : String(error);
}
