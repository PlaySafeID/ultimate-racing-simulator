## The server browser, the second of three facades.
##
## Same three steps as the playlist buttons, different dressing: pick a row, `Join` asks
## for a slot, and the loading text says "Connecting" instead of "Finding a slot". No
## admission logic lives here.
##
## Occupancy is read rather than watched. It is read when this screen opens and when the
## player presses Refresh, with no timer: `GET /worlds` is a cheap read rather than a
## subscription, and the number is a hint about where to go rather than something a
## decision hangs on. Nothing is gated on it.
##
## The table is the whole screen. There is no requirements panel and no standing panel,
## because a real client has nowhere to read a standing from: no response but `POST /play`
## carries one, and that call is the join itself. A world's rules are already in the
## columns.
##
## An empty table is the one thing that greys Join, and it is not a standing. The list
## comes from `GET /config`, so it is empty only where this client never heard of a world,
## which means there is no key to send and nothing for the backend to answer. Greying it
## asserts nothing about the player, where offering a button whose only outcome is silence
## would mislead.
extends Control

const ROW := preload("res://ui/server_row.tscn")

@onready var _hud: Node = %Hud
@onready var _rows: VBoxContainer = %Rows
@onready var _columns: MarginContainer = %HeadPad
@onready var _empty: CenterContainer = %Empty
@onready var _join_server: Button = %JoinServer

## Which row is selected. The first protected world, so the interesting one is under the
## cursor when the screen opens.
var _selected := ""

## Free slots per world, from the last read.
var _free: Dictionary = {}

func _ready() -> void:
	%Back.pressed.connect(_back)
	%Refresh.pressed.connect(_refresh)
	_join_server.pressed.connect(_join)
	_hud.switched.connect(_refresh)

	await _refresh()

func _refresh() -> void:
	for entry: Dictionary in await Backend.occupancy():
		_free[String(entry.key)] = int(entry.capacity) - int(entry.occupancy)

	_build()

func _build() -> void:
	for child in _rows.get_children():
		child.queue_free()

	var worlds := Backend.worlds()

	# Nothing to list, which in practice is a backend that was unreachable at boot: the
	# worlds arrive with `GET /config` and nothing re-reads it here. The column heads go
	# with the rows, since a heading over nothing describes nothing.
	_columns.visible = not worlds.is_empty()
	_empty.visible = worlds.is_empty()
	_join_server.disabled = worlds.is_empty()

	if _selected == "" and not worlds.is_empty():
		_selected = String(worlds[0].key)
		for world: Dictionary in worlds:
			if bool(world.requiresPlaySafeId):
				_selected = String(world.key)
				break

	var group := ButtonGroup.new()

	for world: Dictionary in worlds:
		var free: int = _free.get(String(world.key), int(world.capacity))

		var row := ROW.instantiate()
		_rows.add_child(row)
		row.fill(world, free)
		row.button_group = group
		row.button_pressed = row.key == _selected
		row.pressed.connect(_pick.bind(String(world.key)))

func _pick(key: String) -> void:
	_selected = key

func _join() -> void:
	if _selected != "":
		Join.enter(_selected, "browser")

func _back() -> void:
	get_tree().change_scene_to_file("res://screens/main_menu.tscn")
