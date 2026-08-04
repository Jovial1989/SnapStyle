"""Hybrid VTON: geometry from classical CV, pixels from diffusion.

  Stage A — pose + silhouette   MediaPipe Pose (Apache-2.0), CPU, ~40 ms
  Stage B — conditioning        OpenPose-style skeleton + Canny (OpenCV)
  Stage C — neuro-render        SD-inpaint + MultiControlNet + IP-Adapter

Two decisions worth knowing before you read the code:

1. SD 1.5 is the DEFAULT BASE, not SDXL. The local target is 16 GB of unified
   memory shared with the OS. SDXL-inpaint + two SDXL ControlNets + a ViT-H
   image encoder does not stay resident there; it only runs under sequential
   offload, which turns one render into minutes of PCIe-less page shuffling on
   MPS. SD 1.5 keeps the whole graph in memory. `VTON_BASE=sdxl` switches to
   the SDXL graph for the CUDA deployment, where it is the better model.

2. The model NEVER owns the final pixels outside the mask. Its answer is
   composited back over the ORIGINAL full-resolution avatar through the same
   feathered mask that constrained it. Identity is then a constructive
   guarantee (those pixels are literally untouched), not something we hope the
   sampler preserved. Everything upstream — a bad seed, a drifting face, a
   hallucinated background — is bounded by the mask.
"""

from __future__ import annotations

import math
import os
import threading
from dataclasses import dataclass

import cv2
import mediapipe as mp
import numpy as np
import torch
from PIL import Image

# ─────────────────────────────── device / precision ──────────────────────────

DEVICE = (
    "mps" if torch.backends.mps.is_available()
    else "cuda" if torch.cuda.is_available()
    else "cpu"
)
# fp16 everywhere it is real. CPU fp16 is emulated and ~10× slower than fp32,
# so the CPU fallback stays fp32 rather than pretending to honour the flag.
DTYPE = torch.float16 if DEVICE in ("mps", "cuda") else torch.float32

BASE = os.getenv("VTON_BASE", "sd15").lower()          # sd15 | sdxl
# 20, not the usual 28: measured side by side at a fixed seed, 28 and 20 are
# indistinguishable on garment renders (same neckline, same sleeve hem, same
# fold shading) while 20 is 25% faster. Quality only breaks below ~16, where
# fabric shading flattens into a colour fill.
STEPS = int(os.getenv("VTON_STEPS", "20"))
# Offload is OFF by default on every device. It shuttles weights CPU↔GPU on
# each step; on MPS ("unified" memory!) that measured 50+ min for one 512×768
# render, and on a 24 GB card the whole fp16 stack (~10 GB even for SDXL) fits
# resident with room to spare, so paying that tax buys nothing. Turn it on with
# VTON_OFFLOAD=1 only when squeezing SDXL onto a 12 GB card.
OFFLOAD = os.getenv("VTON_OFFLOAD", "0") == "1"
# xformers: CUDA-only, and only worth it where torch SDPA is not already
# picking a flash kernel. Never on MPS (no xformers backend there).
XFORMERS = os.getenv("VTON_XFORMERS", "1") == "1" and torch.cuda.is_available()

# SD 1.5 was trained at 512²; 768×1024 is off-distribution for it and shows up
# as duplicated torsos. SDXL wants ~1 megapixel. Different defaults per base.
WORK_W, WORK_H = (
    (int(os.getenv("VTON_W", "768")), int(os.getenv("VTON_H", "1024")))
    if BASE == "sdxl"
    else (int(os.getenv("VTON_W", "512")), int(os.getenv("VTON_H", "768")))
)

_MODELS = {
    "sd15": {
        "base": "stable-diffusion-v1-5/stable-diffusion-inpainting",
        "pose": "lllyasviel/control_v11p_sd15_openpose",
        "canny": "lllyasviel/control_v11p_sd15_canny",
        "ip_repo": "h94/IP-Adapter",
        "ip_sub": "models",
        "ip_weight": "ip-adapter-plus_sd15.bin",
    },
    "sdxl": {
        "base": "diffusers/stable-diffusion-xl-1.0-inpainting-0.1",
        "pose": "thibaud/controlnet-openpose-sdxl-1.0",
        "canny": "diffusers/controlnet-canny-sdxl-1.0",
        "ip_repo": "h94/IP-Adapter",
        "ip_sub": "sdxl_models",
        "ip_weight": "ip-adapter-plus_sdxl_vit-h.safetensors",
    },
}

# ───────────────────────────── Stage A: pose + mask ──────────────────────────

# MediaPipe emits 33 landmarks; ControlNet's OpenPose annotator speaks COCO-18.
# Index → MediaPipe index, in COCO order. `None` = derived (neck).
_COCO_FROM_MP = [
    0,      # 0  nose
    None,   # 1  neck  (midpoint of shoulders)
    12,     # 2  right shoulder
    14,     # 3  right elbow
    16,     # 4  right wrist
    11,     # 5  left shoulder
    13,     # 6  left elbow
    15,     # 7  left wrist
    24,     # 8  right hip
    26,     # 9  right knee
    28,     # 10 right ankle
    23,     # 11 left hip
    25,     # 12 left knee
    27,     # 13 left ankle
    5,      # 14 right eye
    2,      # 15 left eye
    8,      # 16 right ear
    7,      # 17 left ear
]

