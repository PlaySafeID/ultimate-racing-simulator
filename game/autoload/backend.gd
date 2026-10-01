## Every call this client makes, in one place. Nothing else in the game speaks HTTP.
##
## It talks only to the game's own backend, never to PlaySafe ID. There is no client id
## here, no client secret, and no authorisation code: a sign-in is a URL the backend hands
## over and the browser opens.
##
## It holds the session token, and whether a PSID is stored, because that is a fact the
## client owns and it never goes stale. It does not keep a standing. `admit()` returns one
## and the caller acts on it there and then; there is no field to cache it in, so no screen
## can gate on a stale one.
extends Node

## The session was created, cleared, or re-read, so anything showing identity should
## repaint. Emitted rather than polled, because a session changes on a sign-in landing or a
## ceiling expiring, and neither of those is a click any screen saw.
signal session_changed()

## Everything `GET /config` said, fetched once at boot. Worlds, ceiling, presets.
var config: Dictionary = {}

## The current session, from `POST /session` or `GET /player`. Never a standing.
var player: Dictionary = {}

var _token := ""

## Where the backend lives. Resolved once, at boot, before anything else runs.
var _base := "http://localhost:8080"

## The commit this bundle was built from, if whatever serves it says so. Empty otherwise.
var _build := ""

## Finds the backend without anything being baked into the export.
##
## Three sources, in order: a `?backend=` query parameter for a one-off, then
## `backend.json` served from the client's own origin, then the origin itself for a
## deployment that serves both from one host.
##
## A static bundle has to learn this address from somewhere. It cannot come from the
## backend's own environment, because the client never reads that, and compiling it in
## would mean a hostname change needs a new client build. So it arrives from a file beside
## the bundle, one hop before `GET /config` supplies everything else. That same file
## carries the build stamp, which is why it is read even when the address comes from
## somewhere else.
func resolve() -> void:
	if not OS.has_feature("web"):
		return

	var origin: Variant = JavaScriptBridge.eval("window.location.origin", true)
	_base = origin if origin is String else _base

	# Read beside the bundle first, whatever the address turns out to be. The build stamp
	# describes the files that were served, so it comes from the origin that served them:
	# a `?backend=` override changes where this client looks for a backend and says nothing
	# about which bundle is running.
	var beside := await _call(HTTPClient.METHOD_GET, "/backend.json")
	_build = String(beside.get("build", ""))

	var query: Variant = JavaScriptBridge.eval(
		"new URLSearchParams(window.location.search).get('backend') || ''", true)
	if query is String and query != "":
		_base = query
		print("[backend] %s, from the query string" % _base)
		return

	if beside.has("backend"):
		_base = String(beside.backend)
		print("[backend] %s, from backend.json" % _base)
		return

	print("[backend] %s, the origin this was served from" % _base)

## The commit this bundle was built from, for the stamp in the menu's corner. It is the one
## fact that tells a deployed game apart from the one it replaced. Empty where nothing
## said, so a caller shows nothing rather than guessing.
##
## A run from the editor reads `editor` instead. The working tree is not a build of
## anything, and naming the commit it happens to sit on would put a value in the corner
## that looks exactly like a deployed one.
func build_tag() -> String:
	if _build == "" and OS.has_feature("editor"):
		return "editor"
	return _build

## True once a session exists. Nothing gated should be attempted before it does.
func has_session() -> bool:
	return _token != ""

## Whether a PSID is stored for this player.
##
## Safe to put on screen, and what gives a returning player the feel of being known. It is
## not a standing and says nothing about whether they may play, so it is shown where it
## describes an account, on the demo badge and the driver rows, and never on a button where
## it would read as permission.
func has_playsafe_id() -> bool:
	return player.get("psid") != null

## The static shape: worlds, the session ceiling, and the preset list. No auth.
func load_config() -> Dictionary:
	var answer := await _call(HTTPClient.METHOD_GET, "/config")
	if not answer.has("error"):
		config = answer
	return answer

## The worlds this deployment offers, in the order they should be listed.
func worlds() -> Array:
	return config.get("worlds", [])

## True in the demo build, the only build with preset accounts or a badge.
func is_demo() -> bool:
	return config.get("environment", "") == "demo"

## Whether signing in on a phone is worth offering, which the backend decides.
##
## False against a local deployment, where the QR and the callback after it are reachable
## from this machine and nowhere else. The client cannot work that out for itself: it knows
## the backend's address but not whether a phone could reach it.
func can_scan() -> bool:
	return bool(config.get("scannable", false))

## Creates the session. Runs at boot, because there is no login screen.
##
## `preset_id` is accepted by the demo build only and refused with a 400 in public.
## Switching preset is `sign_out()` then this again, never a swap in place: a swap would
## leave a ticket and a world membership attached to an identity that never earned entry.
func start_session(display_name: String, preset_id := "") -> Dictionary:
	var body := { "displayName": display_name }
	if preset_id != "":
		body["presetId"] = preset_id

	var answer := await _call(HTTPClient.METHOD_POST, "/session", body)
	if answer.has("error"):
		return answer

	_token = String(answer.get("token", ""))
	player = answer
	session_changed.emit()
	return answer

