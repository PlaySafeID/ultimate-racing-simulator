## The screen the game opens on. There is no login screen anywhere.
##
## A facade, one of three. It does not matchmake. Play Casual and Play Ranked are playlist
## buttons that ask `Join` for a slot in a world, exactly as the server browser and
## character select do, and all this screen contributes is which world and which loading
## copy. Admission, refusals, slots and sign-in live in `autoload/join.gd`; the header and
## the account switcher live in `ui/hud.tscn`.
##
## Three things it does not do:
##
## No button is ever disabled or greyed out, on any standing. Disabling one would assert
## live knowledge this client does not have, since a standing is stale the moment it is
## written, so a greyed-out Play Ranked would hide a ban that had been lifted or admit one
## that had just landed. Clicking a gated action is also how a player finds out what
## PlaySafe ID is.
##
## Neither button says anything about the player: not a standing, and not even whether a
## PSID is held. The shield on Play Ranked describes the door, which is static and true
## for everybody. A button reporting the player's state would invite reading it as
## permission, and the only thing that grants permission is the backend answering a click.
##
## A held slot does lock the other playlist. A held ticket is a fact this client owns, so
## that lock is certain where a status lock would be a guess, and it still stops short of
## disabling the button.
extends Control

## The published API documentation. The only outbound link on this screen, and the only
## thing on it a player is not the audience for.
const DOCS := "https://docs.playsafeid.com/"

@onready var _hud: Node = %Hud
@onready var _slots: Label = %Slots
@onready var _linked: Label = %Linked
@onready var _state: Label = %State
@onready var _detail: Label = %Detail
@onready var _build: Label = %Build

func _ready() -> void:
	# A dedicated server runs this same build and has to reach the world instead, so the
	# role is decided at the entry point. It cannot be decided by a scene path: `--scene`
	# is editor-only and an export template ignores it silently, so a server started that
	# way would sit on the menu with no error to explain why.
	#
	# The feature tag comes from the `Server` export preset and exists only in an exported
	# build, which is why `world.gd` still honours `--server` for a run from the editor.
	# The branch is first so a server never runs the menu's `GET /config` and
	# `POST /session`: it holds no session and needs neither. Deferred because the tree is
	# still adding this scene, so swapping it out in the same frame is refused.
	if OS.has_feature("dedicated_server"):
		get_tree().change_scene_to_file.call_deferred("res://world/world.tscn")
		return

	%PlayCasual.pressed.connect(Join.enter.bind("open", "playlist"))
	%PlayRanked.pressed.connect(Join.enter.bind("protected", "playlist"))
	%BrowseServers.pressed.connect(_go.bind("res://screens/server_browser.tscn"))
	%CharacterSelect.pressed.connect(_go.bind("res://screens/character_select.tscn"))
	%ReadDocs.pressed.connect(OS.shell_open.bind(DOCS))

	Join.state_changed.connect(_say)
	Join.slot_changed.connect(_paint)
	_hud.switched.connect(_paint)

	# Before the first frame is drawn, so the placeholder the label carries for the
	# editor's sake is never on screen. A screen change and back needs nothing more than
	# this, since the tag is held by the `Backend` autoload rather than by this scene.
	_stamp()

	await _boot()

## One `GET /config` and one `POST /session`. In the public build that is the whole of the
## network traffic until somebody clicks something gated.
##
## Guarded, because a screen change and back runs `_ready()` again and the session is held
## by the `Backend` autoload rather than by this scene.
func _boot() -> void:
	if Backend.has_session():
		_hud.refresh()
		_paint()
		_say("Idle", "Pick a playlist to start")
		return

	await Backend.resolve()
	_stamp()

	var config := await Backend.load_config()
	if config.has("error"):
		_say("Backend unreachable", config.error)
		return

	# No name is sent, so the backend assigns one. Two tabs then show two different players
	# in a lobby rather than two called the same thing, and nothing here is player-authored,
	# which a demo with no moderation should avoid.
	var session := await Backend.start_session("")
	if session.has("error"):
		_say("Backend refused a session", session.error)
		return

	_hud.refresh()
	_paint()
	_say("Idle", "Pick a playlist to start")

## The two playlist buttons, painted from facts this client owns and nothing else.
##
## No slot count here: a number beside Play Casual reads as something a player should
## weigh, and there is nothing to weigh. Capacity is a ceiling, a lobby is effectively
## never full, and occupancy is worth showing only on the screen whose subject is picking
## a server.
func _paint() -> void:
	_slots.text = "Release slot" if Join.holds("open") else ""
	_linked.text = "Release slot" if Join.holds("protected") else ""

## The commit this bundle was built from, in the corner.
##
## It answers one question a deployment asks of itself: is the build I rolled out the one
## being served? So the value is baked into the client image rather than supplied by
## whatever deploys it, and it arrives from beside the bundle rather than through the
## backend, so it still reads when the backend is unreachable.
##
## Hidden when there is none: a static host with no `build` in its `backend.json`, or an
## exported build nobody stamped. A run from the editor reads `editor` instead, because
## there the absence is worth saying.
func _stamp() -> void:
	var tag := Backend.build_tag()
	_build.text = tag
	_build.visible = tag != ""

func _go(path: String) -> void:
	get_tree().change_scene_to_file(path)

## The state line is upper-cased here rather than at the call sites, so every caller writes
## ordinary prose and the shouting stays a presentation decision.
func _say(state: String, detail: String) -> void:
	_state.text = state.to_upper()
	_detail.text = detail
