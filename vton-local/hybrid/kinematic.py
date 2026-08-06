"""Kinematic exclusion shields: tapered capsules over the limbs, by geometry alone.

WHAT THIS IS FOR, AND WHAT IT IS NOT FOR. A capsule shield recovers the arm from a
semantic matte using nothing but skeleton keypoints, which is exactly what you need
when there is no photograph to interrogate — a matte handed over on its own, a pose
without its frame, a base whose colours cannot be trusted. It is the fallback path in
this pipeline, and it replaces the fixed-thickness lines that path used before.

It is NOT the primary separator here, and the measurement is worth carrying next to
the code so nobody re-derives it the hard way (this pipeline did, twice):

  * A capsule removes a DISC AROUND THE BONE, and in a frontal projection the arm
    hangs IN FRONT of the hip — the same columns hold arm and trousers both. Measured
    on the demo base at the hip row with a 70px-thick guard: 42px of real denim gone
    on one side, 37px on the other, and the base's grey trousers showed along both
    edges. Narrowing the guard trades one artefact for the other; there is no radius
    that separates them, because the ambiguity is not geometric.
  * The premise that the matte collapses the void did not hold on this base either.
    Classifying that same row pixel by pixel: skin 272..298, REAL BACKDROP 300..312,
    fabric 314..526, backdrop 527..535, skin 540..570. The void survived matting; the
    slabs came from a band sized off the figure's extremes, which at hip rows are the
    hands. That is a sizing bug, and it was fixed by measuring the fabric instead.

Where a base frame IS available, pipeline._garment_mask separates arm from garment by
COLOUR — skin by chroma, the backdrop by luminance and neutrality — because the image
can answer what the skeleton cannot: which of those shared columns is cloth.

Geometry-only, NumPy and OpenCV, no model.
"""
from __future__ import annotations

import cv2
import numpy as np

# COCO-18, the ordering PoseReader emits. Left/right are the image's, not the body's.
_CHAINS: dict[str, tuple[int, int, int]] = {
    "left": (2, 3, 4),      # shoulder, elbow, wrist
    "right": (5, 6, 7),
}
_ALIASES: dict[int, tuple[str, ...]] = {
    2: ("L_shoulder", "left_shoulder", "l_shoulder", "shoulder_l", "LShoulder"),
    3: ("L_elbow", "left_elbow", "l_elbow", "elbow_l", "LElbow"),
    4: ("L_wrist", "left_wrist", "l_wrist", "wrist_l", "LWrist"),
    5: ("R_shoulder", "right_shoulder", "r_shoulder", "shoulder_r", "RShoulder"),
    6: ("R_elbow", "right_elbow", "r_elbow", "elbow_r", "RElbow"),
    7: ("R_wrist", "right_wrist", "r_wrist", "wrist_r", "RWrist"),
}


def _lookup(keypoints, idx: int):
    """Accept the shapes a caller actually has: a COCO-18 sequence, or a dict keyed
    by index or by any of the usual names. Missing or null joints return None rather
    than raising — half a skeleton must still shield the half it knows."""
    if isinstance(keypoints, dict):
        if idx in keypoints:
            p = keypoints[idx]
        else:
            p = next((keypoints[k] for k in _ALIASES[idx] if k in keypoints), None)
    else:
        p = keypoints[idx] if idx < len(keypoints) else None
    if p is None:
        return None
    x, y = float(p[0]), float(p[1])
    if not (np.isfinite(x) and np.isfinite(y)):
        return None
    return x, y


def capsule(shape: tuple[int, int], a, b, r_a: float, r_b: float) -> np.ndarray:
    """Signed-distance capsule between a and b, radius tapering r_a → r_b.

    The distance must be to the SEGMENT, not to the line through it. The textbook
    cross-product form |(p-a)×(b-a)| / |b-a| measures the infinite line, so it keeps
    widening the shield past the wrist and past the shoulder — off the end of the
    forearm it would carve the hip. Clamping the projection parameter t to [0,1] is
    what turns that line into a segment and the shield into a capsule.

    Tapered rather than constant, because an arm is: a shoulder is roughly twice a
    wrist. A single radius either loses the deltoid or eats the hand's surroundings.
    """
    h, w = shape
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    bax, bay = b[0] - a[0], b[1] - a[1]
    denom = bax * bax + bay * bay
    pax, pay = xs - a[0], ys - a[1]
    if denom < 1e-6:                       # degenerate segment: a plain disc
        t = np.zeros_like(pax)
    else:
        t = np.clip((pax * bax + pay * bay) / denom, 0.0, 1.0)
    dx, dy = pax - t * bax, pay - t * bay
    return (dx * dx + dy * dy) <= (r_a + (r_b - r_a) * t) ** 2


