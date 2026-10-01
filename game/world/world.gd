## The shared world. One scene, two roles, so the two sides cannot drift apart.
##
##   server   an exported dedicated-server build, which arrives here on its own
##            from the editor: godot --headless res://world/world.tscn -- --server
##   client   entered from any front door, once a ticket has been issued
##
## The game server receives a ticket and trades it for a display name and, where the deployment
## sets a session ceiling, a kick time. That is all. It never sees a PSID, never sees a standing,
## and never asks whether a player may be here, because that was settled before the ticket
## existed. So this file contains no PlaySafe ID logic at all.
##
## The backend hands out one address for all three worlds, so this process holds all three. They
## are kept apart by visibility: a player is replicated only to peers who redeemed a ticket for
## the same world. Two players in different worlds share the room's coordinates and can neither
## see nor touch one another.
extends Node3D

const PORT := 8211
const PLAYER := preload("res://world/player.tscn")

## Where each arrival stands: one slot per place the world holds, side by side in a line and all
## turned to the sign wall. The window is then over their left shoulder.
##
## As many slots as the world has capacity for, so a slot is always free and an arrival never has
## to share one. A departure gives its slot back, and the next arrival takes the lowest that
## nobody is standing in.
const SPAWN_SLOTS := 10
const SPAWN_SPACING := 2.2
const SPAWN_LINE := 4.0

## How long a peer has to present a ticket before it is dropped. A connection that
## never presents one is not a player.
const HANDSHAKE_SECONDS := 10.0

## How long a peer being sent away is given to hear why before the connection closes.
const GOODBYE_SECONDS := 1.0

@onready var _backend: BackendClient = $BackendClient
@onready var _worlds: Node3D = $Worlds
@onready var _traffic: Node3D = $Traffic
@onready var _hud: CanvasLayer = $Hud
@onready var _title: Label = %WorldTitle
@onready var _note: Label = %WorldNote
@onready var _pause: Control = %Pause

var _role := "client"

## Server side, per peer: the world they redeemed for, their ticket, and when they go.
var _world_of: Dictionary = {}
var _ticket_of: Dictionary = {}
var _kick_at: Dictionary = {}
var _presented_by: Dictionary = {}

## Server side, per peer: display name, broadcast whole so a late arrival gets everyone.
var _names: Dictionary = {}

func _ready() -> void:
	_role = "server" if _is_server() else "client"
	if _role == "server":
		_hud.visible = false

		# The traffic outside the window is for somebody to look at, and the server has no
		# camera. Freed rather than hidden, so it is not a field's worth of transforms every
		# frame for nobody.
		_traffic.queue_free()

		_host()
		return

	%Leave.pressed.connect(_on_leave_pressed)
	%Resume.pressed.connect(_on_resume_pressed)
	_pause.visible = false
	_enter()

# The server side.

## Two ways to be the server, because the two builds arrive differently.
##
## An exported dedicated server carries the feature tag its export preset set, so it
## recognises itself and needs no arguments at all. The editor carries no such tag, and
## an export template ignores `--scene` silently, so a run from the editor names the
## scene and passes `--server` instead. Neither can stand in for the other.
func _is_server() -> bool:
	return OS.has_feature("dedicated_server") or OS.get_cmdline_user_args().has("--server")

func _host() -> void:
	if not _backend.configured():
		push_error("[world] GAME_BACKEND_URL or GAME_SERVER_KEY is unset, so every ticket will be refused")
	else:
		# Before listening, so it can only drop players the previous process held.
		await _backend.reset()

	var peer := WebSocketMultiplayerPeer.new()
	var error := peer.create_server(PORT)
	if error != OK:
		push_error("[world] cannot listen on %d: %s" % [PORT, error_string(error)])
		return

	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_peer_arrived)
	multiplayer.peer_disconnected.connect(_peer_left)
	print("[world] listening on %d" % PORT)

func _peer_arrived(id: int) -> void:
	_presented_by[id] = Time.get_ticks_msec() + HANDSHAKE_SECONDS * 1000.0

