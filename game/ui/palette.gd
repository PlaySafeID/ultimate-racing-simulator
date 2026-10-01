## Every colour in the game, in one resource.
##
## Nothing else declares a colour, so a re-skin is an edit to `palette.tres`. That
## holds only while no scene carries its own override: one inline colour on one node
## breaks it silently.
##
## The four tones exist because a refusal has a temperature. An unverified account is
## not a banned one, and the difference should be visible before the words are read.
class_name Palette
extends Resource

## Surfaces come in three depths and edges in two, because a control has to lift off
## whatever it sits on. A button is `raised` against a `panel`, and the line around it
## is `edge` where a divider between two panels is `line`.
@export_group("Surfaces")
@export var background := Color("0b0d10")
@export var panel := Color("14171c")
@export var raised := Color("1a1e24")
@export var line := Color("262c35")
@export var edge := Color("333b46")

@export_group("Text")
@export var text := Color("e9edf2")
@export var muted := Color("8a94a2")
@export var dim := Color("5d6674")

@export_group("Tones")
@export var accent := Color("4c9ffe")
@export var ok := Color("3fb950")
@export var warn := Color("e3a13c")
@export var bad := Color("e5484d")

## Named so a status badge can ask for a tone rather than choose a colour.
func tone(name: String) -> Color:
	match name:
		"ok": return ok
		"warn": return warn
		"bad": return bad
		"accent": return accent
		_: return muted