def arm_shield(shape: tuple[int, int], keypoints, scale: float = 1.0,
               hand: bool = True, hand_scale: float = 1.5) -> np.ndarray:
    """Both arms as tapered capsules, plus a disc for each hand. uint8, 0 or 255.

    RADII COME FROM THE SKELETON, not from the frame. The forearm's own length is the
    only limb measurement guaranteed present, it scales with the subject's distance
    from the camera exactly as the arm's width does, and it survives cropping — where
    a fraction of image height does not. Ratios are anthropometric and deliberately
    conservative: an over-wide shield costs garment, and on this projection garment is
    what shares the columns.

    THE TERMINAL NODE IS NOT A JOINT, IT IS A BLOB. A line from elbow to wrist stops
    describing the occlusion exactly where the occlusion gets big: fingers, a fist, and
    in a mirror selfie the phone held between both hands — a lump sitting over the
    waistline that no segment can express. So each wrist gets a disc of hand_scale x
    the arm's own radius (1.5 by default), AND the capsule continues past the wrist
    along the forearm's direction, because a phone is held forward of the joint rather
    than centred on it. The disc alone would miss the device; the capsule alone would
    miss the spread of the fingers.
    """
    h, w = shape
    shield = np.zeros((h, w), np.uint8)
    for _, (i_sh, i_el, i_wr) in _CHAINS.items():
        sh = _lookup(keypoints, i_sh)
        el = _lookup(keypoints, i_el)
        wr = _lookup(keypoints, i_wr)
        # The forearm sets the scale; fall back to the upper arm when the wrist is
        # missing, and skip the limb entirely when neither segment exists.
        if el is not None and wr is not None:
            unit = float(np.hypot(wr[0] - el[0], wr[1] - el[1]))
        elif sh is not None and el is not None:
            unit = float(np.hypot(el[0] - sh[0], el[1] - sh[1])) * 0.85
        else:
            continue
        if unit < 2.0:
            continue
        r_sh, r_el, r_wr = (0.42 * unit * scale, 0.30 * unit * scale,
                            0.22 * unit * scale)
        if sh is not None and el is not None:
            shield |= capsule((h, w), sh, el, r_sh, r_el).astype(np.uint8) * 255
        if el is not None and wr is not None:
            shield |= capsule((h, w), el, wr, r_el, r_wr).astype(np.uint8) * 255
            if hand:
                r_hand = r_el * hand_scale
                ux, uy = (wr[0] - el[0]) / unit, (wr[1] - el[1]) / unit
                tip = (wr[0] + ux * 0.45 * unit, wr[1] + uy * 0.45 * unit)
                shield |= capsule((h, w), wr, tip, r_hand,
                                  r_hand * 0.85).astype(np.uint8) * 255
    return shield


def apply_kinematic_shield(raw_mask: np.ndarray, pose_keypoints, *,
                           scale: float = 1.0, hand: bool = True,
                           hand_scale: float = 1.5, buffer: int = 0,
                           feather: int = 0, return_shield: bool = False):
    """Subtract both arms' capsules from a garment mask.

    M' = M \\ (M_left_arm ∪ M_right_arm), as a strict boolean subtraction on the
    BINARY mask. Do this before any feather: a Gaussian bleeds masked values back into
    a hole punched before it — measured at ~15px on this figure, which was enough to
    paint a denim ring around each fist. Anything that must stay out of a repaint zone
    has to be subtracted after every operation that grows the mask, not only before.

    THE SUBTRACTION IS ABSOLUTE AND THE EDGE IS STILL SOFT — both, not one or the
    other, and the order is what makes that possible. `buffer` dilates the shield
    before subtracting, so the cut sits a few pixels clear of the bone and the sampler
    has room to put a crease or a contact shadow there instead of a hard crop.
    `feather` then blurs the mask so the denim does not meet the void along a stair-
    stepped binary edge — and the shield is subtracted AGAIN afterwards, because a
    Gaussian bleeds masked values straight back into the hole you just punched. That is
    not a theoretical worry: at k=29 on this figure it bled ~15px and painted a denim
    ring around each fist. Feather without the second subtraction is the bug it was
    meant to fix, wearing a softer edge.

    raw_mask may be bool, 0/1 or 0/255; the result matches its dtype family (uint8
    0/255 for integer input, bool for bool input).
    """
    if raw_mask.ndim != 2:
        raise ValueError(f"raw_mask must be 2-D, got shape {raw_mask.shape}")
    shield = arm_shield(raw_mask.shape, pose_keypoints, scale=scale, hand=hand,
                        hand_scale=hand_scale)
    if buffer > 0:
        k = int(buffer) * 2 + 1
        shield = cv2.dilate(shield, np.ones((k, k), np.uint8))
    hard = shield > 0
    if raw_mask.dtype == np.bool_:
        out = raw_mask & ~hard
    else:
        out = raw_mask.copy()
        out[hard] = 0
        if feather > 0:
            k = int(feather) | 1
            out = cv2.GaussianBlur(out, (k, k), 0)
            out[hard] = 0                      # …and again, after the blur
    return (out, shield) if return_shield else out
