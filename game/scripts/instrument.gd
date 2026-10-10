extends Node3D
## One instrument in the room: its body, stand, label and light, plus its sound source in the audio core.
## The node's origin is where the sound comes from.

var kind := ""
var display_name := ""
var color := Color.WHITE
var size := Vector3.ONE
var playable := false  # can be played by hand, and has a pattern the sequencer plays
var default_octave := 0  # where the computer keyboard starts when you sit down at it
var source_id := -1
var muted := false     # the Speaker: silenced altogether
var loop_on := true    # playable instruments: whether the sequencer plays their pattern
var input_channel := -1  # live-input instruments: the hardware input they play (0-based), or -1 for all of them
var carried := false
var shadowed := false  # a wall is between it and the listener
var glow := 0.0

var _audio: SoundRoomAudio
var _spin := 0.0
var _body: MeshInstance3D
var _body_material: StandardMaterial3D
var _stand: MeshInstance3D
var _foot: MeshInstance3D
var _light: OmniLight3D
var _label: Label3D
var _collider: CollisionShape3D


func setup(spec: Dictionary, audio: SoundRoomAudio) -> void:
	_audio = audio
	kind = spec.kind
	display_name = spec.name
	color = spec.color
	size = spec.size
	playable = not spec.get("live_input", false)
	default_octave = spec.get("octave", 0)
	_spin = spec.get("spin", 0.0)
	name = display_name
	position = spec.position

	source_id = audio.add_source(kind, position, spec.gain, spec.send)
	if source_id < 0:
		return  # the room is full; whoever asked for this instrument gives up on it

	_body_material = StandardMaterial3D.new()
	_body_material.albedo_color = color.darkened(0.7)
	_body_material.emission_enabled = true
	_body_material.emission = color
	_body = _box(size, _body_material)
	if _spin != 0.0:
		_body.rotation.y = PI / 4

	var stand_material := StandardMaterial3D.new()
	stand_material.albedo_color = Color(0.03, 0.032, 0.04)
	_stand = _box(Vector3(0.07, 1.0, 0.07), stand_material)
	_foot = _box(Vector3(0.5, 0.05, 0.5), stand_material)

	_light = OmniLight3D.new()
	_light.light_color = color
	_light.omni_range = 5.0
	add_child(_light)

	_label = Label3D.new()
	_label.text = display_name
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 40
	_label.pixel_size = 0.004
	_label.outline_size = 10
	_label.modulate = color.lightened(0.35)
	_label.position = Vector3(0, size.y / 2 + 0.3, 0)
	add_child(_label)

	# Something solid to bump into, on the default layer only (sound passes through instruments).
	var body := StaticBody3D.new()
	_collider = CollisionShape3D.new()
	var cylinder := CylinderShape3D.new()
	cylinder.radius = 0.4
	cylinder.height = 2.0
	_collider.shape = cylinder
	body.add_child(_collider)
	add_child(body)


func _process(delta: float) -> void:
	if source_id < 0:
		return
	var target := minf(1.0, sqrt(_audio.get_source_level(source_id)) * 1.6)
	glow = lerpf(glow, target, minf(1.0, delta * (40.0 if target > glow else 7.0)))
	var on := 0.0 if muted else 1.0
	_body_material.emission_energy_multiplier = 0.03 + (0.3 + 2.4 * glow) * on
	_light.light_energy = (0.12 + 2.2 * glow) * on
	_body.scale = Vector3.ONE * (1.0 + 0.07 * glow)
	if _spin != 0.0:
		_body.rotate_y(_spin * delta * (0.4 + 2.0 * glow))
	_update_stand()


## `path` comes from Acoustics.direct_path; it carries the instrument's position, so moving it needs nothing else.
func set_direct_path(path: Dictionary) -> void:
	shadowed = path.blocked
	_audio.set_source_direct_path(source_id, path.via, path.extra, path.deltas, path.blocked)


func set_muted(value: bool) -> void:
	muted = value
	_audio.set_source_muted(source_id, value)
	_label.text = display_name + ("  (muted)" if value else "")
	_label.modulate.a = 0.55 if value else 1.0


func set_input_channel(channel: int) -> void:
	input_channel = channel
	_audio.set_source_input_channel(source_id, channel)


## Stops or restarts the sequencer playing this instrument's pattern. It can still be played by hand.
func set_loop(on: bool) -> void:
	loop_on = on
	_audio.set_source_loop(source_id, on)
	_label.text = display_name + ("" if on else "  (loop off)")
	_label.modulate.a = 1.0 if on else 0.55


## What M does: for an instrument, its loop on or off; for the Speaker, mute.
func toggle_quiet() -> void:
	if playable:
		set_loop(not loop_on)
	else:
		set_muted(not muted)


func is_quiet() -> bool:
	return not loop_on if playable else muted


## The name floating above it. The title screen hides these so they don't drift behind its words.
func set_label_visible(on: bool) -> void:
	_label.visible = on


func set_carried(value: bool) -> void:
	carried = value
	_collider.disabled = value


func set_highlighted(value: bool) -> void:
	_label.outline_modulate = color.darkened(0.2) if value else Color(0, 0, 0, 0.85)


func _update_stand() -> void:
	var bottom := global_position.y - size.y / 2
	_stand.visible = not carried and bottom > 0.02
	_foot.visible = _stand.visible
	_stand.scale.y = maxf(bottom, 0.01)
	_stand.position.y = -size.y / 2 - bottom / 2
	_foot.position.y = -global_position.y + 0.025


func _box(box_size: Vector3, material: Material) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = box_size
	mesh.mesh = box
	mesh.material_override = material
	add_child(mesh)
	return mesh