## A player presenting the ticket the backend issued them.
##
## Redeemed here, once. The display name comes back from the backend rather than from
## the client, so a player cannot choose what others see it called, and a replayed or
## expired ticket is refused and the connection dropped.
@rpc("any_peer", "call_remote", "reliable")
func present(ticket: String) -> void:
	if _role != "server":
		return

	var id := multiplayer.get_remote_sender_id()
	if _world_of.has(id):
		return

	var redeemed := await _backend.redeem(ticket)
	if redeemed.has("error"):
		print("[world] peer %d refused: %s" % [id, redeemed.error])
		_send_away(id, String(redeemed.error))
		return

	var world := String(redeemed.world)
	_world_of[id] = world
	_ticket_of[id] = ticket
	_names[id] = String(redeemed.displayName)
	_presented_by.erase(id)

	# A kick time only where the backend named one. Where it did not, this deployment has no
	# ceiling, so no entry is recorded and nothing below removes them. The value is UTC with a
	# `Z`, the basis `Time.get_unix_time_from_system()` reads in, so the two are comparable
	# without converting either.
	if redeemed.get("kickAt") != null:
		_kick_at[id] = Time.get_unix_time_from_datetime_string(String(redeemed.kickAt))

	_spawn(id, world)
	_send_rosters()
	print("[world] peer %d joined %s as %s" % [id, world, _names[id]])

## The body, placed into its own world's container so the matching spawner replicates
## it, and filtered so only peers in that world ever receive it.
func _spawn(id: int, world: String) -> void:
	var container: Node3D = _worlds.get_node(world)

	var body := PLAYER.instantiate()
	body.name = str(id)

	body.slot = _free_slot(container)

	var across := (float(body.slot) - float(SPAWN_SLOTS - 1) * 0.5) * SPAWN_SPACING
	var spawn := Vector3(SPAWN_LINE, 0.9, across)

	# A quarter turn, because a body's forward is its own negative Z and the sign wall is at
	# positive X. Sent rather than left to replicate, for the reason below.
	var facing := -PI * 0.5
	body.position = spawn
	body.rotation.y = facing

	# The filter runs per peer, on the server, and is what keeps the worlds apart. It goes on
	# `Presence` rather than `Motion`, and that distinction is the whole of the separation: a
	# synchroniser's visibility is consulted only on the peer that is its authority, and `Motion`
	# belongs to the arriving client, so the server's opinion of it is never asked. `Presence`
	# stays with the server, the only party that knows which world anybody redeemed for.
	var presence: MultiplayerSynchronizer = body.get_node("Presence")
	presence.add_visibility_filter(_shares_world.bind(world))

	container.add_child(body, true)

	# The spawn point has to be sent, not set and left to replicate. A synchroniser applies only
	# state arriving from the node's authority, and the authority here is the arriving client, so
	# it would ignore the server's value and then overwrite it.
	body.place.rpc_id(id, spawn, facing)

## The lowest slot in this world that nobody is standing in.
##
## Read off the bodies rather than counted, because a count is wrong the moment somebody
## leaves: with three players and the middle one gone, a count of two would put the next
## arrival inside the player already standing in slot two.
func _free_slot(container: Node3D) -> int:
	var taken: Dictionary = {}
	for body: Node in container.get_children():
		taken[int(body.slot)] = true

	for slot in SPAWN_SLOTS:
		if not taken.has(slot):
			return slot
	return 0

func _shares_world(peer: int, world: String) -> bool:
	return _world_of.get(peer, "") == world

## The roster, sent one peer at a time and holding only that peer's own world.
##
## Not broadcast whole. A player in one world has no business learning who is in another, and a
## client sends its own movement to the peers it knows about, so a client that had heard the whole
## roster would post its position into worlds it is not in.
func _send_rosters() -> void:
	for id: int in _world_of.keys():
		tags.rpc_id(id, _roster_for(String(_world_of[id])))

func _roster_for(world: String) -> Dictionary:
	var roster: Dictionary = {}
	for id: int in _names.keys():
		if _world_of.get(id, "") == world:
			roster[id] = _names[id]
	return roster

func _peer_left(id: int) -> void:
	var body := _body_for(id)
	if body:
		body.queue_free()

	# What frees the slot, so it runs on every exit path.
	if _ticket_of.has(id):
		await _backend.leave(String(_ticket_of[id]))

	_world_of.erase(id)
	_ticket_of.erase(id)
	_kick_at.erase(id)
	_presented_by.erase(id)
	_names.erase(id)
	_send_rosters()

