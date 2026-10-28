"""StudioSim's icon, drawn: a room seen from its doorway (the back wall, and the edges of the walls, floor and ceiling
running out to the viewer), and sound spreading through it from a point on the floor. In the colours of StudioSim's
own pages: a dark blue, and their teal.

  python3 tools/make_icon.py

writes game/icon.png (1024 px, a Mac's icon: the rounded square inside the margin macOS gives every icon) and
game/icon.ico (Windows': the rounded square filling it, at each size Windows asks for). Needs Pillow.
"""

import pathlib

from PIL import Image, ImageDraw, ImageFilter

GAME = pathlib.Path(__file__).resolve().parent.parent / "game"
SCALE = 4  # drawn this many times larger, then made smaller: smooth edges
INK = (125, 227, 209)  # the pages' teal (0.49, 0.89, 0.82)
TOP = (30, 35, 50)
BOTTOM = (11, 13, 19)


def tile(size: int, inset: float, radius: float, shadow: bool) -> Image.Image:
    """The icon on a canvas `size` across: its rounded square `inset` in from each side."""
    s = size * SCALE
    canvas = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    left, right = inset * s, s - inset * s
    span = right - left
    corner = radius * span

    if shadow:  # (as macOS's own icons have, beneath)
        mask = Image.new("L", (s, s), 0)
        ImageDraw.Draw(mask).rounded_rectangle([left, left + 0.012 * s, right, right + 0.012 * s], corner, fill=110)
        mask = mask.filter(ImageFilter.GaussianBlur(0.018 * s))
        canvas.paste(Image.new("RGBA", (s, s), (0, 0, 0, 255)), (0, 0), mask)

    gradient = Image.new("RGBA", (s, s))
    shade = ImageDraw.Draw(gradient)
    for y in range(s):
        t = min(max((y - left) / span, 0.0), 1.0)
        shade.line([(0, y), (s, y)], fill=tuple(int(TOP[k] + (BOTTOM[k] - TOP[k]) * t) for k in range(3)) + (255,))
    shape = Image.new("L", (s, s), 0)
    ImageDraw.Draw(shape).rounded_rectangle([left, left, right, right], corner, fill=255)
    canvas.paste(gradient, (0, 0), shape)

    room = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    draw = ImageDraw.Draw(room)
    at = lambda x, y: (left + x * span, left + y * span)  # (a point on the square, from 0 to 1 across and down)
    line = max(1, round(0.016 * span))
    back = [at(0.33, 0.30), at(0.67, 0.30), at(0.67, 0.58), at(0.33, 0.58)]
    near = [at(0.08, 0.08), at(0.92, 0.08), at(0.92, 0.92), at(0.08, 0.92)]
    for a, b in zip(back, near):  # the edges, running out to the viewer
        draw.line([a, b], fill=INK + (110,), width=line)
    draw.polygon(back, outline=INK + (255,), width=round(line * 1.2))

    middle = at(0.5, 0.79)  # sound, spreading across the floor from a point on it (rings, seen from the doorway)
    for k, reach in enumerate([0.08, 0.15, 0.22, 0.29]):
        r = reach * span
        box = [middle[0] - r, middle[1] - r * 0.36, middle[0] + r, middle[1] + r * 0.36]
        draw.ellipse(box, outline=INK + (int(240 - 50 * k),), width=round(line * 1.1))
    dot = 0.032 * span
    draw.ellipse([middle[0] - dot, middle[1] - dot * 0.45, middle[0] + dot, middle[1] + dot * 0.45], fill=INK + (255,))

    clipped = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    clipped.paste(room, (0, 0), Image.composite(room.getchannel("A"), Image.new("L", (s, s), 0), shape))
    canvas.alpha_composite(clipped)
    return canvas.resize((size, size), Image.LANCZOS)


if __name__ == "__main__":
    tile(1024, 0.0977, 0.225, True).save(GAME / "icon.png")  # (macOS's grid: an 824 px square in 1024)
    windows = tile(256, 0.02, 0.18, False)
    windows.save(GAME / "icon.ico", sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print("game/icon.png and game/icon.ico")
