## One player's body. Moved only by the peer that owns it. Every other peer receives its
## position through the `Motion` synchroniser, and only if the server has decided that peer may
## know this body exists at all, which is what `Presence` is for.
##
## Movement is client-authoritative, which suits a walkaround and would be wrong for a
## competitive game. Nothing here is anti-cheat. PlaySafe ID decides who may enter, and what
## happens inside is the game's own problem.
extends CharacterBody3D

## Which of the world's standing slots this player arrived in, set by the server and
## meaningless afterwards: the player walks off it immediately. It is kept only so the
## server can see which slots are occupied when the next player arrives.
var slot := 0

const SPEED := 4.5
const GRAVITY := 12.0

## Barely a hop: about 25cm up and under half a second in the air. Small because nothing in
## here is meant to be climbed, and any higher turns the furniture into scenery to stand on.
const JUMP_SPEED := 2.4
const LOOK_SENSITIVITY := 0.0022
const PITCH_LIMIT := deg_to_rad(85.0)

## Replicated by the `Motion` synchroniser, so other peers turn this body as its owner
## turns it. Yaw only: nobody needs to see where somebody else is looking vertically.
@onready var _camera: Camera3D = $Camera
@onready var _label: Label3D = $Tag

## The node's name is the peer id it belongs to, set by the server before the spawner
## replicates it. Deriving authority from the name means authority arrives with the
## node rather than needing a message of its own.
##
## Handed over one node at a time, never recursively. `Presence` stays with the server, which
## is the only party entitled to say which peers are told this body exists, and Godot consults a
## synchroniser's visibility only on the peer that is its authority. Handing the whole subtree to
## the client would hand it that decision too, and every world would see every body.
func _enter_tree() -> void:
	var owner_peer := name.to_int()
	set_multiplayer_authority(owner_peer, false)
	$Motion.set_multiplayer_authority(owner_peer, false)

func _ready() -> void:
	var mine := is_multiplayer_authority()

	# Only the owner looks through their own eyes, and only the owner's input is read.
	_camera.current = mine

	# First person, so the owner sees neither their own body nor their own name tag. The camera
	# sits inside the capsule, and without this the view is filled by the inside of it.
	$Mesh.visible = not mine
	_label.visible = not mine

## The display name, which arrives from the game server after it redeemed the ticket. Never
## taken from the client: a player types nothing and cannot choose what others see it called.
func set_tag(text: String) -> void:
	_label.text = text

## Where the server says this player starts.
##
## Sent to the owning peer as a message, because a client that owns its own position
## will not accept that position as replicated state: a synchroniser only applies what
## arrives from the node's authority. Only the server may say it, which is what the
## sender check is for.
@rpc("any_peer", "call_remote", "reliable")
func place(at: Vector3, facing: float) -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return
	position = at
	rotation.y = facing
	velocity = Vector3.ZERO

func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	if not event is InputEventMouseMotion:
		return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return

	var motion: InputEventMouseMotion = event
	rotate_y(-motion.relative.x * LOOK_SENSITIVITY)
	_camera.rotation.x = clamp(
		_camera.rotation.x - motion.relative.y * LOOK_SENSITIVITY, -PITCH_LIMIT, PITCH_LIMIT)

func _physics_process(delta: float) -> void:
	if not is_multiplayer_authority():
		return

	# Walks a circle instead of reading the keyboard, so a headless client can prove replication
	# with nobody pressing a key.
	var direction := _auto_direction() if _auto else _input_direction()

	velocity.x = direction.x * SPEED
	velocity.z = direction.z * SPEED

	# Airborne first, so the hop below is not flattened on the tick it starts. Landed, the
	# vertical velocity is thrown away rather than accumulated: a body resting on the floor that
	# kept subtracting gravity would be pressed into it harder every tick.
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	elif _jumped():
		velocity.y = JUMP_SPEED
	else:
		velocity.y = 0.0

	move_and_slide()

## Read here rather than in `_unhandled_input`, so the hop is decided on the same tick as
## the movement it belongs to.
##
## Held down it does nothing after the first hop, because the press has to arrive on a
## tick that is already standing on something. The mouse check is the one `_input_direction`
## makes for the same reason: with the pause menu open the keyboard belongs to the menu.
func _jumped() -> bool:
	if _auto or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return false
	return Input.is_action_just_pressed("jump")

var _auto := OS.get_cmdline_user_args().has("--auto")

func _auto_direction() -> Vector3:
	var angle := float(Time.get_ticks_msec()) / 1000.0
	return Vector3(cos(angle), 0.0, sin(angle))

## Relative to where the player is facing, because the camera turns the body.
func _input_direction() -> Vector3:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return Vector3.ZERO

	# Forward is negative Z, so `move_forward` is the negative end of the axis.
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	return (transform.basis * Vector3(input.x, 0.0, input.y)).normalized()
