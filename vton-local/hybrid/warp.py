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

import math
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


def _coverage(mask: np.ndarray, slot_mask: np.ndarray) -> float:
    """How much of the band the warp filled — over the ROWS IT CLAIMS, not all of them.

    The band for a dress or a pair of shorts deliberately runs to the ankle, because the
    base wears full-length trousers and the shins have to be repainted rather than left
    grey. Measured against that whole band, a mini dress can never score well: it covered
    its own rows completely and still came out at 0.31, under the 0.35 gate, so a correct
    warp was thrown away and the sampler invented a dress from the prompt — which it did
    across the entire band, giving a dress plus matching trousers plus matching shoes.
    That is the wardrobe's own polka-dot dress, measured.

    Restricting the denominator to the warp's own row span asks the question the gate
    actually wants answered: within the part of the body this garment claims, did its
    pixels arrive? A garment that covers half the band and fills that half is a success;
    one that covers half the band and fills a tenth of it is not, and still fails.
    """
    got = (mask > 0)
    if not got.any():
        return 0.0
    rows = np.flatnonzero(got.any(axis=1))
    band = (slot_mask[rows[0]:rows[-1] + 1] > 20)
    denom = max(1, int(band.sum()))
    return round(float(got.sum()) / denom, 3)


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
    # INCLUDE THE COLLAR. It was excluded first, on the reasoning that a collar is
    # plain fabric at a place the pose fixes exactly — and measured, that was
    # wrong: with the body warped in and denoising down at 0.55, the sampler had
    # less freedom and returned a boat neck for a crew and a keyhole for a V. The
    # flat-lay's own neckline is the right shape by definition, and the quad's top
    # edge is the shoulder line, so it lands about where it belongs.
    return (max(x0, px0), y0, min(x1, px1), y1)


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
        # KEEP THE PANEL'S OWN ASPECT, then clamp at the ankle. Anchoring the
        # bottom to the ankle stretched SHORTS into trousers — found immediately
        # on a test set with a shorts category, which the catalogue did not have.
        # Scaling the height by the same factor as the width needs no extra
        # measurement and separates the two cases for free: shorts stop at the
        # thigh, trousers reach the ankle and are clamped there.
        ankles = [pts[i][1] for i in (10, 13) if pts[i]]
        aspect = (gy1 - gy0) / max(1.0, gx1 - gx0)
        y_natural = y_top + aspect * (2.0 * half_top)
        y_bot = min(y_natural, (max(ankles) + span * 0.02) if ankles
                    else y_top + span * 0.45)
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
    cov = _coverage(mask, slot_mask)
    return Warped(image=img, mask=mask, coverage=cov)

def piecewise_affine(src: np.ndarray, src_pts: np.ndarray, dst_pts: np.ndarray,
                     shape: tuple[int, int]) -> tuple[np.ndarray, np.ndarray]:
    """Warp `src` so its `src_pts` land on `dst_pts`, triangle by triangle.

    Delaunay over the DESTINATION points, so the triangulation matches the frame
    being filled and no triangle degenerates on the side that matters. Returns the
    warped image and the region it covered, which is not the same as the convex
    hull: a T-shaped garment leaves the armpits empty and they must stay empty.
    """
    h, w = shape
    out = np.zeros((h, w, 3), np.uint8)
    filled = np.zeros((h, w), np.uint8)
    subdiv = cv2.Subdiv2D((0, 0, w, h))
    lookup: dict[tuple[int, int], int] = {}
    for i, (x, y) in enumerate(dst_pts):
        xi, yi = int(round(x)), int(round(y))
        if 0 <= xi < w and 0 <= yi < h:
            subdiv.insert((float(xi), float(yi)))
            lookup[(xi, yi)] = i
    for t in subdiv.getTriangleList():
        tri = [(int(round(t[i])), int(round(t[i + 1]))) for i in (0, 2, 4)]
        try:
            ids = [lookup[q] for q in tri]
        except KeyError:
            continue                      # Subdiv2D's outer bounding triangles
        d = np.float32([dst_pts[i] for i in ids])
        sp = np.float32([src_pts[i] for i in ids])
        r = cv2.boundingRect(d)
        if r[2] <= 0 or r[3] <= 0:
            continue
        local = d - np.float32([r[0], r[1]])
        m = cv2.getAffineTransform(sp, local)
        patch = cv2.warpAffine(src, m, (r[2], r[3]), flags=cv2.INTER_LINEAR,
                               borderMode=cv2.BORDER_REPLICATE)
        tm = np.zeros((r[3], r[2]), np.uint8)
        cv2.fillConvexPoly(tm, local.astype(np.int32), 255, cv2.LINE_AA)
        sl = (slice(r[1], r[1] + r[3]), slice(r[0], r[0] + r[2]))
        np.copyto(out[sl], patch, where=tm[:, :, None] > 0)
        filled[sl] = np.maximum(filled[sl], tm)
    return out, filled


