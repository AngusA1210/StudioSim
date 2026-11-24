extends RefCounted
# A Standard MIDI File's notes and sustain pedal (as Pro Tools and other DAWs export them, type 0 or 1), every
# track's together, in time order and in seconds, its tempo changes followed. For the demo videos' recorder.


## {events: [[seconds, "on", note, velocity 0-1] / [seconds, "off", note, 0] / [seconds, "sustain", 1 or 0, 0]],
##  bpm: its first tempo, length: seconds to its last event}, or {} if it can't be read.
static func read(path: String) -> Dictionary:
	var b := FileAccess.get_file_as_bytes(path)
	if b.size() < 14 or b.slice(0, 4).get_string_from_ascii() != "MThd":
		return {}
	var tracks := _be16(b, 10)
	var division := _be16(b, 12)
	if division & 0x8000:  # (frames of SMPTE time rather than beats: not what a DAW exports)
		return {}
	var raw := []     # [tick, order, kind, a, b]
	var tempos := []  # [tick, microseconds a beat]
	var order := 0
	var pos := 8 + _be32(b, 4)
	for t in tracks:
		if pos + 8 > b.size() or b.slice(pos, pos + 4).get_string_from_ascii() != "MTrk":
			break
		var size := _be32(b, pos + 4)
		var p := pos + 8
		var end := mini(p + size, b.size())
		var tick := 0
		var status := 0
		while p < end:
			var delta := _vlq(b, p)
			tick += delta[0]
			p = delta[1]
			if p >= end:
				break
			var c := b[p]
			if c == 0xFF:  # a meta event: the tempo kept, the rest passed over
				var kind := b[p + 1]
				var length := _vlq(b, p + 2)
				if kind == 0x51 and length[0] == 3:
					var q: int = length[1]
					tempos.append([tick, (b[q] << 16) | (b[q + 1] << 8) | b[q + 2]])
				p = length[1] + length[0]
				if kind == 0x2F:
					break
				continue
			if c == 0xF0 or c == 0xF7:  # system exclusive
				var length := _vlq(b, p + 1)
				p = length[1] + length[0]
				continue
			if c & 0x80:
				status = c
				p += 1
			var kind := status & 0xF0  # (otherwise running status: the last one's)
			var d1 := b[p]
			var d2 := 0
			if kind == 0xC0 or kind == 0xD0:
				p += 1
			else:
				d2 = b[p + 1]
				p += 2
			if kind == 0x90 and d2 > 0:
				raw.append([tick, order, "on", d1, d2 / 127.0])
			elif kind == 0x80 or kind == 0x90:
				raw.append([tick, order, "off", d1, 0.0])
			elif kind == 0xB0 and d1 == 64:
				raw.append([tick, order, "sustain", 1 if d2 >= 64 else 0, 0.0])
			order += 1
		pos += 8 + size
	raw.sort_custom(func(x, y): return x[0] < y[0] or (x[0] == y[0] and x[1] < y[1]))
	tempos.sort_custom(func(x, y): return x[0] < y[0])
	var events := []
	var tempo := 500000  # (120 BPM until it says otherwise)
	if not tempos.is_empty() and tempos[0][0] == 0:
		tempo = tempos[0][1]
	var bpm := 60000000.0 / tempo
	var tick_0 := 0
	var seconds_0 := 0.0
	var next := 0
	var pedal := 0
	for e in raw:
		while next < tempos.size() and tempos[next][0] <= e[0]:
			seconds_0 += (tempos[next][0] - tick_0) * tempo / 1000000.0 / division
			tick_0 = tempos[next][0]
			tempo = tempos[next][1]
			next += 1
		if e[2] == "sustain":
			if e[3] == pedal:  # (a pedal's every position sent: only its going down and coming up kept)
				continue
			pedal = e[3]
		events.append([seconds_0 + (e[0] - tick_0) * tempo / 1000000.0 / division, e[2], e[3], e[4]])
	return {"events": events, "bpm": bpm, "length": events[-1][0] if not events.is_empty() else 0.0}


static func _be16(b: PackedByteArray, p: int) -> int:
	return (b[p] << 8) | b[p + 1]


static func _be32(b: PackedByteArray, p: int) -> int:
	return (b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3]


## A variable-length number at p: [it, where what follows it starts].
static func _vlq(b: PackedByteArray, p: int) -> Array:
	var v := 0
	while p < b.size():
		var c := b[p]
		p += 1
		v = (v << 7) | (c & 0x7F)
		if not (c & 0x80):
			break
	return [v, p]
