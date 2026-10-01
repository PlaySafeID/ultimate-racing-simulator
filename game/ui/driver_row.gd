## One driver in the list down the side of character select.
##
## The badge marks the realm the driver was created in, not anything about the player.
## A driver with a shield loads only while the account's PlaySafe ID standing allows
## it; a driver without one always loads. The realm belongs to the character and the
## standing belongs to the account, and entering a world needs both.
extends Button

@onready var _name: Label = %Name
@onready var _detail: Label = %Detail
@onready var _badge: TextureRect = %Badge

func fill(driver_name: String, detail: String, psid_realm: bool) -> void:
	_name.text = driver_name
	_detail.text = detail
	_badge.visible = psid_realm
