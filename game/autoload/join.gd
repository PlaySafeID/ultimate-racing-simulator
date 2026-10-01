## Getting into a world. One implementation, shared by all three front doors.
##
## The main menu's playlist buttons, the server browser and character select are facades.
## None of them matchmakes, restores a character or picks a region: they exist so a partner
## can recognise their own game's shape and see where PlaySafe ID would sit in it.
## Underneath, all three do the same three things.
##
##   1. ask for a slot                   `POST /play`, the only PlaySafe ID call
##   2. show the relevant loading text   cosmetic, and the only per-facade difference
##   3. join the game server             present the ticket in the handshake
##
## So a facade supplies copy and nothing else. A fourth front door adds an entry to
## `FACADES` and calls `enter()`, and cannot acquire its own admission rules, its own
## refusal handling or its own idea of a slot.
##
## The gate is needed once per attempt to enter a world, not once per entry point.
extends Node

## Where the screen is in the three steps, so any screen can render it its own way.
## This never carries a standing, only what the player is being told.
signal state_changed(state: String, detail: String)

## The held slot changed, so anything showing a lock or a slot count should repaint.
signal slot_changed()

## How long to keep asking after the browser has been sent to PlaySafe ID.
const SIGN_IN_PATIENCE := 180.0

## The scan path has no patience of its own, and outlives the code that started it: a player
## who scanned with five seconds left is still signing in a minute later.
##
## Asking for a PSID that is not there yet costs the backend nothing, so putting the code away
## is what ends this, rather than a guess about how long somebody takes with a phone.
const WHILE_OPEN := INF

## The loading text each facade uses, and the whole of what distinguishes them.
##
## `checking` is only shown for a world that needs no PlaySafe ID call, because
## claiming to ask about a player when nothing was asked would be a lie in a demo
## whose entire subject is when the asking happens.
const FACADES := {
	"playlist": {
		"checking": "Finding a slot",
		"waiting": "Checking whether you may enter",
		"joining": "Joining %s",
	},
	"browser": {
		"checking": "Checking for space",
		"waiting": "Checking whether you may enter",
		"joining": "Connecting to %s",
	},
	"character": {
		"checking": "Readying your driver",
		"waiting": "Checking whether your driver may race",
		"joining": "Taking your driver to %s",
	},
}

## The slot this player holds, if any: `world`, `ticket` and `kickAt`.
##
## One at a time, because the backend drops the old ticket whenever it issues a new
## one. A screen that let two be held would free a slot it still believed it had.
var held: Dictionary = {}

## Which poll for a landed sign-in is the live one.
##
## A number rather than a flag, because a sign-in can be restarted while an older poll
## is still suspended between asks: revealing a code and then pressing the button does
## exactly that. A loop that wakes to find the number has moved on has been replaced,
## or cancelled, and stops asking.
var _asking := 0

## Whether a QR code is on screen, which is the only state the scan path has.
var _scan_live := false

## True when a slot is held for this world, which is what a screen locks on.
func holds(world: String) -> bool:
	return held.get("world", "") == world

## The world this player holds a slot in, or an empty string.
func held_world() -> String:
	return String(held.get("world", ""))

## Step 1 to 3, for whichever facade the player came through.
##
## The refusal arrives before any loading text appears, so a refusal never looks like
## an interruption of something already in progress, and every outcome, including a
## transport failure, lands on this one code path.
func enter(world: String, facade := "playlist") -> void:
	var copy: Dictionary = FACADES.get(facade, FACADES.playlist)

	# A slot is already held. Asking for the world it is held for gives it back;
	# asking for a different one explains the conflict and offers the swap.
	if not held.is_empty():
		if holds(world):
			await release()
		else:
			await _conflict(world, facade)
		return

	# An unprotected world says nothing about PlaySafe ID here. The missing shield on the
	# button, the row and the driver already said it.
	if world_requires_playsafe_id(world):
		_say("Asking PlaySafe ID", String(copy.waiting))
	else:
		_say(String(copy.checking), String(copy.joining) % world_name(world))

	var decision := await Backend.admit(world)

	# The call not arriving is not one of the nine reasons, and must not be dressed as one.
	# `UNAVAILABLE` means the backend read PlaySafe ID and could not, which only a protected
	# world can produce. A request that never reached our own backend reached PlaySafe ID even
	# less, and on an unprotected world blames a system that was never going to be asked.
	if decision.has("error"):
		slot_changed.emit()
		await _unreachable(world, facade, int(decision.get("status", 0)))
		return

	if not decision.admitted:
		slot_changed.emit()
		await _refuse(decision, world, facade)
		return

	held = {
		"world": world,
		"ticket": decision.ticket,
		"kickAt": decision.kickAt,
		"server": decision.server,
	}
	slot_changed.emit()

	_say(String(copy.joining) % world_name(world), _slot_note(decision.get("kickAt")))
	_join_server()

