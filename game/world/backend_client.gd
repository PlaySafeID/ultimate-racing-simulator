## The game server's only conversation with the game backend. Three calls.
##
## Everything a game server needs to know about a player arrives through here, and it is
## almost nothing: a display name and a kick time. No PSID reaches this process, and neither
## does a standing. Whether the player may play was answered before the ticket was issued.
##
## This process is the one exposed to the internet on a game port, and it holds no PlaySafe ID
## credential of any kind. Its only secret is `GAME_SERVER_KEY`, issued by the game backend to
## itself, granting nothing but these three calls.
##
## The key arrives in the environment rather than on the command line, which is readable by
## any other process on the host.
class_name BackendClient
extends Node

var _base := ""
var _key := ""

## True when this process was given what it needs to talk to the backend. A game
## server without it can still run, and refuses everybody, which is the safe failure.
func configured() -> bool:
	return _base != "" and _key != ""

## Read for both roles and used by only one. A player's client runs this scene too and is
## given neither value, because a client has no business holding the key that redeems tickets.
func _ready() -> void:
	_base = OS.get_environment("GAME_BACKEND_URL")
	_key = OS.get_environment("GAME_SERVER_KEY")

## Presents a ticket a player arrived with. Single use, so a replayed ticket is
## refused and the player is dropped.
##
## Answers `{ playerId, displayName, world, kickAt }` or `{ error: ... }`, where `kickAt` is
## `null` on a deployment with no session ceiling. The display name comes back from here rather
## than from the player, so a client cannot choose what other players see it called.
func redeem(ticket: String) -> Dictionary:
	return await _call("/match/redeem", { "ticket": ticket })

## Reports a departure, by disconnection or by a local kick. This is what frees the
## slot, so it runs on every exit path.
func leave(ticket: String) -> void:
	await _call("/match/leave", { "ticket": ticket })

## Reports a fresh start, once, before anyone can connect. A previous process that stopped
## without reporting its players left their slots held, and this is what frees them.
func reset() -> void:
	var answer := await _call("/match/reset", {})
	if answer.has("error"):
		push_warning("[world] could not free slots held from before this start: %s" % answer.error)

func _call(path: String, body: Dictionary) -> Dictionary:
	if not configured():
		return { "error": "the game server is not configured to reach the backend" }

	var request := HTTPRequest.new()
	add_child(request)

	var headers: PackedStringArray = [
		"Content-Type: application/json",
		"X-Game-Server-Key: %s" % _key,
	]

	var error := request.request(_base + path, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if error != OK:
		request.queue_free()
		return { "error": "could not reach the backend: %s" % error_string(error) }

	var result: Array = await request.request_completed
	request.queue_free()

	var code := int(result[1])
	var text := (result[3] as PackedByteArray).get_string_from_utf8()

	if code == 204:
		return {}
	if text == "":
		return {} if code < 400 else { "error": "HTTP %d" % code }

	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		return { "error": "unreadable answer from %s" % path }

	var answer: Dictionary = parsed
	if code >= 400 and not answer.has("error"):
		answer["error"] = "HTTP %d" % code
	return answer
