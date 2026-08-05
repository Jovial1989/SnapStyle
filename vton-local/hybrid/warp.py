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
    cov = float((mask > 0).sum()) / max(1, int((slot_mask > 20).sum()))
    return Warped(image=img, mask=mask, coverage=round(cov, 3))

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
    cov = float((mask > 0).sum()) / max(1, int((slot_mask > 20).sum()))
    return Warped(image=img, mask=mask, coverage=round(cov, 3))


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
    img = cv2.warpPerspective(garment, m, (w, h), flags=cv2.INTER_LINEAR,
                              borderMode=cv2.BORDER_REPLICATE)
    msk = cv2.warpPerspective(part, m, (w, h), flags=cv2.INTER_NEAREST)
    np.copyto(out, img, where=(msk > 0)[:, :, None])
    filled[msk > 0] = 255


def parts_warp(garment: np.ndarray, sil: np.ndarray, pose, kind: str,
               slot_mask: np.ndarray, sleeve_ratio: float | None,
               split, sleeves: bool = True) -> Warped | None:
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
        # MEASURE THE SLEEVE INSIDE THE SLEEVE. On a flat-lay the sleeve and the
        # torso are ONE connected blob, so scanning the silhouette for the sleeve's
        # width walks straight into the chest and never exits — measured: half-
        # widths of 89 and 94 px on a sleeve whose axis is 94 px long, i.e. the
        # scan hit its own cap both ways. Every ribbon and quad attempt was fed
        # those numbers. Clipping to the sleeve's own quadrilateral first is what
        # makes the measurement mean anything.
        s_poly = np.zeros(sil.shape, np.uint8)
        cv2.fillConvexPoly(s_poly, cv2.convexHull(np.float32(
            [g_seam, g_top, g_bot, g_pit]).astype(np.int32)), 255)
        s_sil = cv2.bitwise_and((sil > 0).astype(np.uint8) * 255, s_poly)

        a_mid, c_mid = (g_seam + g_pit) / 2, (g_top + g_bot) / 2
        axis = c_mid - a_mid
        g_len = float(np.hypot(*axis)) or 1.0
        u_g = axis / g_len
        n_g = np.float32([-u_g[1], u_g[0]])
        # Orient the garment normal toward the sleeve's UPPER seam, which is the
        # side that runs along the outside of a hanging arm.
        if float(np.dot(n_g, g_top - c_mid)) < 0:
            n_g = -n_g
        scale = reach / g_len

        N = 8
        secs: list[tuple] = []
        for i in range(N + 1):
            t = i / N
            pg = a_mid + axis * t
            # Half-widths measured on the flat-lay itself, so a tapered sleeve
            # tapers and a wide one stays wide.
            hw = []
            for sgn in (1.0, -1.0):
                d = 0.0
                while d < g_len:
                    q = pg + n_g * sgn * (d + 1.0)
                    xi, yi = int(round(q[0])), int(round(q[1]))
                    if not (0 <= xi < s_sil.shape[1] and 0 <= yi < s_sil.shape[0]):
                        break
                    if s_sil[yi, xi] == 0:
                        break
                    d += 1.0
                hw.append(max(d, 1.0))
            path = split(chain, max(t * reach, 1e-3))[0]
            qb = np.float32(path[-1])
            prev = np.float32(path[-2] if len(path) > 1 else chain[0])
            dirv = qb - prev
            nb = float(np.hypot(*dirv)) or 1.0
            dirv = dirv / nb
            n_b = np.float32([-dirv[1], dirv[0]])
            if float(n_b[0]) * (x_edge - cx) < 0:
                n_b = -n_b
            up_b = qb + n_b * min(hw[0] * scale, span * 0.05)
            dn_b = qb - n_b * min(hw[1] * scale, span * 0.05)
            if i == 0:
                # THE ARMHOLE IS NOT A CROSS-SECTION OF THE ARM. On the body it
                # runs down the side of the torso, from the shoulder to the armpit,
                # while every other section of a hanging sleeve is across the arm.
                # Taking a perpendicular slice here put a 120 px band through the
                # chest and smeared the torso that had just been warped correctly —
                # the same damage as the three quad attempts, from the same place.
                up_b = np.float32([x_edge, sh_y])
                dn_b = np.float32([x_edge + (cx - x_edge) * 0.16,
                                   sh_y + span * 0.085])
            secs.append((pg + n_g * hw[0], pg - n_g * hw[1], up_b, dn_b))

        for (a_up, a_dn, A_up, A_dn), (b_up, b_dn, B_up, B_dn) in zip(secs, secs[1:]):
            _quad_warp(garment, s_sil,
                       np.float32([a_up, b_up, b_dn, a_dn]),
                       np.float32([A_up, B_up, B_dn, A_dn]),
                       (h, w), out, filled)

    mask = cv2.bitwise_and(filled, (slot_mask > 20).astype(np.uint8) * 255)
    if not mask.any():
        return None
    cov = float((mask > 0).sum()) / max(1, int((slot_mask > 20).sum()))
    return Warped(image=out, mask=mask, coverage=round(cov, 3))
