## The traffic outside the window. Scenery only: no bodies, no collision, no lap counting, and
## nothing a player can reach or affect.
##
## Thirty cars go round the circuit the room looks out on. The circuit is 4.1km round and the
## window sees 215m of it, so a car is in shot for under three seconds of a lap that takes
## fifty, one or two of the thirty are out there at any moment, and a car that has just gone
## past is the better part of a minute from coming back.
##
## The gaps do the work. What gives a loop away is the rate cars cross the window, which is the
## field divided by the lap, so a field close enough together to keep the window full is a field
## going round often enough to be recognised. Twelve cars on a 377m lap and thirty on a 900m one
## look the same.
##
## Nothing about it is sent. Each car's position comes from the wall clock, so every client works
## it out for itself and they agree without the game server knowing this exists. A clock
## correction mid-session shifts the traffic once.
##
## Thirty cars cost one `_process` and a position and a yaw each: no physics body, no collision
## shape, no per-car script. A car on the part of the lap with no road under it is not drawn, and
## that is nearly all of them. They reuse the parked cars' model, so they add no mesh, and a
## livery is one flat material apiece.
extends Node3D

## Metres a second, one per lane. Around 80 reads as quick from 25m behind glass and still
## leaves a car crossing the view for a second or two.
##
## Every car in a lane holds one speed, which is what makes this safe to leave running
## unwatched: a lane is a rigid train, so nothing in it can catch the car in front, and the two
## lanes never share road. The lanes differ, so the trains work their way past one another and
## the field is a different shape each time somebody looks up. They realign every fourteen
## minutes, against a lap of fifty seconds, and a car passes another by being quicker rather
## than by steering.
const SPEEDS := [83.0, 78.0]

## The lap, in metres. The circuit is 4.1km round, of which the 215m outside the window is the
## only part modelled, so this is the number that says how much of it is elsewhere. It is the
## one knob for how spread out the field is: raise it and cars cross the window less often,
## lower it and they queue up. It must be longer than the road below.
const LAP_METRES := 4100.0

## What the road sits at, which is 3.44m below the room's floor.
const TRACK_Y := -3.44

## How far ahead to look to work out which way a car is pointing.
const NOSE := 1.0

## The line each lane takes, in metres either side of the road's centre.
##
## The tarmac is 6m wide and these cars are 2.3m wide, so 1.4 leaves 0.45m of road outside
## the car and 0.5m of air between the two lanes. Anything past 1.85 puts the outside wheels
## on the grass, which is why there are two lanes and not three: a third would have to sit on
## top of one of these to stay on the road, and then a car being passed would be passed
## through. The turns hold the same clearance, since a lane offset from an arc is another arc
## and the road is the same 6m all the way round.
const LANES := [1.4, -1.4]

## Where each car runs: metres round the lap, and which lane. Listed in the order the scene
## lists the cars, so the table reads down alongside the liveries.
##
## Placed by hand rather than by dividing the lap up, since an evenly divided field is the one
## thing a real one never is. Each lane gets four pairs running nose to tail and the rest strung
## out alone, so the gaps range from 9m to 520m instead of the same 137m thirty times.
##
## Two cars in a lane are never closer than 9m, which at 4.3m long is a tight tow rather than a
## shunt, and they hold that gap since they share a speed.
const FIELD := [
	Vector2i(0, 0),
	Vector2i(11, 0),
	Vector2i(331, 0),
	Vector2i(571, 0),
	Vector2i(991, 0),
	Vector2i(1003, 0),
	Vector2i(1303, 0),
	Vector2i(1783, 0),
	Vector2i(1792, 0),
	Vector2i(2142, 0),
	Vector2i(2662, 0),
	Vector2i(2922, 0),
	Vector2i(2935, 0),
	Vector2i(3335, 0),
	Vector2i(3665, 0),

	Vector2i(165, 1),
	Vector2i(415, 1),
	Vector2i(427, 1),
	Vector2i(807, 1),
	Vector2i(1107, 1),
	Vector2i(1117, 1),
	Vector2i(1577, 1),
	Vector2i(1917, 1),
	Vector2i(1931, 1),
	Vector2i(2221, 1),
	Vector2i(2721, 1),
	Vector2i(2941, 1),
	Vector2i(2952, 1),
	Vector2i(3382, 1),
	Vector2i(3765, 1),
]

