## The header every screen carries: game title, status badge, player name.
##
## One instance of this scene appears on all three front doors, so the badge and the
## account switcher exist once rather than three times.
##
## The badge is a demo affordance, and it shows a tone rather than a status. The public
## build has none, because a badge can only ever show a stale standing. In demo the tone
## comes from which preset was picked, which is a choice this client made and remembers.
## Nothing here calls PlaySafe ID, and the client has no field to keep a standing in.
extends PanelContainer

## The account changed, so a screen should repaint anything derived from identity.
signal switched()

## Tone per preset id, matching the fixtures `backend/.env.example` names. An id with no
## entry gets the neutral tone rather than a guess.
const TONES := {
	"active": "Ok",
	"minor": "Ok",
	"unverified": "Warn",
	"temp": "Warn",
	"reauth": "Warn",
	"perm": "Bad",
	"locked": "Bad",
}

@onready var _badge: Button = %Badge
@onready var _player_name: Label = %PlayerName

func _ready() -> void:
	_badge.pressed.connect(_switch_account)

	# The session can change without this screen touching it: a sign-in landing, or a
	# ceiling expiring and being restarted. So the header follows the session rather than
	# waiting to be told by whoever owns the screen.
	Backend.session_changed.connect(refresh)
	refresh()

func refresh() -> void:
	_player_name.text = String(Backend.player.get("displayName", ""))
	_badge.visible = Backend.is_demo()

	var preset: Variant = Backend.player.get("presetId")
	var tone: String = "None" if preset == null else String(TONES.get(preset, "None"))
	_badge.theme_type_variation = "Badge" + tone

	# The label lives in the tooltip rather than beside the mark, so the header stays the
	# same width whichever account is chosen and the pill reads as a state.
	_badge.tooltip_text = "%s. Click to switch account. Demo build only." % _preset_label()

func _preset_label() -> String:
	var chosen: Variant = Backend.player.get("presetId")
	if chosen == null:
		return "No PlaySafe ID held"
	for preset: Dictionary in Backend.config.get("presets", []):
		if preset.id == chosen:
			return String(preset.label)
	return String(chosen)

## Switching preset is `POST /logout` then `POST /session`, never a swap in place. A swap
## would leave a held slot and a world membership attached to an identity that never
## earned entry, so a demoer could stand in a protected lobby as a banned account.
func _switch_account() -> void:
	var presets: Array = Backend.config.get("presets", [])
	if presets.is_empty():
		await Dialog.open({
			"head": "No preset accounts",
			"body": ["This deployment has none configured, so there is nothing to switch to."],
			"cancel": "Close",
		})
		return

	var spec := {
		"head": "Switch account",
		"body": ["Each of these is a real PlaySafe ID account whose standing is whatever it genuinely is. Picking one skips the sign-in and nothing else."],
		"act": "Use this account",
		"presets": presets,
	}

	if Join.held.is_empty():
		spec.body.append("No slot is held, so nothing is given up.")
	else:
		spec.body.append("You hold a slot in %s, and switching releases it. The new account has not earned that slot." % Join.world_name(Join.held_world()))

	if await Dialog.open(spec) != "action":
		return

	var chosen := Dialog.chosen_preset()

	# `forget()` rather than `release()`: the logout below frees the ticket server side,
	# so cancelling first would be a call about a ticket that is already gone.
	Join.forget()
	await Backend.sign_out()

	var session := await Backend.start_session("", chosen)
	if session.has("error"):
		await Dialog.open({
			"head": "Could not switch account",
			"body": [String(session.error)],
			"cancel": "Close",
		})
		return

	refresh()
	switched.emit()
