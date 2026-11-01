"""Live2D Viewer app icon master generator.

Renders the app mark from a single set of geometry constants and exports
every platform asset in the repo. Run from anywhere:

    python design/icon/make_icon.py

The mark: three overlapping rounded squares standing for Live2D's layered
art meshes, the front one carrying a mask hole that reveals the layer
below. Flat colours only, no gradients.
"""
import math
import os
import struct
import tempfile

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))

MASTER = 512
SS = 4  # supersampling factor

# --- geometry, in 512x512 master space ---
TILE = "#EDEEF3"  # light stage
LAYER_BACK = "#C5CAE9"  # deepest layer
LAYER_MID = "#9FA8DA"  # middle layer
LAYER_FRONT = "#3F51B5"  # front layer (indigo 500)
MASK_HOLE = LAYER_MID  # hole reveals the middle layer

BACK_BOX = (92, 92, 324, 324)
MID_BOX = (140, 140, 372, 372)
FRONT_BOX = (188, 188, 420, 420)
CORNER = 64
HOLE = (304, 304, 46)

# Android adaptive icons: 108dp canvas, 72dp visible, 66dp safe circle.
# The mark's farthest pixel from centre is 205.42/512 of the canvas, so it
# must be scaled by 66 / (2 * 108 * 205.42/512) to stay inside that circle.
ADAPTIVE_SCALE = 0.76


def _rgba(hex_color, alpha=255):
    hex_color = hex_color.lstrip("#")
    return tuple(int(hex_color[i:i + 2], 16) for i in (0, 2, 4)) + (alpha,)


