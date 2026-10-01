## What to say for each of the nine reasons `POST /play` can give.
##
## Copy only. The decision was the backend's, and there is no logic here that could
## disagree with the gate.
##
## A refusal never steers the player somewhere else. Where a check on PlaySafe ID
## failed, whether on standing or on age band, the modal explains it and offers Close.
## It does not suggest another lobby: that reads as a consolation prize, and a player
## who chose the ranked door wanted the ranked door. The other doors are still on the
## menu, where they were before.
##
## So an action button appears only where it does something about this refusal: sign in,
## repair a verification in the portal, or try the same lobby again.
class_name Refusals
extends RefCounted

const TABLE := {
	"NONE": {
		"head": "PlaySafe ID required",
		"act": "Continue with PlaySafe ID",
		"go": "signin",
		"body": [
			"PlaySafe ID ensures everyone in this lobby has verified who they are and are in good standing.",
		],
	},
	"UNVERIFIED": {
		"head": "Verification is in progress",
		"act": "Open PlaySafe ID",
		"go": "portal",
		"body": [
			"Hang tight, this usually takes up to 2 minutes.",
		],
	},
	"TEMP": {
		"head": "Temporary Ban",
		"go": "close",
		"body": [
			"Your PlaySafe ID has a temporary ban.",
			"Open the PlaySafe ID User Portal and follow the steps to see details.",
		],
	},
	"PERM": {
		"head": "Permanent Ban",
		"go": "close",
		"body": [
			"Your PlaySafe ID has a permanent ban.",
			"Open the PlaySafe ID User Portal and follow the steps to see details.",
		],
	},
	"LOCKED": {
		"head": "Security Lock",
		"go": "close",
		"body": [
			"Your PlaySafe ID has been locked to ensure your account is safe.",
			"Open the PlaySafe ID User Portal and follow the steps to unlock your account.",
		],
	},
	"REAUTH": {
		"head": "Re-verification needed",
		"act": "Open PlaySafe ID",
		"go": "portal",
		"body": [
			"Your PlaySafe ID has been automatically locked to ensure your account is still owned by you.",
			"Open the PlaySafe ID User Portal and follow the steps to re-auth and unlock your account.",
		],
	},
	"WRONG_BAND": {
		"head": "Under 18s only",
		"go": "close",
		"body": [
			"This lobby is reserved for PlaySafe ID verified users who are under 18.",
		],
	},
	"FULL": {
		"head": "Lobby full",
		"act": "Try again",
		"go": "retry",
		"body": [
			"Every slot in this lobby is taken.",
			"Slots free up as players leave.",
		],
	},
	# Not a judgement on the player: PlaySafe ID could not be read, so a protected lobby
	# refuses rather than guessing. Retrying the same lobby is a real action, so this one
	# keeps a button.
	"UNAVAILABLE": {
		"head": "Cannot check right now",
		"act": "Try again",
		"go": "retry",
		"body": [
			"PlaySafe ID could not be reached.",
			"Please try again shortly.",
		],
	},
}

## Failures that are ours rather than PlaySafe ID's, and so not in the table above.
##
## The nine reasons are answers from `POST /play`. These two are what it means for that
## call not to arrive at all, and they must never borrow PlaySafe ID's name: a request
## that never reached our own backend reached PlaySafe ID even less, and for a world
## requiring no PlaySafe ID there was nothing to ask in the first place.
const LOCAL := {
	"offline": {
		"head": "Cannot reach the game",
		"act": "Try again",
		"go": "retry",
		"body": [
			"The game's own backend did not answer.",
		],
	},
	"expired": {
		"head": "Session expired",
		"act": "Start a new session",
		"go": "restart",
		"body": [
			"The backend no longer recognises this session.",
		],
	},
}

## The copy for a failure to reach the backend. `status` is the HTTP code, or 0 when
## nothing answered.
static func local(status: int) -> Dictionary:
	var found: Dictionary = LOCAL["expired"] if status == 401 else LOCAL["offline"]

	var copy := found.duplicate()
	copy["code"] = "no answer from the game backend" if status == 0 else "game backend said HTTP %d" % status
	return copy

## The modal copy for one decision, with the wire values shown underneath it, so an
## integrator reading over a player's shoulder can see which `reason` and which
## `ageBand` produced the screen.
static func spec(decision: Dictionary) -> Dictionary:
	var reason := String(decision.get("reason", "UNAVAILABLE"))
	var found: Dictionary = TABLE.get(reason, TABLE["UNAVAILABLE"])

	var copy := found.duplicate()
	copy["code"] = _code(reason, decision)

	# No action means one centred Close, rather than a Cancel on the left with empty
	# space beside it where an offer used to be.
	if not copy.has("act"):
		copy["cancel"] = "Close"

	return copy

static func _code(reason: String, decision: Dictionary) -> String:
	var band: Variant = decision.get("ageBand")
	if band != null:
		return "reason %s, age band %s" % [reason, band]
	return "reason %s, age band not disclosed" % reason
