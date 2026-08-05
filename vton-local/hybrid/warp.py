"""Put the garment's OWN PIXELS on the body, before diffusion sees it.

This is the answer to the one defect no mask work can touch. The adapter carries
a CLIP embedding of the flat-lay — a summary — so the sampler is told "off-white
boxy tee" and paints its own idea of one. Measured across the catalogue: colour
arrives, large patterns sometimes arrive (a plaid did, a chest graphic did),
prints and text do not, and cut never does — every pair of jeans rendered baggy
whether the reference was slim or straight.

A warp changes what the sampler is asked to do. The garment's pixels are placed
on the body first, so denoising at a reduced strength REFINES a real photograph of
that garment — adds folds, shading, the boundary with the neck — instead of
inventing a garment from a description. The print survives because it is the
source print.

WHAT THIS VERSION WARPS: the torso panel of an upper garment, and the leg panel
of a lower one. Not sleeves, not collars.

That is a deliberate first cut, not laziness. On a flat-lay the sleeves stick out
sideways; on a standing body the arms hang down. Mapping one to the other needs
per-sleeve correspondence and it is where a warp goes visibly wrong (a sleeve
landing in mid-air beside the torso). The torso is the easy half AND the valuable
half: it is where prints, logos, stripes and text live, it is the largest area,
and a quad-to-quad map onto a frontal body is well conditioned. Sleeves stay with
the sampler, which already renders plain fabric acceptably.

Everything here is OpenCV and numpy — no weights, no licence questions, and it
runs on a laptop, which is how it gets developed without paying for a GPU.
"""
from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np


@dataclass
class Warped:
    """The garment placed on the body, with the region it actually covers.

    `coverage` is the fraction of the slot's mask the warp filled. It is the
    number to gate on: a low value means the geometry did not work out and the
    caller should fall back to plain inpainting rather than composite a smear.
    """
    image: np.ndarray            # BGR, full frame, garment pixels in place
    mask: np.ndarray             # uint8 0/255, where those pixels are
    coverage: float


def _panel(sil: np.ndarray, kind: str) -> tuple[int, int, int, int] | None:
    """The rectangle of the flat-lay that is the garment's BODY, not its sleeves.

    Read off the width profile rather than guessed: the torso of a top is the part
    whose width is close to the garment's own reference width, which
    `_garment_metrics` already defines as the median width low in the frame. Rows
    much wider than that are the sleeve span, so they are excluded — and the
    columns are clipped to the reference width centred on the garment, which drops
    the sleeves horizontally too.
    """
    ys, xs = np.nonzero(sil)
    if not ys.size:
        return None
    y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
    H = y1 - y0 + 1
    rows = [np.flatnonzero(r) for r in sil[y0:y1 + 1]]
    width = np.array([(r[-1] - r[0] + 1) if r.size else 0 for r in rows], float)
    band = {"upper": (0.62, 0.95), "full": (0.30, 0.45), "lower": (0.02, 0.14)}
    if kind not in band:
        return None
    lo, hi = int(H * band[kind][0]), max(int(H * band[kind][1]), int(H * band[kind][0]) + 1)
    ref = float(np.median(width[lo:hi]))
    if ref < 8:
        return None
    cx = (x0 + x1) / 2.0
    px0, px1 = int(round(cx - ref / 2)), int(round(cx + ref / 2))
    if kind in ("upper", "full"):
        # Start below the collar so the neckline is not stretched onto the chest;
        # the sampler paints the collar, which it does well because a collar is
        # plain fabric at a place the pose fixes exactly.
        py0 = y0 + int(H * 0.06)
    else:
        py0 = y0
    return (max(x0, px0), py0, min(x1, px1), y1)


