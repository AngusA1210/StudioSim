## StudioSim's look, as the website has it (website/static/css/site.css): a dark blue-grey ground, teal for what is on
## or chosen, warm for recording and clipping, and each instrument's own colour to mark its tracks. Its colours, the
## theme every window takes (main.gd merges it into Godot's default theme, which every Control falls back to, the menus and pop-ups too), and the
## pieces a script styles by hand: a window's frame, a panel inside one, a button lit in a colour, a key cap beside a
## button's name. `const UI := preload("res://scripts/ui.gd")`.

# The grounds, darkest first: the room behind a window, a window, a panel in it, a control on that.
const ROOM := Color("090a0f")
const WINDOW := Color("0e1017")
const PANEL := Color("13161f")
const CONTROL := Color("1b1f2b")
const CONTROL_HOVER := Color("242a39")
const LINE := Color(1, 1, 1, 0.09)         # a hairline
const LINE_STRONG := Color(1, 1, 1, 0.16)  # one that must show
# Ink: titles and values; text: everything else; dim: labels and units.
const INK := Color("eceef4")
const TEXT := Color("c9cdda")
const DIM := Color("9aa1b8")
# Signals.
const ACCENT := Color("7de3d1")       # on, chosen
const ACCENT_INK := Color("052b26")   # text on it
const WARM := Color("ff9c7a")         # record, clip, a warning
const AMBER := Color("ffd14a")        # mute, −6 dB
const BLUE := Color("8cc7ff")         # input
# A track's buttons, each lit in its own colour.
const RECORD := WARM
const INPUT := BLUE
const MUTE := AMBER
const SOLO := ACCENT

const RADIUS := 10         # a control's corners
const PANEL_RADIUS := 14   # a panel's
const WINDOW_RADIUS := 16  # a window's
const LABEL_SIZE := 11     # a section's label, in spaced capitals
const TITLE_SIZE := 22     # a window's name

static var _theme: Theme
static var _heading: FontVariation


## A flat box: `bg` filled, `border` round it, `radius` corners, content `h` and `v` in from its edges.
static func box(bg: Color, border := Color(0, 0, 0, 0), radius := RADIUS, h := 12.0, v := 6.0, border_width := 1) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(border_width if border.a > 0.0 else 0)
	style.set_corner_radius_all(radius)
	style.content_margin_left = h
	style.content_margin_right = h
	style.content_margin_top = v
	style.content_margin_bottom = v
	style.anti_aliasing = true
	return style


## A window's frame: over the room, with a shadow under it.
static func window_style(margin := 18.0, alpha := 0.97) -> StyleBoxFlat:
	var style := box(Color(WINDOW, alpha), LINE, WINDOW_RADIUS, margin, margin)
	style.shadow_color = Color(0, 0, 0, 0.45)
	style.shadow_size = 24
	style.shadow_offset = Vector2(0, 10)
	return style


## A panel inside a window.
static func panel_style(margin := 14.0) -> StyleBoxFlat:
	return box(PANEL, LINE, PANEL_RADIUS, margin, margin)


## A control's face, as the theme has it for a button: "normal", "hover", "pressed" (a toggle on), "hover_pressed",
## "disabled".
static func button_style(state: String, h := 14.0, v := 7.0) -> StyleBoxFlat:
	match state:
		"hover":
			return box(CONTROL_HOVER, LINE_STRONG, RADIUS, h, v)
		"pressed":
			return box(Color(ACCENT, 0.16), Color(ACCENT, 0.5), RADIUS, h, v)
		"hover_pressed":
			return box(Color(ACCENT, 0.22), Color(ACCENT, 0.7), RADIUS, h, v)
		"disabled":
			return box(Color(1, 1, 1, 0.03), LINE, RADIUS, h, v)
	return box(CONTROL, LINE, RADIUS, h, v)


