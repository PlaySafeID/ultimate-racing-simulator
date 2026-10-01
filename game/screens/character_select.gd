## Character select, the third of three facades.
##
## It restores nothing. There are no saved characters and no server call for any of it:
## the drivers are fiction, and the screen exists because a great many games put a roster
## here and a partner should see where PlaySafe ID sits when they do.
##
## A driver belongs to the realm it was created in. Some of these were made in a PlaySafe
## ID realm and some were not, and the shield says which. Loading a PlaySafe ID driver
## runs the gate; loading one of the others makes no PlaySafe ID call at all.
##
## So a player whose standing has since gone bad can still play, just not as those
## drivers. The realm is a property of the character and the standing is a property of the
## account, and entry needs both. Which driver is highlighted changes nothing about
## admission; the realm it lives in changes everything.
extends Control

const ROW := preload("res://ui/driver_row.tscn")

## Fiction, and mixed on purpose so the two kinds are not neatly grouped. `world` is the
## realm the driver was created in, and it is the only field here that does anything.
const DRIVERS := [
	{ "name": "Marchetti", "detail": "Formula  ·  Tier 4", "world": "protected" },
	{ "name": "Okonkwo", "detail": "Rally  ·  Tier 2", "world": "open" },
	{ "name": "Vasquez", "detail": "Touring  ·  Tier 1", "world": "protected" },
]

@onready var _hud: Node = %Hud
@onready var _rows: VBoxContainer = %Rows
@onready var _chosen: Label = %Chosen
@onready var _realm: TextureRect = %Realm

var _selected := 0

func _ready() -> void:
	%Back.pressed.connect(_back)
	%Play.pressed.connect(_play)
	_hud.switched.connect(_build)

	_build()

func _build() -> void:
	for child in _rows.get_children():
		child.queue_free()

	var group := ButtonGroup.new()
	for index in DRIVERS.size():
		var driver: Dictionary = DRIVERS[index]
		var row := ROW.instantiate()
		_rows.add_child(row)
		row.fill(String(driver.name), String(driver.detail), String(driver.world) != "open")
		row.button_group = group
		row.button_pressed = index == _selected
		row.pressed.connect(_pick.bind(index))

	_describe()

func _pick(index: int) -> void:
	_selected = index
	_describe()

## The mark under the name repeats what the list already says, where the player is
## looking. The row keeps its height either way, so the name does not shift as the
## selection moves between the two kinds.
func _describe() -> void:
	var driver: Dictionary = DRIVERS[_selected]
	_chosen.text = String(driver.name)
	_realm.visible = String(driver.world) != "open"

## Into the realm this driver belongs to.
##
## The same `Join.enter` the other two doors call, so a PlaySafe ID driver hits the same
## nine refusals and a driver from the open realm never troubles PlaySafe ID.
func _play() -> void:
	Join.enter(String(DRIVERS[_selected].world), "character")

func _back() -> void:
	get_tree().change_scene_to_file("res://screens/main_menu.tscn")
