/**
 * Who gets in.
 *
 * PlaySafe ID reports a standing and an age band. What to do about them is the
 * partner's policy, and this file is that policy. The vocabulary comes from
 * playsafe.ts, so a partner changing their rules edits here and a partner tracking
 * an API change edits there.
 *
 * A protected world fails closed: if the standing cannot be read, nobody gets in.
 * The open world never consults PlaySafe ID, so it is unaffected.
 */

import {
  type AccountRefusal,
  type AgeBand,
  describeFailure,
  lookupStatus,
  type StatusLookup,
  verifiedUnderEighteen,
} from "./playsafe.ts";
import type { World } from "./worlds.ts";

/**
 * The nine reasons a refusal can carry. The client has copy for each.
 *
 * The first five are the refusing standings, taken from the enum rather than
 * relisted, so a new AccountStatus member surfaces as a type error in the client's
 * refusal table rather than as a lobby quietly admitting somebody. The last four
 * are this game's own.
 */
export type Reason =
  | AccountRefusal
  /** No PSID held, so offer sign-in. Also the answer to a 404 (PS_14015). */
  | "NONE"
  /** Not verified as under 18, at the world that admits only those who are. */
  | "WRONG_BAND"
  | "FULL"
  /** PlaySafe ID could not be read. A protected world refuses on this. */
  | "UNAVAILABLE";

export type Decision =
  | { admitted: true; ageBand: AgeBand | null }
  | { admitted: false; reason: Reason; ageBand: AgeBand | null };

/**
 * Reads the standing live and decides. Never cached: a player can be banned a
 * minute after signing in, and a stored standing only says what was true then.
 */
export async function decide(world: World, psid: string | undefined): Promise<Decision> {
  if (!world.requiresPlaySafeId) return { admitted: true, ageBand: null };

  if (psid === undefined) return { admitted: false, reason: "NONE", ageBand: null };

  let lookup: StatusLookup;
  try {
    lookup = await lookupStatus(psid);
  } catch (error) {
    console.error(`[admission] status lookup failed: ${describeFailure(error)}`);
    return { admitted: false, reason: "UNAVAILABLE", ageBand: null };
  }

  // A 404 on a PSID we have stored most likely means the player withdrew consent.
  // Signing in again does not restore it; only the player can, from the User
  // Portal. So this answers NONE, and the sign-in path has to cope with being
  // refused.
  if (lookup.read === "not-found") return { admitted: false, reason: "NONE", ageBand: null };

  // A value the published enums did not contain when this was written. Refuse and
  // say so, rather than admit on something nobody has decided about.
  if (lookup.read === "unrecognised") {
    console.error(
      `[admission] PlaySafe ID sent ${lookup.field} ${lookup.value}, ` +
        "which this build does not recognise, so refusing",
    );
    return { admitted: false, reason: "UNAVAILABLE", ageBand: null };
  }

  const { status, ageBand } = lookup;

  // Every standing other than ACTIVE keeps a player out, and the refusal is the
  // standing itself.
  if (status !== "ACTIVE") return { admitted: false, reason: status, ageBand };

  return decideOnAge(world, ageBand);
}

/**
 * Only the under-18 world refuses on age, and it refuses anyone it cannot see
 * proof for, adults included. Being an adult is a requirement nowhere: the
 * protected world admits every band.
 */
function decideOnAge(world: World, ageBand: AgeBand | null): Decision {
  if (world.ageRequirement === null) return { admitted: true, ageBand };

  // null means this partner is not granted the age band. That is a configuration
  // fault, and without the log line it would look like every player failing the
  // gate.
  if (ageBand === null) {
    console.error(
      "[admission] ageBand is null, so this partner is not granted it. " +
        "The under-18 world will refuse everyone until that is fixed.",
    );
    return { admitted: false, reason: "UNAVAILABLE", ageBand };
  }

  return verifiedUnderEighteen(ageBand)
    ? { admitted: true, ageBand }
    : { admitted: false, reason: "WRONG_BAND", ageBand };
}