## A button that lights in `color` while it is on (a track's R I M S, a loop switched on): a tint of it, its border and
## its letter in it; off, plain. `small`: the size of a track's buttons.
static func lit_button(button: Button, color: Color, small := false) -> void:
	var h := 0.0 if small else 11.0
	var v := 0.0 if small else 7.0
	var radius := 6 if small else RADIUS
	var faces := {
		"normal": box(CONTROL, LINE, radius, h, v), "hover": box(CONTROL_HOVER, LINE_STRONG, radius, h, v),
		"pressed": box(Color(color, 0.2), Color(color, 0.6), radius, h, v), "hover_pressed": box(Color(color, 0.28), Color(color, 0.8), radius, h, v),
		"disabled": box(Color(1, 1, 1, 0.03), LINE, radius, h, v), "focus": StyleBoxEmpty.new()}
	for state in faces:
		button.add_theme_stylebox_override(state, faces[state])
	button.add_theme_color_override("font_color", DIM if small else INK)
	button.add_theme_color_override("font_hover_color", INK)
	button.add_theme_color_override("font_pressed_color", color)
	button.add_theme_color_override("font_hover_pressed_color", color)


## The primary button of a window (Save): teal, its words dark on it.
static func primary_button(button: Button) -> void:
	var faces := {"normal": box(ACCENT, Color(0, 0, 0, 0), RADIUS, 16, 7), "hover": box(Color("a2efe2"), Color(0, 0, 0, 0), RADIUS, 16, 7),
		"pressed": box(Color("a2efe2"), Color(0, 0, 0, 0), RADIUS, 16, 7), "disabled": box(Color(ACCENT, 0.3), Color(0, 0, 0, 0), RADIUS, 16, 7),
		"focus": StyleBoxEmpty.new()}
	faces["hover_pressed"] = faces.hover
	for state in faces:
		button.add_theme_stylebox_override(state, faces[state])
	for which in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(which, ACCENT_INK)


## A quiet button, its border alone (Close, Resume): it says what it does without asking to be pressed.
static func ghost_button(button: Button) -> void:
	var faces := {"normal": box(Color(0, 0, 0, 0), LINE_STRONG, RADIUS, 14, 7), "hover": box(Color(1, 1, 1, 0.07), LINE_STRONG, RADIUS, 14, 7),
		"pressed": box(Color(1, 1, 1, 0.1), LINE_STRONG, RADIUS, 14, 7), "disabled": box(Color(0, 0, 0, 0), LINE, RADIUS, 14, 7),
		"focus": StyleBoxEmpty.new()}
	faces["hover_pressed"] = faces.pressed
	for state in faces:
		button.add_theme_stylebox_override(state, faces[state])


## A button that is its words alone until the pointer is over it (Title screen, Quit): for the least of a row.
static func quiet_button(button: Button) -> void:
	var faces := {"normal": box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), RADIUS, 8, 7), "hover": box(Color(1, 1, 1, 0.07), Color(0, 0, 0, 0), RADIUS, 8, 7),
		"pressed": box(Color(1, 1, 1, 0.1), Color(0, 0, 0, 0), RADIUS, 8, 7), "disabled": box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), RADIUS, 8, 7),
		"focus": StyleBoxEmpty.new()}
	faces["hover_pressed"] = faces.pressed
	for state in faces:
		button.add_theme_stylebox_override(state, faces[state])
	button.add_theme_color_override("font_color", TEXT)


