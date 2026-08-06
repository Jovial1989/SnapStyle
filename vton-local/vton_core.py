# Pure image prep for the local VTON worker — NO web framework here, so the
# bench (test_catvton.py) and the server (main.py) share one implementation.
#
# The mask is the interesting part: our person input is the canonical
# grey-basics avatar, so "which pixels are clothing" is a chroma threshold —
# the same one grid-vton uses server-side. No OpenPose, no human-parsing net,
# which is exactly what makes CatVTON runnable on this box at all.
import numpy as np
from PIL import Image, ImageFilter

# CatVTON's native res is 768x1024, but it concatenates person+cloth latents
# along Y, so self-attention sees ~24.5k tokens there → an 18 GiB attention
# buffer, which a 16 GB M1 Pro cannot allocate (measured 28.07.2026).
# 384x512 quarters the token count (~6.1k) and fits.
W, H = 384, 512


class NoFigure(ValueError):
    """Raised when the person image has no discernible subject."""


def fit(im: Image.Image, w: int = W, h: int = H) -> Image.Image:
    """Aspect-preserving fit into w x h on a white canvas."""
    im = im.convert("RGB")
    s = min(w / im.width, h / im.height)
    im = im.resize((max(1, round(im.width * s)), max(1, round(im.height * s))), Image.LANCZOS)
    canvas = Image.new("RGB", (w, h), "white")
    canvas.paste(im, ((w - im.width) // 2, (h - im.height) // 2))
    return canvas


def build_mask(person: Image.Image, category: str, generous: bool = True) -> Image.Image:
    """Cloth-agnostic mask, white = repaint.

    CatVTON/VITON-HD are trained with GENEROUS agnostic masks: the whole body
    region for the target slot is erased, not just the silhouette of what is
    worn now. A tight mask (first attempt, 28.07) forces the new garment into
    the old garment's outline — the model painted a black turtleneck and smeared
    the sleeves. So by default we erase a torso/leg BOX across the figure's
    width, keeping only the head out of it.
    """
    a = np.asarray(person).astype(int)
    mx, mn = a.max(-1), a.min(-1)
    # Studio backgrounds are near-white, not pure white, and LANCZOS softens the
    # edges — `any()` on a loose threshold once put the whole canvas in the bbox
    # and the mask landed on his face. Require a row/column to hold a real slice
    # of the subject before it counts.
    fig = mx < 235
    h, w = fig.shape
    rows = np.where(fig.sum(1) > max(3, w * 0.02))[0]
    cols = np.where(fig.sum(0) > max(3, h * 0.02))[0]
    if len(rows) < 10 or len(cols) < 5:
        raise NoFigure("no figure found in the person image")
    y0, y1 = int(rows.min()), int(rows.max())
    x0, x1 = int(cols.min()), int(cols.max())
    fh = y1 - y0
    neck = round(y0 + fh * 0.17)      # just under the chin
    hips = round(y0 + fh * 0.52)
    ankle = round(y1 - fh * 0.06)
    lap = max(6, round(fh * 0.03))    # waist overlap so tops/bottoms meet

    band = {"upper_body": (neck, hips + lap),
            "lower_body": (max(0, hips - lap), ankle)}.get(category, (neck, ankle))

    m = np.zeros(fig.shape, dtype=bool)
    if generous:
        # full-width box over the region: lets the model choose the silhouette
        pad = max(4, round((x1 - x0) * 0.10))
        m[band[0]:band[1], max(0, x0 - pad):min(m.shape[1], x1 + pad + 1)] = True
    else:
        # legacy: chroma segmentation of the grey basics, clipped to the region
        grey = (mx - mn < 28) & (mn > 80) & (mx < 225)
        grey[:neck, :] = False
        zone = np.zeros_like(grey)
        zone[band[0]:band[1], :] = True
        m = grey & zone
        if m.mean() < 0.02:
            m = np.zeros_like(grey)
            m[band[0]:band[1], x0:x1 + 1] = True
            m &= fig

    out = Image.fromarray((m * 255).astype(np.uint8))
    if not generous:
        k = max(3, int(round(person.width / 768 * 25)) | 1)
        out = out.filter(ImageFilter.MaxFilter(k)).filter(ImageFilter.GaussianBlur(max(1, k // 8)))
        out = out.point(lambda v: 255 if v > 64 else 0)
    return out