func _body_for(id: int) -> Node:
	for container: Node3D in _worlds.get_children():
		var body := container.get_node_or_null(str(id))
		if body:
			return body
	return null

## Tells a peer why it is being removed, then closes the connection once the reason has had
## time to land. Closing in the same frame can beat the message to the client, which then
## reports only that the connection closed, and a ceiling looks the same as a crash.
func _send_away(id: int, why: String) -> void:
	_turn_away.rpc_id(id, why)
	await get_tree().create_timer(GOODBYE_SECONDS).timeout
	_drop(id)

## A peer told why it was going usually hangs up first, so it may already be gone.
func _drop(id: int) -> void:
	if not multiplayer.get_peers().has(id):
		return
	if multiplayer.multiplayer_peer is WebSocketMultiplayerPeer:
		(multiplayer.multiplayer_peer as WebSocketMultiplayerPeer).disconnect_peer(id)

## The session ceiling, enforced here because the backend cannot reach into a live
## connection. Where a deployment sets one it is the only bound on how long a player
## banned mid-session lingers, which is why a standing can be checked once and not
## again. Where it sets none this list is empty and nobody is removed by a clock.
func _process(_delta: float) -> void:
	if _role != "server":
		return

	var now := Time.get_unix_time_from_system()
	for id: int in _kick_at.keys():
		if now >= float(_kick_at[id]):
			print("[world] peer %d reached its session ceiling" % id)
			_kick_at.erase(id)
			_send_away(id, "Sessions on this demo are time-limited, and yours has ended.")

	var ticks := Time.get_ticks_msec()
	for id: int in _presented_by.keys():
		if ticks >= float(_presented_by[id]):
			print("[world] peer %d never presented a ticket" % id)
			_drop(id)

# The client side.

func _enter() -> void:
	if Join.held.is_empty():
		_leave_to_menu()
		return

	_title.text = Join.world_name(Join.held_world())
	_note.text = "Connecting"

	# The shield on the sign wall describes the door this world is behind, which is static and
	# the same for everybody in here. It says nothing about the player: their standing was
	# settled by the backend before the ticket existed, and a badge in a world could only show a
	# value that had already gone stale.
	%Shield.visible = Join.world_requires_playsafe_id(Join.held_world())

	# Whichever spawner the server used, the arrival of my own body is the moment to decide who
	# it may be reported to.
	for spawner: MultiplayerSpawner in [$SpawnOpen, $SpawnProtected, $SpawnMinor]:
		spawner.spawned.connect(_body_appeared)

	# The backend hands over the whole address, scheme included, and this dials it as given. The
	# scheme describes how the deployment is served rather than anything about the game: a page
	# loaded over HTTPS may only open `wss://`, and a browser refuses `ws://` from one as mixed
	# content. Assembling the URL here would bake that decision into an export.
	var server: Dictionary = Join.held.get("server", {})
	var url := String(server.get("url", "ws://localhost:%d" % PORT))

	var peer := WebSocketMultiplayerPeer.new()
	var error := peer.create_client(url)
	if error != OK:
		_fell_out("Could not reach the game server at %s." % url)
		return

	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(_connected)
	multiplayer.connection_failed.connect(_fell_out.bind("The game server refused the connection."))
	multiplayer.server_disconnected.connect(_hung_up)

## Connected, so present the ticket. This is the client's whole half of the handshake.
func _connected() -> void:
	_note.text = "Presenting your ticket"
	present.rpc_id(1, String(Join.held.get("ticket", "")))
	# No "click to look": the click that got the player here usually counts as the gesture. Escape
	# is named because it is the key a player reaches for, and M is bound too and is the one that
	# always arrives.
	_note.text = "WASD to walk  ·  ESC for the menu"

	# Asked for, not assumed. A browser grants the pointer lock only in response to a gesture, so
	# this succeeds when the click that got us here still counts as one and otherwise waits for
	# the player to click in the world.
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

