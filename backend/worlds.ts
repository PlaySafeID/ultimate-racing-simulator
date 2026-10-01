/**
 * The three worlds, the tickets that admit a player to one, and how many people
 * are in each.
 *
 * A ticket is all the game server ever receives about a player, along with a
 * display name and a kick time. It never receives a PSID and never asks whether
 * someone may play: that was decided before the ticket was issued.
 */

import { randomBytes } from "node:crypto";

import { TICKET_SECONDS, WORLD_CAPACITY } from "./config.ts";
import { ceilingFromNow, restartCeiling, type Session } from "./session.ts";

/**
 * The only age rule any world has. There is no adults-only world: being an adult
 * is a requirement nowhere, so the protected world gates on standing alone and
 * admits every band.
 */
export type AgeRequirement = "minor";

export interface World {
  key: string;
  name: string;
  requiresPlaySafeId: boolean;
  ageRequirement: AgeRequirement | null;
  capacity: number;
}

/**
 * The names say nothing about the rules. A player reads what a server requires
 * from the columns beside it, as they would a region or an anti-cheat flag. The
 * key is the contract and never changes; the name is cosmetic.
 */
export const WORLDS: World[] = [
  {
    key: "open",
    name: "Silverstone Sprint",
    requiresPlaySafeId: false,
    ageRequirement: null,
    capacity: WORLD_CAPACITY,
  },
  {
    key: "protected",
    name: "Monza Endurance",
    requiresPlaySafeId: true,
    ageRequirement: null,
    capacity: WORLD_CAPACITY,
  },
  {
    key: "minor",
    name: "Donington Club",
    requiresPlaySafeId: true,
    ageRequirement: "minor",
    capacity: WORLD_CAPACITY,
  },
];

export function worldFor(key: unknown): World | undefined {
  return typeof key === "string" ? WORLDS.find((world) => world.key === key) : undefined;
}

export interface Ticket {
  ticket: string;
  playerId: string;
  displayName: string;
  world: string;
  issuedAt: number;
  /**
   * The session ceiling. Provisional until redemption, which starts it again. The game
   * server enforces it locally; absent, nobody is removed.
   */
  kickAt?: number;
  redeemedAt?: number;
}

const tickets = new Map<string, Ticket>();

/**
 * An unredeemed ticket holds a slot while it is redeemable, so a player walking
 * from POST /play to the world cannot lose their place. A redeemed ticket holds it
 * until its kick time or, with no ceiling, until the game server reports the
 * departure.
 */
function occupies(ticket: Ticket, now: number): boolean {
  if (ticket.redeemedAt !== undefined) return ticket.kickAt === undefined || now < ticket.kickAt;
  return now < ticket.issuedAt + TICKET_SECONDS * 1000;
}

export function occupancy(world: string): number {
  const now = Date.now();
  let count = 0;
  for (const ticket of tickets.values()) {
    if (ticket.world === world && occupies(ticket, now)) count += 1;
  }
  return count;
}

export function isFull(world: World): boolean {
  return occupancy(world.key) >= world.capacity;
}

/**
 * Any ticket the player already held is dropped first. A player is in one world
 * at a time, so a second POST /play means they left the first.
 *
 * Tickets nobody can use any more go at the same time, so the map is bounded by who is
 * playing rather than by how many admissions the process has ever granted. Occupancy is
 * unaffected, having ignored them already. redeem is not: a swept ticket is absent
 * rather than expired, so it answers "unknown" where it would have said "spent". That
 * is the price of a bounded map, and it is paid by somebody who was already too late.
 */
export function issueTicket(session: Session, world: World): Ticket {
  releaseFor(session.playerId);
  forget();

  const ticket: Ticket = {
    ticket: randomBytes(16).toString("hex"),
    playerId: session.playerId,
    displayName: session.displayName,
    world: world.key,
    issuedAt: Date.now(),
    kickAt: ceilingFromNow(),
  };

  tickets.set(ticket.ticket, ticket);
  return ticket;
}

/** The kick time as the wire carries it: ISO 8601, or null where there is no ceiling. */
export function kickAtIso(ticket: Ticket): string | null {
  return ticket.kickAt === undefined ? null : new Date(ticket.kickAt).toISOString();
}

/** Frees whatever the player held. Called on logout, cancel and a fresh admission. */
export function releaseFor(playerId: string): void {
  for (const ticket of tickets.values()) {
    if (ticket.playerId === playerId) tickets.delete(ticket.ticket);
  }
}

/**
 * Drops tickets that hold no slot. A redeemed ticket with no ceiling is kept: there
 * it is the game server reporting the departure that frees the slot, not a clock.
 */
function forget(): void {
  const now = Date.now();
  for (const ticket of tickets.values()) {
    if (!occupies(ticket, now)) tickets.delete(ticket.ticket);
  }
}

export type Redemption =
  | { redeemed: true; ticket: Ticket }
  | { redeemed: false; reason: "unknown" | "spent" };

/**
 * Single use. A ticket already redeemed or past its window is "spent" rather than
 * "unknown": one is a replay, the other is someone who took too long to arrive.
 *
 * The second of those is best effort. Once issueTicket has swept an expired ticket out
 * of the map nothing remains to tell it from one never issued, so a late arrival whose
 * ticket happened to be swept by another player's admission is told "unknown".
 */
export function redeem(value: unknown): Redemption {
  if (typeof value !== "string" || value === "") return { redeemed: false, reason: "unknown" };

  const ticket = tickets.get(value);
  if (!ticket) return { redeemed: false, reason: "unknown" };

  const now = Date.now();
  if (ticket.redeemedAt !== undefined) return { redeemed: false, reason: "spent" };
  if (!occupies(ticket, now)) return { redeemed: false, reason: "spent" };

  ticket.redeemedAt = now;
  ticket.kickAt = restartCeiling(ticket.playerId);
  return { redeemed: true, ticket };
}

/** The game server reporting a disconnection or a local kick. Frees the slot. */
export function leave(value: unknown): void {
  if (typeof value === "string") tickets.delete(value);
}

/**
 * The game server starting up. Whoever it held left with the previous process, which
 * could not report them, so every redeemed ticket goes. An unredeemed one stays: its
 * player is still on the way, and will arrive at this process instead.
 *
 * This assumes one game server, which is what GAME_SERVER_URL names. A deployment
 * running several would need each to reset only the tickets it redeemed.
 */
export function resetRedeemed(): number {
  let dropped = 0;
  for (const ticket of tickets.values()) {
    if (ticket.redeemedAt !== undefined) {
      tickets.delete(ticket.ticket);
      dropped += 1;
    }
  }
  return dropped;
}

export interface RosterEntry {
  ticket: string;
  playerId: string;
  displayName: string;
  kickAt: string | null;
  /** Whether they have redeemed their ticket, or are still on their way. */
  connected: boolean;
}

/** Who is in a world, for inspection. Nothing polls it. */
export function roster(world: World): RosterEntry[] {
  const now = Date.now();
  return [...tickets.values()]
    .filter((ticket) => ticket.world === world.key && occupies(ticket, now))
    .map((ticket) => ({
      ticket: ticket.ticket,
      playerId: ticket.playerId,
      displayName: ticket.displayName,
      kickAt: kickAtIso(ticket),
      connected: ticket.redeemedAt !== undefined,
    }));
}