def garment_keypoints(sil: np.ndarray, kind: str) -> dict | None:
    """The points that matter on a flat-lay, read off its own outline.

    The SCHEME is DeepFashion2's — which points a garment actually has per
    category: collar, shoulder seams, armpits, sleeve hems, side seams, hem
    corners. The DATA is not: that dataset is research/non-commercial only, so
    neither its images nor anything trained on them can ship here. A published
    taxonomy of where a sleeve ends is an idea, and computing those points from
    our own silhouette needs no dataset at all.

    Why bother when four corners already worked: a quad cannot express a sleeve.
    It maps a rectangle to a rectangle, so the sleeves had to be excluded and left
    to the sampler, which renders plain fabric acceptably and a striped or printed
    sleeve not at all. With the armpit and the sleeve hem as their own points, the
    warp carries the sleeve too.
    """
    ys, xs = np.nonzero(sil)
    if not ys.size:
        return None
    y0, y1, x0, x1 = int(ys.min()), int(ys.max()), int(xs.min()), int(xs.max())
    sub = sil[y0:y1 + 1, x0:x1 + 1]
    H, W = sub.shape
    if H < 24 or W < 24:
        return None
    rows = [np.flatnonzero(r) for r in sub]
    left = np.array([r[0] if r.size else -1 for r in rows], float)
    right = np.array([r[-1] if r.size else -1 for r in rows], float)
    if (left < 0).all():
        return None
    width = right - left

    if kind not in ("upper", "full"):
        # A bottom has no sleeves, so its outline gives nothing a quad does not.
        return None

    # The sleeve span is the widest row in the upper part of the garment.
    top = max(4, int(H * 0.45))
    y_wide = int(np.argmax(width[:top]))
    # THE ARMPIT IS A THRESHOLD ON THE WIDTH PROFILE, not a step in the outline.
    # The first attempt looked for the row where the edge leaps inward, which is
    # what a sharp T-shape does — and MEASURED, catalogue flat-lays do not: the
    # largest step was 2 px on a striped tee and 9 px on a graphic one, against a
    # 21-24 px threshold, so every garment fell through to the quad. Real sleeves
    # taper into the body over dozens of rows. Width is smooth, and halfway between
    # the sleeve span and the torso width is a stable place to call the armpit.
    w_max = float(width[y_wide])
    torso_lo = max(y_wide + 1, int(H * 0.68))
    torso_l = float(np.median(left[torso_lo:]))
    torso_r = float(np.median(right[torso_lo:]))
    w_torso = torso_r - torso_l
    # No sleeve worth warping: the widest row is barely wider than the body.
    if w_max - w_torso < W * 0.06:
        return None
    cut = (w_max + w_torso) / 2.0
    below = np.flatnonzero(width[y_wide:torso_lo] <= cut)
    if not below.size:
        return None
    ay_l = ay_r = y_wide + int(below[0])
    body_lo = ay_l

    # The extreme column on each side IS the cuff; its occupied rows are the
    # cuff's two ends.
    x_tip_l = int(left[:torso_lo].min())
    x_tip_r = int(right[:torso_lo].max())
    rows_l = np.flatnonzero(sub[:, x_tip_l])
    rows_r = np.flatnonzero(sub[:, x_tip_r])
    if rows_l.size < 2 or rows_r.size < 2:
        return None

    full_rows = np.flatnonzero(width[body_lo:] >= w_torso * 0.8)
    y_hem = (body_lo + int(full_rows[-1])) if full_rows.size else H - 1

    def pt(x, y):
        return [float(x + x0), float(y + y0)]

    return {
        "collar":     pt((left[0] + right[0]) / 2 if width[0] > 0 else W / 2, 0),
        # THE OUTLINE AT THE TOP IS NOT THE SHOULDER SEAM. On a flat-lay the widest
        # thing at 4% of the height is the pair of sleeve caps, so taking the
        # outline there and mapping it to the body's shoulders squeezed the
        # sleeves' fabric into the torso — measured as stripes bunched against both
        # edges of the chest and a print crowded under a diagonal. The seam is
        # where the sleeve leaves the body, which is the TORSO's own edge carried up
        # to the shoulder row.
        "shoulder_l": pt(left[max(1, int(H * 0.04))], int(H * 0.04)),
        "shoulder_r": pt(right[max(1, int(H * 0.04))], int(H * 0.04)),
        "seam_l":     pt(torso_l, int(H * 0.04)),
        "seam_r":     pt(torso_r, int(H * 0.04)),
        # THE CUFF IS AN EDGE, NOT A POINT. Using one point twice made the sleeve
        # quad degenerate — two coincident corners — and a degenerate perspective
        # transform filled the whole frame with the border colour, wiping the
        # torso that had been warped correctly a moment earlier. The cuff's own
        # column gives its two ends.
        "cuff_l":     pt(left[y_wide], y_wide),
        "cuff_r":     pt(right[y_wide], y_wide),
        "cuff_l_top": pt(x_tip_l, rows_l[0]),
        "cuff_l_bot": pt(x_tip_l, rows_l[-1]),
        "cuff_r_top": pt(x_tip_r, rows_r[0]),
        "cuff_r_bot": pt(x_tip_r, rows_r[-1]),
        "armpit_l":   pt(torso_l, ay_l),
        "armpit_r":   pt(torso_r, ay_r),
        "waist_l":    pt(torso_l, int(H * 0.75)),
        "waist_r":    pt(torso_r, int(H * 0.75)),
        # THE HEM IS NOT THE LAST ROW. The bottom row of a silhouette is the hem's
        # lowest tongue — measured on a striped tee, 10 px wide — and stretching
        # ten pixels across a whole torso produced a flat colour with no stripes
        # and no print at all. Take the lowest row where the garment is still
        # essentially full width.
        "hem_l":      pt(left[y_hem], y_hem),
        "hem_r":      pt(right[y_hem], y_hem),
    }


def mesh_warp(garment: np.ndarray, sil: np.ndarray, pose, kind: str,
              slot_mask: np.ndarray, sleeve_ratio: float | None,
              split) -> Warped | None:
    """The keypoint version of `torso_warp`: sleeves included.

    The body side of each garment point, in the same order as
    `garment_keypoints`. Every one of them is already established elsewhere in
    this engine, which is the point — the warp and the mask agree by construction
    rather than by coincidence:

      collar      the collar line, COLLAR_UP above the shoulders in the mask
      shoulder    the shoulder keypoints, widened by the same 1.30 as `gw`
      cuff        the sleeve reach measured off THIS flat-lay, walked down the
                  arm chain by `_split` — the number that made short sleeves short
      armpit      below the shoulder, at the torso's own edge
      waist/hem   the hip line and the mask's hem

    Falls back to None when a point is missing, so the caller can use the quad.
    """
    kp = garment_keypoints(sil, kind)
    if kp is None or sleeve_ratio is None:
        return None
    pts = pose.pts
    ls, rs, lh, rh = pts[5], pts[2], pts[11], pts[8]
    if not (ls and rs and lh and rh):
        return None
    ys = [q[1] for q in pts if q]
    span = max(1.0, max(ys) - min(ys))
    shoulder_px = abs(ls[0] - rs[0])
    gw = shoulder_px * 1.30
    cx = (ls[0] + rs[0]) / 2.0
    sh_y = min(ls[1], rs[1])
    hip_y = max(lh[1], rh[1])

    cuffs = {}
    for tag, ids in (("l", (5, 6, 7)), ("r", (2, 3, 4))):
        chain = [pts[i] for i in ids if pts[i]]
        if len(chain) < 2:
            return None
        total = sum(math.hypot(b[0] - a[0], b[1] - a[1])
                    for a, b in zip(chain, chain[1:]))
        reach = min(max(sleeve_ratio * gw, total * 0.18), total * 0.94)
        cuffs[tag] = split(chain, reach)[0][-1]

    body = {
        "collar":     [cx, sh_y - span * 0.045],
        "shoulder_l": [cx + gw / 2, sh_y],
        "shoulder_r": [cx - gw / 2, sh_y],
        "cuff_l":     list(cuffs["l"]),
        "cuff_r":     list(cuffs["r"]),
        "armpit_l":   [cx + gw / 2 * 0.86, sh_y + span * 0.085],
        "armpit_r":   [cx - gw / 2 * 0.86, sh_y + span * 0.085],
        "waist_l":    [cx + gw / 2 * 0.94, (sh_y + hip_y) / 2],
        "waist_r":    [cx - gw / 2 * 0.94, (sh_y + hip_y) / 2],
        "hem_l":      [cx + gw / 2, hip_y + span * 0.03],
        "hem_r":      [cx - gw / 2, hip_y + span * 0.03],
    }
    # `shoulder_l` in garment space is the LEFT edge of the flat-lay, which faces
    # the viewer's left — the same side as the body's `cx + gw/2`. Mirroring here
    # rather than in the dict keys keeps both dicts readable in their own frame.
    order = list(body)
    src = np.float32([kp[k] for k in order])
    dst = np.float32([body[k] for k in order])
    img, filled = piecewise_affine(garment, src, dst, (pose.h, pose.w))

    mask = cv2.bitwise_and(filled, (slot_mask > 20).astype(np.uint8) * 255)
    if not mask.any():
        return None
    cov = _coverage(mask, slot_mask)
    return Warped(image=img, mask=mask, coverage=cov)


