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

from kinematic import apply_kinematic_shield, arm_shield
from warp import (apply_shading, dual_cylinder_warp, harmonise_poisson, mesh_warp,
                  parts_warp, shoes_warp, torso_warp, tps_warp)

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

# Two mask constants that have to be CALIBRATED rather than reasoned about, so
# they live here where a sweep can reach them. Both trade one visible defect for
# another, and the window between is narrow:
#   COLLAR_UP  how far above the shoulder keypoints the band starts, in figure
#              heights. Too small and the base's own collar shows at the throat;
#              too large and the sampler fills the neck, turning a crew neck into
#              a mock neck (measured at 0.07).
#   SIDE_PAD   drape allowance on each flank. Too small and the base garment
#              shows along the sides; too large and the mask sits off the body,
#              where the halo used to be painted.
COLLAR_UP = float(os.getenv("VTON_COLLAR_UP", "0.045"))
# WARP THE GARMENT ONTO THE BODY BEFORE DENOISING. See warp.py: the adapter only
# ever carried a description, so prints came back as blobs and cut never arrived.
# With the panel warped into the init image, denoising REFINES a photograph of the
# garment instead of inventing one — hence the much lower strength. 1.0 is the old
# behaviour and the rollback.
WARP = os.getenv("VTON_WARP", "1") == "1"
WARP_STRENGTH = float(os.getenv("VTON_WARP_STRENGTH", "0.55"))
# The keypoint mesh is OFF by default because it measured WORSE than the quad it
# was meant to replace: stripes came back wavy and a chest print was squeezed into
# an hourglass, against 84-90% clean coverage from four corners. The triangulation
# folds — the armpit and waist points are not consistent on the body side, and a
# sleeve sharing a mesh with the torso shears it. Sleeves want their own quads
# rather than one mesh over everything, which is the next thing to try, not a
# tuning pass on this. VTON_MESH_WARP=1 to look at it again.
MESH_WARP = os.getenv("VTON_MESH_WARP", "0") == "1"
# Non-rigid cylinder fit and gradient-domain blending. Both off by default and both
# for the same reason: each trades the property this engine is built on — the
# garment's own pixels, its own colour — for a different kind of realism, and neither
# has earned that trade on measurement yet. VTON_TPS=1 / VTON_POISSON=1 to weigh them.
# CONDITIONING WEIGHTS, out where they can be swept. Both were literals in the
# call, so weighing "obey the Canny print harder" against "let the adapter lead"
# meant editing the file on the pod between samples.
POSE_SCALE = float(os.getenv("VTON_POSE_SCALE", "0.9"))
CANNY_SCALE = float(os.getenv("VTON_CANNY_SCALE", "0.45"))
# RE-INJECT THE WARP'S OWN PIXELS IN THE DEEP CORE. Distance-transform weighted, so
# the centre of a panel keeps the flat-lay exactly while the edges stay the sampler's
# to shade and fold. 0 disables. Default off: it trades the sampler's folds for the
# source print, and which of those a given garment needs is a measurement, not a
# guess — the pod was down when this landed, so nothing has weighed it yet.
CORE_PROTECT = float(os.getenv("VTON_CORE_PROTECT", "0"))
TPS_WARP = os.getenv("VTON_TPS", "1") == "1"
# Two cylinders for the legs, one solver each. Off until measured on a phone: the
# single-cylinder version of the same idea looked fine in a metric and was visibly
# wrong at full zoom, which is the whole reason this one starts behind a flag.
DUAL_CYL = os.getenv("VTON_DUAL_CYL", "0") == "1"
POISSON = os.getenv("VTON_POISSON", "0") == "1"
# Deformable parts — torso quad plus a quad per sleeve — is the right idea and is
# NOT ready. Two measured attempts at warping sleeves (one mesh, one parts) both
# damaged the TORSO, which is where prints and text live and where a demo is won:
# stripes bunched to one edge, a chest graphic squeezed under a diagonal seam. The
# sleeve's destination geometry is the unsolved part (where the armpit sits on the
# body, and how the cuff's width scales), not a coefficient. Until that is derived
# properly the plain torso quad ships, because it measured clean at 84-90% coverage
# with prints intact. VTON_PARTS_WARP=1 to work on it.
PARTS_WARP = os.getenv("VTON_PARTS_WARP", "0") == "1"
SIDE_PAD = float(os.getenv("VTON_SIDE_PAD", "0.035"))

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


def _split(chain: list[tuple[int, int]],
           dist: float) -> tuple[list[tuple[int, int]], list[tuple[int, int]]]:
    """Cut a polyline at arc length `dist`. Returns (before, after).

    The arm is a polyline and a sleeve is a length along it: `before` is the
    sleeve, `after` is the bare arm below the cuff. Both matter — the first is
    the region to repaint, the second is the region to protect.
    """
    before = [chain[0]]
    left = dist
    for i, (a, b) in enumerate(zip(chain, chain[1:])):
        seg = math.hypot(b[0] - a[0], b[1] - a[1])
        if seg <= 1e-6:
            continue
        if seg >= left:
            t = max(0.0, left) / seg
            cut = (round(a[0] + (b[0] - a[0]) * t),
                   round(a[1] + (b[1] - a[1]) * t))
            return before + [cut], [cut, b] + chain[i + 2:]
        before.append(b)
        left -= seg
    return before, [chain[-1]]


def _flatlay_silhouette(garment: np.ndarray) -> np.ndarray | None:
    """The garment alone, cut out of its studio background. None if unclear.

    SEPARATE BY FLOOD-FILLING THE BACKGROUND, not by thresholding the garment.
    "Garment on white" does not mean "garment is darker than 235": the first
    catalogue top measured is an off-white tee at grey 238 on paper at 252, and a
    plain threshold picked up its shadow instead of the shirt (2% of the frame).
    Filling inward from the border finds the background by connectivity, whatever
    the garment is. FIXED_RANGE is the part that matters: the default compares
    each pixel to its NEIGHBOUR, so the fill walks up the soft shadow gradient
    and eats the whole white shirt (measured: zero object left at every
    tolerance). Against the SEED value it stops at the shadow, as intended.
    """
    g = cv2.cvtColor(garment, cv2.COLOR_BGR2GRAY) if garment.ndim == 3 else garment
    g = cv2.medianBlur(g, 5)
    h, w = g.shape

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
    return (lab == best).astype(np.uint8)


def _nearest_fill(img: np.ndarray, have: np.ndarray) -> np.ndarray:
    """Every pixel takes the colour of the NEAREST pixel we actually have.

    A MEAN COLOUR IS A LIE ABOUT A PATTERN. The flat fill exists so that a region the
    sampler declines to paint reads as a plain piece of the new garment rather than as
    the old one — and for a plain garment that is exactly right. For a black-and-white
    striped tee the mean is MID GREY, which is precisely the colour of the basics
    underneath, so the one region the fill was invented to rescue came back looking
    like the thing it was hiding: a grey slab across the shoulders above the stripes.
    Measured on the wardrobe's striped tee, whose flat-lay carries 13.4% edge density.

    Nearest-neighbour extension has no such failure. Stripes continue as stripes, a
    plaid continues as plaid, and a plain garment gives back exactly what the mean
    would have given. Exact rather than iterated: the distance transform's label map
    already names the nearest source pixel for every position, so one pass does it.

    BUT NEAREST REPEATS, AND A PATTERN NEEDS TO CONTINUE. Straight up from the warp's
    top row, "nearest" is that row for every pixel above it — and if that row happens
    to fall on a white stripe, the whole collar arrives as one flat white patch. Seen
    immediately on the striped tee, in the region the previous fix had just rescued.
    So above the fabric and below it, each column REFLECTS across its own boundary
    instead: the rhythm carries on with the right period, which is what continuing a
    pattern means. Sideways stays nearest, where repeating a column is correct — a
    stripe runs that way. Anything the reflection cannot reach falls back to nearest.
    """
    src = (have > 0)
    if not src.any():
        return img
    inp = np.where(src, 0, 255).astype(np.uint8)
    _, labels = cv2.distanceTransformWithLabels(inp, cv2.DIST_L2, 3,
                                                labelType=cv2.DIST_LABEL_PIXEL)
    ys, xs = np.nonzero(src)
    lut = np.zeros(int(labels.max()) + 1, np.int64)
    lut[labels[ys, xs]] = ys.astype(np.int64) * img.shape[1] + xs
    flat = lut[labels]
    out = img.reshape(-1, img.shape[2])[flat.ravel()].reshape(img.shape)

    h, w = src.shape
    col_has = src.any(axis=0)
    if not col_has.any():
        return out
    rows = np.arange(h)[:, None]
    y_top = np.argmax(src, axis=0)[None, :]
    y_bot = (h - 1 - np.argmax(src[::-1], axis=0))[None, :]
    for zone, pivot in ((rows < y_top, y_top), (rows > y_bot, y_bot)):
        zone = zone & col_has[None, :]
        if not zone.any():
            continue
        mirror = np.clip(2 * pivot - rows, 0, h - 1)
        take = np.take_along_axis(img, np.broadcast_to(
            mirror[:, :, None], img.shape), axis=0)
        valid = zone & np.take_along_axis(src, np.broadcast_to(mirror, src.shape),
                                          axis=0)
        out[valid] = take[valid]
    return out