## This world's display names, whole, so a late arrival learns the names already here.
##
## `call_remote`, because the server holds the real roster and a per-world subset
## arriving back would overwrite it with one world's worth.
@rpc("authority", "call_remote", "reliable")
func tags(names: Dictionary) -> void:
	_names = names
	for container: Node3D in _worlds.get_children():
		for body: Node in container.get_children():
			var id := body.name.to_int()
			if names.has(id):
				body.set_tag(String(names[id]))

	_aim_my_reports()

## My own body reports its position to the peers the server has named, and to nobody else.
##
## Necessary because the body is client-authoritative, and an authority sends to every
## peer it can see. The server's filter cannot help here: it is not the authority of
## `Motion`, so its opinion of who may receive that state is never asked. Without this a
## player in one world posts their position into all three, where it arrives as an error
## about a body those peers were correctly never told about.
##
## `Motion` therefore starts visible to nobody, in the scene rather than from here, and peers are
## named one at a time as the roster says so. Starting open and closing it afterwards would be too
## late: the engine sets up its path to a peer the moment it first believes it may send.
func _aim_my_reports() -> void:
	var mine := _body_for(multiplayer.get_unique_id())
	if mine == null:
		return

	var motion: MultiplayerSynchronizer = mine.get_node("Motion")
	for peer: int in multiplayer.get_peers():
		motion.set_visibility_for(peer, _names.has(peer))

## A body arriving here. The name and the body it belongs to travel separately, and
## either can arrive first, so each is applied from both sides and whichever is second
## is the one holding both halves.
##
## The bodies already standing in the world when this peer arrived are what make that
## necessary. One of them becomes visible to a new peer only when the server's
## `Presence` filter is next re-evaluated, which is a frame or more after the roster
## naming it was sent, so the roster reached a world this body was not in yet.
func _body_appeared(body: Node) -> void:
	var id := body.name.to_int()
	if _names.has(id):
		body.set_tag(String(_names[id]))

	if id == multiplayer.get_unique_id():
		_aim_my_reports()

## The server declining to keep us: a spent ticket, or the session ceiling.
@rpc("authority", "call_remote", "reliable")
func _turn_away(why: String) -> void:
	_fell_out(why)

func _hung_up() -> void:
	_fell_out("The game server closed the connection.")

var _falling_out := false

## Being removed from the world by something other than the player: a ticket that would
## not redeem, the session ceiling, or the server going away.
##
## This one keeps a modal, and only this one. Leaving on purpose gets none, since the player knows
## what they did, but being ejected without being told why reads as a bug.
func _fell_out(why: String) -> void:
	if _falling_out:
		return
	_falling_out = true

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Join.forget()
	_leave_to_menu()

	await Dialog.open({
		"head": "Removed from the world",
		"body": [why],
		"cancel": "Close",
	})

func _unhandled_input(event: InputEvent) -> void:
	if _role == "server":
		return

	# M as well as Escape, and M is the one to rely on. In a browser Escape is spoken for: it
	# releases the pointer lock and leaves fullscreen, and the page may never see the key. So a
	# player whose mouse has come free reaches the menu with M, and takes the mouse back by
	# clicking, below.
	if event.is_action_pressed("toggle_menu"):
		_show_pause(not _pause.visible)
		return

	# Clicking back into the world takes the mouse again, which a browser grants only in response
	# to a gesture.
	if event is InputEventMouseButton and not _pause.visible:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _show_pause(shown: bool) -> void:
	_pause.visible = shown
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if shown else Input.MOUSE_MODE_CAPTURED

func _on_resume_pressed() -> void:
	_pause.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _on_leave_pressed() -> void:
	# Claims the exit, so closing the connection below cannot come back as an involuntary one and
	# put a modal on the menu the player just asked for.
	_falling_out = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# Closing the connection tells the server, which tells the backend, which frees the slot.
	# Cancelling from here as well would be a call about a ticket the game server is already in
	# the middle of returning.
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()

	Join.forget()
	_leave_to_menu()

## Deferred, because a scene cannot be swapped while the tree is still building this
## one, which is exactly when the no-ticket guard fires.
func _leave_to_menu() -> void:
	get_tree().change_scene_to_file.call_deferred("res://screens/main_menu.tscn")