def _quad_warp(garment: np.ndarray, sil: np.ndarray, src: np.ndarray,
               dst: np.ndarray, shape: tuple[int, int],
               out: np.ndarray, filled: np.ndarray) -> None:
    """Warp ONE part and lay it into the accumulating frame.

    The part's own silhouette goes through the same transform, so what lands is
    the garment's outline rather than a rectangle — an armpit stays empty, a
    tapered cuff stays tapered.
    """
    h, w = shape
    m = cv2.getPerspectiveTransform(src.astype(np.float32), dst.astype(np.float32))
    poly = np.zeros(sil.shape, np.uint8)
    cv2.fillConvexPoly(poly, src.astype(np.int32), 255)
    part = cv2.bitwise_and((sil > 0).astype(np.uint8) * 255, poly)

    # A HOLE IN THE FLAT-LAY IS NOT A HOLE IN THE OUTFIT. The gap between a pair of
    # trousers' legs is background in the photograph, so it was background in the
    # silhouette, so it punched a hole in what got laid down — and on a body whose
    # legs are together that hole lands ON the leg, showing the base through it as a
    # thin pale line down each outer seam. Same class for the gap inside a folded
    # sleeve. The garment's OUTER contour is what carries its shape; interior gaps
    # are an artefact of how it was photographed, and the slot mask still confines
    # everything to the body, so filling them cannot paint past the figure.
    cnts, _ = cv2.findContours(part, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if cnts:
        cv2.drawContours(part, cnts, -1, 255, cv2.FILLED)
    # And drop the outline itself. warpPerspective interpolates the IMAGE bilinearly
    # while the mask goes through nearest-neighbour, so the outermost pixels arrive
    # blended with the studio white they were photographed against — a bright rim
    # tracing every warped edge. Two source pixels is enough to lose it and far less
    # than any garment feature.
    er = max(2, int(round(min(part.shape) * 0.004))) | 1
    part = cv2.erode(part, np.ones((er, er), np.uint8), iterations=1)
    img = cv2.warpPerspective(garment, m, (w, h), flags=cv2.INTER_LINEAR,
                              borderMode=cv2.BORDER_REPLICATE)
    msk = cv2.warpPerspective(part, m, (w, h), flags=cv2.INTER_NEAREST)
    np.copyto(out, img, where=(msk > 0)[:, :, None])
    filled[msk > 0] = 255


def parts_warp(garment: np.ndarray, sil: np.ndarray, pose, kind: str,
               slot_mask: np.ndarray, sleeve_ratio: float | None,
               split, sleeves: bool = True,
               trace: list | None = None) -> Warped | None:
    """DEFORMABLE PARTS: the torso is one quad, each sleeve is its own.

    Why not one mesh over all of it — measured, and this is the whole reason this
    function exists. A single Delaunay mesh spanning torso and sleeves came back
    with wavy stripes and a chest print squeezed into an hourglass: a sleeve
    rotating onto a hanging arm shears every triangle it shares with the torso,
    and the torso is where the print is. Splitting them means the torso keeps a
    pure quad — no shear, straight stripes — and the sleeve's rotation stays
    inside the sleeve, where there is rarely a print and never text.

    Each part is a perspective map on four points, which cannot fold. The parts
    meet at the armpit and the shoulder seam, so they abut instead of overlapping,
    and the sleeve is drawn last: at the shoulder the sleeve's fabric is what sits
    on top in a real garment.
    """
    if kind not in ("upper", "full") or sleeve_ratio is None:
        return None
    kp = garment_keypoints(sil, kind)
    if kp is None:
        return None
    pts = pose.pts
    ls, rs, lh, rh = pts[5], pts[2], pts[11], pts[8]
    if not (ls and rs and lh and rh):
        return None
    ys = [q[1] for q in pts if q]
    span = max(1.0, max(ys) - min(ys))
    gw = abs(ls[0] - rs[0]) * 1.30
    cx = (ls[0] + rs[0]) / 2.0
    sh_y = float(min(ls[1], rs[1]))
    hip_y = float(max(lh[1], rh[1]))
    x_l, x_r = cx - gw / 2, cx + gw / 2          # image-left and image-right edges

    # A FLAT-LAY IS SHOT FROM THE FRONT, LIKE THE BODY, so its left edge is the
    # body's left edge in image coordinates. No mirroring — and getting this wrong
    # is one of the ways the mesh version sheared, since a sleeve crossing to the
    # far arm drags the whole triangulation with it.
    arm_left = (5, 6, 7) if ls[0] < rs[0] else (2, 3, 4)
    arm_right = (2, 3, 4) if ls[0] < rs[0] else (5, 6, 7)

    h, w = pose.h, pose.w
    out = np.zeros((h, w, 3), np.uint8)
    filled = np.zeros((h, w), np.uint8)

    # ── torso: shoulder seam to hem, the quad that already worked ──────────────
    t_src = np.float32([kp["seam_l"], kp["seam_r"], kp["hem_r"], kp["hem_l"]])
    t_dst = np.float32([[x_l, sh_y], [x_r, sh_y],
                        [x_r, hip_y + span * 0.03], [x_l, hip_y + span * 0.03]])
    _quad_warp(garment, sil, t_src, t_dst, (h, w), out, filled)
    if trace is not None:
        trace.append(("torso", t_src.copy(), t_dst.copy()))

    # ── sleeves: a ribbon along the bones ─────────────────────────────────────
    for side, ids, x_edge in ((("l", arm_left, x_l), ("r", arm_right, x_r))
                              if sleeves else ()):
        chain = [pts[i] for i in ids if pts[i]]
        if len(chain) < 2:
            continue
        total = sum(math.hypot(b[0] - a[0], b[1] - a[1])
                    for a, b in zip(chain, chain[1:]))
        reach = min(max(sleeve_ratio * gw, total * 0.16), total * 0.9)

        # A SLEEVE IS A RIBBON, NOT A QUAD, and this is the third design here for a
        # reason worth writing down. Three attempts mapped the sleeve with a single
        # quad and all three wrecked the TORSO — isolated by rendering the torso
        # alone, which came out clean. A quad maps a straight strip; the arm CHAIN
        # BENDS at the elbow, so one quad spanning shoulder to cuff has to shear,
        # and its own convex hull reaches across the chest, overwriting what was
        # already correct there.
        #
        # So: walk both the garment's sleeve and the arm in the same number of
        # steps, take a cross-section at each, and warp between consecutive
        # sections. Each little quad is nearly rectangular, the ribbon follows the
        # bend, and nothing it draws can land outside the sleeve.
        g_pit = np.float32(kp["armpit_" + side])
        g_seam = np.float32(kp["seam_" + side])
        g_top = np.float32(kp[f"cuff_{side}_top"])
        g_bot = np.float32(kp[f"cuff_{side}_bot"])
        # NO WIDTH SCAN AT ALL. Both boundaries are interpolations between the
        # sleeve's OWN FOUR CORNERS, subdivided along the arm. Scanning the
        # silhouette for a width was wrong twice over: the sleeve and the torso are
        # one connected blob so the scan walked into the chest (89 and 94 px on a
        # 94 px axis), and even clipped, a perpendicular section near the armhole
        # reaches inboard — traced, the second section's inner corner landed at
        # x=324 with the torso spanning 257..514, i.e. 40 px inside the chest.
        #
        # The armhole on a body is not a cross-section of the arm: it runs down the
        # side of the torso. So the ribbon is pinned at BOTH ends — the armhole edge
        # at t=0, the cuff edge at t=1 — and every section between is a linear
        # blend of the two. Each little quad is then nearly rectangular, the ribbon
        # follows the elbow, and nothing can reach past the armpit.
        s_poly = np.zeros(sil.shape, np.uint8)
        cv2.fillConvexPoly(s_poly, cv2.convexHull(np.float32(
            [g_seam, g_top, g_bot, g_pit]).astype(np.int32)), 255)
        s_sil = cv2.bitwise_and((sil > 0).astype(np.uint8) * 255, s_poly)

        # Body-side armhole edge and cuff edge.
        b_sh = np.float32([x_edge, sh_y])
        b_pit = np.float32([x_edge + (cx - x_edge) * 0.16, sh_y + span * 0.085])
        path_end = split(chain, reach)[0]
        cuff = np.float32(path_end[-1])
        prev = np.float32(path_end[-2] if len(path_end) > 1 else chain[0])
        d = cuff - prev
        nd = float(np.hypot(*d)) or 1.0
        n_b = np.float32([-d[1] / nd, d[0] / nd])
        if float(n_b[0]) * (x_edge - cx) < 0:
            n_b = -n_b
        # The cuff keeps the sleeve's own proportions: its width scales with its
        # length, the rule that stopped shorts stretching into trousers.
        g_axis = float(np.hypot(*((g_top + g_bot) / 2 - (g_seam + g_pit) / 2))) or 1.0
        half = max(span * 0.018,
                   float(np.hypot(*(g_bot - g_top))) * (reach / g_axis) * 0.5)
        b_cuff_up, b_cuff_dn = cuff + n_b * half, cuff - n_b * half

        N = 8
        secs = []
        for i in range(N + 1):
            t = i / N
            secs.append((g_seam + (g_top - g_seam) * t,     # src outer edge
                         g_pit + (g_bot - g_pit) * t,       # src inner edge
                         b_sh + (b_cuff_up - b_sh) * t,     # dst outer edge
                         b_pit + (b_cuff_dn - b_pit) * t))  # dst inner edge

        for i, ((a_up, a_dn, A_up, A_dn), (b_up, b_dn, B_up, B_dn)) in enumerate(
                zip(secs, secs[1:])):
            sq = np.float32([a_up, b_up, b_dn, a_dn])
            dq = np.float32([A_up, B_up, B_dn, A_dn])
            _quad_warp(garment, s_sil, sq, dq, (h, w), out, filled)
            if trace is not None:
                trace.append((f"{side}{i}", sq.copy(), dq.copy()))

    mask = cv2.bitwise_and(filled, (slot_mask > 20).astype(np.uint8) * 255)
    if not mask.any():
        return None
    cov = _coverage(mask, slot_mask)
    return Warped(image=out, mask=mask, coverage=cov)


def shoes_warp(garment: np.ndarray, sil: np.ndarray, pose,
               slot_mask: np.ndarray) -> Warped | None:
    """A pair of shoes onto a pair of feet, one quad each.

    THE EASIEST WARP IN THIS FILE, and the one with the most demo value: footwear
    appears in every look, and it was the weakest slot — the metrics reject shoes
    outright (no reference band applies to them), so nothing measured their length
    and the sampler was left to invent a shoe. It returned a brown mass up the calf
    from a brogue, which is what forced the shoe zone down from 7.5% of the figure
    to 3% and left boots unrenderable.

    Why it is easy: a shoe is nearly rigid, both feet are frontal, and the
    flat-lay is a pair photographed side by side — so it splits into two connected
    components and each maps onto one foot's own bounding box. No bend, no armhole,
    none of what defeated the sleeves.

    A single shoe in frame (one component) is mirrored for the other foot, which is
    what a catalogue photo of one shoe means anyway.

    THE SHOE IS STRETCHED TO THE FOOT'S BOX ON PURPOSE, and preserving its own
    aspect instead was tried and measured worse: coverage of the shoe zone fell
    from 56-63% to 30-45% and the base's white sneaker reappeared around the edges.
    A boot's proportions would be better served by the aspect, but the catalogue has
    no boots — that was protecting a hypothetical case at the cost of a visible one.
    Revisit when boots exist, with the zone height fixed in the same change.
    """
    n, lab, stats, cent = cv2.connectedComponentsWithStats((sil > 0).astype(np.uint8), 8)
    if n < 2:
        return None
    order = sorted(range(1, n), key=lambda i: -stats[i, cv2.CC_STAT_AREA])
    big = order[0]
    parts = [big]
    # A pair only if the second blob is a comparable object rather than a shadow.
    if len(order) > 1 and stats[order[1], cv2.CC_STAT_AREA] > stats[big, cv2.CC_STAT_AREA] * 0.45:
        parts.append(order[1])
    parts.sort(key=lambda i: cent[i][0])          # left blob first, image order

    pts = pose.pts
    ys = [q[1] for q in pts if q]
    if not ys:
        return None
    span = max(1.0, max(ys) - min(ys))
    ankles = [(i, pts[i]) for i in (10, 13) if pts[i]]
    if not ankles:
        return None
    ankles.sort(key=lambda a: a[1][0])             # left foot first, same order

    h, w = pose.h, pose.w
    out = np.zeros((h, w, 3), np.uint8)
    filled = np.zeros((h, w), np.uint8)

    for k, (ank_i, ank) in enumerate(ankles):
        # THE FOOT IS BELOW THE LAST KEYPOINT. COCO-18 stops at the ankle, so the
        # foot's extent comes from the matte: rows under the ankle, columns near it.
        pad = int(span * 0.075)
        y0 = max(0, ank[1] - int(span * 0.02))
        band = pose.silhouette[y0:h, max(0, ank[0] - pad):min(w, ank[0] + pad)]
        if not band.any():
            continue
        ys_, xs_ = np.nonzero(band)
        fx0 = max(0, ank[0] - pad) + int(xs_.min())
        fx1 = max(0, ank[0] - pad) + int(xs_.max())
        fy0, fy1 = y0 + int(ys_.min()), y0 + int(ys_.max())
        if fx1 - fx0 < 6 or fy1 - fy0 < 6:
            continue

        blob = parts[min(k, len(parts) - 1)]
        bx, by = stats[blob, cv2.CC_STAT_LEFT], stats[blob, cv2.CC_STAT_TOP]
        bw, bh = stats[blob, cv2.CC_STAT_WIDTH], stats[blob, cv2.CC_STAT_HEIGHT]
        one = ((lab == blob).astype(np.uint8) * 255)
        img = garment
        if len(parts) == 1 and k == 1:
            # Mirror the single shoe for the second foot, so a left shoe does not
            # appear twice.
            one = cv2.flip(one, 1)
            img = cv2.flip(garment, 1)
            bx = one.shape[1] - (bx + bw)

        # COVER, NOT STRETCH AND NOT FIT. The two options tried before were the two
        # bad ones. Stretching the blob's box onto the foot's box distorts by the
        # ratio of their aspects, and on the catalogue's shoes that ratio is brutal:
        # measured on the brogue, the flat-lay blob is 370x840 (aspect 0.44, a shoe
        # seen from the SIDE) while a frontal foot's box is about 1.5 wide to 1 tall
        # — a 3.5x squash, which is why the brogue arrived as a dark smear with a
        # pale cap instead of a shoe. Preserving the aspect and fitting INSIDE the
        # box was the other option, and it was measured worse for its own reason:
        # coverage fell to 30-45% and the base's own shoe showed around the edges.
        #
        # Covering does both jobs — scale by the LARGER ratio so the box is filled
        # completely, keep the aspect, and let the overflow fall outside (the slot
        # mask clips it anyway, two lines below). A side view still cannot become a
        # front view, but the leather, the colour and the local proportions survive.
        bw_f, bh_f = float(fx1 - fx0), float(fy1 - fy0)
        s = max(bw_f / max(1.0, bw), bh_f / max(1.0, bh))
        cx_s, cy_s = bx + bw / 2.0, by + bh / 2.0
        cx_d, cy_d = (fx0 + fx1) / 2.0, (fy0 + fy1) / 2.0
        hw_s, hh_s = bw_f / (2.0 * s), bh_f / (2.0 * s)
        src = np.float32([[cx_s - hw_s, cy_s - hh_s], [cx_s + hw_s, cy_s - hh_s],
                          [cx_s + hw_s, cy_s + hh_s], [cx_s - hw_s, cy_s + hh_s]])
        dst = np.float32([[fx0, fy0], [fx1, fy0], [fx1, fy1], [fx0, fy1]])
        # THE FOOT HAS AN ANGLE, AND THE BOX DOES NOT. The canonical pose is
        # mid-step: the trailing heel is raised and the foot's own axis
        # (heel→toe, MediaPipe 29-32 — COCO-18 stops at the ankle) tilts well
        # off the horizontal, but an axis-aligned quad dressed that foot as if
        # it stood flat — the crumpled derby on every phone render. Rotating
        # the DESTINATION quad by the measured axis angle stands the shoe on
        # its toe. Gated to angles that matter: the planted foot measures a
        # few degrees and stays byte-identical through the identity rotation.
        feet = getattr(pose, "feet", None) or {}
        # side from the JOINT INDEX, not from image order: sorted-by-x puts the
        # person's RIGHT foot first on a frontal photo (COCO 10=R, 13=L).
        side = "r" if ank_i == 10 else "l"
        heel, toe = feet.get(f"heel_{side}"), feet.get(f"toe_{side}")
        if heel and toe:
            ang = math.atan2(toe[1] - heel[1], toe[0] - heel[0])
            # a flat foot's heel→toe reads ±180° or 0° depending on which way
            # the toe points; fold to the deviation from horizontal
            dev = math.atan2(math.sin(ang), math.cos(ang))
            if dev > math.pi / 2:
                dev -= math.pi
            elif dev < -math.pi / 2:
                dev += math.pi
            if abs(dev) > math.radians(8):
                cd, sd = math.cos(dev), math.sin(dev)
                rot = []
                for qx, qy in dst:
                    ox, oy = qx - cx_d, qy - cy_d
                    rot.append([cx_d + ox * cd - oy * sd,
                                cy_d + ox * sd + oy * cd])
                dst = np.float32(rot)
                print("[shoe] %s foot tilted %.0f°" %
                      (side, math.degrees(dev)), flush=True)
        _quad_warp(img, one, src, dst, (h, w), out, filled)

    mask = cv2.bitwise_and(filled, (slot_mask > 20).astype(np.uint8) * 255)
    if not mask.any():
        return None
    cov = _coverage(mask, slot_mask)
    return Warped(image=out, mask=mask, coverage=cov)


def apply_shading(warped: np.ndarray, mask: np.ndarray, base: np.ndarray,
                  strength: float = 1.0) -> np.ndarray:
    """Give the flat garment the body's own light falloff. Colour is untouched.

    A flat-lay is lit flat, by design — even light, no shadows, so the catalogue
    photograph reads as a product rather than a scene. Warped onto a body it keeps
    that flatness and looks pasted on: no darkening at the sides, no lift on the
    chest, none of the shading that tells an eye the thing has volume.
    The body already carries that information, in the pixels the garment is
    covering. Normalising its luminance to its own mean turns it into a MULTIPLIER
    — bright where the light hits, dim in the folds — and multiplying is the one
    operation that adds shading without touching hue or saturation, which matters
    because garment colour is the thing we spent the whole warp preserving.

    Low-passed heavily first: the base's own seams, texture and print must not
    print through the new garment. Clamped, because a deep shadow on the base would
    otherwise stamp a black band onto a garment that has no such fold.
    """
    if not mask.any():
        return warped
    g = cv2.cvtColor(base, cv2.COLOR_BGR2GRAY).astype(np.float32)
    # 10% of the frame, not 4%. At 4% the base's own ARMHOLE SHADOWS survived the
    # blur and printed a hard dark band across a yellow tee — the field has to
    # carry the body's broad falloff and nothing that belongs to the garment
    # underneath, and a tank's edges are exactly the scale that got through.
    k = (max(3, int(base.shape[0] * 0.10)) | 1)
    field = cv2.GaussianBlur(g, (k, k), 0)
    m = mask > 20
    # NORMALISE PER ROW, NOT PER FIGURE. A single mean over the whole zone leaves
    # every VERTICAL step in the field intact — and on a real base those steps are
    # not the body, they are the OLD CLOTHES: a grey top against darker grey
    # trousers puts a luminance edge across the waist, inside the mask of a tee that
    # covers both. Measured the hard way: raising the strength to 2.0 drove that step
    # into the clamp and printed it as a seam across the shirt, pale above and olive
    # below with a ruler edge — reported from the phone, reverted the same hour.
    #
    # Dividing each row by its OWN mean removes exactly that and keeps exactly what
    # shading is for. What is left is the left-to-right falloff, which is the body
    # reading as a cylinder; what goes is every along-the-body change, which on this
    # base is the wardrobe underneath. Rows the mask does not reach fall back to the
    # zone mean so the arithmetic stays defined at the edges.
    mean = float(field[m].mean()) or 1.0
    rows = np.where(m.any(axis=1),
                    np.divide((field * m).sum(axis=1),
                              np.maximum(m.sum(axis=1), 1)), mean)
    rows[rows <= 1e-6] = mean
    # ±12%, not ±22%. Shading is meant to hint volume, and a deeper range lets any
    # residual structure in the field stamp itself onto flat fabric.
    ratio = np.clip(field / rows[:, None], 0.88, 1.12)
    ratio = 1.0 + (ratio - 1.0) * float(np.clip(strength, 0.0, 2.0))
    out = warped.astype(np.float32) * ratio[:, :, None]
    return np.where(m[:, :, None], np.clip(out, 0, 255), warped).astype(np.uint8)


def tps_warp(garment: np.ndarray, sil: np.ndarray, pose, kind: str,
             slot_mask: np.ndarray, rows: int = 9, cols: int = 7,
             wrap: float = 1.0) -> Warped | None:
    """Thin-plate spline onto the body, with the torso treated as a CYLINDER.

    A quad maps a plane to a plane. A body is not a plane, and the tell is the print:
    on a real tee the graphic compresses toward the sides as the fabric turns away
    from the camera, and a homography cannot express that at all — it can only shear.
    That missing foreshortening is what reads as an applique.

    The correction is orthographic projection of a cylinder. The flat-lay IS the
    unrolled surface, so a point u away from the garment's centre line lies at arc
    length u on the cylinder, at angle u/R, and the camera sees it at

        x = R * sin(u / R),     R = half the BODY's own width on that row

    which is identity at the centre and compresses to zero derivative at the profile.
    Rows come from the body's silhouette so the fit is the body's, not a rectangle's;
    `wrap` scales how much of the cylinder the garment is assumed to cover (1.0 wraps
    the full visible half; lower values keep more of the print flat).

    TPS is what turns that grid of correspondences into a smooth deformation: it is
    the interpolant that minimises the bending energy of a thin sheet, which is a
    reasonable stand-in for cloth that resists creasing. cv2's shape transformer
    solves exactly that system (U(r) = r² log r radial basis plus an affine term).

    VERIFIED ON A SYNTHETIC SYMMETRIC SKELETON, which isolates the algorithm from
    landmark noise: axis 384.0 against a spine at 384.0, flanks landing on xc ± R to
    within 0.00 px on both sides, mirrored |x - xc| identical to three decimals, and the
    column step compressing 63.2 px at the centre to 16.9 px at each flank — the same
    16.9 on both, which is the foreshortening this exists to produce. With the plain
    offset instead of arc length the flank would sit at 0.841 R = 106.4 against R = 126.5,
    leaving 20.1 px of the old garment showing down each side.

    Off by default. Kept behind VTON_TPS because the last non-rigid warp tried here —
    a single Delaunay mesh over torso and sleeves — measured worse than the quad:
    wavy stripes and a chest print squeezed into an hourglass. Non-rigid is only an
    improvement when the correspondences are right; when they are not, it is a
    licence to distort.
    """
    panel = _panel(sil, kind)
    if panel is None:
        return None
    gx0, gy0, gx1, gy1 = panel
    gw, gh = float(gx1 - gx0), float(gy1 - gy0)
    if gw < 8 or gh < 8:
        return None

    # THE CYLINDER IS ANCHORED TO THE SKELETON, NOT TO THE MASK. Taking the axis and
    # the radius from the mask's own extent was the bug: the mask holds the SLEEVES,
    # they lie asymmetrically, so the centre drifted off the spine and the warp sheared
    # one way. Measured on the striped tee, stripes landed -65.9 px at the left flank
    # against -23.7 px at the right — a bow that belongs to no body.
    #
    # Bones are symmetric by construction. The axis is the mean x of both shoulders and
    # both hips; the radius is half the WIDER of the two spans, scaled by 1.15 because
    # joints sit inside the flesh and the fabric sits outside it.
    pts_p = pose.pts
    ls, rs, lh, rh = pts_p[5], pts_p[2], pts_p[11], pts_p[8]
    anchors = [q for q in (ls, rs, lh, rh) if q]
    if len(anchors) < 3 or not (ls and rs):
        return None
    cxb = float(sum(q[0] for q in anchors)) / len(anchors)
    w_sh = abs(ls[0] - rs[0])
    w_hip = abs(lh[0] - rh[0]) if (lh and rh) else 0.0
    R = max(w_sh, w_hip) * 1.15 / 2.0
    if R < 6:
        return None

    ys_all = [q[1] for q in pts_p if q]
    span = max(1.0, max(ys_all) - min(ys_all))
    if kind in ("upper", "full"):
        ty0 = min(ls[1], rs[1]) - span * 0.02
        ty1 = (max(lh[1], rh[1]) + span * 0.03) if (lh and rh) else ty0 + span * 0.35
    else:
        if not (lh and rh):
            return None
        ty0 = min(lh[1], rh[1]) - span * 0.02
        ankles = [pts_p[i][1] for i in (10, 13) if pts_p[i]]
        aspect = gh / max(1.0, gw)
        ty1 = min(ty0 + aspect * (2.0 * R),
                  (max(ankles) + span * 0.02) if ankles else ty0 + span * 0.45)
    if ty1 - ty0 < 8:
        return None

    h, w = pose.h, pose.w
    src_pts, dst_pts = [], []
    for r in range(rows):
        fy = r / (rows - 1.0)
        ty = ty0 + fy * (ty1 - ty0)
        for c in range(cols):
            fx = c / (cols - 1.0)
            src_pts.append([gx0 + fx * gw, gy0 + fy * gh])
            # ARC LENGTH, not a plain offset. The flat-lay is the UNROLLED surface, so
            # the coordinate that spans the garment is arc length along the cylinder,
            # and the visible half spans a quarter turn each way: u in [-R*pi/2,
            # +R*pi/2] maps through sin to exactly [-R, +R], so the garment's own edge
            # lands on the profile. Feeding a plain pixel offset u = x - xc instead
            # tops out at sin(1) = 0.841 and dresses only 84% of the torso, leaving a
            # strip of the old garment down each flank — the same class of gap this
            # engine spent a day removing. `wrap` scales how much of that quarter turn
            # the garment is assumed to cover.
            u = (fx - 0.5) * 2.0 * R * (np.pi / 2.0) * wrap
            theta = float(np.clip(u / R, -np.pi / 2, np.pi / 2))
            dst_pts.append([cxb + R * np.sin(theta), ty])
    if len(src_pts) < 12:
        return None

    src = np.asarray(src_pts, np.float32).reshape(1, -1, 2)
    dst = np.asarray(dst_pts, np.float32).reshape(1, -1, 2)
    matches = [cv2.DMatch(i, i, 0) for i in range(src.shape[1])]

    tps = cv2.createThinPlateSplineShapeTransformer()
    # OpenCV's convention: estimateTransformation(target, source, matches) then
    # warpImage(source_image) produces the image sampled into the target frame.
    tps.estimateTransformation(dst, src, matches)

    pad = np.zeros((h, w, 3), np.uint8)
    ph, pw = min(h, garment.shape[0]), min(w, garment.shape[1])
    pad[:ph, :pw] = garment[:ph, :pw]
    pad_sil = np.zeros((h, w), np.uint8)
    pad_sil[:ph, :pw] = sil[:ph, :pw]

    out = tps.warpImage(pad, flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)
    msk = tps.warpImage(pad_sil, flags=cv2.INTER_NEAREST,
                        borderMode=cv2.BORDER_CONSTANT)
    msk = cv2.erode((msk > 0).astype(np.uint8) * 255,
                    np.ones((3, 3), np.uint8))
    mask = cv2.bitwise_and(msk, (slot_mask > 20).astype(np.uint8) * 255)
    if not mask.any():
        return None
    cov = _coverage(mask, slot_mask)
    return Warped(image=out, mask=mask, coverage=cov)


def harmonise_poisson(init: np.ndarray, warped: np.ndarray, mask: np.ndarray,
                      mode: int = cv2.NORMAL_CLONE) -> np.ndarray:
    """Gradient-domain paste of the warped garment into the base frame.

    Solves ∇²f = ∇·v over the mask with f fixed to the base on the boundary, which is
    what cv2.seamlessClone does: it keeps the garment's TEXTURE (its gradients) and
    takes its absolute level from the surroundings, so a studio-lit flat-lay inherits
    the photograph's own light instead of announcing itself with a seam.

    THE RISK IS THE WHOLE POINT OF THE WARP. Dirichlet boundaries do not merely adjust
    brightness — they drag the interior's colour toward whatever the boundary carries.
    Paste a yellow tee against grey basics and Poisson will happily desaturate it,
    which destroys the one property the warp exists to preserve. That is why this is
    a flag rather than the default, and why the caller should measure the garment's
    mean colour against the flat-lay's before and after.
    """
    m = (mask > 20).astype(np.uint8) * 255
    ys, xs = np.nonzero(m)
    if not ys.size:
        return init
    # seamlessClone needs the patch's centre and a mask with a clear border; a mask
    # touching the frame edge makes it throw.
    m[0, :] = m[-1, :] = m[:, 0] = m[:, -1] = 0
    ys, xs = np.nonzero(m)
    if not ys.size:
        return init
    centre = (int((xs.min() + xs.max()) / 2), int((ys.min() + ys.max()) / 2))
    try:
        return cv2.seamlessClone(warped, init, m, centre, mode)
    except cv2.error:
        return init


def dual_cylinder_warp(garment: np.ndarray, sil: np.ndarray, pose,
                       slot_mask: np.ndarray, rows: int = 9, cols: int = 5,
                       wrap: float = 1.0, radius_k: float = 0.55,
                       len_ratio: float | None = None) -> Warped | None:
    """Trousers onto TWO cylinders, one per leg, each with its own solver.

    The single-cylinder fit that works on a torso is wrong here and it showed: spanning
    one cylinder across the whole hip width compresses the fabric toward the flanks and
    smears the inseam into a bright rail down the leg — peak brightness excess 173
    against 152 for the plain quad, and unmistakable at full zoom on a phone.

    Two departures from the obvious dual-cylinder formulation, both from this base's
    geometry rather than from theory.

    THE AXIS IS NOT VERTICAL. Taking each leg's axis as its hip's x holds only for a
    figure standing to attention; on any real pose the chain hip → knee → ankle leans,
    and a vertical axis would place the fabric beside the leg instead of on it. The axis
    is therefore interpolated along that chain per row, which costs nothing and is the
    difference between fabric on a leg and fabric next to one.

    AND EACH LEG GETS ITS OWN SOLVER. A thin-plate spline is globally smooth by
    construction — that is what makes it a good model of cloth — so feeding one solver
    the correspondences of two separated cylinders would smooth away the very
    bifurcation the split exists to express. Two warps, unioned, keep the crotch a
    boundary instead of a blend.

    The projection itself is the torso's: the flat-lay is the unrolled surface, so the
    coordinate across each leg is arc length, and the visible half is a quarter turn
    each way — u in [-R*pi/2, R*pi/2] maps through sin to exactly [-R, R], putting each
    leg's outseam on its own profile.
    """
    panel = _panel(sil, "lower")
    if panel is None:
        return None
    gx0, gy0, gx1, gy1 = panel
    gw, gh = float(gx1 - gx0), float(gy1 - gy0)
    if gw < 16 or gh < 16:
        return None

    pts = pose.pts
    lh, rh = pts[11], pts[8]
    if not (lh and rh):
        return None
    ys_all = [q[1] for q in pts if q]
    span = max(1.0, max(ys_all) - min(ys_all))
    R = abs(lh[0] - rh[0]) * radius_k
    if R < 6:
        return None

    h, w = pose.h, pose.w
    ty0 = min(lh[1], rh[1]) - span * 0.02
    ankles = [pts[i][1] for i in (10, 13) if pts[i]]
    # THE GARMENT'S LENGTH COMES FROM ITS OWN MEASUREMENT when one exists.
    # len_ratio is length over reference width, both read off the flat-lay, so
    # length-on-body = len_ratio x width-on-body — no panel involved. The panel's
    # aspect stays only as the metric-less fallback: on a wardrobe shorts photo
    # the panel misread the frame and stretched knee shorts to the ankle.
    width_on_body = 2.0 * abs(lh[0] - rh[0]) * 0.78
    length = (len_ratio * width_on_body) if len_ratio else         (gh / max(1.0, gw)) * width_on_body
    ty1 = min(ty0 + length,
              (max(ankles) + span * 0.02) if ankles else ty0 + span * 0.45)
    if ty1 - ty0 < 16:
        return None

    pad = np.zeros((h, w, 3), np.uint8)
    ph, pw = min(h, garment.shape[0]), min(w, garment.shape[1])
    pad[:ph, :pw] = garment[:ph, :pw]
    pad_sil = np.zeros((h, w), np.uint8)
    pad_sil[:ph, :pw] = sil[:ph, :pw]

    out = np.zeros((h, w, 3), np.uint8)
    filled = np.zeros((h, w), np.uint8)
    src_mid = (gx0 + gx1) / 2.0

    # image-left leg first, so the flat-lay's left half meets the figure's left leg
    chains = []
    for ids in ((11, 12, 13), (8, 9, 10)):
        chain = [pts[i] for i in ids if pts[i]]
        if len(chain) >= 2:
            chains.append(chain)
    if len(chains) < 2:
        return None
    chains.sort(key=lambda c: c[0][0])

    for leg, chain in enumerate(chains):
        sx0 = gx0 if leg == 0 else src_mid
        sx1 = src_mid if leg == 0 else gx1
        if sx1 - sx0 < 8:
            continue
        cys = np.array([q[1] for q in chain], np.float32)
        cxs = np.array([q[0] for q in chain], np.float32)
        order = np.argsort(cys)
        cys, cxs = cys[order], cxs[order]

        src_pts, dst_pts = [], []
        for r in range(rows):
            fy = r / (rows - 1.0)
            ty = ty0 + fy * (ty1 - ty0)
            axis = float(np.interp(ty, cys, cxs))
            for c in range(cols):
                fx = c / (cols - 1.0)
                src_pts.append([sx0 + fx * (sx1 - sx0), gy0 + fy * gh])
                u = (fx - 0.5) * 2.0 * R * (np.pi / 2.0) * wrap
                theta = float(np.clip(u / R, -np.pi / 2, np.pi / 2))
                dst_pts.append([axis + R * np.sin(theta), ty])
        if len(src_pts) < 12:
            continue

        src = np.asarray(src_pts, np.float32).reshape(1, -1, 2)
        dst = np.asarray(dst_pts, np.float32).reshape(1, -1, 2)
        matches = [cv2.DMatch(i, i, 0) for i in range(src.shape[1])]
        tps = cv2.createThinPlateSplineShapeTransformer()
        tps.estimateTransformation(dst, src, matches)

        half = np.zeros((h, w), np.uint8)
        half[:, int(max(0, sx0)):int(min(w, sx1)) + 1] = 255
        one = cv2.bitwise_and(pad_sil, half)
        img = tps.warpImage(pad, flags=cv2.INTER_LINEAR,
                            borderMode=cv2.BORDER_CONSTANT)
        msk = tps.warpImage(one, flags=cv2.INTER_NEAREST,
                            borderMode=cv2.BORDER_CONSTANT)
        msk = cv2.erode((msk > 0).astype(np.uint8) * 255, np.ones((3, 3), np.uint8))
        take = (msk > 0) & (filled == 0)
        out[take] = img[take]
        filled[take] = 255

    mask = cv2.bitwise_and(filled, (slot_mask > 20).astype(np.uint8) * 255)
    if not mask.any():
        return None
    return Warped(image=out, mask=mask, coverage=_coverage(mask, slot_mask))


def sleeves_cylinder_warp(garment: np.ndarray, sil: np.ndarray, pose, kind: str,
                          slot_mask: np.ndarray, sleeve_ratio: float | None,
                          rows: int = 9, cols: int = 5) -> Warped | None:
    """Each sleeve onto its own arm cylinder — the leg treatment, one joint up.

    Six attempts at a sleeve QUAD failed for a reason that is now understood rather
    than mysterious: the armhole edge lies along the arm's axis, so a quad anchored
    to it is degenerate by construction. The dual-cylinder legs proved the primitive
    that works — a cylinder per limb, axis interpolated along the limb's own chain,
    its own TPS solver so the joint stays a boundary. An arm is the same problem one
    joint up, with one addition: the sleeve ENDS partway down, and where it ends
    comes from the flat-lay's own sleeve_ratio, not from a guess.

    Source geometry: on a flat-lay the sleeves stick out SIDEWAYS — the length axis
    is horizontal (armpit to cuff), the width axis vertical. The torso panel's
    columns say where the sleeves start; everything outside them is sleeve.
    Front-of-garment and front-of-person agree on image left/right, same as legs.
    """
    panel = _panel(sil, kind)
    if panel is None:
        return None
    gx0, gy0, gx1, gy1 = panel
    ys_s, xs_s = np.nonzero(sil)
    if not ys_s.size:
        return None
    sx_min, sx_max = int(xs_s.min()), int(xs_s.max())

    pts = pose.pts
    ys_all = [q[1] for q in pts if q]
    span = max(1.0, max(ys_all) - min(ys_all))
    h, w = pose.h, pose.w
    out = np.zeros((h, w, 3), np.uint8)
    filled = np.zeros((h, w), np.uint8)

    pad = np.zeros((h, w, 3), np.uint8)
    ph, pw = min(h, garment.shape[0]), min(w, garment.shape[1])
    pad[:ph, :pw] = garment[:ph, :pw]
    pad_sil = np.zeros((h, w), np.uint8)
    pad_sil[:ph, :pw] = sil[:ph, :pw]

    chains = []
    for ids in ((2, 3, 4), (5, 6, 7)):
        chain = [pts[i] for i in ids if pts[i]]
        if len(chain) >= 2:
            chains.append(chain)
    if len(chains) < 2:
        return None
    chains.sort(key=lambda c: c[0][0])          # image-left arm first

    # THE SOURCE IS A WEDGE BETWEEN ARMPIT AND CUFF, NOT A COLUMN BAND. The first
    # cut took every occupied row in the columns beside the torso panel — and on a
    # boxy tee the BODY is wider than the panel, so its rows rode along and the left
    # sleeve arrived as vertical smears of body fabric. garment_keypoints already
    # names the armpit, the shoulder seam and both ends of the cuff; between them
    # the sleeve is a wedge, and sampling that wedge takes sleeve fabric only.
    kp = garment_keypoints(sil, kind)

    for side, chain in enumerate(chains):       # 0 = image left
        if kp is not None:
            sfx = "l" if side == 0 else "r"
            armpit = kp[f"armpit_{sfx}"]
            seam = kp[f"seam_{sfx}"]
            c_top = kp[f"cuff_{sfx}_top"]
            c_bot = kp[f"cuff_{sfx}_bot"]
            def src_at(t: float):
                x = armpit[0] + t * (c_top[0] - armpit[0])
                y_lo = seam[1] + t * (c_top[1] - seam[1])
                y_hi = armpit[1] + t * (c_bot[1] - armpit[1])
                return x, y_lo, y_hi
        else:
            if side == 0:
                cx0, cx1 = sx_min, int(gx0)
            else:
                cx0, cx1 = int(gx1), sx_max
            if cx1 - cx0 < 8:
                continue
            band = pad_sil[:, cx0:cx1 + 1]
            rows_occ = np.flatnonzero(band.any(axis=1))
            if rows_occ.size < 8:
                continue
            ry0, ry1 = int(rows_occ[0]), int(rows_occ[-1])
            def src_at(t: float, _cx0=cx0, _cx1=cx1, _ry0=ry0, _ry1=ry1,
                       _side=side):
                x = (_cx1 - t * (_cx1 - _cx0)) if _side == 0 else (_cx0 + t * (_cx1 - _cx0))
                return x, _ry0, _ry1

        # TARGET: down the arm chain, as far as the sleeve actually reaches.
        seg = [(np.hypot(b[0] - a[0], b[1] - a[1])) for a, b in zip(chain, chain[1:])]
        chain_len = float(sum(seg))
        if chain_len < 8:
            continue
        gw_ref = float(gx1 - gx0)
        reach = min(chain_len, (sleeve_ratio * gw_ref) if sleeve_ratio
                    else 0.42 * chain_len)
        unit = float(np.hypot(chain[-1][0] - chain[-2][0],
                              chain[-1][1] - chain[-2][1])) or chain_len * 0.5
        r0, r1 = 0.45 * unit, 0.30 * unit

        # points along the chain at arc length t·reach, with the local perpendicular
        def at(dist: float):
            d = dist
            for a, b in zip(chain, chain[1:]):
                L = float(np.hypot(b[0] - a[0], b[1] - a[1]))
                if d <= L or (a, b) == (chain[-2], chain[-1]):
                    f = 0.0 if L == 0 else min(1.0, d / L)
                    cx = a[0] + (b[0] - a[0]) * f
                    cy = a[1] + (b[1] - a[1]) * f
                    ux, uy = ((b[0] - a[0]) / L, (b[1] - a[1]) / L) if L else (0, 1)
                    return (cx, cy), (-uy, ux)
                d -= L
            return (chain[-1][0], chain[-1][1]), (0.0, 1.0)

        src_pts, dst_pts = [], []
        for r in range(rows):
            t = r / (rows - 1.0)
            (cx, cy), (px_, py_) = at(t * reach)
            R = (r0 + (r1 - r0) * t)
            sx, sy_lo, sy_hi = src_at(t)
            # THE ACROSS-AXIS MUST POINT LATERAL ON BOTH ARMS. The chain runs
            # downward on both sides, so its perpendicular (-uy, ux) points the SAME
            # image direction for both — which is lateral for one arm and medial for
            # the other. With one sign, one sleeve mapped its outer edge onto the
            # inner side of the arm and the spline expressed the flip as a full
            # twist: the left sleeve arrived as a swirl while the right was clean.
            lat = 1.0 if side == 0 else -1.0
            for c in range(cols):
                f = c / (cols - 1.0)
                src_pts.append([sx, sy_lo + f * (sy_hi - sy_lo)])
                u = (f - 0.5) * 2.0 * R * (np.pi / 2.0)
                theta = float(np.clip(u / R, -np.pi / 2, np.pi / 2))
                off = R * np.sin(theta) * lat
                dst_pts.append([cx + px_ * off, cy + py_ * off])
        if len(src_pts) < 12:
            continue

        src = np.asarray(src_pts, np.float32).reshape(1, -1, 2)
        dst = np.asarray(dst_pts, np.float32).reshape(1, -1, 2)
        matches = [cv2.DMatch(i, i, 0) for i in range(src.shape[1])]
        tps = cv2.createThinPlateSplineShapeTransformer()
        tps.estimateTransformation(dst, src, matches)

        region = np.zeros((h, w), np.uint8)
        if kp is not None:
            quad = np.int32([[armpit[0], seam[1]], [c_top[0], c_top[1]],
                             [c_top[0], c_bot[1]], [armpit[0], armpit[1]]])
            cv2.fillConvexPoly(region, quad, 255)
        else:
            region[:, cx0:cx1 + 1] = 255
        one = cv2.bitwise_and(pad_sil, region)
        img = tps.warpImage(pad, flags=cv2.INTER_LINEAR,
                            borderMode=cv2.BORDER_CONSTANT)
        msk = tps.warpImage(one, flags=cv2.INTER_NEAREST,
                            borderMode=cv2.BORDER_CONSTANT)
        msk = cv2.erode((msk > 0).astype(np.uint8) * 255, np.ones((3, 3), np.uint8))
        take = (msk > 0) & (filled == 0)
        out[take] = img[take]
        filled[take] = 255

    mask = cv2.bitwise_and(filled, (slot_mask > 20).astype(np.uint8) * 255)
    if not mask.any():
        return None
    return Warped(image=out, mask=mask, coverage=_coverage(mask, slot_mask))


def sigmoid_merge(torso: Warped, sleeves: Warped, k: float = 0.5,
                  d0: float = 4.0) -> Warped:
    """Join two warps with a sigmoid over the distance to the torso's own region.

    The armhole is a topological break — torso and sleeve are different cylinders —
    so the join must be a RAMP, not a seam. W(d) = 1/(1+exp(k·(d−d0))) is 1 deep
    inside the torso's alpha and falls to 0 within ~2·d0/k pixels outside it, so in
    the overlap the torso owns its side, the sleeve owns the far side, and the
    handover is a few soft pixels along the seam line.
    """
    inv = (torso.mask == 0).astype(np.uint8)
    D = cv2.distanceTransform(inv, cv2.DIST_L2, 3)
    W = 1.0 / (1.0 + np.exp(np.clip(k * (D - d0), -30, 30)))
    img = torso.image.astype(np.float32)
    s_img = sleeves.image.astype(np.float32)
    only_s = (sleeves.mask > 0) & (torso.mask == 0)
    overlap = (sleeves.mask > 0) & (torso.mask > 0)
    outim = torso.image.copy()
    outim[only_s] = sleeves.image[only_s]
    if overlap.any():
        Wf = W[:, :, None]
        blend = img * Wf + s_img * (1.0 - Wf)
        outim[overlap] = np.clip(blend[overlap], 0, 255).astype(np.uint8)
    mask = cv2.bitwise_or(torso.mask, sleeves.mask)
    return Warped(image=outim, mask=mask, coverage=max(torso.coverage,
                                                       sleeves.coverage))
