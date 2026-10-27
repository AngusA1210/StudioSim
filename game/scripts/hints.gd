extends RefCounted
## Hover hints. Rather than every explanation being written out on a panel, a control carries a short description of
## itself, and the panel's hint line shows the description of whatever the mouse is over, and nothing otherwise.
## Descriptions name the keys as a Mac has them (Cmd, Option, ⌘); off a Mac they read as that keyboard has them.

static var _mac := OS.get_name() == "macOS"


## A description with its keys named as this computer's keyboard names them: off a Mac, Cmd is Ctrl and Option is Alt.
static func keys(text: String) -> String:
	if _mac:
		return text
	return text.replace("⌘", "Ctrl+").replace("Cmd", "Ctrl").replace("Option-", "Alt-").replace("Option ", "Alt ").replace(
		"Option:", "Alt:").replace("Option)", "Alt)")

## Gives a control its description: a String, or a Callable returning one for a description that changes.
static func give(control: Control, hint) -> Control:
	control.set_meta("hint", hint)
	if control.mouse_filter == Control.MOUSE_FILTER_IGNORE:  # a label: it has to notice the mouse to be described
		control.mouse_filter = Control.MOUSE_FILTER_PASS
	return control


## The description of the control under the mouse, or of the nearest thing holding it that has one, so long as it is
## inside `within`. "" when there is none.
static func under_mouse(within: Control) -> String:
	if not within.is_visible_in_tree():
		return ""
	var control := within.get_viewport().gui_get_hovered_control()
	while control != null:
		if control.has_meta("hint"):
			if not within.is_ancestor_of(control) and control != within:
				return ""
			var hint = control.get_meta("hint")
			return keys(str(hint.call()) if hint is Callable else str(hint))
		if control == within:
			return ""
		control = control.get_parent() as Control
	return ""


## A panel's hint line: dim, keeping its place whether or not there is anything to say (at least `least` high), and
## wrapped onto as many lines as a hint needs, all of it shown. It keeps the height of the tallest hint shown while its
## panel is open, so that what is under the mouse isn't moved from under it as hints come and go.
static func line(least := 18.0) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.62, 0.65, 0.74))
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.y = least
	label.minimum_size_changed.connect(func() -> void:
		label.custom_minimum_size.y = maxf(label.custom_minimum_size.y, label.get_minimum_size().y))
	label.visibility_changed.connect(func() -> void:
		if not label.is_visible_in_tree():  # (the panel closed: as short as it can be, until a hint needs more)
			label.custom_minimum_size.y = least)
	return label
