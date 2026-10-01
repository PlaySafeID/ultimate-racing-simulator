## Paints a QR code from the module grid the backend sends.
##
## A grid rather than an image on the wire, so the colours come from the palette like
## every other colour in the game. Modules are drawn one pixel each and the
## `TextureRect` scales them with nearest filtering, so the result is exact at any
## size rather than resampled.
##
## This reads `palette.tres` directly rather than the theme, the only script that
## does. A QR is two colours with a required contrast relationship, and the theme has
## nowhere to say that.
class_name Qr
extends RefCounted

const PALETTE: Palette = preload("res://ui/palette.tres")

## The quiet zone the spec asks for, in modules. A code butted against a panel edge
## gives a scanner no boundary to find.
const QUIET := 4

## How far down a blurred copy is taken before being scaled back up. Low enough that
## no module survives, so what comes back is the shape of a code and none of its data.
const SMEAR := 4

## `modules` is one string of `0` and `1` per row, `size` long.
##
## Dark modules on a light field, not the dark-themed inverse. An inverted code is
## outside the spec and readers are only sometimes forgiving of it, so it works on the
## phone it was tried on and fails on a player's.
##
## `blurred` gives the same code with nothing readable left in it, for an expired one
## that stays on screen to hold its place. Blurred rather than removed so the modal
## does not change height under the player's pointer, and blurred rather than dimmed
## so it cannot be recovered by turning a monitor's brightness up.
static func paint(size: int, modules: Array, blurred := false) -> ImageTexture:
	var side := size + QUIET * 2
	var image := Image.create_empty(side, side, false, Image.FORMAT_RGB8)
	image.fill(PALETTE.text)

	for y in mini(size, modules.size()):
		var row := String(modules[y])
		for x in mini(size, row.length()):
			if row[x] == "1":
				image.set_pixel(x + QUIET, y + QUIET, PALETTE.background)

	# Down and back up, which is a blur anything can do. The caller pairs it with a
	# linear texture filter, since nearest would rebuild it as visible blocks.
	if blurred:
		image.resize(side / SMEAR, side / SMEAR, Image.INTERPOLATE_BILINEAR)
		image.resize(side, side, Image.INTERPOLATE_BILINEAR)

	return ImageTexture.create_from_image(image)