def torso_warp(garment: np.ndarray, sil: np.ndarray, pose, kind: str,
               slot_mask: np.ndarray) -> Warped | None:
    """Map the garment's panel onto the body's torso (or legs) as a quad.

    A PERSPECTIVE map on four corners, not a triangulated mesh. The body here is
    frontal and standing by construction, so the panel's corners are the whole
    story, and four points cannot fold or self-intersect the way a mesh can when
    one landmark is off. It is also ~1 ms, which keeps this on the CPU where it
    belongs.

    Returns None when the pose lacks the joints the quad needs, so the caller
    keeps its existing path instead of getting a half-warp.
    """
    rect = _panel(sil, kind)
    if rect is None:
        return None
    gx0, gy0, gx1, gy1 = rect
    if gx1 - gx0 < 8 or gy1 - gy0 < 8:
        return None

    pts = pose.pts
    ls, rs = pts[5], pts[2]
    lh, rh = pts[11], pts[8]
    ys = [q[1] for q in pts if q]
    if not ys:
        return None
    span = max(1.0, max(ys) - min(ys))

    if kind in ("upper", "full"):
        if not (ls and rs):
            return None
        # Fabric sits outside the joints; the same 1.30 the mask uses, so the warp
        # and the mask agree on where the garment's edge is.
        half_top = abs(ls[0] - rs[0]) * 0.65
        cx_top = (ls[0] + rs[0]) / 2.0
        y_top = min(ls[1], rs[1]) - span * 0.02
        # Bottom of the panel: the hem the mask allows. Wider than the top for a
        # boxy cut is the flat-lay's business, not ours — the panel's own aspect
        # carries that, which is the point of warping the panel rather than a box.
        y_bot = (max(lh[1], rh[1]) + span * 0.03) if (lh and rh) else y_top + span * 0.35
        half_bot = half_top
        cx_bot = cx_top if not (lh and rh) else (lh[0] + rh[0]) / 2.0
    else:
        if not (lh and rh):
            return None
        half_top = abs(lh[0] - rh[0]) * 0.78
        cx_top = (lh[0] + rh[0]) / 2.0
        y_top = min(lh[1], rh[1]) - span * 0.02
        ankles = [pts[i][1] for i in (10, 13) if pts[i]]
        y_bot = (max(ankles) + span * 0.02) if ankles else y_top + span * 0.45
        # Legs stand apart, so the bottom of the quad is as wide as the figure is
        # down there — read it off the matte rather than assuming a taper.
        band = pose.silhouette[int(max(0, y_bot - span * 0.05)):int(y_bot) + 1]
        occ = np.flatnonzero(band.any(axis=0)) if band.size else np.array([])
        half_bot = ((occ[-1] - occ[0]) / 2.0) if occ.size else half_top
        cx_bot = ((occ[-1] + occ[0]) / 2.0) if occ.size else cx_top

    src = np.float32([[gx0, gy0], [gx1, gy0], [gx1, gy1], [gx0, gy1]])
    dst = np.float32([[cx_top - half_top, y_top], [cx_top + half_top, y_top],
                      [cx_bot + half_bot, y_bot], [cx_bot - half_bot, y_bot]])
    m = cv2.getPerspectiveTransform(src, dst)
    h, w = pose.h, pose.w
    img = cv2.warpPerspective(garment, m, (w, h), flags=cv2.INTER_LINEAR,
                              borderMode=cv2.BORDER_REPLICATE)
    panel_mask = cv2.warpPerspective(
        (sil > 0).astype(np.uint8) * 255, m, (w, h), flags=cv2.INTER_NEAREST)

    # The warp may only claim pixels the slot already owns. Everything the mask
    # stage learned — hands out, the collar line, the hem, the outward allowance —
    # stays in force, and the warp cannot reintroduce a defect that cost a day.
    mask = cv2.bitwise_and(panel_mask, (slot_mask > 20).astype(np.uint8) * 255)
    mask = cv2.bitwise_and(mask, pose.silhouette)
    if not mask.any():
        return None
    cov = float((mask > 0).sum()) / max(1, int((slot_mask > 20).sum()))
    return Warped(image=img, mask=mask, coverage=round(cov, 3))