## Re-reads identity, and the poll target while a sign-in is in flight.
##
## Cheap by construction: with no PSID stored the backend touches PlaySafe ID not at all,
## so polling this costs nothing until the moment it succeeds.
func refresh_player() -> Dictionary:
	var answer := await _call(HTTPClient.METHOD_GET, "/player")
	if not answer.has("error"):
		player = answer
		session_changed.emit()
	return answer

## Asks to enter a world. The only call that returns a standing.
##
## Both outcomes arrive as `200`, because "may I play?" is a question with answers rather
## than an operation that fails, which keeps every outcome on one code path. Answers
## `{ admitted: true, ticket, server, kickAt }` or `{ admitted: false, reason, ageBand }`.
##
## Call it on the click, every time. Never cache what it says, and never disable a button
## because of what it said last time.
func admit(world: String) -> Dictionary:
	return await _call(HTTPClient.METHOD_POST, "/play", { "world": world })

## Gives up a held ticket and frees the slot, without ending the session.
##
## A ticket holds a slot the moment it is issued, so leaving a queue has to say so rather
## than letting it age out. Distinct from `sign_out()`, which ends the whole session, and
## from the game server reporting a disconnection.
func cancel() -> void:
	await _call(HTTPClient.METHOD_POST, "/cancel", {})

## Live occupancy, one entry per world. Worth polling only while it is on screen.
func occupancy() -> Array:
	var answer := await _call(HTTPClient.METHOD_GET, "/worlds")
	return answer.get("list", [])

## Starts a sign-in and returns the URL for the player's browser.
func sign_in_url() -> String:
	var answer := await _call(HTTPClient.METHOD_POST, "/playsafe/sign-in", {})
	return String(answer.get("authorisationUrl", ""))

## Asks for a QR code, so the player can finish the sign-in on their phone.
##
## Answers `{ qr: { size, modules }, expiresIn, signInExpiresIn }`. The code is the
## short-lived part and `signInExpiresIn` is the sign-in behind it, which outlives several
## codes: asking again refreshes the code without restarting the sign-in.
func scan_code() -> Dictionary:
	return await _call(HTTPClient.METHOD_POST, "/playsafe/scan", {})

## Voids the code, for a player who put it away. Not left to expire on its own, because the
## reason a player hides a code is that they did not mean to show it.
func void_scan_code() -> void:
	await _call(HTTPClient.METHOD_POST, "/playsafe/scan/void", {})

## Drops the local session without telling the backend, for when the backend has already
## said the session is gone. Calling `sign_out()` there would be a logout against a token
## that no longer authenticates anything.
func forget_session() -> void:
	_token = ""
	player = {}
	session_changed.emit()

## Ends the session, frees the slot and voids the ticket.
func sign_out() -> void:
	if _token == "":
		return
	await _call(HTTPClient.METHOD_POST, "/logout", {})
	_token = ""
	player = {}
	session_changed.emit()

## One request, one dictionary back.
##
## A failure comes back as `{ error: ..., status: ... }` rather than as an exception, so a
## caller has one shape to handle. It is not one of the nine refusal reasons and must not be
## reported as one: those are answers this backend gave, and this is this backend not
## answering.
func _call(method: int, path: String, body: Variant = null) -> Dictionary:
	var request := HTTPRequest.new()
	add_child(request)

	var headers: PackedStringArray = []
	if _token != "":
		headers.append("Authorization: Bearer %s" % _token)
	if body != null:
		headers.append("Content-Type: application/json")

	var error := request.request(
		_base + path, headers, method, "" if body == null else JSON.stringify(body))
	if error != OK:
		request.queue_free()
		return { "error": "could not reach the backend: %s" % error_string(error), "status": 0 }

	var result: Array = await request.request_completed
	request.queue_free()

	var code := int(result[1])
	var text := (result[3] as PackedByteArray).get_string_from_utf8()

	# `status` rides along with every failure, because a caller has to tell two different
	# things apart: this backend not answering at all, and this backend answering that the
	# session is gone. A `0` means nothing answered.
	if code == 0:
		return { "error": "no answer from %s" % _base, "status": 0 }
	if text == "":
		return {} if code < 400 else { "error": "HTTP %d" % code, "status": code }

	var parsed: Variant = JSON.parse_string(text)
	if parsed is Array:
		return { "list": parsed }
	if not parsed is Dictionary:
		return { "error": "unreadable answer from %s%s" % [_base, path], "status": code }

	var answer: Dictionary = parsed
	if code >= 400:
		answer["status"] = code
		if not answer.has("error"):
			answer["error"] = "HTTP %d" % code
	return answer
