extends CanvasLayer
## Asks for a name, for saving a template or a preset under: a box over everything else with the name to type, Save
## and Cancel. Enter saves, Esc cancels. While it is open the keys are for typing: the windows under it leave them be.

const DIM := Color(0.62, 0.65, 0.74)
const WARN := Color(1.0, 0.61, 0.48)

var _root: Control
var _title: Label
var _name: LineEdit
var _note: Label
var _save: Button
var _on_done := Callable()
var _taken := Callable()  # whether a name is in use already: saving under it replaces what has it
var _mouse_was := Input.MOUSE_MODE_VISIBLE


func _ready() -> void:
	layer = 20
	_build()
	_root.visible = false


func is_open() -> bool:
	return _root.visible


## Asks for a name. `on_done` is called with it if it is saved; `taken` (optional) says whether a name is in use.
func ask(title: String, suggestion: String, on_done: Callable, taken := Callable()) -> void:
	_title.text = title
	_on_done = on_done
	_taken = taken
	_name.text = suggestion
	_mouse_was = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_root.visible = true
	_name.grab_focus()
	_name.select_all()
	_check(suggestion)


func cancel() -> void:
	_root.visible = false
	_name.release_focus()
	Input.mouse_mode = _mouse_was


func confirm() -> void:
	var text := _name.text.strip_edges()
	if text == "":
		return
	cancel()
	if _on_done.is_valid():
		_on_done.call(text)


func _input(event: InputEvent) -> void:
	if is_open() and event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE:
		cancel()
		get_viewport().set_input_as_handled()


func _check(text: String) -> void:
	var name := text.strip_edges()
	_save.disabled = name == ""
	var replacing: bool = name != "" and _taken.is_valid() and _taken.call(name)
	_note.text = "There is one called that already: saving replaces it." if replacing else ""
	_save.text = "Replace" if replacing else "Save"


func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.4)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.09, 0.12, 0.99)
	style.set_corner_radius_all(12)
	style.set_border_width_all(1)
	style.border_color = Color(1, 1, 1, 0.18)
	style.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", style)
	panel.custom_minimum_size.x = 420
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 18)
	box.add_child(_title)
	_name = LineEdit.new()
	_name.placeholder_text = "Name"
	_name.text_changed.connect(_check)
	_name.text_submitted.connect(func(_text: String) -> void: confirm())
	box.add_child(_name)
	_note = Label.new()
	_note.add_theme_color_override("font_color", WARN)
	_note.add_theme_font_size_override("font_size", 12)
	box.add_child(_note)
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 8)
	box.add_child(buttons)
	var cancel_button := Button.new()
	cancel_button.text = "Cancel"
	cancel_button.pressed.connect(cancel)
	buttons.add_child(cancel_button)
	_save = Button.new()
	_save.text = "Save"
	_save.custom_minimum_size.x = 90
	_save.pressed.connect(confirm)
	buttons.add_child(_save)
