extends CanvasLayer
## A room being opened or made, shown: its name, a bar for how far it has got, and what is being set up now (each
## instrument, as its plug-ins load). A room with many plug-ins takes a while to put in place, and without this the
## screen would only stand still. session.gd steps the room in a frame at a time and says how far it is; nothing else
## on the screen takes the mouse or the keys meanwhile.

const ACCENT := Color(0.49, 0.89, 0.82)
const DIM := Color(0.62, 0.65, 0.74)

var app
var _root: Control
var _title: Label
var _bar: ProgressBar
var _step: Label


func setup(the_app) -> void:
	app = the_app
	layer = 30  # over everything, the questions asked too
	_build()
	_root.visible = false


func is_open() -> bool:
	return _root.visible


## Shown, with what is being done ("Opening Night session").
func begin(title: String) -> void:
	_title.text = title
	_bar.value = 0.0
	_step.text = ""
	_root.visible = true


## What is being set up now, and how far along it is (0 to 1).
func show_step(what: String, progress: float) -> void:
	_bar.value = clampf(progress, 0.0, 1.0) * 100.0
	_step.text = what


func end() -> void:
	_root.visible = false


## The keys go nowhere while it is up (Esc would close the page the room was chosen on, half-way through).
func _input(event: InputEvent) -> void:
	if is_open() and (event is InputEventKey or event is InputEventMouseButton):
		get_viewport().set_input_as_handled()


func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	var shade := ColorRect.new()
	shade.color = Color(0.01, 0.012, 0.02, 0.72)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(shade)
	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(centre)
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.055, 0.06, 0.075, 0.97)
	style.set_corner_radius_all(14)
	style.set_border_width_all(1)
	style.border_color = Color(1, 1, 1, 0.12)
	style.content_margin_left = 28
	style.content_margin_right = 28
	style.content_margin_top = 22
	style.content_margin_bottom = 22
	panel.add_theme_stylebox_override("panel", style)
	panel.custom_minimum_size.x = 420
	centre.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	panel.add_child(column)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 20)
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	column.add_child(_title)
	_bar = ProgressBar.new()
	_bar.show_percentage = false
	_bar.custom_minimum_size.y = 8
	var track := StyleBoxFlat.new()
	track.bg_color = Color(1, 1, 1, 0.08)
	track.set_corner_radius_all(4)
	var fill := StyleBoxFlat.new()
	fill.bg_color = ACCENT
	fill.set_corner_radius_all(4)
	_bar.add_theme_stylebox_override("background", track)
	_bar.add_theme_stylebox_override("fill", fill)
	column.add_child(_bar)
	_step = Label.new()
	_step.add_theme_font_size_override("font_size", 14)
	_step.add_theme_color_override("font_color", DIM)
	_step.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	column.add_child(_step)