## How long the slot is held, said only where the backend named a time.
##
## A length rather than the time itself, because the ceiling starts again on joining, so
## the `kickAt` from admission is a few seconds early. A deployment without a ceiling has
## nothing to count down to, and inventing one would promise a limit that is not there.
func _slot_note(kick_at: Variant) -> String:
	var seconds: Variant = Backend.config.get("sessionSeconds")
	if kick_at == null or seconds == null:
		return "Slot held for you"
	return "Slot held for %s" % _length(int(seconds))

func _length(seconds: int) -> String:
	if seconds % 3600 == 0:
		var hours := int(seconds / 3600.0)
		return "1 hour" if hours == 1 else "%d hours" % hours
	var minutes := maxi(1, roundi(seconds / 60.0))
	return "1 minute" if minutes == 1 else "%d minutes" % minutes

## Step 3, and the only seam all three facades reach.
##
## The world scene does the rest: it dials the address the backend named, presents this
## ticket, and the game server redeems it. Nothing about admission happens over there,
## because it already happened here.
func _join_server() -> void:
	get_tree().change_scene_to_file("res://world/world.tscn")

## Gives the slot back, so it returns to the pool at once rather than waiting out its
## redemption window.
func release() -> void:
	var world := held_world()
	held = {}
	await Backend.cancel()
	slot_changed.emit()
	_say("Slot released", "Your slot in %s is back in the pool" % world_name(world))

## Drops the local record of a slot the backend has already freed for us, which is
## what `POST /logout` does. Calling `release()` there would cancel a ticket that no
## longer exists, under a session that no longer exists.
func forget() -> void:
	held = {}
	slot_changed.emit()

## Asking for a second world while a slot is held.
func _conflict(world: String, facade: String) -> void:
	var spec := {
		"head": "You already hold a slot",
		"body": [
			"Your slot is in %s. One at a time." % world_name(held_world()),
			"Releasing it frees the slot for somebody else straight away, and the check runs again from scratch when you ask for %s." % world_name(world),
		],
		"cancel": "Keep this slot",
		"act": "Release and join %s" % world_name(world),
	}

	if await Dialog.open(spec) != "action":
		return

	await release()
	await enter(world, facade)

## The game backend did not answer, or answered that the session is gone.
##
## Both are recoverable and neither is about the player, so each offers the step that clears
## it: retry, or start a fresh session.
func _unreachable(world: String, facade: String, status: int) -> void:
	var spec := Refusals.local(status)
	_say(String(spec.head), String(spec.code))

	if await Dialog.open(spec) != "action":
		_say("Idle", "Pick a playlist to start")
		return

	if String(spec.go) == "restart":
		# The old session is already gone server side, so this drops it locally and makes
		# another. The preset carries over; a PSID does not, because it was granted to the
		# session that went away.
		var preset: Variant = Backend.player.get("presetId")
		Backend.forget_session()
		held = {}
		slot_changed.emit()

		var session := await Backend.start_session("", "" if preset == null else String(preset))
		if session.has("error"):
			_say("Cannot reach the game", String(session.error))
			return

	await enter(world, facade)

## The refusal modal, over whichever screen the player was already on.
func _refuse(decision: Dictionary, world: String, facade: String) -> void:
	var spec := Refusals.spec(decision)
	_say("Refused", "reason %s" % decision.reason)

	# Where a portal link is the only thing on offer and nobody has configured one, say so
	# rather than showing a button that goes nowhere.
	if spec.go == "portal" and portal_url() == "":
		spec["act"] = ""
		spec["cancel"] = "Close"

	# Signing in is the one refusal with two ways to act on it, and both are the same sign-in:
	# this browser, or a phone. The QR sits on the modal rather than behind the button, so a
	# player who would rather not sign in at this desk is offered the alternative before
	# choosing.
	#
	# Offered only where a phone could reach the backend. Against a local deployment neither
	# the code nor the callback after it is reachable from anywhere but this machine.
	var scannable := String(spec.go) == "signin" and Backend.can_scan()
	if scannable:
		spec["scan"] = true
		Dialog.scan_toggled.connect(_on_scan_toggled)

	var outcome: String = await Dialog.open(spec)

	if scannable:
		Dialog.scan_toggled.disconnect(_on_scan_toggled)
		await _drop_scan()

	# Finished on the phone. The gate has not run yet, so it runs now.
	if outcome == "signed-in":
		await enter(world, facade)
		return

	if outcome != "action":
		_say("Idle", "Pick a playlist to start")
		return

	match String(spec.go):
		"signin": await _sign_in(world, facade)
		"portal": OS.shell_open(portal_url())
		"retry": await enter(world, facade)
		_: await enter(String(spec.go), facade)