def render_mark(background=None):
    """The three stacked layers plus the mask hole.

    background=None yields a transparent canvas (adaptive icon foreground),
    otherwise the canvas is filled with that colour (flat icon master).
    """
    w = MASTER * SS
    img = Image.new("RGBA", (w, w), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if background is not None:
        d.rectangle([0, 0, w, w], fill=_rgba(background))

    for box, color in ((BACK_BOX, LAYER_BACK), (MID_BOX, LAYER_MID), (FRONT_BOX, LAYER_FRONT)):
        d.rounded_rectangle(
            [box[0] * SS, box[1] * SS, box[2] * SS, box[3] * SS],
            radius=CORNER * SS,
            fill=_rgba(color),
        )
    cx, cy, r = HOLE
    d.ellipse([(cx - r) * SS, (cy - r) * SS, (cx + r) * SS, (cy + r) * SS], fill=_rgba(MASK_HOLE))
    return img.resize((MASTER, MASTER), Image.LANCZOS)


def squircle_mask(size, n=5.0, samples=720, ss=4):
    """iOS-style superellipse, used to preview how the OS masks the tile."""
    big = size * ss
    m = Image.new("L", (big, big), 0)
    a = size / 2.0
    pts = []
    for i in range(samples):
        t = 2 * math.pi * i / samples
        c, s = math.cos(t), math.sin(t)
        pts.append((
            (a * math.copysign(abs(c) ** (2 / n), c) + a) * ss,
            (a * math.copysign(abs(s) ** (2 / n), s) + a) * ss,
        ))
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return m.resize((size, size), Image.LANCZOS)


def masked(img, size):
    """Downscale to size and apply the squircle mask (preview / .ico)."""
    small = img.resize((size, size), Image.LANCZOS)
    alpha = small.getchannel("A")
    small.putalpha(Image.composite(alpha, Image.new("L", (size, size), 0), squircle_mask(size)))
    return small


def write(path, img):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    print("wrote", os.path.relpath(path, REPO))


def _ico_entries(path):
    """Parse a Pillow-written .ico into {size: payload}."""
    with open(path, "rb") as f:
        raw = f.read()
    _, _, count = struct.unpack("<HHH", raw[:6])
    entries = {}
    offset = 6
    for _ in range(count):
        width, _, _, _, _, _, size, at = struct.unpack("<BBBBHHII", raw[offset:offset + 16])
        offset += 16
        entries[width or 256] = raw[at:at + size]
    return entries


def build_ico(img, sizes):
    """Assemble an .ico from Pillow-generated payloads.

    256px uses a PNG payload (half the bytes, and every Windows shell
    reads it); the smaller sizes use BMP payloads, because PNG-in-ICO is
    only reliably read by the shell — GDI+ size-specific lookups fail on
    it.
    """
    with tempfile.TemporaryDirectory() as tmp:
        png_path = os.path.join(tmp, "png.ico")
        bmp_path = os.path.join(tmp, "bmp.ico")
        pillow_sizes = [(size, size) for size in sizes]
        img.save(png_path, format="ICO", sizes=pillow_sizes)
        img.save(bmp_path, format="ICO", bitmap_format="bmp", sizes=pillow_sizes)
        png_entries = _ico_entries(png_path)
        bmp_entries = _ico_entries(bmp_path)

    directory = bytearray(struct.pack("<HHH", 0, 1, len(sizes)))
    payload = bytearray()
    for size in sizes:
        data = png_entries[size] if size == 256 else bmp_entries[size]
        offset = 6 + 16 * len(sizes) + len(payload)
        directory += struct.pack(
            "<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(data), offset
        )
        payload += data
    return bytes(directory + payload)


def export():
    flat = render_mark(background=TILE)

    # --- masters ---
    write(os.path.join(HERE, "live2d-viewer-icon-512.png"), flat)
    write(os.path.join(HERE, "live2d-viewer-icon-1024.png"), flat.resize((1024, 1024), Image.LANCZOS))

    # --- Android legacy launcher icons (full squircle tile) ---
    res = os.path.join(REPO, "app", "android", "app", "src", "main", "res")
    for density, size in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
        write(os.path.join(res, f"mipmap-{density}", "ic_launcher.png"), masked(flat, size))

    # --- Android adaptive foreground: mark only, scaled into the safe circle ---
    # The mark's farthest pixel from centre sits 205.42/512 of the master
    # width out. On a 108dp canvas that would be 43.3dp, so the mark is
    # scaled to 33/43.3 = 0.762 of the canvas to stay inside the 66dp circle.
    mark = render_mark(background=None)
    for density, size in (("mdpi", 108), ("hdpi", 162), ("xhdpi", 216), ("xxhdpi", 324), ("xxxhdpi", 432)):
        side = round(size * ADAPTIVE_SCALE)
        scaled = mark.resize((side, side), Image.LANCZOS)
        canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        off = (size - side) // 2
        canvas.alpha_composite(scaled, (off, off))
        write(os.path.join(res, f"mipmap-{density}", "ic_launcher_foreground.png"), canvas)

    # --- Windows .ico ---
    sizes = [16, 24, 32, 48, 64, 256]
    ico_path = os.path.join(REPO, "app", "windows", "runner", "resources", "app_icon.ico")
    os.makedirs(os.path.dirname(ico_path), exist_ok=True)
    with open(ico_path, "wb") as f:
        f.write(build_ico(masked(flat, 256), sizes))
    print("wrote", os.path.relpath(ico_path, REPO))


SVG = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512" role="img" aria-label="Live2D Viewer">
  <rect width="512" height="512" fill="{tile}"/>
  <rect x="{bx}" y="{by}" width="{bw}" height="{bh}" rx="{r}" fill="{back}"/>
  <rect x="{mx}" y="{my}" width="{mw}" height="{mh}" rx="{r}" fill="{mid}"/>
  <rect x="{fx}" y="{fy}" width="{fw}" height="{fh}" rx="{r}" fill="{front}"/>
  <circle cx="{hx}" cy="{hy}" r="{hr}" fill="{hole}"/>
</svg>
""".format(
    tile=TILE,
    back=LAYER_BACK, mid=LAYER_MID, front=LAYER_FRONT, hole=MASK_HOLE,
    bx=BACK_BOX[0], by=BACK_BOX[1], bw=BACK_BOX[2] - BACK_BOX[0], bh=BACK_BOX[3] - BACK_BOX[1],
    mx=MID_BOX[0], my=MID_BOX[1], mw=MID_BOX[2] - MID_BOX[0], mh=MID_BOX[3] - MID_BOX[1],
    fx=FRONT_BOX[0], fy=FRONT_BOX[1], fw=FRONT_BOX[2] - FRONT_BOX[0], fh=FRONT_BOX[3] - FRONT_BOX[1],
    r=CORNER,
    hx=HOLE[0], hy=HOLE[1], hr=HOLE[2],
)

if __name__ == "__main__":
    with open(os.path.join(HERE, "live2d-viewer-icon.svg"), "w", encoding="utf-8") as f:
        f.write(SVG)
    print("wrote", os.path.relpath(os.path.join(HERE, "live2d-viewer-icon.svg"), REPO))
    export()
