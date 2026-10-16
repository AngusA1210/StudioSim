extends PopupPanel
## The plug-in browser: every effect plug-in on the computer, grouped by the kind of effect it is or by who makes it,
## with a search box. The mix window's insert slots and the amps' Plug-in pedals open it. Double-click a plug-in (or
## pick one and press Load, or Enter) to choose it.
##
## Most plug-ins don't say what kind of effect they are, so the kinds are worked out from their names in the audio core
## (plugin_category.cpp): a good guess rather than a certainty. By maker is always exact.

const DIM := Color(0.62, 0.65, 0.74)
# The order the kinds are listed in, roughly the order they would sit on a channel.
const TYPE_ORDER := ["Amps & cabinets", "EQ", "Dynamics", "Channel strips", "Saturation & distortion", "Filter", "Modulation",
	"Delay", "Reverb", "Pitch & vocal", "Spatial", "Restoration", "Mastering", "Utility & metering", "Other"]

var plugins: Array = []  # [{id, name, maker, category}]
var by_maker := false
var _on_chosen := Callable()
var _title: Label
var _search: LineEdit
var _by_type: Button
var _by_maker: Button
var _tree: Tree
var _load: Button
var _count: Label


func _init() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.09, 0.11, 0.99)
	style.set_corner_radius_all(10)
	style.set_border_width_all(1)
	style.border_color = Color(1, 1, 1, 0.18)
	style.set_content_margin_all(12)
	add_theme_stylebox_override("panel", style)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	add_child(box)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 17)
	box.add_child(_title)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	box.add_child(row)
	_search = LineEdit.new()
	_search.placeholder_text = "Search by name, maker or kind"
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_text: String) -> void: _fill())
	_search.text_submitted.connect(_on_search_submitted)
	row.add_child(_search)
	var group := ButtonGroup.new()
	_by_type = _group_button(row, "By type", group)
	_by_maker = _group_button(row, "By maker", group)
	_by_type.set_pressed_no_signal(true)
	_tree = Tree.new()
	_tree.hide_root = true
	_tree.columns = 2
	_tree.set_column_expand(1, true)
	_tree.set_column_expand_ratio(0, 3)
	_tree.set_column_expand_ratio(1, 2)
	_tree.custom_minimum_size = Vector2(480, 380)
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.item_activated.connect(_on_item_activated)
	_tree.item_selected.connect(_on_item_selected)
	box.add_child(_tree)
	var bottom := HBoxContainer.new()
	box.add_child(bottom)
	_count = Label.new()
	_count.add_theme_color_override("font_color", DIM)
	_count.add_theme_font_size_override("font_size", 12)
	_count.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_count.clip_text = true
	bottom.add_child(_count)
	_load = Button.new()
	_load.text = "Load"
	_load.custom_minimum_size.x = 90
	_load.disabled = true
	_load.pressed.connect(_on_load_pressed)
	bottom.add_child(_load)


## Shows the browser near `at` (a point on screen), titled for what it is choosing for. `on_chosen` is called with
## the plug-in picked: {id, name, maker, category}.
func open_for(title: String, list: Array, at: Vector2, on_chosen: Callable) -> void:
	plugins = list
	_on_chosen = on_chosen
	_title.text = title
	_search.text = ""
	_fill()
	var screen := Vector2(get_parent().get_viewport().get_visible_rect().size)
	var want := Vector2(520, 500)
	var spot := Vector2(clampf(at.x, 8.0, maxf(screen.x - want.x - 8.0, 8.0)), clampf(at.y, 8.0, maxf(screen.y - want.y - 8.0, 8.0)))
	popup(Rect2i(Vector2i(spot), Vector2i(want)))
	_search.grab_focus()


func _group_button(parent: Control, text: String, group: ButtonGroup) -> Button:
	var button := Button.new()
	button.text = text
	button.toggle_mode = true
	button.button_group = group
	button.focus_mode = Control.FOCUS_NONE
	button.toggled.connect(func(on: bool) -> void:
		if on:
			by_maker = button == _by_maker
			_fill())
	parent.add_child(button)
	return button


## The list, grouped, showing only what matches the search. Groups start folded, unless searching.
func _fill() -> void:
	_tree.clear()
	_load.disabled = true
	var root := _tree.create_item()
	var words := _search.text.strip_edges().to_lower()
	var groups := {}
	var shown := 0
	for i in plugins.size():
		var p: Dictionary = plugins[i]
		var kind: String = p.get("category", "Other")
		if words != "" and not ("%s %s %s" % [p.name, p.maker, kind]).to_lower().contains(words):
			continue
		var key: String = (p.maker if p.maker != "" else "Unknown maker") if by_maker else kind
		if not groups.has(key):
			groups[key] = []
		groups[key].append(i)
		shown += 1
	var keys: Array = groups.keys()
	if by_maker:
		keys.sort_custom(func(a: String, b: String) -> bool: return a.to_lower() < b.to_lower())
	else:
		keys.sort_custom(func(a: String, b: String) -> bool:
			var ia := TYPE_ORDER.find(a)
			var ib := TYPE_ORDER.find(b)
			return (ia if ia >= 0 else 99) < (ib if ib >= 0 else 99))
	for key in keys:
		var heading := _tree.create_item(root)
		heading.set_text(0, "%s   (%d)" % [key, groups[key].size()])
		heading.set_selectable(0, false)
		heading.set_selectable(1, false)
		heading.set_custom_color(0, Color(0.9, 0.92, 0.97))
		heading.collapsed = words == ""
		for i in groups[key]:
			var p: Dictionary = plugins[i]
			var item := _tree.create_item(heading)
			item.set_text(0, p.name)
			item.set_text(1, p.category if by_maker else p.maker)
			item.set_custom_color(1, DIM)
			item.set_metadata(0, i)
	if plugins.is_empty():
		_count.text = "No effect plug-ins are installed."
	else:
		_count.text = "%d of %d · your Audio Units (AAX-only plug-ins can't be used)" % [shown, plugins.size()]


## The plug-in an item stands for, or {} for a heading.
func _plugin_at(item: TreeItem) -> Dictionary:
	if item == null or item.get_metadata(0) == null:
		return {}
	return plugins[int(item.get_metadata(0))]


func _choose(plugin: Dictionary) -> void:
	if plugin.is_empty():
		return
	hide()
	if _on_chosen.is_valid():
		_on_chosen.call(plugin)


func _on_item_selected() -> void:
	_load.disabled = _plugin_at(_tree.get_selected()).is_empty()


func _on_item_activated() -> void:
	var item := _tree.get_selected()
	if item != null and item.get_metadata(0) == null:  # a heading: open or fold it
		item.collapsed = not item.collapsed
		return
	_choose(_plugin_at(item))


func _on_load_pressed() -> void:
	_choose(_plugin_at(_tree.get_selected()))


## Enter in the search box: the selected plug-in, or the first that matches.
func _on_search_submitted(_text: String) -> void:
	var picked := _plugin_at(_tree.get_selected())
	if picked.is_empty():
		var first := _tree.get_root().get_first_child() if _tree.get_root() != null else null
		picked = _plugin_at(first.get_first_child() if first != null else null)
	_choose(picked)