_LIMBS = [
    (1, 2), (1, 5), (2, 3), (3, 4), (5, 6), (6, 7), (1, 8), (8, 9), (9, 10),
    (1, 11), (11, 12), (12, 13), (1, 0), (0, 14), (14, 16), (0, 15), (15, 17),
]

_COLORS = [
    (255, 0, 0), (255, 85, 0), (255, 170, 0), (255, 255, 0), (170, 255, 0),
    (85, 255, 0), (0, 255, 0), (0, 255, 85), (0, 255, 170), (0, 255, 255),
    (0, 170, 255), (0, 85, 255), (0, 0, 255), (85, 0, 255), (170, 0, 255),
    (255, 0, 255), (255, 0, 170), (255, 0, 85),
]

_VIS = 0.35  # below this MediaPipe is guessing; drawing it misleads ControlNet


@dataclass
class Pose:
    """COCO-18 keypoints in pixels; `None` where the joint isn't visible."""
    pts: list[tuple[int, int] | None]
    silhouette: np.ndarray          # uint8 0/255, HxW
    w: int
    h: int


class PoseReader:
    """MediaPipe Pose with segmentation on. One call gives both the skeleton
    and the person matte, so there is no second model to load or keep in sync."""

    def __init__(self) -> None:
        self._pose = mp.solutions.pose.Pose(
            static_image_mode=True,
            model_complexity=2,
            enable_segmentation=True,
            min_detection_confidence=0.4,
        )
        self._lock = threading.Lock()

    def read(self, bgr: np.ndarray) -> Pose:
        h, w = bgr.shape[:2]
        with self._lock:  # the solution object is not thread-safe
            res = self._pose.process(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB))
        if not res.pose_landmarks:
            raise ValueError("no person detected in the avatar photo")

        lm = res.pose_landmarks.landmark

        def at(i: int) -> tuple[int, int] | None:
            p = lm[i]
            if p.visibility < _VIS:
                return None
            return int(p.x * w), int(p.y * h)

        pts: list[tuple[int, int] | None] = []
        for mp_idx in _COCO_FROM_MP:
            if mp_idx is None:
                ls, rs = at(11), at(12)
                pts.append(
                    ((ls[0] + rs[0]) // 2, (ls[1] + rs[1]) // 2)
                    if ls and rs else None
                )
            else:
                pts.append(at(mp_idx))

        if res.segmentation_mask is None:
            sil = np.full((h, w), 255, np.uint8)
        else:
            sil = (res.segmentation_mask > 0.5).astype(np.uint8) * 255
            sil = cv2.morphologyEx(
                sil, cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8)
            )
        return Pose(pts, sil, w, h)


def _draw_openpose(p: Pose) -> np.ndarray:
    """Canonical OpenPose rendering — the exact colours ControlNet was trained
    on. A monochrome stick figure is a much weaker signal; the hue carries the
    joint identity."""
    canvas = np.zeros((p.h, p.w, 3), np.uint8)
    stroke = max(2, round(min(p.w, p.h) / 180))

    for i, (a, b) in enumerate(_LIMBS):
        pa, pb = p.pts[a], p.pts[b]
        if not (pa and pb):
            continue
        mx, my = (pa[0] + pb[0]) / 2, (pa[1] + pb[1]) / 2
        length = math.hypot(pa[0] - pb[0], pa[1] - pb[1])
        angle = math.degrees(math.atan2(pa[1] - pb[1], pa[0] - pb[0]))
        poly = cv2.ellipse2Poly(
            (int(mx), int(my)), (int(length / 2), stroke), int(angle), 0, 360, 1
        )
        cv2.fillConvexPoly(canvas, poly, _COLORS[i])

    canvas = (canvas.astype(np.float32) * 0.6).astype(np.uint8)
    for i, pt in enumerate(p.pts):
        if pt:
            cv2.circle(canvas, pt, stroke + 1, _COLORS[i], -1)
    return canvas


def _walk(chain: list[tuple[int, int]], dist: float) -> list[tuple[int, int]]:
    """The first `dist` pixels of a polyline, as a polyline.

    Used to lay a sleeve of measured length along the arm: the flat-lay says how
    far the sleeve reaches, the pose says where the arm goes, and this puts one
    on the other.
    """
    out = [chain[0]]
    left = dist
    for a, b in zip(chain, chain[1:]):
        seg = math.hypot(b[0] - a[0], b[1] - a[1])
        if seg <= 1e-6:
            continue
        if seg >= left:
            t = left / seg
            out.append((round(a[0] + (b[0] - a[0]) * t),
                        round(a[1] + (b[1] - a[1]) * t)))
            return out
        out.append(b)
        left -= seg
    return out


