/**
 * Everything read from the environment, in one place.
 *
 * Two deployments run this code and differ only here. ENVIRONMENT=demo gives
 * preset accounts and no session ceiling; anything else gives PlaySafe ID sign-in
 * and a short one. Nothing environment-specific is baked into the client: it all
 * arrives through GET /config.
 *
 * Copy .env.example to .env and fill it in.
 */

function env(name: string, fallback = ""): string {
  return (process.env[name] ?? fallback).trim();
}

export const PORT = Number(env("PORT", "8080"));

/**
 * Where a browser reaches this backend. The callback URL is built from it and has
 * to match what is registered on the OAuth client, so behind a tunnel or a load
 * balancer set it to the public address.
 */
export const PUBLIC_BASE_URL = env("PUBLIC_BASE_URL", `http://localhost:${PORT}`);

export const CALLBACK_PATH = "/playsafe/callback";
export const REDIRECT_URI = `${PUBLIC_BASE_URL}${CALLBACK_PATH}`;

/**
 * Whether a phone could reach this backend, and so whether a QR code for signing
 * in on one is worth offering. Both the scanned URL and the callback after it are
 * built from PUBLIC_BASE_URL, so on a loopback address neither is reachable from a
 * second device.
 */
export const SCANNABLE = !isLoopback(new URL(PUBLIC_BASE_URL).hostname);

function isLoopback(host: string): boolean {
  const bare = host.replace(/^\[|]$/g, "");
  return bare === "localhost" || bare === "::1" || bare.endsWith(".localhost")
    || bare.startsWith("127.");
}

/** The authorisation server. Discovery reads its metadata from here. */
export const ISSUER = new URL(env("PLAYSAFE_ISSUER", "https://auth.playsafeid.com"));

export const API_BASE = env("PLAYSAFE_API_BASE", "https://api.playsafeid.com/v2");

export const CLIENT_ID = env("OAUTH_CLIENT_ID");
export const CLIENT_SECRET = env("OAUTH_CLIENT_SECRET");
export const API_KEY = env("PLAYSAFE_API_KEY");

/** demo or public. */
export const IS_DEMO = env("ENVIRONMENT", "demo") === "demo";
export const ENVIRONMENT = IS_DEMO ? "demo" : "public";

/**
 * Hard ceiling on a session, in seconds. 0 means none.
 *
 * Public keeps one because status is checked at admission and not again, so the
 * ceiling is the only bound on how long a player banned mid-session can stay.
 * Demo has none: its sessions stand for preset accounts whose standing the demoer
 * chose, and being kicked mid-demonstration would be worse than anything a
 * ceiling prevents.
 *
 * Expiry is checked on read, so nothing sweeps.
 */
export const SESSION_SECONDS = Number(env("SESSION_SECONDS", IS_DEMO ? "0" : "3600"));

/** How long a ticket stays redeemable. It holds a slot for that long. */
export const TICKET_SECONDS = Number(env("TICKET_SECONDS", "60"));

/** Players per world. */
export const WORLD_CAPACITY = Number(env("WORLD_CAPACITY", "10"));

/**
 * What POST /play tells an admitted client to connect to, scheme included.
 *
 * A browser refuses a ws:// connection from a page loaded over HTTPS, so anything
 * served over TLS needs wss:// here. Where TLS terminates at a load balancer the
 * game server still listens on plain WebSocket and only this value changes.
 */
export const GAME_SERVER_URL = env("GAME_SERVER_URL", "ws://localhost:8211");

/**
 * Shared secret between this backend and the game server. Deliberately not the
 * PlaySafe ID API key: that belongs in one process, and the game server never
 * talks to PlaySafe ID.
 */
export const GAME_SERVER_KEY = env("GAME_SERVER_KEY");

/** Signs session tokens. A restart invalidates every token. */
export const SESSION_SECRET = env("SESSION_SECRET");

/** Where the client is served from, for CORS. */
export const ALLOWED_ORIGIN = env("ALLOWED_ORIGIN", "*");

/**
 * Where a player finishes or repairs their verification. UNVERIFIED and REAUTH
 * are only actionable with it. Left empty, the client offers no button.
 */
export const PORTAL_URL = env("PLAYSAFE_PORTAL_URL");

export interface Preset {
  id: string;
  label: string;
  psid: string;
}

/**
 * The demo build's preset accounts, one environment variable each:
 *
 *   PRESET_ACTIVE=Verified adult|019f7c3e-...
 *
 * Choosing one attaches its PSID to the session without a sign-in. The accounts
 * are real, so their standings are real, and every PSID comes from the
 * environment rather than being committed. The id is the part of the name after
 * PRESET_, lowercased. Empty in public, where POST /session refuses a presetId.
 */
export const PRESETS: Preset[] = IS_DEMO ? readPresets() : [];

function readPresets(): Preset[] {
  const presets: Preset[] = [];

  for (const [name, value] of Object.entries(process.env)) {
    if (!name.startsWith("PRESET_")) continue;

    const id = name.slice("PRESET_".length).toLowerCase();
    const [label, psid] = (value ?? "").split("|").map((part) => part.trim());

    // Warned rather than skipped silently: a preset whose PSID was never pasted
    // in would otherwise just be missing from the picker.
    if (!label || !psid) {
      console.warn(
        `[config] ${name} needs a label and a PSID separated by |, so ${id} is not offered`,
      );
      continue;
    }

    presets.push({ id, label, psid });
  }

  return presets;
}

/** Checked at boot, so a missing value is reported once, by name. */
export function missingCredentials(): string[] {
  const required = {
    OAUTH_CLIENT_ID: CLIENT_ID,
    OAUTH_CLIENT_SECRET: CLIENT_SECRET,
    PLAYSAFE_API_KEY: API_KEY,
    SESSION_SECRET,
    GAME_SERVER_KEY,
  };
  return Object.entries(required)
    .filter(([, value]) => value === "")
    .map(([name]) => name);
}
