extends RefCounted
# A check of the recorder: the default room lit, the camera moved through it as the band plays, and a caption.


func run(r) -> void:
	var main = r.main
	main.title.enter()
	main.settings.room_brightness = 2.2
	main._apply_lighting()
	main.player.place(Vector3(-7.5, 0.0, 6.5), 0.0)  # (out of the shot: the room is heard from the camera)
	await r.seconds(1.5)
	r.camera(Vector3(-6.2, 2.6, 4.4), Vector3(1.5, 0.5, -1.5), 62.0)
	await r.frames(10)
	r.start()
	await r.seconds(0.5)
	r.caption("A room of instruments, heard from where you stand")
	await r.glide(Vector3(-1.2, 1.75, 4.6), Vector3(0.9, 0.9, -2.4), 5.0, 66.0)
	r.caption("Move, and what you hear moves with you")
	await r.glide(Vector3(2.4, 1.6, 0.6), Vector3(0.4, 0.9, -3.4), 5.0, 60.0)
	r.caption("")
	await r.seconds(1.0)
	r.stop()
