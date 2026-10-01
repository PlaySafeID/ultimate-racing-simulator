## Pushes the palette into the theme at boot, which is what makes a re-skin one edit.
##
## Without this, every colour would live twice: once in `palette.tres` and again inside
## each `StyleBoxFlat` in `theme.tres`. They would drift, and the second copy would win.
## So the theme owns shape and the palette owns colour. Corner radii, borders, margins
## and font sizes are authored in `theme.tres` and left alone here.
##
## A texture pack later replaces those `StyleBoxFlat`s with `StyleBoxTexture`s, which
## have no colour to set. Every write below is guarded for that, so an unrecognised box
## is left as the artist made it.
extends Node

const THEME: Theme = preload("res://ui/theme.tres")
const PALETTE: Palette = preload("res://ui/palette.tres")

func _ready() -> void:
	# The three surfaces a screen is built from: the page, the header strip across the
	# top of it, and the key art panel beside the menu.
	_recolour("Screen", ["panel"], PALETTE.background, PALETTE.background)
	_recolour("Hud", ["panel"], PALETTE.panel.darkened(0.08), PALETTE.line)
	_recolour("KeyArt", ["panel"], PALETTE.background.lerp(PALETTE.panel, 0.75), PALETTE.line)

	_recolour("Button", ["normal", "disabled"], PALETTE.raised, PALETTE.edge)
	_recolour("Button", ["hover"], PALETTE.raised.lightened(0.03), PALETTE.edge)
	_recolour("Button", ["pressed"], PALETTE.panel.darkened(0.2), PALETTE.accent)
	_recolour("Button", ["focus"], PALETTE.panel, PALETTE.accent)
	_recolour("Ghost", ["normal", "pressed", "disabled"], PALETTE.background, PALETTE.line)
	_recolour("Ghost", ["hover"], PALETTE.background.lerp(PALETTE.panel, 0.5), PALETTE.line)
	_recolour("Panel", ["panel"], PALETTE.panel, PALETTE.line)
	_recolour("PanelContainer", ["panel"], PALETTE.panel, PALETTE.line)
	_recolour("LineEdit", ["normal"], PALETTE.background, PALETTE.line)
	_recolour("OptionButton", ["normal", "pressed"], PALETTE.background, PALETTE.line)

	# The queue box floats over the key art rather than sitting in a column, so it keeps
	# a little transparency: the art reads through it and it still reads as a surface.
	var floating := PALETTE.background.lerp(PALETTE.panel, 0.5)
	floating.a = 0.93
	_recolour("MatchBox", ["panel"], floating, PALETTE.edge)

	# The bar down the left edge of a control, the one place a colour carries meaning on
	# this screen: accent marks the door PlaySafe ID stands at.
	_recolour("EdgeAccent", ["panel"], PALETTE.accent, PALETTE.accent)
	_recolour("EdgeDim", ["panel"], PALETTE.dim, PALETTE.dim)

	# The status badge's four tones, derived from the palette so a re-skin still carries
	# them. A tone reads before the words do: an unverified account is not a banned one.
	_tone("BadgeNone", PALETTE.muted, PALETTE.line)
	_tone("BadgeOk", PALETTE.ok)
	_tone("BadgeWarn", PALETTE.warn)
	_tone("BadgeBad", PALETTE.bad)

	# The "Under 18" chip, warm because it marks a restriction rather than a fault.
	THEME.set_color("font_color", "Chip", PALETTE.warn)
	_recolour(
		"Chip",
		["normal"],
		PALETTE.background.lerp(PALETTE.warn, 0.09),
		PALETTE.background.lerp(PALETTE.warn, 0.46),
	)

	THEME.set_color("font_color", "Label", PALETTE.text)
	THEME.set_color("font_color", "Title", PALETTE.text)
	THEME.set_color("font_color", "Display", PALETTE.text)
	THEME.set_color("font_color", "Sub", PALETTE.dim)
	THEME.set_color("font_color", "GroupLabel", PALETTE.dim)
	THEME.set_color("font_color", "ArtSub", PALETTE.dim)
	THEME.set_color("font_color", "HudTitle", PALETTE.muted)
	THEME.set_color("font_color", "HudStudio", PALETTE.dim)
	THEME.set_color("font_color", "PlayerName", PALETTE.text)
	THEME.set_color("font_color", "MatchState", PALETTE.muted)
	THEME.set_color("font_color", "Button", PALETTE.text)
	THEME.set_color("font_hover_color", "Button", PALETTE.text.lightened(0.2))
	THEME.set_color("font_pressed_color", "Button", PALETTE.accent)
	THEME.set_color("font_disabled_color", "Button", PALETTE.dim)
	THEME.set_color("font_color", "Ghost", PALETTE.muted)
	THEME.set_color("font_hover_color", "Ghost", PALETTE.text)
	THEME.set_color("font_color", "LineEdit", PALETTE.text)
	THEME.set_color("font_placeholder_color", "LineEdit", PALETTE.dim)
	THEME.set_color("caret_color", "LineEdit", PALETTE.accent)
	THEME.set_color("font_color", "OptionButton", PALETTE.text)

## One badge tone: the mark takes the tone, and the fill and edge are the tone mixed back
## towards the background so it reads as a tint rather than a block of colour.
func _tone(variation: String, colour: Color, edge := Color()) -> void:
	THEME.set_color("icon_normal_color", variation, colour)
	_recolour(
		variation,
		["normal", "hover", "pressed"],
		PALETTE.background.lerp(colour, 0.09),
		edge if edge != Color() else PALETTE.background.lerp(colour, 0.46),
	)

func _recolour(type: String, states: Array, fill: Color, edge: Color) -> void:
	for state: String in states:
		var box := THEME.get_stylebox(state, type)
		if box is StyleBoxFlat:
			box.bg_color = fill
			box.border_color = edge
