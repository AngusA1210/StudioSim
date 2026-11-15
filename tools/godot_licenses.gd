extends SceneTree
## Prints Godot's own licence and those of the libraries built into it, as the engine itself reports them, for
## tools/notices.sh to put in THIRD-PARTY-NOTICES.txt (Godot asks that they go with anything made with it).
##   godot --headless --path game --script ../tools/godot_licenses.gd


func _initialize() -> void:
	var out := PackedStringArray()
	out.append("Godot Engine")
	out.append("")
	out.append(Engine.get_license_text())
	out.append("")
	out.append("Godot Engine is built with the following, each under its own licence (given in full after the list).")
	out.append("")
	for component in Engine.get_copyright_info():
		for part in component.parts:
			out.append("- %s: %s (%s)" % [component.name, ", ".join(PackedStringArray(part.copyright)), part.license])
	out.append("")
	var licenses: Dictionary = Engine.get_license_info()
	var names := licenses.keys()
	names.sort()
	for name in names:
		out.append("---- %s ----" % name)
		out.append("")
		out.append(str(licenses[name]))
		out.append("")
	print("@@NOTICES@@")
	print("\n".join(out))
	print("@@END@@")
	quit(0)
