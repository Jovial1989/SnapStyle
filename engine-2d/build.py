"""Looktok 2D vector atelier — one visual language for avatar AND garments.

Avatar = the user's own cutout photo, vectorized (VTracer) → a personal
fashion-illustration figure ("полная копия юзера"). Garments = library
flat-lays, white-keyed then vectorized. Dressing = SVG layers over body
anchors — instant, offline, $0. Raster collage failed because it mixed photo
and sticker languages; all-vector unifies them.
"""
import pathlib
import vtracer
from PIL import Image, ImageFilter

ROOT = pathlib.Path(__file__).parent
CASES = ROOT.parent / "spike-qwen" / "cases"
OUT = ROOT / "svg"
OUT.mkdir(exist_ok=True)

def key_white(src: pathlib.Path, dst: pathlib.Path, thr=238):
    """Border-connected near-white → transparent (same trick as the app)."""
    im = Image.open(src).convert("RGBA")
    w, h = im.size
    px = im.load()
    seen = bytearray(w * h)
    stack = []
    def near_white(x, y):
        r, g, b, a = px[x, y]
        return r >= thr and g >= thr and b >= thr
    def seed(x, y):
        i = y * w + x
        if not seen[i] and near_white(x, y):
            seen[i] = 1
            stack.append((x, y))
    for x in range(w):
        seed(x, 0); seed(x, h - 1)
    for y in range(h):
        seed(0, y); seed(w - 1, y)
    while stack:
        x, y = stack.pop()
        if x > 0: seed(x - 1, y)
        if x < w - 1: seed(x + 1, y)
        if y > 0: seed(x, y - 1)
        if y < h - 1: seed(x, y + 1)
    for y in range(h):
        for x in range(w):
            if seen[y * w + x]:
                r, g, b, a = px[x, y]
                px[x, y] = (r, g, b, 0)
    # Crop to the garment's own bbox — leftover transparent margin would make
    # the SVG render tiny inside its anchor box (object-fit: contain).
    bbox = im.getbbox()
    if bbox:
        im = im.crop(bbox)
    im.save(dst)

def trace(src: pathlib.Path, dst: pathlib.Path, detail: int):
    vtracer.convert_image_to_svg_py(
        str(src), str(dst),
        colormode="color", hierarchical="stacked", mode="spline",
        filter_speckle=10, color_precision=detail, layer_difference=16,
        corner_threshold=60, length_threshold=4.0, splice_threshold=45,
    )
    print("traced", dst.name, f"{dst.stat().st_size//1024}KB")

def stylize(src: pathlib.Path, dst: pathlib.Path, colors=32):
    """Posterize into a fashion-illustration palette before tracing: median
    filter kills JPEG noise (the speckled face), quantize flattens skin and
    fabric into flat editorial planes."""
    im = Image.open(src).convert("RGB")
    im = im.filter(ImageFilter.MedianFilter(size=3))
    im = im.quantize(colors=colors, method=Image.MEDIANCUT, dither=Image.NONE)
    im.convert("RGB").save(dst)

# Avatar — the user himself, posterized into flat planes, then traced.
# NEUTRAL-BASE source: layering a garment over a photo of the user in his OWN
# clothes always leaves the old piece peeking (black tank at the shoulders,
# beige shorts at the sides). The canonical avatar — the user rendered once in
# plain grey basics — is the clean canvas every garment layers onto.
stylize(CASES / "01" / "gemini.png", OUT / "_avatar.png")
trace(OUT / "_avatar.png", OUT / "avatar.svg", detail=8)
# Garments — flat-lays, keyed then traced.
for case, name in [("01", "tee"), ("08", "shorts"), ("19", "chinos")]:
    keyed = OUT / f"_{name}.png"
    key_white(CASES / case / "garment.jpg", keyed)
    trace(keyed, OUT / f"{name}.svg", detail=6)
print("done")