## A button's name with its key in a key cap after it ("Close" and a P), instead of "Close  (P)". Called again when
## the key changes; `key` "" takes the cap away.
static func keyed(button: Button, text: String, key: String) -> void:
	button.text = text
	button.set_meta("key", key)
	var font: Font = ThemeDB.fallback_font
	var cap: float = font.get_string_size(key, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 12.0 if key != "" else 0.0
	var extra: float = cap + 8.0 if key != "" else 0.0
	for state in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
		var face: StyleBox = button.get_theme_stylebox(state) if button.has_theme_stylebox_override(state) else button_style(state)
		face = face.duplicate()
		if not button.has_meta("key_room"):
			face.content_margin_right += extra
		else:
			face.content_margin_right += extra - float(button.get_meta("key_room"))
		button.add_theme_stylebox_override(state, face)
	button.set_meta("key_room", extra)
	if not button.has_meta("key_drawn"):
		button.set_meta("key_drawn", true)
		button.draw.connect(func() -> void: _draw_key(button))
	button.queue_redraw()


static func _draw_key(button: Button) -> void:
	var key: String = button.get_meta("key", "")
	if key == "":
		return
	var font := button.get_theme_default_font()
	var width: float = font.get_string_size(key, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 12.0
	var right: float = button.get_theme_stylebox("normal").content_margin_right - float(button.get_meta("key_room", 0.0))
	var rect := Rect2(button.size.x - right - width, (button.size.y - 20.0) / 2.0, width, 20.0)
	var face := box(Color(CONTROL, 0.9), LINE_STRONG, 5, 0, 0)
	face.border_width_bottom = 2
	button.draw_style_box(face, rect)
	button.draw_string(font, Vector2(rect.position.x, rect.position.y + 14.5), key, HORIZONTAL_ALIGNMENT_CENTER, width, 12, TEXT)


## A section's label: small spaced capitals, dim (INSERTS, INPUT LEVEL).
static func section_label(label: Label, text := "") -> Label:
	if text != "":
		label.text = text.to_upper()
	label.uppercase = true
	label.add_theme_font_size_override("font_size", LABEL_SIZE)
	label.add_theme_color_override("font_color", DIM)
	label.add_theme_constant_override("outline_size", 0)
	return label


## A window's name: larger, heavier, ink.
static func title_label(label: Label, size := TITLE_SIZE, color := INK) -> Label:
	label.add_theme_font_override("font", heading_font())
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label


## The heavier face, for titles: the theme's own, emboldened.
static func heading_font() -> FontVariation:
	if _heading == null:
		_heading = FontVariation.new()
		_heading.base_font = ThemeDB.fallback_font
		_heading.variation_embolden = 0.55
	return _heading


## A switch, drawn: a pill, on (teal, its knob right) or off.
static func _switch(on: bool, dim := false) -> ImageTexture:
	var a := 0.4 if dim else 1.0
	var svg := ("<svg xmlns='http://www.w3.org/2000/svg' width='36' height='20'><rect x='0.5' y='0.5' width='35' height='19' rx='9.5' fill='#7de3d1' fill-opacity='%s'/><circle cx='26' cy='10' r='7' fill='#052b26'/></svg>" % a) if on else \
		("<svg xmlns='http://www.w3.org/2000/svg' width='36' height='20'><rect x='0.5' y='0.5' width='35' height='19' rx='9.5' fill='#1b1f2b' stroke='#ffffff' stroke-opacity='0.16' fill-opacity='%s'/><circle cx='10' cy='10' r='7' fill='#9aa1b8' fill-opacity='%s'/></svg>" % [a, a])
	return _texture(svg)


static func _tick(on: bool, circle := false) -> ImageTexture:
	var shape := "<circle cx='9' cy='9' r='8'" if circle else "<rect x='1' y='1' width='16' height='16' rx='4'"
	var svg := "<svg xmlns='http://www.w3.org/2000/svg' width='18' height='18'>" + shape + \
		(" fill='#7de3d1'/>" if on else " fill='#0e1017' stroke='#ffffff' stroke-opacity='0.22'/>")
	if on:
		svg += "<circle cx='9' cy='9' r='3.5' fill='#052b26'/>" if circle else "<path d='M5 9.2 7.8 12 13 6.4' fill='none' stroke='#052b26' stroke-width='2' stroke-linecap='round' stroke-linejoin='round'/>"
	return _texture(svg + "</svg>")


## A small dot of `color`, as an icon before a name (a track's).
static func dot_icon(color: Color, size := 8) -> ImageTexture:
	return _dot(size, "#" + color.to_html(false))


static func _dot(size: int, color: String) -> ImageTexture:
	var r := size / 2.0
	return _texture("<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d'><circle cx='%s' cy='%s' r='%s' fill='%s'/></svg>" % [size, size, r, r, r - 0.5, color])


static func _chevron(color: String) -> ImageTexture:
	return _texture("<svg xmlns='http://www.w3.org/2000/svg' width='12' height='12'><path d='M3 4.5 6 7.5 9 4.5' fill='none' stroke='%s' stroke-width='1.6' stroke-linecap='round' stroke-linejoin='round'/></svg>" % color)


static func _texture(svg: String) -> ImageTexture:
	var image := Image.new()
	image.load_svg_from_string(svg, 1.0)
	return ImageTexture.create_from_image(image)


## The theme every window takes: its controls as the website's.
static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	_theme = t
	var none := StyleBoxEmpty.new()

	t.set_color("font_color", "Label", INK)

	for type in ["Button", "OptionButton", "MenuButton", "CheckButton", "CheckBox"]:
		var plain: bool = type in ["CheckButton", "CheckBox"]
		for state in ["normal", "hover", "pressed", "hover_pressed", "disabled"]:
			var face: StyleBox = button_style(state)
			if plain:  # (a switch or a tick box is its icon and its words, no face)
				face = box(Color(1, 1, 1, 0.06) if state.begins_with("hover") else Color(0, 0, 0, 0), Color(0, 0, 0, 0), RADIUS, 8, 5)
			t.set_stylebox(state, type, face)
		t.set_stylebox("focus", type, none)
		t.set_color("font_color", type, INK if not plain else TEXT)
		t.set_color("font_hover_color", type, INK)
		t.set_color("font_focus_color", type, INK)
		t.set_color("font_pressed_color", type, ACCENT if type == "Button" else INK)
		t.set_color("font_hover_pressed_color", type, ACCENT if type == "Button" else INK)
		t.set_color("font_disabled_color", type, Color(DIM, 0.55))
		t.set_constant("h_separation", type, 8)
	t.set_icon("arrow", "OptionButton", _chevron("#9aa1b8"))
	t.set_constant("arrow_margin", "OptionButton", 10)
	t.set_icon("checked", "CheckButton", _switch(true))
	t.set_icon("unchecked", "CheckButton", _switch(false))
	t.set_icon("checked_disabled", "CheckButton", _switch(true, true))
	t.set_icon("unchecked_disabled", "CheckButton", _switch(false, true))
	t.set_icon("checked_mirrored", "CheckButton", _switch(true))
	t.set_icon("unchecked_mirrored", "CheckButton", _switch(false))
	t.set_icon("checked", "CheckBox", _tick(true))
	t.set_icon("unchecked", "CheckBox", _tick(false))
	t.set_icon("radio_checked", "CheckBox", _tick(true, true))
	t.set_icon("radio_unchecked", "CheckBox", _tick(false, true))
	t.set_color("font_pressed_color", "CheckButton", INK)
	t.set_color("font_color", "CheckButton", TEXT)

	for type in ["LineEdit", "TextEdit"]:
		t.set_stylebox("normal", type, box(WINDOW, LINE_STRONG, 8, 10, 6))
		var focus := box(Color(0, 0, 0, 0), ACCENT, 8, 10, 6)
		focus.draw_center = false
		t.set_stylebox("focus", type, focus)
		t.set_stylebox("read_only", type, box(Color(0, 0, 0, 0), LINE, 8, 10, 6))
		t.set_color("font_color", type, INK)
		t.set_color("font_placeholder_color", type, DIM)
		t.set_color("font_readonly_color", type, TEXT)
		t.set_color("caret_color", type, INK)
		t.set_color("selection_color", type, Color(ACCENT, 0.3))
		t.set_color("font_selected_color", type, INK)

	t.set_stylebox("panel", "Panel", panel_style())
	t.set_stylebox("panel", "PanelContainer", panel_style())
	t.set_stylebox("panel", "PopupPanel", box(WINDOW, LINE_STRONG, 12, 8, 8))
	var menu := box(WINDOW, LINE_STRONG, 12, 6, 6)
	menu.shadow_color = Color(0, 0, 0, 0.45)
	menu.shadow_size = 16
	t.set_stylebox("panel", "PopupMenu", menu)
	t.set_stylebox("hover", "PopupMenu", box(Color(ACCENT, 0.14), Color(0, 0, 0, 0), 7, 8, 4))
	var rule := StyleBoxLine.new()
	rule.color = LINE
	rule.thickness = 1
	t.set_stylebox("separator", "PopupMenu", rule)
	t.set_color("font_color", "PopupMenu", TEXT)
	t.set_color("font_hover_color", "PopupMenu", INK)
	t.set_color("font_disabled_color", "PopupMenu", Color(DIM, 0.55))
	t.set_color("font_separator_color", "PopupMenu", DIM)
	t.set_constant("v_separation", "PopupMenu", 8)
	t.set_constant("item_start_padding", "PopupMenu", 10)
	t.set_constant("item_end_padding", "PopupMenu", 10)
	t.set_icon("checked", "PopupMenu", _tick(true))
	t.set_icon("unchecked", "PopupMenu", _tick(false))
	t.set_icon("radio_checked", "PopupMenu", _tick(true, true))
	t.set_icon("radio_unchecked", "PopupMenu", _tick(false, true))

	t.set_stylebox("panel", "TooltipPanel", box(WINDOW, LINE_STRONG, 8, 10, 6))
	t.set_color("font_color", "TooltipLabel", TEXT)

	for type in ["TabBar", "TabContainer"]:
		var chosen := box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 14, 9)
		chosen.border_color = ACCENT
		chosen.border_width_bottom = 2
		t.set_stylebox("tab_selected", type, chosen)
		t.set_stylebox("tab_unselected", type, box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 14, 9))
		t.set_stylebox("tab_hovered", type, box(Color(1, 1, 1, 0.04), Color(0, 0, 0, 0), 6, 14, 9))
		t.set_stylebox("tab_disabled", type, box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 14, 9))
		t.set_stylebox("tab_focus", type, none)
		t.set_color("font_selected_color", type, INK)
		t.set_color("font_unselected_color", type, DIM)
		t.set_color("font_hovered_color", type, TEXT)
		t.set_color("font_disabled_color", type, Color(DIM, 0.5))
	var under_tabs := box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 4, 14)
	under_tabs.border_color = LINE
	under_tabs.border_width_top = 1
	t.set_stylebox("panel", "TabContainer", under_tabs)
	t.set_stylebox("tabbar_background", "TabContainer", none)

	for type in ["HSlider", "VSlider"]:
		var track := box(CONTROL, Color(0, 0, 0, 0), 2, 2, 2)
		t.set_stylebox("slider", type, track)
		t.set_stylebox("grabber_area", type, box(ACCENT, Color(0, 0, 0, 0), 2, 2, 2))
		t.set_stylebox("grabber_area_highlight", type, box(Color("a2efe2"), Color(0, 0, 0, 0), 2, 2, 2))
		t.set_icon("grabber", type, _dot(16, "#eceef4"))
		t.set_icon("grabber_highlight", type, _dot(16, "#ffffff"))
		t.set_icon("grabber_disabled", type, _dot(16, "#5b6070"))
		t.set_icon("tick", type, _dot(4, "#9aa1b8"))

	for type in ["HScrollBar", "VScrollBar"]:
		t.set_stylebox("scroll", type, box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 4, 3, 3))
		t.set_stylebox("scroll_focus", type, box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 4, 3, 3))
		t.set_stylebox("grabber", type, box(Color(1, 1, 1, 0.14), Color(0, 0, 0, 0), 4, 3, 3))
		t.set_stylebox("grabber_highlight", type, box(Color(1, 1, 1, 0.24), Color(0, 0, 0, 0), 4, 3, 3))
		t.set_stylebox("grabber_pressed", type, box(Color(ACCENT, 0.55), Color(0, 0, 0, 0), 4, 3, 3))

	t.set_stylebox("background", "ProgressBar", box(CONTROL, Color(0, 0, 0, 0), 4, 0, 0))
	t.set_stylebox("fill", "ProgressBar", box(ACCENT, Color(0, 0, 0, 0), 4, 0, 0))
	t.set_color("font_color", "ProgressBar", INK)

	var line := StyleBoxLine.new()
	line.color = LINE
	t.set_stylebox("separator", "HSeparator", line)
	var upright := StyleBoxLine.new()
	upright.color = LINE
	upright.vertical = true
	t.set_stylebox("separator", "VSeparator", upright)

	for type in ["ItemList", "Tree"]:
		t.set_stylebox("panel", type, box(WINDOW, LINE, RADIUS, 6, 6))
		t.set_stylebox("focus", type, none)
		t.set_stylebox("selected", type, box(Color(ACCENT, 0.16), Color(0, 0, 0, 0), 6, 4, 2))
		t.set_stylebox("selected_focus", type, box(Color(ACCENT, 0.2), Color(0, 0, 0, 0), 6, 4, 2))
		t.set_stylebox("hovered", type, box(Color(1, 1, 1, 0.05), Color(0, 0, 0, 0), 6, 4, 2))
		t.set_stylebox("cursor", type, none)
		t.set_stylebox("cursor_unfocused", type, none)
		t.set_color("font_color", type, TEXT)
		t.set_color("font_selected_color", type, INK)
		t.set_color("font_hovered_color", type, INK)
		t.set_color("guide_color", type, LINE)

	t.set_stylebox("panel", "AcceptDialog", box(WINDOW, Color(0, 0, 0, 0), 0, 16, 16))
	t.set_stylebox("embedded_border", "Window", window_style(8))
	t.set_stylebox("embedded_unfocused_border", "Window", window_style(8))
	t.set_color("title_color", "Window", INK)
	t.set_stylebox("panel", "ScrollContainer", none)
	return t
