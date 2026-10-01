/**
 * Signing in on a phone: a short-lived code standing in for an authorisation URL.
 *
 * A player's PlaySafe ID credentials often live on their phone rather than the
 * machine running the game, so the game can show a QR code and let them finish
 * there. The OAuth flow is unchanged: state already identifies the player and the
 * PKCE verifier already lives here, so whichever device completes the flow, the
 * PSID lands on the same session.
 *
 * The QR encodes a code rather than the authorisation URL itself, for two reasons.
 *
 * Lifetime. A code on a screen is exposed for as long as it is shown, and on a
 * stream for as long as the clip exists, so it lasts 60 seconds and is spent on
 * first read. The sign-in behind it keeps its full five minutes, and a fresh code
 * wraps the same sign-in rather than starting a new one, so a slow phone is never
 * cut off by a countdown on the monitor.
 *
 * Size. The authorisation URL is around 390 characters and needs a 77-module
 * code; a URL this short needs about 35, which a phone reads from across a desk.
 *
 * A stolen code does not give access to the player's account. It lets the thief
 * attach their own PlaySafe ID to the victim's session. Still worth closing.
 */

import { randomBytes } from "node:crypto";

import { Byte, Encoder } from "@nuintun/qrcode";

import { PUBLIC_BASE_URL } from "./config.ts";

/** Where a scanned code is followed. The QR holds this plus a code. */
export const SCAN_PATH = "/playsafe/scan/";

const SCAN_SECONDS = 60;

interface Scan {
  playerId: string;
  authorisationUrl: string;
  /** When the sign-in behind this code stops being completable. */
  signInExpiresAt: number;
  expiresAt: number;
}

/** Keyed by code, since that is what arrives from the phone. */
const scans = new Map<string, Scan>();

export interface Revealed {
  /** The URL the QR encodes. */
  follow: string;
  /** Seconds rather than timestamps, so client clock skew does not matter. */
  expiresIn: number;
  signInExpiresIn: number;
  qr: { size: number; modules: string[] };
}

/** A sign-in already under way, for a new code to point at. */
export interface InFlight {
  authorisationUrl: string;
  expiresAt: number;
}

/**
 * The sign-in this player is in the middle of, if it can still be finished.
 * Checked before starting another, so showing a code twice does not orphan the
 * first.
 */
export function signInInFlight(playerId: string): InFlight | undefined {
  for (const scan of scans.values()) {
    if (scan.playerId !== playerId) continue;
    if (Date.now() >= scan.signInExpiresAt) continue;
    return { authorisationUrl: scan.authorisationUrl, expiresAt: scan.signInExpiresAt };
  }
  return undefined;
}

/**
 * Mints a code and draws it. Any code the player already held is dropped first,
 * so the one on screen is the only one that works.
 */
export function reveal(playerId: string, authorisationUrl: string, signInExpiresAt: number): Revealed {
  hide(playerId);

  const code = randomBytes(6).toString("hex");
  const expiresAt = Date.now() + SCAN_SECONDS * 1000;
  scans.set(code, { playerId, authorisationUrl, signInExpiresAt, expiresAt });

  const follow = `${PUBLIC_BASE_URL}${SCAN_PATH}${code}`;
  return {
    follow,
    expiresIn: SCAN_SECONDS,
    signInExpiresIn: Math.max(0, Math.round((signInExpiresAt - Date.now()) / 1000)),
    qr: draw(follow),
  };
}

/**
 * Drops this player's code, for a player who hid the QR or closed the modal, and any
 * code at all whose sign-in can no longer be finished.
 */
export function hide(playerId: string): void {
  const now = Date.now();
  for (const [code, scan] of scans) {
    // The second test reads signInExpiresAt rather than expiresAt: a code whose
    // minute has passed still names a sign-in a fresh code can wrap, which is what
    // signInInFlight looks for. Once the sign-in itself cannot be finished, neither
    // the code nor the sign-in behind it can do anything.
    if (scan.playerId === playerId || now >= scan.signInExpiresAt) scans.delete(code);
  }
}

/** Reads a code and deletes it, valid or not. Single use, like takeSignIn. */
export function follow(code: string): Scan | undefined {
  const scan = scans.get(code);
  scans.delete(code);
  if (!scan) return undefined;
  return Date.now() >= scan.expiresAt ? undefined : scan;
}

const encoder = new Encoder({ level: "M" });

/**
 * The module grid as one string of 0s and 1s per row. The client paints it, so
 * the two colours come from the game's palette like everything else rather than
 * being baked into an image here.
 */
function draw(text: string): { size: number; modules: string[] } {
  const encoded = encoder.encode(new Byte(text));

  const modules: string[] = [];
  for (let y = 0; y < encoded.size; y += 1) {
    let row = "";
    for (let x = 0; x < encoded.size; x += 1) row += encoded.get(x, y);
    modules.push(row);
  }

  return { size: encoded.size, modules };
}
