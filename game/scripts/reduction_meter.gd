extends Control
## A gain reduction meter, as Pro Tools shows one beside a track's meter: a thin orange bar that falls from the top as
## far as the track's compressors and limiters are turning it down (24 dB down its whole height), at once, and lets go
## steadily. Feed it every frame with what they took off since the last (dB).

const RANGE_DB := 24.0
const LET_GO_DB_PER_SECOND := 30.0
const ORANGE := Color(1.0, 0.58, 0.16)
const WIDTH := 4.0

var shown := 0.0  # dB, as the bar has it now


func _ready() -> void:
	custom_minimum_size.x = WIDTH
	mouse_filter = Control.MOUSE_FILTER_PASS  # (its hint)


func feed(db: float) -> void:
	shown = maxf(shown, clampf(db, 0.0, RANGE_DB))


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	shown = maxf(shown - LET_GO_DB_PER_SECOND * delta, 0.0)
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, 0.06))
	if shown > 0.05:
		draw_rect(Rect2(0, 0, size.x, maxf(size.y * shown / RANGE_DB, 1.0)), ORANGE)