## The sign-in, of which this client only ever does half: it opens a URL the backend
## minted and waits to be told a PSID landed.
##
## It never sees the client id, the secret, the authorisation code or the state.
func _sign_in(world: String, facade: String) -> void:
	var url := await Backend.sign_in_url()
	if url == "":
		await Dialog.open({
			"head": "Could not start sign-in",
			"body": ["The backend could not reach PlaySafe ID to begin. Try again in a moment."],
			"cancel": "Close",
		})
		return

	OS.shell_open(url)

	# Polling `GET /player`, because the browser completing the flow has no session with this
	# client and cannot tell it anything. The backend learns the outcome and this asks until
	# it shows up.
	_start_asking(SIGN_IN_PATIENCE)

	var outcome: String = await Dialog.open({
		"head": "Waiting for PlaySafe ID",
		"body": [
			"A PlaySafe ID tab has opened. Sign in there and come back; this picks it up on its own.",
			"Nothing about the outcome appears in that tab. The game is where you find out whether you may play.",
		],
		"cancel": "Cancel",
	})
	_stop_asking()

	if outcome == "signed-in":
		await enter(world, facade)

func _start_asking(patience: float) -> void:
	_asking += 1
	_poll_for_psid(_asking, patience)

func _stop_asking() -> void:
	_asking += 1

## Asks until a PSID shows up, which is the whole of this client's half of a sign-in
## finished elsewhere: another tab, or another device.
##
## It closes the modal and nothing more. Deciding what happens next belongs to whoever
## opened it, so there is exactly one place that re-runs the gate.
func _poll_for_psid(generation: int, patience: float) -> void:
	var waited := 0.0
	while _asking == generation and waited < patience:
		await get_tree().create_timer(2.0).timeout
		waited += 2.0
		if _asking != generation:
			return

		# A session that has run out cannot be polled into working, and the refusal for it is
		# better raised by the next click than by a modal the player is reading.
		if (await Backend.refresh_player()).has("error"):
			return

		if not Backend.has_playsafe_id():
			continue

		slot_changed.emit()
		Dialog.close("signed-in")
		return

	if _asking == generation:
		Dialog.retitle("PlaySafe ID is taking a while",
			"Nothing has arrived yet. Close this and try again when you have finished signing in.")

## The player asked to see a QR code, or to put it away.
##
## Asking again after one expired takes this same path. A fresh code wraps the sign-in already
## in flight rather than starting another, so a phone halfway through consenting is not cut
## off by a code running out behind it.
func _on_scan_toggled(revealed: bool) -> void:
	if revealed:
		await _show_scan()
	else:
		await _drop_scan()

func _show_scan() -> void:
	var answer := await Backend.scan_code()

	# The modal can close during that round trip, and a code minted for a modal nobody is
	# looking at any more is a code nobody meant to leave live. Voided rather than left to age
	# out, for the same reason hiding one voids it.
	if not Dialog.visible or answer.has("error"):
		_scan_live = false
		Dialog.hide_code()
		await Backend.void_scan_code()
		return

	var qr: Dictionary = answer.get("qr", {})
	Dialog.show_code(int(qr.get("size", 0)), qr.get("modules", []), float(answer.get("expiresIn", 0)))
	_scan_live = true
	_start_asking(WHILE_OPEN)

func _drop_scan() -> void:
	if not _scan_live:
		return

	_scan_live = false
	_stop_asking()
	Dialog.hide_code()
	await Backend.void_scan_code()

## The world's display name, identical whichever facade was used.
func world_name(key: String) -> String:
	for world: Dictionary in Backend.worlds():
		if world.key == key:
			return String(world.name)
	return key

## Whether a world sits behind a PlaySafe ID door. A fact about the door rather than the
## player, so it is the same for everybody and cannot go stale, which is what makes it safe
## to put on screen. Fails closed on a world this build has never heard of.
func world_requires_playsafe_id(key: String) -> bool:
	for world: Dictionary in Backend.worlds():
		if world.key == key:
			return bool(world.requiresPlaySafeId)
	return true

func portal_url() -> String:
	return String(Backend.config.get("portalUrl", ""))

func _say(state: String, detail: String) -> void:
	state_changed.emit(state, detail)