def inject_bare_legs(init_image: np.ndarray, keypoints, lower_mask: np.ndarray,
                     garment_mask: np.ndarray, silhouette: np.ndarray | None = None,
                     base: np.ndarray | None = None) -> np.ndarray:
    """Overwrite the base's trousers with lit skin, so a dress can end where it ends.

    Under a dress or a pair of shorts the band deliberately reaches the ankle — the base
    wears full-length trousers and the shins have to be REPLACED, not left grey. But
    denoising at 0.55 refines what it is given, and what it was given was denim: seams,
    hem, fold structure. It kept them. Flooding the region with skin before the latent
    pass removes that structure at the source.

    TWO THINGS BEYOND THE FLOOD, both from measurement rather than theory.

    The skin is sampled from the FACE, not the forearms. The face is bare in every base
    by construction, it is large enough for a stable median, and it cannot be inside the
    repaint zone — the forearm sample this replaced can be, and when it was, the flood
    took its colour from pixels we were about to overwrite.

    And the flood is SHADED, not flat. Filling with one colour was tried: the sampler
    declined to add anatomy and the composite kept the fill, so the legs came back as
    flat salmon trousers — measured, skin-like pixels went 3% to 98% while the texture
    fell 8.57 to 2.59, which is exactly "correctly coloured, still a slab". Multiplying
    by the base's own row-normalised luminance costs nothing and gives the region the
    body's light, so even a declined pass composites as a lit leg.

    Fills only where the garment does NOT cover, and only inside the figure.
    """
    out = init_image.copy()
    h, w = out.shape[:2]
    lower = (lower_mask > 20)
    exposed = lower & (garment_mask <= 20)
    if silhouette is not None:
        exposed &= (silhouette > 0)
    if not exposed.any():
        return out

    def pt(idx):
        q = keypoints[idx] if idx < len(keypoints) else None
        return (float(q[0]), float(q[1])) if q else None

    nose = pt(0)
    if nose is None:
        return out
    r = max(6, int(round(h * 0.02)))
    y0, y1 = max(0, int(nose[1] - r)), min(h, int(nose[1] + r))
    x0, x1 = max(0, int(nose[0] - r)), min(w, int(nose[0] + r))
    patch = (base if base is not None else init_image)[y0:y1, x0:x1]
    if patch.size == 0:
        return out
    skin = np.median(patch.reshape(-1, 3), axis=0)

    # Polygons per leg, hip to ankle, as wide as the figure is down there. A line would
    # miss the calf; the silhouette knows the real width and needs no constant.
    legs = np.zeros((h, w), np.uint8)
    for hip_i, knee_i, ank_i in ((11, 12, 13), (8, 9, 10)):
        chain = [pt(i) for i in (hip_i, knee_i, ank_i)]
        chain = [q for q in chain if q]
        if len(chain) < 2:
            continue
        for a, b in zip(chain, chain[1:]):
            row = int(np.clip((a[1] + b[1]) / 2.0, 0, h - 1))
            occ = np.flatnonzero((silhouette if silhouette is not None
                                  else lower_mask)[row] > 20)
            half = max(12.0, (occ[-1] - occ[0]) * 0.28) if occ.size else 24.0
            cv2.line(legs, (int(a[0]), int(a[1])), (int(b[0]), int(b[1])),
                     255, int(half * 2))
        if chain and pt(ank_i):
            cv2.circle(legs, (int(chain[-1][0]), int(chain[-1][1])),
                       max(10, int(h * 0.018)), 255, -1)
    target = exposed & (legs > 0)
    if not target.any():
        return out

    field = np.ones((h, w), np.float32)
    if base is not None:
        g = cv2.cvtColor(base, cv2.COLOR_BGR2GRAY).astype(np.float32)
        k = (max(3, int(h * 0.10)) | 1)
        blur = cv2.GaussianBlur(g, (k, k), 0)
        m = target
        mean = float(blur[m].mean()) or 1.0
        rows_mean = np.where(m.any(axis=1),
                             np.divide((blur * m).sum(axis=1),
                                       np.maximum(m.sum(axis=1), 1)), mean)
        rows_mean[rows_mean <= 1e-6] = mean
        field = np.clip(blur / rows_mean[:, None], 0.88, 1.12)

    out[target] = np.clip(skin[None, :] * field[target][:, None], 0, 255)
    return out


