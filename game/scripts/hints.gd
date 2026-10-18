extends RefCounted
## Hover hints. Rather than every explanation being written out on a panel, a control carries a short description of
## itself, and the panel's hint line shows the description of whatever the mouse is over, and nothing otherwise.

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
			return str(hint.call()) if hint is Callable else str(hint)
		if control == within:
			return ""
		control = control.get_parent() as Control
	return ""


## A panel's hint line: one dim line that keeps its place whether or not there is anything to say.
static func line() -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.62, 0.65, 0.74))
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.custom_minimum_size.y = 18
	return label