def _garment_metrics(garment: np.ndarray, kind: str) -> dict | None:
    """Measure the flat-lay so the mask can follow the CUT, not the slot.

    The zone mask has to be generous — traced around the existing clothes it
    could never grow a different silhouette, so a tee would never become a
    puffer. But generosity has a mirror cost: inpainting must fill its whole
    mask, and where the new garment is SHORTER than the zone the model invents
    something. A short-sleeve tee came back long-sleeved, with a halo tracing
    the figure. Three fixes were tried and measured away (adapter scale, fill
    colour, compositing by difference) because none of them addressed the shape.

    The flat-lay already knows the shape. It is a garment on white, so a
    threshold separates it exactly, and its own proportions say where the
    sleeves end and where the hem falls. What it cannot give is placement: laid
    flat the sleeves point sideways, on a standing body the arms hang down. So
    this returns RATIOS, in units of the garment's own width, and the mask
    builder scales them onto the pose. Cut without a dictionary of garment
    names, and no rigid stamp that would land the sleeves in mid-air.

        len_ratio     collar→hem, over torso width  (crop top ≈ 0.8, coat ≈ 1.8)
        sleeve_ratio  shoulder→cuff, over torso width  (vest 0, long sleeve ≈ 1)

    Returns None when the flat-lay is unusable — a busy background, no clear
    object, a garment cropped by the frame. The caller then keeps the slot band,
    which is wrong in a known way rather than wrong in a surprising one.
    """
    g = cv2.cvtColor(garment, cv2.COLOR_BGR2GRAY) if garment.ndim == 3 else garment
    g = cv2.medianBlur(g, 5)
    h, w = g.shape

    # SEPARATE BY FLOOD-FILLING THE BACKGROUND, not by thresholding the garment.
    # "Garment on white" does not mean "garment is darker than 235": the first
    # catalogue top measured is an off-white tee at grey 238 on paper at 252, and
    # a threshold picked up its shadow instead of the shirt (2% of the frame — it
    # would have failed the size check and silently fallen back). Filling inward
    # from the border finds the background by connectivity, whatever the garment
    # is. FIXED_RANGE is the part that matters: the default compares each pixel
    # to its NEIGHBOUR, so the fill walks up the soft shadow gradient and eats
    # the whole white shirt (measured: zero object left at every tolerance).
    # Against the SEED value it stops at the shadow, as intended.
    m = np.zeros((h + 2, w + 2), np.uint8)
    flags = 4 | cv2.FLOODFILL_MASK_ONLY | cv2.FLOODFILL_FIXED_RANGE | (255 << 8)
    for seed in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1),
                 (w // 2, 0), (w // 2, h - 1)):
        cv2.floodFill(g.copy(), m, seed, 255, 5, 5, flags)
    ink = (m[1:-1, 1:-1] == 0).astype(np.uint8)
    ink = cv2.morphologyEx(ink, cv2.MORPH_CLOSE, np.ones((11, 11), np.uint8))
    ink = cv2.morphologyEx(ink, cv2.MORPH_OPEN, np.ones((5, 5), np.uint8))

    n, lab, stats, _ = cv2.connectedComponentsWithStats(ink, 8)
    if n < 2:
        return None
    best = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    if stats[best, cv2.CC_STAT_AREA] < g.size * 0.02:
        return None
    sil = (lab == best).astype(np.uint8)
    ys, xs = np.nonzero(sil)
    y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
    # A garment touching the frame edge is cropped, so its length is unknown and
    # a ratio taken from it would be a lie. Better to fall back to the band.
    if y0 <= 1 or x0 <= 1 or y1 >= h - 2 or x1 >= w - 2:
        return None
    sil = sil[y0:y1 + 1, x0:x1 + 1]
    H, W = sil.shape
    if H < 24 or W < 24:
        return None

    rows = [np.flatnonzero(r) for r in sil]
    width = np.array([(r[-1] - r[0] + 1) if r.size else 0 for r in rows], float)

    # Where to read the garment's own width. For a top the hem is the torso; for
    # a dress the hem is a skirt, so read its waist instead; for a bottom it is
    # the waistband at the very top.
    band = {
        "upper": (0.62, 0.95),
        "full": (0.30, 0.45),
        "lower": (0.02, 0.14),
    }.get(kind)
    if band is None:
        return None
    lo, hi = int(H * band[0]), max(int(H * band[1]), int(H * band[0]) + 1)
    ref = float(np.median(width[lo:hi]))
    if ref < 8:
        return None

    # PLAUSIBLE RATIOS ONLY. A catalogue row could hold a worn shot instead of a
    # flat-lay, and a person's proportions would sail through everything above —
    # then the mask would follow the photo's body rather than the garment. Real
    # garments live in a narrow band of length-over-width; outside it, fall back
    # to the slot band rather than trust a measurement of the wrong thing.
    len_ratio = H / ref
    lo_r, hi_r = {"upper": (0.55, 2.6), "full": (1.2, 4.0),
                  "lower": (0.7, 4.2)}[kind]
    if not lo_r <= len_ratio <= hi_r:
        return None

    out = {"len_ratio": len_ratio}
    if kind in ("upper", "full"):
        # Sleeve as one straight segment from the shoulder corner to the cuff.
        # Measuring only horizontal reach under-reads a sleeve laid diagonally,
        # which is how long sleeves are usually photographed.
        cx = W / 2.0
        shoulder_y = H * 0.06
        reach = 0.0
        for side in (0, 1):
            tip_x = 0 if side == 0 else W - 1
            col = np.flatnonzero(sil[:, tip_x])
            if not col.size:
                # Sleeve does not reach the crop edge: find the extreme column
                # that any row occupies on this side.
                ext = [r[0] if side == 0 else r[-1] for r in rows if r.size]
                tip_x = min(ext) if side == 0 else max(ext)
                col = np.flatnonzero(sil[:, tip_x])
            if not col.size:
                continue
            tip_y = float(col.mean())
            dx = abs(cx + (ref / 2.0) * (1 if side else -1) - tip_x)
            dy = max(0.0, tip_y - shoulder_y)
            reach = max(reach, math.hypot(dx, dy))
        sleeve_ratio = reach / ref
        if sleeve_ratio > 1.7:      # longer than a sleeve can be: not a flat-lay
            return None
        out["sleeve_ratio"] = sleeve_ratio
    return out


def _garment_mask(p: Pose, kind: str,
                  garment: np.ndarray | None = None) -> np.ndarray:
    """AGNOSTIC mask — the region to repaint, not a trace of the current
    clothes.

    Tracing what the person is already wearing is the classic trap: the mask
    then physically cannot express a different silhouette, so a tee can never
    become a jacket and every result quietly regresses toward the input
    garment. The mask has to be GENEROUS — the whole body zone for that slot,
    intersected with the person matte so the background stays untouched.

    Generous in the CUT'S OWN direction, though, not blindly. Pass `garment` and
    the band is fitted to ratios measured off the flat-lay (`_garment_metrics`):
    the sleeve corridor stops where that garment's sleeve stops instead of at
    the wrist, the sides sit at its own width instead of spanning the figure, and
    the hem can run past the basics' for a long shirt or a coat. The floor is
    always the base avatar's own clothes — see the note at the bands below.
    Without `garment` this is the old full-slot rectangle, which is why a
    short-sleeve tee used to come back long-sleeved.
    """
    h, w = p.h, p.w
    pts = p.pts
    ys = [q[1] for q in pts if q]
    xs = [q[0] for q in pts if q]
    if not ys:
        raise ValueError("pose has no usable keypoints")

    def y_of(idx: int, fallback: float) -> float:
        return pts[idx][1] if pts[idx] else fallback

    top_body = min(ys)
    bot_body = max(ys)
    span = max(1.0, bot_body - top_body)

    shoulder = min(y_of(2, top_body + span * 0.18), y_of(5, top_body + span * 0.18))
    hip = max(y_of(8, top_body + span * 0.55), y_of(11, top_body + span * 0.55))
    ankle = max(y_of(10, bot_body), y_of(13, bot_body))

    # Horizontal extent: the whole figure for body slots, but only the legs'
    # own column for shoes — a full-width band would let the model treat the
    # trousers as part of the footwear (it repainted them leather-brown when
    # shoes had no zone of their own).
    xpad = max(6, round((max(xs) - min(xs)) * 0.14))
    x0, x1 = max(0, min(xs) - xpad), min(w - 1, max(xs) + xpad)
    dilate_frac = 0.035

    met = _garment_metrics(garment, kind) if garment is not None else None
    # The garment's width ON THE BODY. Joints sit inside the flesh and fabric
    # sits outside it, so the shoulder/hip keypoint distance under-reads what a
    # garment actually spans; the factors below are what closes that gap.
    ls, rs = pts[5], pts[2]
    lh, rh = pts[11], pts[8]
    if met and kind in ("upper", "full") and ls and rs:
        gw = abs(ls[0] - rs[0]) * 1.30
        cx = (ls[0] + rs[0]) // 2
    elif met and kind == "lower" and lh and rh:
        gw = abs(lh[0] - rh[0]) * 1.55
        cx = (lh[0] + rh[0]) // 2
    else:
        met, gw, cx = None, 0.0, (x0 + x1) // 2

    # THE BASE AVATAR SETS A FLOOR the mask can never go under. It wears grey
    # basics — short-sleeve tee, full-length trousers — so a mask that stops
    # where the NEW garment stops would leave the old one showing beneath it,
    # which reads as two layers rather than a swap. So the measurements can only
    # EXTEND a zone past the basics, never trim inside them. For 'lower' and
    # 'full' that means the band still runs to the ankle whatever the flat-lay
    # says: shorts and skirts need the shins repainted as skin, and the shins are
    # currently trousers.
    if kind == "lower":
        y0, y1 = hip - span * 0.06, min(h - 1, ankle + span * 0.03)
    elif kind == "full":
        y0, y1 = shoulder - span * 0.07, min(h - 1, ankle + span * 0.03)
    elif kind == "shoes":
        # The FEET LIE BELOW THE LAST KEYPOINT: COCO-18 stops at the ankle, so
        # the ankle cannot define the bottom edge. The silhouette's lowest
        # occupied row can — it already contains the feet, whatever their pose.
        rows = np.flatnonzero(p.silhouette.any(axis=1))
        foot_bottom = int(rows[-1]) if rows.size else bot_body
        # Start above the ankle so a boot shaft has room to exist; a mask that
        # begins at the ankle can only ever produce a low-top.
        y0 = ankle - span * 0.075
        y1 = min(h - 1, foot_bottom + span * 0.015)
        ax = [pts[i][0] for i in (10, 13) if pts[i]]
        if ax:
            # Generous sideways: a shoe is longer than the ankle is wide, and
            # the toe box may point away from the leg's axis.
            fpad = max(10, round(span * 0.09))
            x0, x1 = max(0, min(ax) - fpad), min(w - 1, max(ax) + fpad)
        dilate_frac = 0.018   # a foot-sized kernel, not a torso-sized one
    else:  # upper
        y0, y1 = shoulder - span * 0.07, hip + span * 0.10
        if met:
            # A long shirt and a cropped top are both 'upper'; only the flat-lay
            # knows which. It can lengthen the band (a shirt worn out, a coat) but
            # not shorten it below the basics' hem. Never past the knee — a top
            # measuring that long means the flat-lay was misread.
            y1 = max(y1, min(shoulder + met["len_ratio"] * gw, hip + span * 0.55))

    if met and kind in ("upper", "full", "lower"):
        # SIDES AT THE GARMENT'S OWN WIDTH, not the figure's. The 14% figure pad
        # runs from wrist to wrist, so on a standing figure it put mask well
        # outside the body on both flanks — and the model filled that strip with
        # the halo that traced the silhouette. The pad here is for drape only.
        half = gw / 2.0 + max(6, span * 0.035)
        x0, x1 = max(0, int(cx - half)), min(w - 1, int(cx + half))

    box = np.zeros((h, w), np.uint8)
    box[max(0, int(y0)):int(y1) + 1, x0:x1 + 1] = 255

    # ARM CORRIDOR. A torso band ending at hip+10% CUTS ACROSS THE ARMS, so a
    # sleeve hanging past that line sits OUTSIDE the repaint zone. Swapping a
    # sleeved top for a sleeveless one then left the old sleeves on the body and
    # the new garment read as a second layer worn over them (reported from the
    # phone: blue shirt sleeves under a dark vest). The model was not ignoring the
    # instruction — those pixels were simply never up for redrawing.
    #
    # Only for zones that own the arms. 'lower' and 'shoes' must never touch them.
    if kind in ("upper", "full"):
        arm = np.zeros((h, w), np.uint8)
        # Thick enough to cover a rolled cuff or a loose sleeve, scaled to the
        # figure so it holds for any framing.
        thick = max(6, round(span * 0.055))
        for shoulder_i, elbow_i, wrist_i in ((2, 3, 4), (5, 6, 7)):
            chain = [pts[i] for i in (shoulder_i, elbow_i, wrist_i) if pts[i]]
            if len(chain) < 2:
                continue
            if met:
                # HOW FAR down the arm, measured off the flat-lay. This used to be
                # the constant 88%-of-the-forearm for every garment, which is
                # exactly why a short-sleeve tee came back long-sleeved: the mask
                # asked for a full sleeve, and inpainting must fill what it is
                # given. A sleeveless top now measures ~0 and gets a shoulder cap
                # only; a long sleeve measures about one torso width and gets the
                # whole arm.
                chain_len = sum(math.hypot(b[0] - a[0], b[1] - a[1])
                                for a, b in zip(chain, chain[1:]))
                # …but never shorter than the basics' own sleeve, which ends
                # around a third of the way down the arm. A tank top measures
                # near zero, and stopping there would leave the grey sleeve
                # under it.
                reach = max(met["sleeve_ratio"] * gw, chain_len * 0.42)
                path = _walk(chain, reach)
            else:
                # STOP SHORT OF THE WRIST. Reaching the wrist pulled the HAND into
                # the repaint zone, and hands are what diffusion mangles most
                # visibly — a swapped top is not worth six fingers. A cuff sits
                # above the wrist anyway.
                path = _walk(chain, 0.94 * sum(
                    math.hypot(b[0] - a[0], b[1] - a[1])
                    for a, b in zip(chain, chain[1:])))
            for a, b in zip(path, path[1:]):
                cv2.line(arm, a, b, 255, thick)
        box = cv2.bitwise_or(box, arm)

    mask = cv2.bitwise_and(box, p.silhouette)
    # Dilate past the silhouette edge: garments sit OUTSIDE the body outline
    # (sleeves, drape, a coat's shoulder line). A mask clipped to the skin
    # cannot grow one.
    k = max(5, round(span * dilate_frac)) | 1
    mask = cv2.dilate(mask, np.ones((k, k), np.uint8), iterations=1)
    mask = cv2.bitwise_and(mask, box)   # …but never past the slot's own band

    # HANDS OUT, unconditionally and AFTER dilation. Shortening the arm corridor
    # was not enough: dilation grows the mask by span*0.035 and won back most of
    # what the shortening gave up, so the hands were still in the repaint zone.
    # Tuning the percentage would be guesswork against a kernel size; carving the
    # hands out at the end is deterministic. Hands are what diffusion mangles most
    # visibly, and no sleeve is worth six fingers.
    if kind in ("upper", "full"):
        for wrist_i in (4, 7):
            wr = pts[wrist_i]
            if wr:
                cv2.circle(mask, wr, max(8, round(span * 0.045)), 0, -1)

    return cv2.GaussianBlur(mask, (k | 1, k | 1), 0)


# ───────────────────────────── Stage C: the renderer ─────────────────────────

_PROMPT = (
    "a photo of the same person wearing {g}, "
    "full body, natural fabric folds, correct garment fit, "
    "consistent studio lighting, photorealistic, sharp, 8k"
)
_NEGATIVE = (
    "different person, changed face, extra limbs, extra arms, deformed hands, "
    "floating clothes, mannequin, doll, plastic skin, text, watermark, logo, "
    "blurry, lowres, cropped, duplicate torso"
)


class HybridVTONPipeline:
    """Loads once, renders many. Model load is lazy so the API answers
    /health before ~7 GB of weights are resident."""

    def __init__(self) -> None:
        self.reader = PoseReader()
        self._pipe = None
        self._lock = threading.Lock()

    # -- loading ------------------------------------------------------------

    def _build(self):
        from diffusers import ControlNetModel

        cfg = _MODELS[BASE]
        nets = [
            ControlNetModel.from_pretrained(cfg["pose"], torch_dtype=DTYPE),
            ControlNetModel.from_pretrained(cfg["canny"], torch_dtype=DTYPE),
        ]

        if BASE == "sdxl":
            from diffusers import StableDiffusionXLControlNetInpaintPipeline as P
            pipe = P.from_pretrained(
                cfg["base"], controlnet=nets, torch_dtype=DTYPE, variant="fp16",
            )
        else:
            from diffusers import StableDiffusionControlNetInpaintPipeline as P
            # The community mirror (runwayml is gone) publishes safetensors
            # ONLY as the fp16 variant; without variant= the loader finds bare
            # configs and dies. fp16 is also half the download.
            pipe = P.from_pretrained(
                cfg["base"], controlnet=nets, torch_dtype=DTYPE, variant="fp16",
                safety_checker=None, requires_safety_checker=False,
            )

        # IP-Adapter carries the GARMENT'S TEXTURE. This is the part a text
        # prompt cannot do: "navy tee" is a category, the adapter transfers the
        # actual weave, print placement and colour of the reference photo.
        pipe.load_ip_adapter(
            cfg["ip_repo"], subfolder=cfg["ip_sub"], weight_name=cfg["ip_weight"],
        )
        pipe.set_ip_adapter_scale(float(os.getenv("VTON_IP_SCALE", "0.75")))

        # ORDER MATTERS: xformers AFTER load_ip_adapter. Enabling it first (or
        # any processor swap after) replaces IPAdapterAttnProcessor with a
        # plain one and the adapter silently stops transferring texture —
        # the same class of bug that attention slicing caused on MPS. diffusers
        # ≥0.31 installs the IP-Adapter-aware xformers processor when the
        # adapter is already loaded.
        if XFORMERS:
            try:
                pipe.enable_xformers_memory_efficient_attention()
            except Exception as e:  # noqa: BLE001 — wheel/torch mismatch
                print(f"[vton] xformers unavailable ({e}); using torch SDPA")

        pipe.set_progress_bar_config(disable=True)
        # Memory: NO attention slicing — it swaps in SlicedAttnProcessor over
        # the IPAdapterAttnProcessor that load_ip_adapter just installed, and
        # the sliced path chokes on the adapter's tuple encoder_hidden_states
        # ("'tuple' object has no attribute 'shape'"). torch≥2 SDPA is already
        # memory-efficient, slicing buys nothing here. Offload is a much bigger
        # win but a bigger risk — on MPS it is only supported in recent
        # diffusers and interacts badly with some adapter hooks, so it degrades
        # to a plain device move instead of taking the process down.
        pipe.enable_vae_slicing()
        # VAE tiling crashes on MPS (non-contiguous view inside _tiled_encode)
        # and is only worth having at ≥1MP anyway — CUDA/SDXL territory.
        if DEVICE == "cuda":
            pipe.enable_vae_tiling()
        moved = False
        if OFFLOAD:
            try:
                pipe.enable_model_cpu_offload(device=DEVICE)
                moved = True
            except Exception as e:  # noqa: BLE001
                print(f"[vton] cpu offload unavailable ({e}); keeping resident")
        if not moved:
            pipe.to(DEVICE)
        return pipe

    def ensure_loaded(self):
        if self._pipe is None:
            with self._lock:
                if self._pipe is None:
                    self._pipe = self._build()
        return self._pipe

    def warmup(self) -> None:
        """Load weights AND run one throwaway 2-step render.

        Loading alone is not warm: the first real diffusion still pays for CUDA
        kernel autotuning and lazy allocator growth, which is seconds the first
        paying request should not absorb. Two steps is enough to touch every
        code path (UNet, both ControlNets, IP-Adapter, VAE decode).
        """
        pipe = self.ensure_loaded()
        blank = Image.new("RGB", (WORK_W, WORK_H), "white")
        pipe(
            prompt="warmup", image=blank, mask_image=blank,
            control_image=[blank, blank], ip_adapter_image=blank,
            num_inference_steps=2, guidance_scale=1.0,
        )
        _drain()

    # -- rendering ----------------------------------------------------------

    def generate(
        self,
        avatar: Image.Image,
        garment: Image.Image,
        kind: str = "upper",
        prompt_hint: str = "the garment in the reference image",
        steps: int | None = None,
        seed: int | None = None,
        # PER-RENDER IP SCALE. It was build-time only, so comparing 0.75 against
        # 0.9 meant restarting the worker and reloading 5 GB between samples —
        # slow enough that the knob never got measured properly. The adapter's
        # scale is cheap to set on a live pipeline, so a job can carry its own.
        ip_scale: float | None = None,
    ) -> Image.Image:
        avatar = _fix_exif(avatar).convert("RGB")
        garment = _fix_exif(garment).convert("RGB")
        if ip_scale is not None:
            self.ensure_loaded().set_ip_adapter_scale(float(ip_scale))
        full = np.array(avatar)[:, :, ::-1].copy()          # RGB → BGR

        # A — geometry at the ORIGINAL resolution, so the mask lines up with
        # the pixels we composite back onto later.
        pose = self.reader.read(full)
        # The flat-lay goes in as well: the mask is trimmed to THIS garment's cut
        # (hem, sleeve, width) rather than the whole slot band.
        mask_full = _garment_mask(pose, kind, np.array(garment)[:, :, ::-1])

        # B — conditioning, then everything down to the model's working size.
        control_pose = _draw_openpose(pose)
        gray = cv2.cvtColor(full, cv2.COLOR_BGR2GRAY)
        edges = cv2.Canny(cv2.bilateralFilter(gray, 7, 60, 60), 80, 170)
        # Erase edges inside the repaint zone: they describe the OLD garment
        # and would drag its outline into the new one.
        edges[mask_full > 20] = 0
        control_canny = cv2.cvtColor(edges, cv2.COLOR_GRAY2RGB)

        # NEUTRALISE THE ZONE BEFORE ENCODING. The inpaint pipeline VAE-encodes
        # this image, so whatever is under the mask sets the luminance the sampler
        # starts from — and it does not travel far from it. Measured on the same
        # photo and garment: swapping a butter-yellow tee onto a BLACK sleeveless
        # top returned brown, at IP scale 0.75 and again at 0.95 (the print got
        # sharper, the colour did not budge). The same garment on the grey-basics
        # avatar rendered correctly, which is the tell: the old garment's darkness
        # was leaking, not the conditioning being weak.
        #
        # SKIN, NOT MID-GREY. Grey is neutral in luminance and wrong in meaning:
        # the sampler read it as an intended fabric colour and filled with it
        # everything the new garment did not cover — so a short-sleeve tee came
        # back long-sleeved, and a grey halo traced the figure wherever the
        # garment stopped short. Raising IP scale did not help (0.75 → 0.9 → 1.0
        # at a fixed seed: more of the right colour, same grey), which is what
        # ruled the adapter out as the cause.
        #
        # The body's own skin tone is the honest prior: where a garment ends,
        # skin is what belongs there. Sampled from the forearms OUTSIDE the mask
        # (the one large skin area the repaint zone never covers), with mid-grey
        # kept as the fallback when no such pixels are visible.
        init = full.copy()
        fill = np.array([128, 128, 128], np.uint8)
        try:
            skin = np.zeros(mask_full.shape, np.uint8)
            for wrist_i, elbow_i in ((4, 3), (7, 6)):
                a, b = pose.pts[wrist_i], pose.pts[elbow_i]
                if a and b:
                    cv2.line(skin, a, b, 255, max(6, round(full.shape[0] * 0.02)))
            skin = cv2.bitwise_and(skin, pose.silhouette)
            skin[mask_full > 20] = 0          # only pixels we are NOT repainting
            if int(skin.sum()) > 0:
                fill = cv2.mean(full, mask=skin)[:3]
                fill = np.array([int(c) for c in fill], np.uint8)
        except Exception:  # noqa: BLE001 — a fill is never worth failing a render
            pass
        init[mask_full > 20] = fill
        init_s = _to_pil(init[:, :, ::-1]).resize((WORK_W, WORK_H), Image.LANCZOS)
        mask_s = Image.fromarray(mask_full).resize((WORK_W, WORK_H), Image.LANCZOS)
        pose_s = _to_pil(control_pose).resize((WORK_W, WORK_H), Image.LANCZOS)
        canny_s = _to_pil(control_canny).resize((WORK_W, WORK_H), Image.NEAREST)

        pipe = self.ensure_loaded()
        gen = None
        if seed is not None:
            gen = torch.Generator(device="cpu").manual_seed(seed)

        with self._lock:      # MPS serialises kernels anyway; make it explicit
            out = pipe(
                prompt=_PROMPT.format(g=prompt_hint),
                negative_prompt=_NEGATIVE,
                image=init_s,
                mask_image=mask_s,
                control_image=[pose_s, canny_s],
                ip_adapter_image=garment,
                num_inference_steps=steps or STEPS,
                guidance_scale=float(os.getenv("VTON_CFG", "6.5")),
                strength=float(os.getenv("VTON_STRENGTH", "0.99")),
                controlnet_conditioning_scale=[0.9, 0.45],
                generator=gen,
            ).images[0]
        _drain()

        # C — reverse composite at full resolution. See the module docstring:
        # this is what makes identity a guarantee instead of a hope.
        gen_full = np.array(out.resize(avatar.size, Image.LANCZOS)).astype(np.float32)
        base = np.array(avatar).astype(np.float32)

        # COMPOSITE WHERE THE MODEL ACTUALLY DREW, not across the whole mask.
        #
        # Inpainting has no way to leave part of its mask alone — the mask IS the
        # instruction to repaint. Ours is deliberately generous (the whole torso
        # band plus the arms) because a mask traced around the old garment can
        # never grow a different silhouette: a tee could not become a puffer. The
        # cost of that generosity showed up as its mirror image: a short-sleeve
        # tee came back long-sleeved, or left a halo of fill colour tracing the
        # figure wherever the garment stopped short.
        #
        # Neither the fill colour nor the adapter scale was the cause. Swept
        # 0.75/0.9/1.0 at a fixed seed (more of the right colour, same halo), then
        # swapped mid-grey for the body's own skin tone (the halo turned skin-
        # coloured and stayed). What was left is structural: the model must put
        # SOMETHING everywhere, and where it had nothing to draw it emits ~the
        # fill it started from.
        #
        # So ask, per pixel, whether it drew anything: distance from the fill.
        # Close to the fill → it had nothing there → keep the original. This is
        # arithmetic on the same footing as the identity guarantee, not a prompt
        # we hope lands.
        drew = np.abs(gen_full - fill.astype(np.float32)).max(axis=2)
        # 26/255: above sampling noise and JPEG ringing, well below any real
        # garment/skin boundary. Blurred so the kept and repainted regions meet
        # in a gradient rather than a cut-out edge.
        drew = cv2.GaussianBlur((np.clip(drew / 26.0, 0.0, 1.0) * 255).astype(np.uint8), (21, 21), 0)
        alpha = ((mask_full.astype(np.float32) / 255.0) *
                 (drew.astype(np.float32) / 255.0))[:, :, None]
        blended = gen_full * alpha + base * (1.0 - alpha)
        return Image.fromarray(np.clip(blended, 0, 255).astype(np.uint8))

    # -- introspection ------------------------------------------------------

    def debug(self, avatar: Image.Image, kind: str = "upper",
              garment: Image.Image | None = None) -> Image.Image:
        """Pose + mask overlay, no diffusion. Every mask bug this session was
        found by LOOKING at this, and every one that shipped was found by not
        looking. Free and instant — use it before spending a render."""
        avatar = _fix_exif(avatar).convert("RGB")
        full = np.array(avatar)[:, :, ::-1].copy()
        pose = self.reader.read(full)
        g = np.array(_fix_exif(garment).convert("RGB"))[:, :, ::-1] if garment else None
        mask = _garment_mask(pose, kind, g)
        vis = full.copy()
        vis[mask > 20] = (vis[mask > 20] * 0.45 + np.array([0, 0, 200]) * 0.55)
        vis = cv2.addWeighted(vis, 1.0, _draw_openpose(pose)[:, :, ::-1], 0.9, 0)
        return _to_pil(vis[:, :, ::-1])


# ─────────────────────────────────── helpers ─────────────────────────────────

def _to_pil(rgb: np.ndarray) -> Image.Image:
    return Image.fromarray(np.ascontiguousarray(rgb))


def _fix_exif(im: Image.Image) -> Image.Image:
    from PIL import ImageOps
    return ImageOps.exif_transpose(im)


def _drain() -> None:
    if DEVICE == "mps":
        torch.mps.empty_cache()
    elif DEVICE == "cuda":
        torch.cuda.empty_cache()
