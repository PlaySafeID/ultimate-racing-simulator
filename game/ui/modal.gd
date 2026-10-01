## One modal, reused for every refusal and for the account picker.
##
## A refusal is never a screen. It appears over whatever the player was already looking
## at, so the thing they were trying to do stays visible behind it and cancelling puts
## them back where they were.
##
## Cancel sits on the left and the positive action on the right, here and everywhere else.
class_name Modal
extends CanvasLayer

@onready var _head: Label = %Head
@onready var _body: Label = %Body
@onready var _code: Label = %Code
@onready var _picker: VBoxContainer = %Picker
@onready var _options: OptionButton = %Options
@onready var _cancel: Button = %Cancel
@onready var _action: Button = %Action
@onready var _buttons: HBoxContainer = %Buttons
@onready var _spacer: Control = %Spacer
@onready var _scan: VBoxContainer = %Scan
@onready var _reveal: Button = %Reveal
@onready var _shown: VBoxContainer = %Shown
@onready var _image: TextureRect = %Image
@onready var _countdown: Label = %Countdown

signal _decided(outcome: String)

## The player asked to see a QR code, or to put it away again. Whoever owns the sign-in
## answers by calling `show_code()`, because minting one is a backend call and this scene
## makes none.
signal scan_toggled(revealed: bool)

## What the one button says in each state, so the sentence names the thing it is about to
## do rather than leaving the player to work out which half changed.
const SHOW := "Sign in on my phone (Show QR code)"
const HIDE := "Sign in on my phone (Hide QR code)"

## Seconds left on the code being shown, counted down here so the label cannot disagree
## with the image beside it.
var _left := 0.0

## Whether a live code is on screen.
##
## Not the same as the block being visible: an expired code leaves the picture in place,
## blurred, so the modal does not change height. The button offers a fresh one from then
## on, which is what this distinguishes.
var _live := false

## The same code with nothing readable left in it, painted at the same time as the code
## itself so expiry is a swap rather than a repaint from a grid kept around.
var _blurred: ImageTexture

func _ready() -> void:
	_cancel.pressed.connect(_decided.emit.bind("cancel"))
	_action.pressed.connect(_decided.emit.bind("action"))
	_reveal.pressed.connect(_on_reveal_pressed)

## Shows the modal and waits. Answers "action" or "cancel".
##
## `spec` carries `head`, `body`, `code`, `act`, and optionally `presets` to offer, `scan`
## to offer the QR code, and `cancel` to relabel the left button. An empty `act` hides the
## right one, for the cases where there is nothing useful to offer.
func open(spec: Dictionary) -> String:
	_head.text = String(spec.get("head", ""))
	_body.text = "\n\n".join(spec.get("body", []) as Array)
	_code.text = String(spec.get("code", ""))
	_code.visible = _code.text != ""

	_cancel.text = String(spec.get("cancel", "Cancel"))
	_action.text = String(spec.get("act", ""))
	_action.visible = _action.text != ""

	# With nothing to offer, the one button sits in the middle. Left-aligning it would
	# leave a gap where an action used to be, which reads as something missing.
	_spacer.visible = _action.visible
	_buttons.alignment = BoxContainer.ALIGNMENT_BEGIN if _action.visible else BoxContainer.ALIGNMENT_CENTER

	# Offered folded away, never already on screen. The player is the one who knows
	# whether anybody else can see their screen, so showing a code is their decision,
	# taken after they have read what it does.
	_scan.visible = bool(spec.get("scan", false))
	hide_code()

	var presets: Array = spec.get("presets", [])
	_picker.visible = not presets.is_empty()
	_options.clear()
	for preset: Dictionary in presets:
		_options.add_item(String(preset.label))
		_options.set_item_metadata(_options.item_count - 1, String(preset.id))

	visible = true

	# Focus lands on the button that does something, so a keyboard can answer this.
	if _action.visible:
		_action.grab_focus()
	else:
		_cancel.grab_focus()

	var outcome: String = await _decided
	visible = false
	return outcome

## Which preset the player chose, by id.
func chosen_preset() -> String:
	if _options.item_count == 0:
		return ""
	return String(_options.get_item_metadata(_options.selected))

## Replaces the body while the modal stays open, for the waiting-on-a-browser case.
func retitle(head: String, body: String) -> void:
	_head.text = head
	_body.text = body

## Closes the modal from outside, for when the thing it was waiting for happened
## somewhere else: a sign-in landing on a phone rather than on this button.
##
## It still answers the caller awaiting `open()`. A coroutine left suspended on a modal
## nobody can see shows up later as a screen that has quietly stopped responding to its
## own buttons.
func close(outcome := "closed") -> void:
	if not visible:
		return
	_decided.emit(outcome)

## Draws a minted code and starts its clock. `seconds` is what the backend said it has
## left, so the number on screen is the backend's fact rather than a guess here.
func show_code(size: int, modules: Array, seconds: float) -> void:
	_image.texture = Qr.paint(size, modules)
	_image.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_blurred = Qr.paint(size, modules, true)

	_left = seconds
	_live = true
	_shown.visible = true
	_reveal.text = HIDE
	_tick()

## Puts the code away, and drops both images with it: a texture still in memory is a
## texture something could put back on screen.
func hide_code() -> void:
	_left = 0.0
	_live = false
	_shown.visible = false
	_image.texture = null
	_blurred = null
	_reveal.text = SHOW

func _on_reveal_pressed() -> void:
	var revealing := not _live
	if not revealing:
		hide_code()
	scan_toggled.emit(revealing)

func _process(delta: float) -> void:
	if _left <= 0.0:
		return

	_left -= delta
	if _left > 0.0:
		_tick()
		return

	# Run out, so it blurs itself rather than sitting there readable, and nothing is
	# minted in its place: a code nobody scanned in a minute is one the player has stopped
	# looking at. The sign-in behind it is untouched, so the next press is instant.
	_live = false
	_image.texture = _blurred
	_image.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_countdown.text = "Expired. Show a fresh one."
	_reveal.text = SHOW

func _tick() -> void:
	_countdown.text = "Single use, and expires in %ds" % ceili(_left)
