"""Body landmarks from the cutout silhouette — no ML, no deps beyond PIL.

The width profile of a standing full-body cutout carries every anchor we need:
the neck is the narrowest row up top, shoulders are the sharp widening right
below it, the waist is the narrowest row mid-torso, hips the widening below.
Deterministic, instant, and portable to Dart for the app (same arithmetic).

Emits svg/anchors.json — fractions of the image box, so the viewer can place
garments on the REAL body instead of guessed percentages.
"""
import json
import pathlib

from PIL import Image

ROOT = pathlib.Path(__file__).parent


def profile(img: Image.Image):
    """Per-row (left, right) extent of the subject."""
    im = img.convert("RGBA")
    w, h = im.size
    px = im.load()
    rows = []
    for y in range(h):
        lo, hi = None, None
        for x in range(w):
            r, g, b, a = px[x, y]
            solid = a > 40 and not (r > 238 and g > 238 and b > 238)
            if solid:
                if lo is None:
                    lo = x
                hi = x
        rows.append((lo, hi) if lo is not None else None)
    return rows, w, h


def landmarks(path: pathlib.Path) -> dict:
    rows, w, h = profile(Image.open(path))
    ys = [y for y, r in enumerate(rows) if r]
    top, bot = ys[0], ys[-1]
    H = bot - top
    width = lambda y: (rows[y][1] - rows[y][0]) if rows[y] else 0
    center = lambda y: ((rows[y][0] + rows[y][1]) / 2) if rows[y] else w / 2

    def band(a, b):
        return range(max(top, top + int(H * a)), min(bot, top + int(H * b)))

    # Neck: narrowest row in the head/neck band. Shoulders: the row just below
    # where width jumps hardest (arms + deltoids enter the profile).
    neck_y = min(band(0.10, 0.24), key=width)
    jumps = [(width(y + 3) - width(y), y) for y in band(0.14, 0.30)]
    shoulder_y = max(jumps)[1] + 4
    shoulder_w = max(width(y) for y in band(0.18, 0.32))
    # Waist: narrowest row mid-torso. Hip: widest row just below it.
    waist_y = min(band(0.38, 0.55), key=width)
    hip_y = max(band(0.45, 0.60), key=width)
    knee_y = top + int(H * 0.72)
    # Real silhouette width at each anchor line — garments sized from these
    # actually COVER what the user is already wearing (a fixed fraction of the
    # shoulder span left the old clothes peeking at the sides).
    span = lambda y: max(width(yy) for yy in range(max(top, y - 6), min(bot, y + 7)))
    f = lambda v, size: round(v / size, 4)
    return {
        "image": [w, h],
        "centerX": f(center(shoulder_y), w),
        "neckY": f(neck_y, h),
        "shoulderY": f(shoulder_y, h),
        "shoulderW": f(shoulder_w, w),
        "waistY": f(waist_y, h),
        "hipY": f(hip_y, h),
        "kneeY": f(knee_y, h),
        "ankleY": f(bot, h),
        "topY": f(top, h),
        "chestW": f(span(shoulder_y + int(H * 0.10)), w),
        "hipW": f(span(hip_y), w),
        "kneeW": f(span(knee_y), w),
    }


if __name__ == "__main__":
    src = ROOT.parent / "spike-qwen" / "cases" / "01" / "gemini.png"
    lm = landmarks(src)
    (ROOT / "svg" / "anchors.json").write_text(json.dumps(lm, indent=1))
    print(json.dumps(lm, indent=1))