## The lap, in the direction of travel, following the centre of the road as it is actually
## laid out. A leg is a straight between two points, or, where it carries a `centre`, a
## quarter turn about that point.
##
## Travel is towards +X along the main straight, which is the way round the cars on the
## grid are pointing: pole sits on the start line with the rest of the field strung out
## behind it. Going the other way would be driving the circuit backwards.
##
## The two turns and the straight between them are what the window shows. The legs either side
## of them run south past the room and out of sight partway along.
##
## The last leg is the rest of the circuit, the part nothing is modelled along. It takes whatever
## `LAP_METRES` has left over rather than the distance between its ends, because out there the
## circuit goes the long way round while the shape here only has to close. It runs 9m south of
## the glass, where a car is already hidden by the north wall, so a car stops being drawn at a
## point nobody can be looking at.
const LAP := [
	{"from": Vector3(-81.1, TRACK_Y, -6.0), "to": Vector3(-81.1, TRACK_Y, -24.0)},
	{
		"from": Vector3(-81.1, TRACK_Y, -24.0),
		"to": Vector3(-66.1, TRACK_Y, -39.0),
		"centre": Vector3(-66.1, TRACK_Y, -24.0),
	},
	{"from": Vector3(-66.1, TRACK_Y, -39.0), "to": Vector3(65.9, TRACK_Y, -39.0)},
	{
		"from": Vector3(65.9, TRACK_Y, -39.0),
		"to": Vector3(80.9, TRACK_Y, -24.0),
		"centre": Vector3(65.9, TRACK_Y, -24.0),
	},
	{"from": Vector3(80.9, TRACK_Y, -24.0), "to": Vector3(80.9, TRACK_Y, -6.0)},
	{"from": Vector3(80.9, TRACK_Y, -6.0), "to": Vector3(-81.1, TRACK_Y, -6.0), "drawn": false},
]

## The cars, in the order the scene lists them. Taken from the children rather than made
## here, so which cars they are and what they look like stays an edit in the editor.
var _cars: Array[Node3D] = []

## Where each leg of the lap finishes, measured from the lap's start, and the whole lap.
var _ends := PackedFloat64Array()
var _lap := 0.0

func _ready() -> void:
	for car: Node3D in get_children():
		_cars.append(car)

	# The modelled road first, then the leg with no road under it, which takes however much of
	# the lap the modelled part did not account for.
	var modelled := 0.0
	for leg: Dictionary in LAP:
		if leg.get("drawn", true):
			modelled += _length(leg)

	for leg: Dictionary in LAP:
		_lap += _length(leg) if leg.get("drawn", true) else LAP_METRES - modelled
		_ends.append(_lap)

func _process(_delta: float) -> void:
	var elapsed := Time.get_unix_time_from_system()

	for index in mini(_cars.size(), FIELD.size()):
		var slot: Vector2i = FIELD[index]
		var speed := float(SPEEDS[slot.y])
		_drive(_cars[index], elapsed * speed + float(slot.x), float(LANES[slot.y]))

## Puts one car where it has got to, and points it where it is going.
func _drive(car: Node3D, distance: float, lane: float) -> void:
	var leg: Dictionary = LAP[_leg_at(fposmod(distance, _lap))]

	var drawn: bool = leg.get("drawn", true)
	car.visible = drawn
	if not drawn:
		return

	var here := _point(distance)
	var heading := (_point(distance + NOSE) - here).normalized()

	car.position = here + Vector3(heading.z, 0.0, -heading.x) * lane

	# The models are built nose down their own +Z, not the -Z a Godot node treats as forward,
	# so this points the model rather than the node.
	car.rotation.y = atan2(heading.x, heading.z)

## The point on the centre of the road this far round the lap.
func _point(distance: float) -> Vector3:
	var at := fposmod(distance, _lap)
	var leg := _leg_at(at)
	var began := 0.0 if leg == 0 else _ends[leg - 1]
	var along := (at - began) / (_ends[leg] - began)

	var from: Vector3 = LAP[leg].from
	var to: Vector3 = LAP[leg].to
	if not LAP[leg].has("centre"):
		return from.lerp(to, along)

	# Both ends of a turn are the same distance from its centre, so interpolating by angle
	# traces the arc rather than the chord across it.
	var centre: Vector3 = LAP[leg].centre
	return centre + (from - centre).slerp(to - centre, along)

func _leg_at(at: float) -> int:
	for leg in _ends.size():
		if at <= _ends[leg]:
			return leg
	return _ends.size() - 1

func _length(leg: Dictionary) -> float:
	var from: Vector3 = leg.from
	var to: Vector3 = leg.to
	if not leg.has("centre"):
		return from.distance_to(to)

	# Every turn here is a quarter circle, so its length is a quarter of a circumference.
	var centre: Vector3 = leg.centre
	return from.distance_to(centre) * PI * 0.5
