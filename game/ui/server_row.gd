## One row of the server browser. A scene rather than something a script draws, so the
## table's look is edited in the editor like everything else.
##
## Four columns. The server's name says nothing about its rules: a player reads what it
## requires from the columns, the way they would read a region or an anti-cheat flag in
## any other browser.
extends Button

## The world this row stands for, so the screen can ask what was selected.
var key := ""

@onready var _name: Label = %Name
@onready var _shield: TextureRect = %Shield
@onready var _unprotected: Label = %Unprotected
@onready var _under_eighteen: TextureRect = %UnderEighteen
@onready var _over_eighteen: TextureRect = %OverEighteen
@onready var _any_age: Label = %AnyAge
@onready var _players: Label = %Players

## `world` is a `GET /config` entry and `free` is the count from the last read.
##
## Every fact here comes from the world's definition rather than from the player, so a
## row looks the same to everybody. Nothing on it is derived from a standing.
func fill(world: Dictionary, free: int) -> void:
	key = String(world.key)
	_name.text = String(world.name)

	# Protection shows as the mark being present, and its absence as a dash rather than
	# an empty cell, so the cell reads as answered rather than unfilled. Not a
	# crossed-out shield: nothing has failed, the server simply does not ask.
	var protected := bool(world.requiresPlaySafeId)
	_shield.visible = protected
	_unprotected.visible = not protected

	_show_age(world.get("ageRequirement"))

	var capacity := int(world.capacity)
	_players.text = "%d / %d" % [capacity - free, capacity]

## The backend sends only `minor` or `null` today, because the age gate runs one way:
## no server requires being an adult. `adult` is rendered anyway, so adding such a
## server later is a backend change and not a client release.
##
## The mark is a picture rather than a word, matching the shield beside it, and the
## absence of a requirement is again a dash. A requirement this client has no mark for
## reads as the dash too, since the cell is not where the restriction is enforced.
func _show_age(requirement: Variant) -> void:
	_under_eighteen.visible = requirement == "minor"
	_over_eighteen.visible = requirement == "adult"
	_any_age.visible = not (_under_eighteen.visible or _over_eighteen.visible)