def _extend_fabric(img: np.ndarray, have: np.ndarray,
                   holes: np.ndarray) -> np.ndarray:
    """Continue the fabric into a gap. Periodically when it repeats, nearest otherwise.

    THREE METHODS MEASURED ON THE WARDROBE'S STRIPED TEE, filling a 120-row gap where
    the collar sits, scored against what was actually there (vertical gradient / local
    contrast, as a fraction of ground truth):

        nearest neighbour   38% / 55%   a clean vertical extrusion — the "barcode"
        Telea inpainting    17% / 40%   smears the gap into a white blob
        Navier-Stokes       14% / 37%   worse still
        mirror reflection  363% / 148%  chaotic; the number is artefacts, it duplicated
                                        the chest logo and misaligned every stripe
        periodic copy      198% / 163%  the stripes continue with the right rhythm

    Telea is built for thin scratches: over a gap this size it averages the boundary and
    the structure is gone, which is why it scores half of what plain nearest does. What
    the gap actually wants is the PATTERN, and a pattern that repeats can be copied from
    a whole number of periods away — exact by construction for stripes, and the period
    comes free from the autocorrelation of the row-mean profile.

    Gated on that autocorrelation, because the method only makes sense when there IS a
    period: below the threshold this falls back to nearest, which for a plain garment
    gives exactly what the old flat mean would have. The shift is chosen to minimise the
    mismatch across the gap's boundary, so the phase lands as well as the rhythm.
    """
    if not holes.any() or not (have > 0).any():
        return _nearest_fill(img, have)
    src = (have > 0)
    grey = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY).astype(np.float32)
    rows = np.flatnonzero(src.any(axis=1))
    prof = np.array([grey[y][src[y]].mean() for y in rows], np.float32)
    lo, hi = 6, min(90, prof.size // 3)
    if hi <= lo:
        return _nearest_fill(img, have)
    q = prof - prof.mean()
    ac = np.correlate(q, q, mode="full")[q.size - 1:]
    ac = ac / (ac[0] if ac[0] else 1.0)
    period = int(lo + np.argmax(ac[lo:hi]))
    if float(ac[lo:hi].max()) < 0.45:
        return _nearest_fill(img, have)

    out = img.copy()
    ys, xs = np.nonzero(holes)
    filled = np.zeros(holes.shape, bool)
    h_img = img.shape[0]
    # Whole periods, nearest first, and both directions — a gap above the panel is fed
    # from below and vice versa.
    for mult in (1, -1, 2, -2, 3, -3, 4, -4, 5, -5):
        todo = ~filled[ys, xs]
        if not todo.any():
            break
        yy, xx = ys[todo], xs[todo]
        sy = yy + mult * period
        ok = (sy >= 0) & (sy < h_img)
        yy, xx, sy = yy[ok], xx[ok], sy[ok]
        if not yy.size:
            continue
        good = src[sy, xx]
        out[yy[good], xx[good]] = img[sy[good], xx[good]]
        filled[yy[good], xx[good]] = True
    if not filled[holes].all():
        rest = _nearest_fill(img, have)
        left = holes & ~filled
        out[left] = rest[left]
    return out


def _garment_color(garment: np.ndarray) -> np.ndarray | None:
    """The garment's own average colour. See the fill note in `generate`."""
    sil = _flatlay_silhouette(garment)
    if sil is None:
        return None
    return np.array([int(c) for c in cv2.mean(garment, mask=sil)[:3]], np.uint8)


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
    sil = _flatlay_silhouette(garment)
    if sil is None:
        return None
    h, w = sil.shape
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


def _arm_zone(p: Pose, kind: str, from_frac: float = 0.25) -> np.ndarray:
    """The arm below the shoulder cap — where a sleeve may or may not reach.

    Used to answer "what belongs here if the garment does not cover it" per
    region rather than per render: on the torso the answer is the garment, on the
    arm it is skin. One flat fill cannot say both, and getting it wrong shows —
    see the note in `generate`.
    """
    zone = np.zeros((p.h, p.w), np.uint8)
    if kind not in ("upper", "full"):
        return zone
    ys = [q[1] for q in p.pts if q]
    span = max(1.0, max(ys) - min(ys)) if ys else 1.0
    thick = max(6, round(span * 0.075))
    for ids in ((2, 3, 4), (5, 6, 7)):
        chain = [p.pts[i] for i in ids if p.pts[i]]
        if len(chain) < 2:
            continue
        total = sum(math.hypot(b[0] - a[0], b[1] - a[1])
                    for a, b in zip(chain, chain[1:]))
        _, rest = _split(chain, total * from_frac)
        for a, b in zip(rest, rest[1:]):
            cv2.line(zone, a, b, 255, thick)
    return zone


def _garment_mask(p: Pose, kind: str,
                  garment: np.ndarray | None = None,
                  person: np.ndarray | None = None) -> np.ndarray:
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
        # 0.03, not 0.075. The taller zone existed so a boot shaft could grow into
        # it, but with a low shoe as the reference the sampler filled the whole
        # band anyway — from the phone, a brogue came back as a brown mass up the
        # calf. A boot now renders clipped, which is a wrong hem; the alternative
        # was a wrong leg on every ordinary shoe.
        y0 = ankle - span * 0.03
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
            # THE HEM IS FIXED JUST UNDER THE BASICS', and len_ratio does NOT get a
            # vote. Two reasons, both measured.
            #
            # First, the sampler paints the hem where its own prior puts it, not
            # where the mask ends, and the strip between the two comes back as
            # exposed fill — a film over the trousers with a hard horizontal edge.
            #
            # Second, the ratio cannot be mapped onto the body through one factor.
            # It is a length over the garment's OWN width, and that width is a
            # property of the cut: an oversized tee measured 1.61 and a slim
            # V-neck 2.08. Multiplied by the same body-side width they predict
            # hems 120 px apart for two shirts that are the same length in real
            # life. Fixing that needs the garment's SHOULDER width, which the
            # sleeves sit across in a flat-lay, so it is not reliably measurable.
            #
            # A long coat therefore will not render long. That is a known loss,
            # and it costs less than the artefact it removes. len_ratio stays as a
            # plausibility check on the flat-lay.
            y1 = hip + span * 0.03

    if met and kind in ("upper", "full"):
        # THE THROAT IS NOT A COLLAR. Starting the band 7% of the figure above the
        # shoulder line gives a collar room to exist, but it also puts the throat
        # and the lower jaw inside the repaint zone — and with the zone
        # neutralised, the sampler read that as garment and painted a mock-neck up
        # to the chin over a crew-neck reference.
        #
        # A crew collar sits 3% of the figure above the shoulder keypoints — that
        # is where the basics' own collar is, measured on this avatar (row 225,
        # shoulders at 250, figure 833 tall). 7% is row 192, which is the throat
        # and the bottom of the jaw.
        #
        # Two silhouette-derived rules were tried first and both landed higher
        # than the collar they were meant to find: the narrowest row between nose
        # and shoulders is the CHIN (68 px at row 180 — a jaw tapers to a point,
        # so it is thinner than the neck below it), and walking up to where the
        # figure narrows to 55% of shoulder width stops at row 208, mid-throat.
        # The width profile through the neck is too shallow to threshold safely.
        y0 = max(y0, shoulder - span * COLLAR_UP)

    # WHAT IS NOT GARMENT, BY COLOUR, ONCE. Two things sit in the columns a pair of
    # trousers needs: the arms hanging in front of the hips, and the sliver of
    # backdrop between arm and body that MediaPipe's matte closes over. Geometry
    # cannot separate either from the garment — the arm is IN FRONT of the hip, so
    # the same columns hold both, which is why trimming by column only ever shrank
    # the denim slabs while also clipping the jeans (measured at 0.95 and 0.85 hip
    # widths: the base's grey trousers showed along both edges). The base image can
    # separate them: skin is the arm, backdrop is the gap, and neither is trousers.
    # Computed here because it answers two questions — how wide the band may be, and
    # what must stay out of the repaint zone.
    not_garment = np.zeros((h, w), np.uint8)
    zone = None
    # TROUSERS ONLY. Shoes never had the hip problem — the arms are nowhere near the
    # feet, and their own per-foot quad already places them — but they DID pick up the
    # widened band this carve enables, and the toe came back capped in white. A guard
    # belongs where the defect is.
    if kind == "lower" and person is not None:
        corridor = np.zeros((h, w), np.uint8)
        wide = np.zeros((h, w), np.uint8)
        sample = np.zeros((h, w), np.uint8)
        for ids in ((2, 3, 4), (5, 6, 7)):
            chain = [pts[i] for i in ids if pts[i]]
            for a, b in zip(chain, chain[1:]):
                cv2.line(corridor, a, b, 255, int(max(24, span * 0.11)))
                cv2.line(wide, a, b, 255, int(max(36, span * 0.18)))
                cv2.line(sample, a, b, 255, max(4, round(span * 0.012)))
        # BY CHROMA, NOT BY RGB DISTANCE. An RGB ball of radius 46 around skin also
        # contains mid grey — and the base wears grey trousers, so the first version
        # of this test carved the garment it was meant to protect: measured, it
        # covered 419 px of the hip row where the fabric is 259, and the mask came out
        # 148. Skin is separable from grey by its WARMTH rather than its brightness
        # (Cr well above 128 while grey sits on it), and chroma is also what survives
        # the shading down an arm. The backdrop needs the opposite pairing — white and
        # grey share chroma, so it is caught by luminance plus neutrality.
        ycc = cv2.cvtColor(person, cv2.COLOR_BGR2YCrCb).astype(np.float32)
        probe = cv2.bitwise_and(sample, p.silhouette)
        if int(probe.sum()):
            ref = np.array(cv2.mean(ycc, mask=probe)[:3], np.float32)
            grow = max(3, round(span * 0.008)) | 1
            near = ((np.abs(ycc[:, :, 1] - ref[1]) < 12)
                    & (np.abs(ycc[:, :, 2] - ref[2]) < 12))
            not_garment = cv2.bitwise_and(corridor, cv2.dilate(
                (near.astype(np.uint8) * 255), np.ones((grow, grow), np.uint8)))
        # The backdrop is sampled from the frame's own corners rather than assumed
        # white, and both tests are confined to an arm corridor so a pale garment
        # elsewhere on the body is untouched.
        back = np.float32([0, 0, 0])
        for cy, cx in ((0, 0), (0, w - 6), (h - 6, 0), (h - 6, w - 6)):
            back += np.array(cv2.mean(ycc[cy:cy + 6, cx:cx + 6])[:3], np.float32)
        back /= 4.0
        gap = cv2.bitwise_and(wide, (((np.abs(ycc[:, :, 0] - back[0]) < 25)
                                      & (np.abs(ycc[:, :, 1] - back[1]) < 8)
                                      & (np.abs(ycc[:, :, 2] - back[2]) < 8))
                                     .astype(np.uint8) * 255))
        not_garment = cv2.bitwise_or(not_garment, gap)

    if met and kind in ("upper", "full", "lower"):
        # SIDES AT THE GARMENT'S OWN WIDTH, not the figure's. The 14% figure pad
        # runs from wrist to wrist, so on a standing figure it put mask well
        # outside the body on both flanks — and the model filled that strip with
        # the halo that traced the silhouette. The pad here is for drape only.
        pad = max(6, span * SIDE_PAD)
        half = gw / 2.0 + pad
        x0, x1 = max(0, int(cx - half)), min(w - 1, int(cx + half))
        # …BUT NEVER NARROWER THAN THE BODY IT HAS TO COVER. Legs stand apart, so
        # a band sized from the HIP width clipped 13 px of the far ankle, and the
        # foot came back as a white blob beside the shoe. Widen to whatever the
        # figure actually occupies inside these rows.
        occ_src = p.silhouette.copy()
        carved = bool(int(not_garment.max()))
        if carved:
            # Columns owned by the hanging arms must not widen the band — at hip
            # rows the figure's extremes ARE the arms. Carved by COLOUR (skin and
            # backdrop) rather than by a line down the arm: a line removes the
            # centreline and leaves the arm's own width plus the whole gap behind
            # it, so the band still reached the arms' outer edge.
            occ_src = cv2.bitwise_and(occ_src, cv2.bitwise_not(not_garment))
        elif kind in ("lower", "shoes"):
            # NO BASE FRAME TO SAMPLE, so geometry is all there is: tapered capsules
            # over both arms (kinematic.arm_shield) instead of a line of fixed
            # thickness. Same intent, better shape — radii come from the forearm's own
            # length, so they scale with the subject rather than with the frame, and
            # the shoulder end is wider than the wrist end the way an arm is.
            occ_src = apply_kinematic_shield(occ_src, pts)
        # MEASURE IT ACROSS THE WHOLE BAND, INCLUDING THE HIPS. Skipping the upper
        # third was a way to keep the merged arms out of the answer, and it worked —
        # but it also meant the widest part of a pair of trousers was never measured,
        # and the band fell back to the flat-lay's own width: 133 px of mask where
        # the base carries 259 px of fabric (measured at the hip row, silhouette
        # minus skin colour), i.e. HALF THE GARMENT. That is what left grey trouser
        # showing along both edges — the defect I twice blamed on the arm guard.
        # With the arms carved by colour the hip rows are safe to measure. Without the
        # carve they are not, and skipping the upper third is still the best available
        # answer — that is the path shoes take.
        row_lo = int(y0) if carved else (
            int(y0 + (y1 - y0) * 0.35) if kind in ("lower", "shoes") else int(y0))
        band = occ_src[max(0, row_lo):int(y1) + 1]
        occupied = np.flatnonzero(band.any(axis=0)) if band.size else np.array([])
        if occupied.size:
            x0 = min(x0, max(0, int(occupied[0] - pad)))
            x1 = max(x1, min(w - 1, int(occupied[-1] + pad)))

    box = np.zeros((h, w), np.uint8)
    box[max(0, int(y0)):int(y1) + 1, x0:x1 + 1] = 255

    # REACH THE OLD GARMENT'S OWN COLLAR, wherever it happens to be. The band's top is
    # a constant — the shoulder line less 4.5% of the figure — and a constant cannot
    # know where the thing being replaced ends. Measured on the demo base: the basics'
    # neutral pixels start at row 232 and ride higher over the shoulder slope, while
    # the band starts at 238, so a sliver of the old top survived every render. In the
    # output it is 187 px at rows 225-250, x 452-482, unchanged from the base
    # ([162,164,162] in, [161,167,166] out) — the grey rim beside the neck.
    #
    # Raising the constant instead was tried and is recorded above: at 7% the band
    # reaches the throat and the sampler reads that as garment, painting a mock-neck up
    # to the chin. So this extends UPWARD ONLY, and only over pixels that actually look
    # like the neutral basics, which the throat does not. The chin can never be reached
    # because the cap sits a third of the way down from the nose.
    if kind in ("upper", "full") and person is not None:
        ycc_b = cv2.cvtColor(person, cv2.COLOR_BGR2YCrCb)
        neutral = ((np.abs(ycc_b[:, :, 1].astype(np.int16) - 128) < 7)
                   & (np.abs(ycc_b[:, :, 2].astype(np.int16) - 128) < 7)
                   & (ycc_b[:, :, 0] > 110) & (ycc_b[:, :, 0] < 225))
        worn = cv2.bitwise_and((neutral.astype(np.uint8) * 255), p.silhouette)
        nose = pts[0][1] if pts[0] else None
        cap = int(nose + (shoulder - nose) * 0.35) if nose else int(shoulder - span * 0.05)
        lo = max(0, cap, int(y0) - int(span * 0.10))
        strip = np.zeros((h, w), np.uint8)
        strip[lo:int(y0), x0:x1 + 1] = 255
        box = cv2.bitwise_or(box, cv2.bitwise_and(worn, strip))

    # ARM CORRIDOR. A torso band ending at hip+10% CUTS ACROSS THE ARMS, so a
    # sleeve hanging past that line sits OUTSIDE the repaint zone. Swapping a
    # sleeved top for a sleeveless one then left the old sleeves on the body and
    # the new garment read as a second layer worn over them (reported from the
    # phone: blue shirt sleeves under a dark vest). The model was not ignoring the
    # instruction — those pixels were simply never up for redrawing.
    #
    # Only for zones that own the arms. 'lower' and 'shoes' must never touch them.
    kdil = max(5, round(span * dilate_frac)) | 1
    bare = np.zeros((h, w), np.uint8)

    if kind in ("upper", "full"):
        arm = np.zeros((h, w), np.uint8)
        # Thick enough to cover a rolled cuff or a loose sleeve, scaled to the
        # figure so it holds for any framing.
        thick = max(6, round(span * 0.055))
        for shoulder_i, elbow_i, wrist_i in ((2, 3, 4), (5, 6, 7)):
            chain = [pts[i] for i in (shoulder_i, elbow_i, wrist_i) if pts[i]]
            if len(chain) < 2:
                continue
            chain_len = sum(math.hypot(b[0] - a[0], b[1] - a[1])
                            for a, b in zip(chain, chain[1:]))
            if met:
                # HOW FAR down the arm, measured off the flat-lay — but never
                # shorter than the basics' own sleeve, which ends about a third
                # of the way down. A tank measures near zero, and stopping there
                # would leave the grey sleeve under it.
                reach = max(met["sleeve_ratio"] * gw, chain_len * 0.42)
            else:
                # STOP SHORT OF THE WRIST. Reaching the wrist pulled the HAND
                # into the repaint zone, and hands are what diffusion mangles
                # most visibly. A cuff sits above the wrist anyway.
                reach = 0.94 * chain_len
            sleeve, rest = _split(chain, reach)
            for a, b in zip(sleeve, sleeve[1:]):
                cv2.line(arm, a, b, 255, thick)
            if met:
                # AND THE BARE ARM BELOW THE CUFF IS PROTECTED. Measuring the
                # sleeve is not enough on its own: with the hands in the pockets
                # the torso band already spans wrist to wrist and hip to thigh,
                # so it covered the whole arm no matter where the corridor
                # stopped — the corridor could only ever add. Measured on this
                # avatar, both masks reached 89% down the arm. Carving the rest
                # of the arm back out is what actually lets a short sleeve be
                # short. Thicker than the corridor by the dilation kernel, since
                # this is applied after dilation.
                for a, b in zip(rest, rest[1:]):
                    cv2.line(bare, a, b, 255, thick + kdil)
        box = cv2.bitwise_or(box, arm)

    mask = cv2.bitwise_and(box, p.silhouette)
    # Dilate past the silhouette edge: garments sit OUTSIDE the body outline
    # (sleeves, drape, a coat's shoulder line). A mask clipped to the skin
    # cannot grow one.
    k = kdil
    mask = cv2.dilate(mask, np.ones((k, k), np.uint8), iterations=1)
    mask = cv2.bitwise_and(mask, box)   # …but never past the slot's own band
    mask = cv2.bitwise_and(mask, cv2.bitwise_not(bare))   # …and not the bare arm

    # HOW FAR OUTSIDE THE BODY, from the garment's width rather than a constant.
    # The dilation above is what lets a mask grow a silhouette the body does not
    # have — a coat's shoulder line, a puffer's bulk — but applied at full
    # strength to a plain tee it left a 29 px ring of mask hanging in the air all
    # round the figure, and the model filled that ring with the halo. Measured
    # here: 17% of the old mask lay off the body. A garment WIDER than the
    # shoulders earns that room; one that is not, does not.
    if met:
        # Measure the body's width WHERE THIS SLOT LIVES. The chest row was used
        # for every slot, and on a build whose hips-in-pixels run wide the lower
        # allowance came out tens of pixels — denim slabbed sideways into the
        # arm-hip gap on the free-arms base. The chest answers for tops, the hip
        # row answers for trousers.
        row = int(min(h - 1, max(0, (hip + span * 0.06)
                                    if kind in ("lower", "shoes")
                                    else (shoulder + span * 0.06))))
        occupied = np.flatnonzero(p.silhouette[row])
        body_w = float(occupied[-1] - occupied[0] + 1) if occupied.size else gw
        allow = max(8, int((gw - body_w) / 2))
        reachable = cv2.dilate(p.silhouette,
                               np.ones((allow * 2 + 1,) * 2, np.uint8), iterations=1)
        mask = cv2.bitwise_and(mask, reachable)
    else:
        reachable = None

        # Whatever survives as a detached speck is mask floating beside the
        # figure, and inpainting will dutifully paint fabric there.
        n, lab, st, _ = cv2.connectedComponentsWithStats((mask > 20).astype(np.uint8), 8)
        if n > 2:
            keep = st[1:, cv2.CC_STAT_AREA].max() * 0.04
            for i in range(1, n):
                if st[i, cv2.CC_STAT_AREA] < keep:
                    mask[lab == i] = 0

    # HANDS OUT, unconditionally and AFTER dilation. Shortening the arm corridor
    # was not enough: dilation grows the mask by span*0.035 and won back most of
    # what the shortening gave up, so the hands were still in the repaint zone.
    # Tuning the percentage would be guesswork against a kernel size; carving the
    # hands out at the end is deterministic. Hands are what diffusion mangles most
    # visibly, and no sleeve is worth six fingers.
    # HANDS AND FOREARMS OUT, FOR EVERY SLOT. Reported from the phone: swapping
    # trousers painted dark denim blocks over both forearms and hands, and the
    # shoes pass added a brown one. The hands hang AT HIP HEIGHT in the canonical
    # pose — thumbs in the pockets — so the lower band covers them, and widening
    # that band to the figure's true extent (needed so the far ankle is not
    # clipped) made it worse. Nothing below the waist is ever in front of a hand:
    # trousers and shoes go BEHIND the arm, so the arm is not theirs to repaint.
    # 'upper' and 'full' keep the measured sleeve instead, which may legitimately
    # cover the forearm.
    # ARMS ARE NEVER THE LOWER SLOT'S TO PAINT. Trousers and shoes cannot touch
    # an arm on any body, so for those slots the whole arm — shoulder to wrist
    # plus a hand disc — is shielded GEOMETRICALLY, no skin test. The skin test
    # existed for the pockets pose, where the pixels around a hand are the old
    # trousers; but on a FREE-ARMS base it let denim onto the arms whenever the
    # match misfired, and the free-arms base is what the demo account uses.
    # Measured there: at hip rows the figure's occupied columns ARE the hanging
    # arms, so the band widened to them and denim slabbed across the arm-hip
    # gap. A pockets-pose base keeps a patch of its old trousers around the
    # fist — the known lesser evil; the real cure for that pose is the minimal
    # base. The upper slot keeps the skin-tested hand disc: a sleeve may
    # legitimately cover any part of the arm, so only the hand is carved there.
    # ONE ACCUMULATOR FOR EVERYTHING THAT MUST STAY OUT. Whatever is subtracted
    # here is subtracted AGAIN after the feather — the Gaussian bleeds masked
    # values back into any hole punched before it, and that is not a detail: with
    # the arm shield it painted a denim ring around each fist, and with the hand
    # disc it painted the tee's own fill colour there (measured by attributing the
    # change per step: the UPPER pass altered 1100-1700 px around each hand in
    # exactly its fill colour). Same class, two slots, one place to fix it.
    shield = np.zeros((h, w), np.uint8)
    if kind in ("lower", "shoes") and int(not_garment.max()):
        # THE COLOUR CARVE REPLACES THE ARM LINES, it does not join them. Both ran,
        # and the lines were what still clipped the trousers: 70px thick around each
        # arm's centreline, and the right shoulder keypoint sits INSIDE the trouser
        # columns, so they carved 42px of fabric on one side and 37px on the other —
        # the grey edges I chased through the band, the quad and the allowance. Read
        # off one hip row: skin 272..298, real backdrop 300..312, fabric 314..526,
        # backdrop 527..535, skin 540..570. The hands are OUTSIDE the trousers with
        # actual background between; a line down the arm cannot express that, and the
        # colour test does it exactly.
        pass
    elif kind in ("lower", "shoes"):
        # Same fallback, same reason: the capsules carry the hand disc too, placed
        # PAST the wrist along the forearm's direction rather than centred on the
        # joint, which is where a fist actually is.
        shield = cv2.bitwise_or(shield, arm_shield((h, w), pts))
    else:
        skin_ref = None
        if person is not None:
            probe = np.zeros((h, w), np.uint8)
            for a_i, b_i in ((4, 3), (7, 6)):
                a, b = pts[a_i], pts[b_i]
                if a and b:
                    cv2.line(probe, a, b, 255, max(4, round(span * 0.012)))
            probe = cv2.bitwise_and(probe, p.silhouette)
            if int(probe.sum()):
                skin_ref = np.array(cv2.mean(person, mask=probe)[:3], np.float32)
        for wrist_i in (4, 7):
            wr = pts[wrist_i]
            if not wr:
                continue
            disc = np.zeros((h, w), np.uint8)
            cv2.circle(disc, wr, max(10, round(span * 0.055)), 255, -1)
            if skin_ref is not None:
                near = (np.abs(person.astype(np.float32) - skin_ref).max(axis=2) < 46)
                grow = max(3, round(span * 0.006)) | 1
                disc = cv2.bitwise_and(disc, cv2.dilate(
                    (near.astype(np.uint8) * 255), np.ones((grow, grow), np.uint8)))
            shield = cv2.bitwise_or(shield, disc)

    # THE LOWER SLOT LIVES ON THE PELVIS AND THE LEGS, and that is knowable from
    # the SKELETON — which is the point. MediaPipe's matte merges the hanging arms
    # into the torso blob at hip height, so any mask built by intersecting the
    # matte inherits the gap between arm and body; the warp then filled that gap
    # with denim and the render grew two flat slabs sticking out sideways with a
    # straight vertical cut. Two attempts trimmed it by columns and only shrank
    # the slabs, because the matte was the thing lying. A pelvis quad plus a
    # corridor per leg cannot contain that gap at all: it is lateral, and this
    # shape is not. Generous on purpose — baggy jeans must still fit inside it.
    if kind in ("lower", "shoes") and lh and rh:
        zone = np.zeros((h, w), np.uint8)
        # THE QUAD SHAPES, IT DOES NOT SIZE. Its width used to come from the hip
        # landmarks, and that was the thing clipping the jeans through three
        # attempts at the wrong knob: traced stage by stage, the band arrived 310px
        # wide at the hip row and this quad cut it to 148 — the landmarks it scales
        # from sit 53px apart on a figure carrying 259px of fabric, so no multiplier
        # of them can be right. Width is now the band's, which was measured off the
        # base; the quad only says WHERE the slot lives vertically, and the colour
        # carve says which of those columns are arm rather than trousers.
        cols = np.flatnonzero(box.any(axis=0))
        bx0 = float(cols[0]) if cols.size else 0.0
        bx1 = float(cols[-1]) if cols.size else float(w - 1)
        top = min(lh[1], rh[1]) - span * 0.09
        cv2.fillConvexPoly(zone, np.int32([
            [bx0, top], [bx1, top],
            [bx1, max(lh[1], rh[1]) + span * 0.06],
            [bx0, max(lh[1], rh[1]) + span * 0.06]]), 255)
        for ids in ((8, 9, 10), (11, 12, 13)):
            chain = [pts[i] for i in ids if pts[i]]
            for a, b in zip(chain, chain[1:]):
                cv2.line(zone, a, b, 255, int(max(20, span * 0.13)))
            if pts[ids[2]]:      # the foot reaches past the last keypoint
                cv2.circle(zone, pts[ids[2]], int(max(20, span * 0.09)), 255, -1)
        # The same colour carve that sized the band keeps the arms and the gap behind
        # them out of the repaint zone — one test, both jobs, so the boundary the
        # band was measured against and the boundary the sampler sees cannot drift
        # apart. (The geometric arm lines above stay: they are the fallback when no
        # base image is available to sample.)
        shield = cv2.bitwise_or(shield, not_garment)
        mask = cv2.bitwise_and(mask, zone)

    mask[shield > 0] = 0
    mask = cv2.GaussianBlur(mask, (k | 1, k | 1), 0)
    if True:
        # SUBTRACT THE ARM SHIELD AGAIN, AFTER THE FEATHER. It was cut out of the
        # binary mask, but the Gaussian feather (k≈29) bleeds masked values ~15px
        # back INTO the shield — so the sampler painted a faint denim ring around
        # each fist, the blue hooks visible beside the hands on the phone. Same
        # lesson the bare-arm carve already recorded: anything that must stay out
        # of the repaint zone must be subtracted after every operation that grows
        # the mask, not only before.
        mask[shield > 0] = 0
    if reachable is not None:
        # The feather has to respect the allowance too. Clipping only the binary
        # mask left the blur's tail hanging outside the body, and the sampler
        # painted that tail — measured at 13.8k px of soft fabric-coloured smear
        # around the figure, against a white background where it shows plainly.
        mask = cv2.bitwise_and(mask, reachable)

    # WHICH CLIP TOOK WHAT, on one row. Four independent things narrow this mask —
    # the band, the zone, the carve and the allowance — and a wrong answer looks
    # identical whichever one produced it. Two full sessions went into blaming the
    # wrong one of them, each time "fixed" by making something narrower, because the
    # only number I had was the final width. VTON_MASK_TRACE=1 prints all four.
    if os.getenv("VTON_MASK_TRACE") == "1":
        def _ext(m, row):
            r = np.flatnonzero(m[int(row)] > 20)
            return f"{r[0]}..{r[-1]}({r[-1] - r[0]})" if r.size else "-"
        probe_row = min(h - 1, int(hip))
        print(f"[maskdbg] {kind} row={probe_row} box={_ext(box, probe_row)} "
              f"zone={_ext(zone, probe_row) if zone is not None else '-'} "
              f"carve={_ext(not_garment, probe_row)} "
              f"shield={_ext(shield, probe_row)} final={_ext(mask, probe_row)}",
              flush=True)
    return mask


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
        # Per-call conditioning weights. A printed tee wants the Canny map obeyed
        # harder and the adapter's global colour turned down; a plain one does not
        # care. Defaults come from the env so a sweep needs no code change.
        pose_scale: float | None = None,
        canny_scale: float | None = None,
        core_protect: float | None = None,
        # ONE GEOMETRY FOR THE WHOLE OUTFIT. Without this, every step re-reads
        # pose and matte from the PREVIOUS step's output, so the upper and lower
        # masks are computed on different pixel states and their boundaries need
        # not agree — ∂M_upper(x0) ≠ ∂M_lower(x1), which is where the waist seam
        # artefacts live. A job passes the pose it read once from the clean base
        # and every slot's mask shares the same silhouette by construction. The
        # person does not move between steps, so nothing is lost.
        pose: Pose | None = None,
        # Return the effective coverage alongside the image, so a caller can
        # composite several INDEPENDENT layers itself instead of chaining them.
        # See the unified-batch loop in worker_jobs.
        return_mask: bool = False,
    ) -> Image.Image | tuple[Image.Image, np.ndarray]:
        avatar = _fix_exif(avatar).convert("RGB")
        garment = _fix_exif(garment).convert("RGB")
        if ip_scale is not None:
            self.ensure_loaded().set_ip_adapter_scale(float(ip_scale))
        full = np.array(avatar)[:, :, ::-1].copy()          # RGB → BGR

        # A — geometry at the ORIGINAL resolution, so the mask lines up with
        # the pixels we composite back onto later.
        if pose is None:
            pose = self.reader.read(full)
        # The flat-lay goes in as well: the mask is trimmed to THIS garment's cut
        # (hem, sleeve, width) rather than the whole slot band.
        mask_full = _garment_mask(pose, kind, np.array(garment)[:, :, ::-1], full)

        # B — conditioning, then everything down to the model's working size.
        control_pose = _draw_openpose(pose)
        gray = cv2.cvtColor(full, cv2.COLOR_BGR2GRAY)
        edges = cv2.Canny(cv2.bilateralFilter(gray, 7, 60, 60), 80, 170)
        # Erase edges inside the repaint zone: they describe the OLD garment
        # and would drag its outline into the new one.
        edges_wiped = int((edges[mask_full > 20] > 0).sum())
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
        # THE GARMENT'S OWN COLOUR, not mid-grey and not skin. Both of those were
        # tried and both are visible when exposed, and a fill IS exposed: the mask
        # has to cover the old garment, the sampler paints the new hem where its
        # own prior puts it, and the strip between the two is fill. Grey left a
        # grey halo; skin sampled from the forearms left a salmon slab across the
        # hips (measured, |output − fill| ≈ 24/255, i.e. the sampler simply kept
        # the fill). Raising IP scale changed neither (0.75 → 0.9 → 1.0 at a fixed
        # seed).
        #
        # Averaging the flat-lay makes the fill benign in exactly that strip — an
        # unpainted patch reads as a slightly longer garment instead of a bruise —
        # and it biases the initial latent TOWARDS the target colour rather than
        # away from it. Skin stays the fallback for an unreadable flat-lay.
        init = full.copy()
        fill = _garment_color(np.array(garment)[:, :, ::-1])
        if fill is None:
            fill = np.array([128, 128, 128], np.uint8)
            try:
                skin = np.zeros(mask_full.shape, np.uint8)
                for wrist_i, elbow_i in ((4, 3), (7, 6)):
                    a, b = pose.pts[wrist_i], pose.pts[elbow_i]
                    if a and b:
                        cv2.line(skin, a, b, 255,
                                 max(6, round(full.shape[0] * 0.02)))
                skin = cv2.bitwise_and(skin, pose.silhouette)
                skin[mask_full > 20] = 0      # only pixels we are NOT repainting
                if int(skin.sum()) > 0:
                    fill = np.array([int(c) for c in cv2.mean(full, mask=skin)[:3]],
                                    np.uint8)
            except Exception:  # noqa: BLE001 — a fill is never worth a failed render
                pass
        # TWO-TONE, because the question the fill answers has two answers. On the
        # torso the garment certainly covers the pixel, so the garment's colour is
        # right. On the ARM it may not: a short sleeve leaves skin, and the model
        # stops where its prior stops regardless of how far the mask reaches.
        # Measured on a navy V-neck: the sampler painted the sleeve shorter than
        # the mask, the composite correctly declined to paint the remainder, and
        # what showed through was the BASICS' GREY SLEEVE — a light block at each
        # cuff. Filling the arm with skin makes that same declined region read as
        # a bare arm, which is what a short sleeve actually looks like.
        fill_img = np.empty_like(full)
        fill_img[:] = fill
        arm = _arm_zone(pose, kind)
        if arm.any():
            skin = np.zeros(mask_full.shape, np.uint8)
            for wrist_i, elbow_i in ((4, 3), (7, 6)):
                a, b = pose.pts[wrist_i], pose.pts[elbow_i]
                if a and b:
                    cv2.line(skin, a, b, 255, max(6, round(full.shape[0] * 0.02)))
            skin = cv2.bitwise_and(skin, pose.silhouette)
            skin[mask_full > 20] = 0      # sample only pixels we are NOT repainting
            if int(skin.sum()) > 0:
                fill_img[arm > 0] = [int(c) for c in cv2.mean(full, mask=skin)[:3]]
        init[mask_full > 20] = fill_img[mask_full > 20]

        # …and then the garment's real pixels over that, where the geometry works.
        # The flat fill stays everywhere the warp does not reach — sleeves, the
        # collar — so the sampler still has a neutral start there.
        warped = None
        if WARP:
            try:
                g_bgr = np.array(garment)[:, :, ::-1]
                sil = _flatlay_silhouette(g_bgr)
                if sil is not None:
                    if kind == "shoes":
                        # Footwear is in every look and was the weakest slot: the
                        # metrics reject shoes (no reference band applies), so
                        # nothing measured them and the sampler invented one — a
                        # brogue came back as a brown mass up the calf. A shoe is
                        # nearly rigid and both feet are frontal, so a quad per
                        # foot carries the real product: laces, sole, shape.
                        warped = shoes_warp(g_bgr, sil, pose, mask_full)
                    elif PARTS_WARP:
                        g_met = _garment_metrics(g_bgr, kind) or {}
                        warped = parts_warp(
                            g_bgr, sil, pose, kind, mask_full,
                            g_met.get("sleeve_ratio"), _split)
                    if DUAL_CYL and kind == "lower":
                        # A LEG IS ITS OWN CYLINDER. Behind its own flag until it has
                        # been weighed against the quad on the phone, the way the torso's
                        # cylinder was — the single-cylinder version of this shipped and
                        # had to be pulled the same hour.
                        warped = dual_cylinder_warp(g_bgr, sil, pose, mask_full) or warped
                    if TPS_WARP and kind in ("upper", "full"):
                        # UPPER BODY ONLY. A torso is one cylinder and the model fits it;
                        # a pair of legs is TWO, and fitting one cylinder across the whole
                        # hip span compresses the fabric toward the flanks and smears the
                        # inseam into a bright band down the leg. Measured on the jeans:
                        # peak brightness excess 173 with tps against 152 without, and on
                        # screen the difference is not subtle — darker denim, a hard white
                        # streak down one leg, a smeared edge on the other.
                        #
                        # The flag still takes precedence where it applies, and keeps the
                        # quad if tps declines.
                        warped = tps_warp(g_bgr, sil, pose, kind, mask_full,
                                          wrap=float(os.getenv("VTON_TPS_WRAP", "1.0"))) or warped
                    if warped is None and MESH_WARP:
                        g_met = _garment_metrics(g_bgr, kind) or {}
                        warped = mesh_warp(
                            g_bgr, sil, pose, kind, mask_full,
                            g_met.get("sleeve_ratio"), _split)
                    if warped is None:
                        warped = torso_warp(g_bgr, sil, pose, kind, mask_full)
            except Exception as e:  # noqa: BLE001 — a failed warp must not fail a render
                print(f"[warp] skipped: {type(e).__name__}: {e}", flush=True)
                warped = None
            # A warp that covers almost none of the slot did not work out; falling
            # back to plain inpainting beats compositing a sliver.
            if warped is not None and warped.coverage < 0.35:
                warped = None
        if warped is not None:
            # The flat-lay is lit flat by design; the body's own light falloff is
            # what makes it read as worn rather than pasted. Multiplicative, so the
            # colour the warp exists to preserve stays exactly as it was.
            warped.image[:] = apply_shading(
                warped.image, warped.mask, full,
                float(os.getenv("VTON_SHADING", "2.0")))
            wm = (cv2.GaussianBlur(warped.mask, (9, 9), 0).astype(np.float32) / 255.0)
            init = np.clip(warped.image * wm[:, :, None] +
                           init * (1.0 - wm[:, :, None]), 0, 255).astype(np.uint8)
            if POISSON:
                init = harmonise_poisson(init, warped.image, warped.mask)
            # GIVE CONTROLNET THE GARMENT'S OWN EDGES BACK. The Canny map is wiped
            # inside the mask because the edges there describe the OLD clothes —
            # true when the zone held nothing but a flat fill. Now it holds the
            # actual garment, and its seams, hem and print boundaries are exactly
            # the structure we want denoising to keep rather than smooth away.
            # EDGES IN COLOUR, NOT IN GREY. Dumped and counted: on a white-on-yellow
            # print the Canny map came back essentially empty inside the garment — the
            # figure's outline and the face, and nothing else — because that print is
            # nearly ISOLUMINANT. Grey levels around 200 against 185 carry no gradient
            # worth a threshold, while in chroma the same boundary is unmistakable. So
            # the ControlNet was given no structure at all exactly where the structure
            # is, which is a fair share of why a printed tee arrives flat: there was
            # nothing telling the sampler where the print ends and the fold begins.
            #
            # Lab, and all three channels unioned: L keeps what grey already found,
            # a and b catch every boundary that is a change of colour rather than of
            # brightness. Bilateral first, on the colour image, so micro-noise is
            # suppressed without softening the boundaries this exists to find.
            lab = cv2.cvtColor(cv2.bilateralFilter(init, 7, 60, 60), cv2.COLOR_BGR2LAB)
            w_edges = np.zeros(lab.shape[:2], np.uint8)
            for ch, (lo, hi) in zip(cv2.split(lab), ((80, 170), (24, 60), (24, 60))):
                w_edges = cv2.bitwise_or(w_edges, cv2.Canny(ch, lo, hi))

            # AND WHERE THE WARP DID NOT REACH, CONTINUE THE FABRIC instead of the mean.
            # See _nearest_fill: the mean of a black-and-white stripe is mid grey, which
            # is the colour of the basics underneath, so the flat fill handed back the
            # very thing it exists to hide. This replaces it inside the mask only where
            # the warp has nothing to say, and it feeds BOTH the init the sampler starts
            # from and the fallback the composite lands on, so the two cannot disagree.
            holes = (mask_full > 20) & (warped.mask == 0)
            if holes.any():
                near = _extend_fabric(warped.image, warped.mask, holes)
                fill_img[holes] = near[holes]
                init[holes] = near[holes]

            # BELOW THE HEM IS A LEG, NOT MORE FABRIC. For 'full' and 'lower' the band
            # deliberately runs to the ankle whatever the garment measures, because the
            # base wears full-length trousers and a dress or a pair of shorts needs the
            # shins repainted rather than left grey. Continuing the fabric down there —
            # which is what the fix above does everywhere else, correctly — dressed the
            # legs in the garment: the polka-dot dress came back as a dress AND matching
            # trousers AND matching shoes, measured on the wardrobe's own dress.
            #
            # So the extension stops at the hem and skin takes over. Sampled from the
            # forearms, the only skin guaranteed bare on this base, and the sampler then
            # has a leg-coloured region to turn into a leg instead of a garment-coloured
            # one to keep as garment.
            # SKIN BELOW THE HEM IS FOR A DRESS, AND THE HEM IS ONE ROW.
            #
            # Two corrections, both from a regression that reached the phone. Taking the
            # hem PER COLUMN meant any column where the warp happened to stop early —
            # the gap between two trouser legs is full of them — flooded everything
            # under it with skin, and a pair of jeans came back as one leg of denim and
            # one bare leg. A hem is a line across a garment, not a per-column
            # accident, so it is now the 85th percentile of where the warp actually
            # ends: high enough to ignore a ragged edge, low enough to be the hem.
            #
            # And only for 'full'. Trousers reach the ankle by definition, so there is
            # nothing below their hem to repaint; the flood there could only ever be a
            # bug. Shorts and skirts want it and will get it through their own measured
            # length, not by inference from a patchy warp.
            if kind == "full":
                wm_any = (warped.mask > 0)
                if wm_any.any():
                    cols = wm_any.any(axis=0)
                    ends = (wm_any.shape[0] - 1
                            - np.argmax(wm_any[::-1], axis=0))[cols]
                    hem_row = int(np.percentile(ends, 85)) if ends.size else 0
                    rows_i = np.arange(wm_any.shape[0])[:, None]
                    below = ((rows_i > hem_row) & (mask_full > 20)
                             ).astype(np.uint8) * 255
                    lit = inject_bare_legs(init, pose.pts, below, warped.mask,
                                           pose.silhouette, full)
                    changed = np.abs(lit.astype(np.int16)
                                     - init.astype(np.int16)).max(axis=2) > 0
                    init = lit
                    fill_img[changed] = lit[changed]

            # WHEN THE WARP IS GOOD, IT OWNS THE SILHOUETTE. The band is a rectangle
            # — it has to be, since a mask traced round the old clothes could never
            # grow a different shape — and everything inside it that the warp did not
            # reach got filled with flat garment colour. On a top that is most of the
            # defect: the tee arrived as a yellow rectangle with ruler-straight sides
            # and a hem that dissolved into a blur instead of ending, which is exactly
            # the "flat, pasted on" read. The warp already knows the garment's outline
            # — it carries it as its own alpha — so past a coverage threshold the mask
            # follows the warp plus room for a hem edge and its contact shadow.
            #
            # Gated on coverage, because the opposite bug is just as real: a warp that
            # only found half the garment must NOT be allowed to lock in half a
            # silhouette. Below the gate the band stays, and the sampler completes the
            # shoulders and side seams the warp missed.
            # AND ONLY BELOW THE ARMHOLE. Applied to the whole band this exposed the
            # base's own grey basics across the collar and one shoulder: up there the
            # warp's alpha stops short of where the old garment actually is, and the
            # band's first job — cover every pixel of what is being replaced — outranks
            # its silhouette. Below the armhole nothing of the base tee remains to
            # uncover, and that is where the dissolving hem lives.
            if kind in ("upper", "full") and warped.coverage >= 0.70:
                sh = [pose.pts[i][1] for i in (2, 5) if pose.pts[i]]
                hp = [pose.pts[i][1] for i in (8, 11) if pose.pts[i]]
                if sh and hp:
                    # THE ALLOWANCE HAS TO BE SMALLER THAN THE OVERHANG IT TRIMS.
                    # Pinned by row: the warp's alpha ends at 602, the mask runs to
                    # 614, and in that 12px gap init IS the base — so the sampler,
                    # refining at strength 0.55, kept the base's grey and painted it
                    # at the feather's own weight (row 605: mask 58, warp 0, output
                    # RGB 160,150,139). That is the grey haze under every hem, and the
                    # hard-hem experiment turned it into a bar. At 1.5% of the figure
                    # this dilation was 17px — wider than the 12px it needed to cut,
                    # so it cut nothing, which is why the first attempt measured as a
                    # no-op. 0.5% leaves ~6px, enough for a contact shadow.
                    r = max(3, int(round(full.shape[0] * 0.005))) | 1
                    room = cv2.dilate(warped.mask, np.ones((r, r), np.uint8))
                    # AND THE SLEEVES ARE EXEMPT. A tight allowance is only safe where
                    # the warp actually reached, and on the arms it does not: sleeve
                    # warping is parked (a 2D quad degenerates at the armhole), so the
                    # torso quad carries the whole 84% and the sleeve columns have no
                    # alpha at all. At 17px that was invisible; at 6px the trim cut the
                    # sleeve off and left a slice of bare arm and background through it.
                    # The corridor the mask builds for the arms is exactly the region
                    # that must survive this, so it is rebuilt here and added back.
                    ys = [q[1] for q in pose.pts if q]
                    span = max(1.0, max(ys) - min(ys)) if ys else 1.0
                    for ids in ((2, 3, 4), (5, 6, 7)):
                        chain = [pose.pts[i] for i in ids if pose.pts[i]]
                        for a_pt, b_pt in zip(chain, chain[1:]):
                            cv2.line(room, a_pt, b_pt, 255,
                                     int(max(24, span * 0.13)))
                    y_arm = int(min(sh) + (max(hp) - min(sh)) * 0.35)
                    mask_full[y_arm:] = cv2.bitwise_and(mask_full[y_arm:],
                                                        room[y_arm:])
        # ONE DRY LINE PER RENDER. Every mask defect this engine has had was
        # eventually pinned by a number, never by squinting at a phone screenshot
        # — and each time the number had to be re-derived by hand on the pod.
        # bbox answers "matchbox jacket", cov answers "mask escaped the slot",
        # warp/wcov answer "did the garment's own pixels arrive", wiped answers
        # "did ControlNet keep a cue of the old clothes".
        mm_ = mask_full > 20
        ys_, xs_ = np.nonzero(mm_)
        print("[diag] kind=%s hint=%r mask_px=%dk bbox=(%d,%d..%d,%d) "
              "warp=%s wcov=%s fill=%s edges_wiped=%d shading=%s" % (
                  kind, (prompt_hint or "")[:40], int(mm_.sum()) // 1000,
                  int(xs_.min()) if xs_.size else -1, int(ys_.min()) if ys_.size else -1,
                  int(xs_.max()) if xs_.size else -1, int(ys_.max()) if ys_.size else -1,
                  ("shoes" if kind == "shoes" and warped is not None else
                   "quad" if warped is not None else "none"),
                  ("%.0f%%" % (warped.coverage * 100)) if warped is not None else "-",
                  fill.tolist() if hasattr(fill, "tolist") else fill,
                  edges_wiped, os.getenv("VTON_SHADING", "2.0")), flush=True)

        # TENSOR DUMP, at the last moment before the sampler sees anything. Every
        # question about "what did we actually feed it" has been answered here by
        # argument until now, and argument has been wrong twice. VTON_DUMP=<dir>
        # writes the four arrays that decide the render, named by slot so a
        # three-layer look does not overwrite itself.
        dump = os.getenv("VTON_DUMP")
        pose_scale = POSE_SCALE if pose_scale is None else float(pose_scale)
        canny_scale = CANNY_SCALE if canny_scale is None else float(canny_scale)
        core_protect = CORE_PROTECT if core_protect is None else float(core_protect)

        if dump:
            os.makedirs(dump, exist_ok=True)
            cv2.imwrite(f"{dump}/{kind}_garment_cond.jpg",
                        np.array(garment.convert("RGB"))[:, :, ::-1])
            cv2.imwrite(f"{dump}/{kind}_init_image.jpg", init)
            cv2.imwrite(f"{dump}/{kind}_canny_map.jpg", control_canny)
            cv2.imwrite(f"{dump}/{kind}_mask.jpg", mask_full)
            if warped is not None:
                cv2.imwrite(f"{dump}/{kind}_warped.jpg", warped.image)
            print(f"[dump] {kind} -> {dump} ; init std={float(init[mask_full > 20].std()):.1f} "
                  f"canny_on={int((control_canny[:, :, 0] > 0).sum())} "
                  f"strength={WARP_STRENGTH if warped is not None else float(os.getenv('VTON_STRENGTH', '0.99'))} "
                  f"ip_scale={ip_scale if ip_scale is not None else 'default'} "
                  f"steps={steps or STEPS} cfg={os.getenv('VTON_CFG', '6.5')}", flush=True)

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
                strength=(WARP_STRENGTH if warped is not None
                          else float(os.getenv("VTON_STRENGTH", "0.99"))),
                controlnet_conditioning_scale=[pose_scale, canny_scale],
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
        # So ask, per pixel, whether it drew anything. This is arithmetic on the
        # same footing as the identity guarantee, not a prompt we hope lands.
        #
        # COLOUR ALONE CANNOT ANSWER THIS, and asking it that way broke dark
        # garments. Now that the fill IS the garment's colour, a correctly painted
        # black puffer sits close to a black fill — the test read that as "drew
        # nothing", kept the original, and the render came back wearing the grey
        # basics. Measured across twelve catalogue items: a black puffer rendered
        # silver and black jeans rendered grey, while navy (far from the grey
        # underneath) came out right.
        #
        # So ask it twice. Colour distance still catches a garment that differs
        # from the fill, and LOCAL CONTRAST catches one that matches it: real
        # fabric has folds and shading, a flat fill has none, and that holds at
        # any brightness. Only flat AND fill-coloured counts as untouched.
        by_colour = np.abs(gen_full - fill_img.astype(np.float32)).max(axis=2) / 26.0
        grey = cv2.cvtColor(np.clip(gen_full, 0, 255).astype(np.uint8), cv2.COLOR_BGR2GRAY)
        gf = grey.astype(np.float32)
        local_mean = cv2.blur(gf, (9, 9))
        local_std = np.sqrt(np.maximum(cv2.blur(gf * gf, (9, 9)) - local_mean ** 2, 0.0))
        by_texture = local_std / 3.0
        drew = np.maximum(by_colour, by_texture)
        # Blurred so the kept and repainted regions meet in a gradient rather than
        # a cut-out edge.
        drew = cv2.GaussianBlur((np.clip(drew, 0.0, 1.0) * 255).astype(np.uint8), (21, 21), 0)
        m = mask_full.astype(np.float32) / 255.0
        alpha = (m * (drew.astype(np.float32) / 255.0))[:, :, None]

        # WHAT TO FALL BACK TO depends on where we are in the mask. At the
        # feathered EDGE the original is right: that is the boundary with the rest
        # of the photo. But DEEP INSIDE, the original is the garment we were asked
        # to replace, and keeping it is the worst of the three options. Measured
        # on the hip strip of a look: the mask covered it, the sampler painted
        # almost nothing there, and the composite returned a half-and-half blend
        # of denim and the base's grey hem — the grey band reported from the
        # phone. The fill is the new garment's own colour, so an unpainted patch
        # in the core reads as a plain piece of that garment instead.
        # …AND NEVER OUTSIDE THE BODY. The mask is allowed a few pixels past the
        # silhouette so a garment can drape wider than the flesh — measured at 5 px
        # median, 11 px max — but the fallback there must be the PHOTOGRAPH, not the
        # garment's colour. Filling it with denim drew a saturated blue rim around
        # the hips and bulges in the gaps beside the arms, which on a white
        # background reads as the figure bleeding. This is the halo that was chased
        # all day at the mask level: the mask was right, the fallback was not.
        core = np.clip((m - 0.85) / 0.15, 0.0, 1.0)
        core = (core * (pose.silhouette > 0))[:, :, None]
        fallback = base * (1.0 - core) + fill_img.astype(np.float32) * core
        blended = gen_full * alpha + fallback * (1.0 - alpha)

        # THE DEEP CORE MAY KEEP THE SOURCE PIXELS. A single scalar strength is the
        # only denoising knob the pipeline exposes, and it applies to the whole mask
        # — so the centre of a panel, where a print lives, is denoised exactly as
        # hard as the boundary, where the sampler's folds and shading are wanted. The
        # distance transform separates the two by geometry: far from any edge is
        # "inside the garment", near an edge is "where it meets the body".
        #
        # Weighted, not switched, and gated on the layer having written something —
        # re-injecting warp pixels where the sampler declined would put garment back
        # into a region the composite deliberately left alone.
        if core_protect > 0 and warped is not None:
            d = cv2.distanceTransform((warped.mask > 20).astype(np.uint8),
                                      cv2.DIST_L2, 5)
            mx = float(d.max())
            if mx > 1e-6:
                prot = np.clip((d / mx - 0.2) * 2.0, 0.0, 1.0) * core_protect
                # Feathered, so the handover from source pixels to sampled ones is a
                # gradient rather than a ring — a hard core edge is its own artefact.
                prot = cv2.GaussianBlur(prot, (31, 31), 0)
                prot = (prot * (alpha[:, :, 0] > 0.05))[:, :, None]
                if dump:
                    cv2.imwrite(f"{dump}/{kind}_core_mask.jpg",
                                (prot[:, :, 0] * 255).astype(np.uint8))
                    print(f"[core] {kind} protect={core_protect} "
                          f"full={int((prot[:, :, 0] > 0.95).sum())}px "
                          f"any={int((prot[:, :, 0] > 0.01).sum())}px "
                          f"max={float(prot.max()):.2f}", flush=True)
                blended = (warped.image[:, :, ::-1].astype(np.float32) * prot
                           + blended * (1.0 - prot))

        out_img = Image.fromarray(np.clip(blended, 0, 255).astype(np.uint8))
        if not return_mask:
            return out_img
        # WHERE THIS LAYER WROTE ANYTHING — the sampler's own alpha plus the fill
        # core it falls back to. Not the raw mask: where the sampler declined and
        # the core was zero this is zero, so compositing layers with it reproduces
        # exactly what this method would have written and nothing else.
        wrote = alpha[:, :, 0] + (1.0 - alpha[:, :, 0]) * core[:, :, 0]
        return out_img, (np.clip(wrote, 0.0, 1.0) * 255).astype(np.uint8)

    # -- base preparation ---------------------------------------------------

    @staticmethod
    def leg_zones(pose: Pose) -> list[np.ndarray]:
        """Where the base's TROUSERS have to become bare legs, one zone per leg.

        Same lesson as the sleeves, one slot down: the base wears full-length
        trousers, so under a pair of SHORTS its grey leg shows and no mask can
        remove it — the sampler ends the shorts where its prior ends and the mask
        must reach past that to cover the old garment. Measured on the shorts
        category of the test set: every render showed trouser below the hem.

        THE CUT IS AT 30% OF HIP→ANKLE, upper thigh. Higher and the base has no
        shorts left, so a rendered pair of trousers has nothing to sit on at the
        waist and the crotch becomes the sampler's invention. Lower and short
        shorts still show trouser. It is the same trade the arms had, and the arms
        settled at "from the joint" only because a sleeve's own seam is at the
        joint; a leg has no such landmark, so this one is a choice to verify on
        the GPU rather than a derivation.

        FEET AND HANDS ARE CARVED OUT. Shoes are not this pass's business, and the
        hands hang at hip height in the canonical pose — the same reason the lower
        garment mask has to exclude them.
        """
        h, w = pose.h, pose.w
        pts = pose.pts
        ys = [q[1] for q in pts if q]
        if not ys:
            return []
        span = max(1.0, max(ys) - min(ys))
        zones: list[np.ndarray] = []
        for ids in ((8, 9, 10), (11, 12, 13)):
            chain = [pts[i] for i in ids if pts[i]]
            if len(chain) < 2:
                continue
            total = sum(math.hypot(b[0] - a[0], b[1] - a[1])
                        for a, b in zip(chain, chain[1:]))
            # FROM NEAR THE HIP, AND AS WIDE AS THE LEG ACTUALLY IS. Starting 30% down
            # and drawing a line 8.5% of the figure thick gave zones of 18k and 15k px
            # — a quarter of the leg — and the pass duly failed: too little of the
            # trouser was inside the zone for anything but trouser to come back.
            # Measured against the flood that DID work inside a render, which covered
            # 63k px. The silhouette knows each row's real width; a constant cannot.
            _, rest = _split(chain, total * 0.12)
            m = np.zeros((h, w), np.uint8)
            for a, b in zip(rest, rest[1:]):
                row = int(np.clip((a[1] + b[1]) / 2.0, 0, h - 1))
                occ = np.flatnonzero(pose.silhouette[row] > 20)
                thick = (max(20, int((occ[-1] - occ[0]) * 0.55)) if occ.size
                         else max(10, round(span * 0.085)))
                cv2.line(m, a, b, 255, thick)
            m = cv2.bitwise_and(m, pose.silhouette)
            ankle = pts[ids[2]]
            if ankle:      # the shoe stays; a foot is not a leg
                cv2.circle(m, ankle, max(10, round(span * 0.05)), 0, -1)
            for wrist_i in (4, 7):
                wr = pts[wrist_i]
                if wr:
                    cv2.circle(m, wr, max(10, round(span * 0.055)), 0, -1)
            if m.any():
                zones.append(m)
        return zones

    def bare_legs(self, avatar: Image.Image, seed: int | None = 7) -> Image.Image:
        """Repaint the base's trouser legs as bare skin. Run ONCE per avatar.

        The legs half of `bare_arms`, and it exists for the same measured reason —
        see `leg_zones`. Runs the identical per-zone machinery: own crop at native
        resolution (a leg inside a downscaled full frame came back as a smear when
        this was tried on arms), the adapter muted (it imposes garments, which is
        the opposite of this), and up to three seeds kept against the smoothness of
        real skin, because one arm in three came back ribbed.
        """
        return self._repaint(avatar, self.leg_zones, seed,
                             "bare human legs, sleeveless, smooth natural skin, "
                             "soft studio light, photographic",
                             "trousers, jeans, shorts, hem, seam, fabric, cloth, "
                             "textile, clothing, sock, shoe, tattoo, text, "
                             "watermark, deformed")

    def minimal_base(self, avatar: Image.Image, seed: int | None = 7) -> Image.Image:
        """Arms then legs: the base covering as little as any garment we render.

        Every artefact this engine has fought traces to the base covering MORE than
        the garment replacing it — the grey cuff under a short sleeve, the trouser
        under shorts. Two passes, ~12s once per avatar, and every later render
        inherits it.
        """
        return self.bare_legs(self.bare_arms(avatar, seed), seed)

    @staticmethod
    def arm_zones(pose: Pose) -> list[np.ndarray]:
        """Where the base's SLEEVES must become bare arms, one zone per arm."""
        h, w = pose.h, pose.w
        ys = [q[1] for q in pose.pts if q]
        span = max(1.0, (max(ys) - min(ys)) if ys else 1.0)
        zones: list[np.ndarray] = []
        for ids in ((2, 3, 4), (5, 6, 7)):
            chain = [pose.pts[i] for i in ids if pose.pts[i]]
            if len(chain) < 2:
                continue
            total = sum(math.hypot(b[0] - a[0], b[1] - a[1])
                        for a, b in zip(chain, chain[1:]))
            # FROM THE SHOULDER JOINT, not from partway down. Starting at 18% of
            # the upper arm left the top of the sleeve unmasked, and its hem
            # visible in the Canny map — the model read both as "a sleeve
            # continues here" and painted one, slightly longer than the original.
            # The torso is protected by subtracting the column between the
            # shoulders instead, which keeps the chest out of the zone without
            # leaving the cue in.
            mask = np.zeros((h, w), np.uint8)
            for a, b in zip(chain, chain[1:]):
                cv2.line(mask, a, b, 255, max(8, round(span * 0.075)))
            mask = cv2.bitwise_and(mask, pose.silhouette)
            ls, rs = pose.pts[5], pose.pts[2]
            if ls and rs:
                inner = max(6, round(span * 0.02))
                mask[:, min(ls[0], rs[0]) + inner:max(ls[0], rs[0]) - inner] = 0
            wrist = pose.pts[ids[2]]
            if wrist:      # hands stay original; diffusion mangles them
                cv2.circle(mask, wrist, max(8, round(span * 0.045)), 0, -1)
            if mask.any():
                zones.append(mask)
        return zones

    def bare_arms(self, avatar: Image.Image, seed: int | None = 7) -> Image.Image:
        """Repaint the base avatar's sleeves as bare skin. Run ONCE per avatar.

        THE BASE HAVING SLEEVES IS THE SINGLE BIGGEST SOURCE OF ARTEFACTS, and
        measuring said so plainly: of seven tops rendered across the catalogue,
        five showed the basics' grey sleeve or a coloured block at the cuff. The
        cause is structural and no mask tuning removes it — the sampler paints the
        sleeve where its prior ends, the mask must reach past that to cover the old
        sleeve, and whatever is in between shows. Every fill colour tried is
        visible there in a different way: grey read as fabric, skin read as a
        block, the garment's own colour read as an over-long sleeve.

        With bare arms underneath there is nothing to cover, so "the model stopped
        here" resolves to bare skin — which is what a short sleeve looks like, and
        a tank top, and a rolled cuff. One render per avatar buys that for every
        swap the avatar will ever appear in.

        PER ARM, ON ITS OWN CROP. The first attempt inpainted both arms inside the
        full frame, which is downscaled to 512 wide before it reaches the model:
        an arm is a thin thing, ~28k px of a 885k px frame, and it came back
        blurred into a smear. Cropping to one arm and giving it the whole 512×768
        raises the arm's effective resolution about fivefold for the same 20 steps.
        """
        return self._repaint(avatar, self.arm_zones, seed,
                             "bare skin, sleeveless, smooth natural skin, "
                             "soft studio light, photographic",
                             "sleeve, short sleeve, cuff, hem, seam, fabric, "
                             "cloth, textile, shirt, t-shirt, clothing, glove, "
                             "tattoo, text, watermark, deformed")

    def _repaint(self, avatar: Image.Image, zones_fn, seed: int | None,
                 prompt: str, negative: str) -> Image.Image:
        """One skin-repaint pass per zone. Shared by `bare_arms` and `bare_legs`:
        same crop per zone at native resolution, same muted adapter, same retry
        against real skin. Zones and wording are the only difference."""
        avatar = _fix_exif(avatar).convert("RGB")
        full = np.array(avatar)[:, :, ::-1].copy()
        pose = self.reader.read(full)
        h, w = full.shape[:2]
        ys = [q[1] for q in pose.pts if q]
        span = max(1.0, (max(ys) - min(ys)) if ys else 1.0)

        skin_src = np.zeros((h, w), np.uint8)
        for a_i, b_i in ((4, 3), (7, 6)):
            a, b = pose.pts[a_i], pose.pts[b_i]
            if a and b:
                cv2.line(skin_src, a, b, 255, max(6, round(h * 0.02)))
        skin_src = cv2.bitwise_and(skin_src, pose.silhouette)
        col = ([int(c) for c in cv2.mean(full, mask=skin_src)[:3]]
               if int(skin_src.sum()) else [128, 128, 128])

        pipe = self.ensure_loaded()
        control_pose = _draw_openpose(pose)
        out = full.copy()

        for mask in zones_fn(pose):

            xs_, ys_ = np.nonzero(mask)[1], np.nonzero(mask)[0]
            pad = int(span * 0.05)
            bx0, bx1 = max(0, xs_.min() - pad), min(w - 1, xs_.max() + pad)
            by0, by1 = max(0, ys_.min() - pad), min(h - 1, ys_.max() + pad)
            # Grow the crop to the model's aspect so nothing is squashed on resize.
            bw, bh = bx1 - bx0 + 1, by1 - by0 + 1
            want = WORK_W / WORK_H
            if bw / bh < want:
                need = int(bh * want) - bw
                bx0, bx1 = max(0, bx0 - need // 2), min(w - 1, bx1 + need - need // 2)
            else:
                need = int(bw / want) - bh
                by0, by1 = max(0, by0 - need // 2), min(h - 1, by1 + need - need // 2)

            init = full.copy()
            # SHADED FLOOD, not a flat one. A single colour was what this pass fed the
            # sampler, and the sampler kept it: measured in a render, a flat skin fill
            # came back as flat salmon trousers (skin-like 3% → 98% while texture fell
            # 8.57 → 2.59 — correctly coloured, still a slab). Multiplying by the base's
            # own row-normalised luminance costs nothing and gives the region the body's
            # light, so there is something for denoising to build anatomy on.
            zone_b = (mask > 20)
            grey_b = cv2.cvtColor(full, cv2.COLOR_BGR2GRAY).astype(np.float32)
            kb = (max(3, int(full.shape[0] * 0.10)) | 1)
            blur_b = cv2.GaussianBlur(grey_b, (kb, kb), 0)
            mean_b = float(blur_b[zone_b].mean()) or 1.0
            rows_b = np.where(zone_b.any(axis=1),
                              np.divide((blur_b * zone_b).sum(axis=1),
                                        np.maximum(zone_b.sum(axis=1), 1)), mean_b)
            rows_b[rows_b <= 1e-6] = mean_b
            field_b = np.clip(blur_b / rows_b[:, None], 0.88, 1.12)
            init[zone_b] = np.clip(np.array(col, np.float32)[None, :]
                                   * field_b[zone_b][:, None], 0, 255)
            sub = (slice(by0, by1 + 1), slice(bx0, bx1 + 1))
            cm = mask[sub]
            grey = cv2.cvtColor(full, cv2.COLOR_BGR2GRAY)
            edges = cv2.Canny(cv2.bilateralFilter(grey, 7, 60, 60), 80, 170)
            edges[mask > 20] = 0

            # ERASE THE OLD GARMENT'S OUTLINE ABOVE THE ZONE TOO. Inside the zone
            # the Canny map is already wiped, but a trouser leg continues from the
            # band just ABOVE it, and ControlNet carries that edge straight into the
            # zone — measured: the legs pass returned grey trouser with the base's
            # printed emblem showing through, the same way the first arms pass
            # returned a sleeve. The arms were fixed by starting at the joint so no
            # garment cue remained; a leg cannot be cut at the hip without leaving
            # the base naked, so the cue has to be removed instead.
            above = np.zeros_like(mask)
            ys0 = np.nonzero(mask > 20)[0]
            if ys0.size:
                top = int(ys0.min())
                above[max(0, top - int(span * 0.07)):top, :] = 255
                edges[cv2.bitwise_and(above, pose.silhouette) > 0] = 0

            # SKIN IS SMOOTH, AND THAT IS MEASURABLE. One arm in three came back
            # ribbed with periodic diagonal stripes — a plain diffusion artefact,
            # not a systematic error, so it is fixed by trying another seed rather
            # than by another parameter. The test is mean |Laplacian| inside the
            # zone against the SAME BODY'S forearm, which is original untouched
            # pixels: real skin sets the scale, so this needs no absolute
            # threshold and holds for any lighting or resolution. Once per avatar,
            # so up to three attempts is cheap insurance on an image that every
            # later render inherits.
            ref = cv2.Laplacian(cv2.cvtColor(full, cv2.COLOR_BGR2GRAY),
                                cv2.CV_32F)
            skin_ref = float(np.abs(ref[skin_src > 0]).mean()) if int(skin_src.sum()) else 0.0

            # THE ADAPTER IS NOT WANTED HERE. It exists to impose a garment, and
            # this pass is the opposite of that; a flat skin swatch through it
            # only adds a colour the fill already carries. Turned down for the
            # pass and restored after, so a queued render is unaffected.
            pipe.set_ip_adapter_scale(0.2)
            # PICK THE MOST SKIN-LIKE, NOT THE SMOOTHEST. Choosing the minimum
            # Laplacian was written to reject a ribbed arm, and on legs it did the
            # opposite of its intent: a pair of trousers is SMOOTHER than a knee, so
            # among three candidates the criterion reliably preferred the one that had
            # not been repainted at all. Measured: the pass returned trouser three
            # seeds running while its prompt, its zone and its flood were all correct.
            #
            # Skin has a warm chroma that fabric here does not, so the fraction of
            # skin-chromatic pixels inside the zone answers "is this a limb" directly.
            # Smoothness stays as the tie-break, since among two limbs the smoother one
            # is the one without the ribbing artefact.
            best, best_score = None, None
            for attempt in range(3):
                res = self._bare_arm_pass(
                    pipe, init, mask, control_pose, edges, sub, cm, col,
                    None if seed is None else seed + attempt * 101, prompt, negative)
                g = cv2.cvtColor(res, cv2.COLOR_BGR2GRAY)
                energy = float(np.abs(cv2.Laplacian(g, cv2.CV_32F))[cm > 20].mean())
                ycc_r = cv2.cvtColor(res, cv2.COLOR_BGR2YCrCb)
                warm = ((np.abs(ycc_r[:, :, 1].astype(np.int16) - 150) < 18)
                        & (np.abs(ycc_r[:, :, 2].astype(np.int16) - 112) < 18))
                frac = float(warm[cm > 20].mean())
                score = (round(frac, 2), -energy)
                if best_score is None or score > best_score:
                    best, best_score = res, score
                if frac > 0.6 and skin_ref and energy <= skin_ref * 1.6:
                    break
            pipe.set_ip_adapter_scale(float(os.getenv("VTON_IP_SCALE", "0.75")))

            k = max(5, round(span * 0.012)) | 1
            a = (cv2.GaussianBlur(cm, (k, k), 0).astype(np.float32) / 255.0)[:, :, None]
            out[sub] = np.clip(best.astype(np.float32) * a +
                               out[sub].astype(np.float32) * (1 - a), 0, 255)

        return _to_pil(out[:, :, ::-1])

    def _bare_arm_pass(self, pipe, init: np.ndarray, mask: np.ndarray,
                       control_pose: np.ndarray, edges: np.ndarray,
                       sub: tuple, cm: np.ndarray, col: list[int],
                       seed: int | None, prompt: str, negative: str) -> np.ndarray:
        """One attempt at one arm, returned as a BGR crop. See `bare_arms`."""
        # USE THE PROMPT THE CALLER PASSED. It was accepted and then ignored: both
        # arguments sat in the signature while the body asked for "a bare human arm"
        # and negated sleeves, whichever limb was being repainted. So bare_legs sent a
        # leg prompt with trousers, jeans and shorts in its negative, and the sampler
        # was asked for an arm and told to avoid a cuff — while looking at trousers.
        # It duly returned trousers, three seeds in a row, and the pass was written off
        # as a dead end for a reason that was never tested.
        res = pipe(
            prompt=prompt,
            negative_prompt=negative,
            image=_to_pil(init[sub][:, :, ::-1]).resize((WORK_W, WORK_H), Image.LANCZOS),
            mask_image=Image.fromarray(cm).resize((WORK_W, WORK_H), Image.LANCZOS),
            control_image=[
                _to_pil(control_pose[sub]).resize((WORK_W, WORK_H), Image.LANCZOS),
                _to_pil(cv2.cvtColor(edges[sub], cv2.COLOR_GRAY2RGB)).resize(
                    (WORK_W, WORK_H), Image.NEAREST),
            ],
            ip_adapter_image=Image.new("RGB", (224, 224), tuple(col[::-1])),
            num_inference_steps=STEPS,
            guidance_scale=float(os.getenv("VTON_CFG", "6.5")),
            controlnet_conditioning_scale=[0.9, 0.45],
            generator=(torch.Generator(device="cpu").manual_seed(seed)
                       if seed is not None else None),
        ).images[0]
        _drain()
        return cv2.resize(np.array(res)[:, :, ::-1], (cm.shape[1], cm.shape[0]),
                          interpolation=cv2.INTER_LANCZOS4)

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
        mask = _garment_mask(pose, kind, g, full)
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
