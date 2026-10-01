## Shuffles one bay of a stand on the way in, and hops the people in it now and then.
##
## Every bay is this same scene, so left as authored the stand reads as one group of seats
## repeated along the row, and the mirrored bays make the repeat obvious. So a seat is nudged,
## takes a shirt colour from the bay's own palette, and may be left empty. The shuffle happens
## once, in `_ready`, and the arrangement differs from client to client, since a crowd is scenery
## and there is nothing here worth agreeing on.
##
## A hop is short, and only one person starts one at a time. A shared phase would read as a wave
## whatever its shape, and a rise held long enough to notice would read as levitating, because a
## spectator is drawn seated with nothing below the seat surface.
extends Node3D

## Share of seats left empty, which breaks up the grid more than moving a seat does.
const SPARE := 0.05

## Metres a seat may move: along the row, and back into the bank. Both are small, since
## the scene already spaces the seats and a step is only 0.32 m deep.
const SHIFT := Vector2(0.1, 0.04)

## How far along the row a body may sit. A stand's seating stops short of its own side
## walls, and a bay that is mirrored borrows from the bay beside it, so this is the band
## that is inside the seats either way round.
const EDGE := Vector2(-0.99, 2.69)

## Metres a hop clears the seat at its highest, and metres it leans while it does, which
## is what keeps it from reading as a pogo.
const HOP := Vector2(0.07, 0.17)
const LEAN := 0.05

## Seconds a hop lasts, and seconds one person waits between hops.
const AIR := Vector2(0.32, 0.52)
const EVERY := Vector2(2.5, 6.0)

var _people: Array[Sprite3D] = []
var _seat := PackedVector2Array()
var _from := PackedFloat32Array()
var _span := PackedFloat32Array()
var _peak := PackedFloat32Array()
var _lean := PackedFloat32Array()
var _hopping := PackedInt32Array()
var _gap := 0.0
var _at := 0.0

func _ready() -> void:
	# The dedicated server loads the circuit as well, and has nobody to show it to.
	if OS.has_feature("dedicated_server") or OS.get_cmdline_user_args().has("--server"):
		set_process(false)
		return

	var shirts: Array[Color] = []
	for person: Sprite3D in get_children():
		shirts.append(person.modulate)

	for person: Sprite3D in get_children():
		if randf() < SPARE:
			person.visible = false
			continue

		person.modulate = shirts.pick_random()
		person.position.x = clampf(
			person.position.x + randf_range(-SHIFT.x, SHIFT.x), EDGE.x, EDGE.y
		)
		person.position.z += randf_range(-SHIFT.y, SHIFT.y)

		_people.append(person)
		_seat.append(Vector2(person.position.x, person.position.y))
		_from.append(0.0)
		_span.append(1.0)
		_peak.append(0.0)
		_lean.append(0.0)

func _process(delta: float) -> void:
	_at += delta
	_gap -= delta

	if _gap <= 0.0 and not _people.is_empty():
		# Timed per person rather than per bay, so how lively a stand looks does not change
		# with how many seats the scene happens to hold.
		_gap = randf_range(EVERY.x, EVERY.y) / float(_people.size())
		var who := randi() % _people.size()
		if not _hopping.has(who):
			_from[who] = _at
			_span[who] = randf_range(AIR.x, AIR.y)
			_peak[who] = randf_range(HOP.x, HOP.y)
			_lean[who] = randf_range(-LEAN, LEAN)
			_hopping.append(who)

	# Only the handful mid-hop are touched. A crowd is mostly sitting still, and a write per
	# seat per frame is work the web build does not need to do.
	var slot := _hopping.size() - 1
	while slot >= 0:
		var who := _hopping[slot]
		var seat := _seat[who]
		var over := (_at - _from[who]) / _span[who]
		if over >= 1.0:
			_people[who].position.x = seat.x
			_people[who].position.y = seat.y
			_hopping.remove_at(slot)
		else:
			var arc := sin(PI * over)
			_people[who].position.x = seat.x + arc * _lean[who]
			_people[who].position.y = seat.y + arc * _peak[who]
		slot -= 1
