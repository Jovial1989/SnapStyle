"""Geometric middleware between MediaPipe pose landmarks and SAM 2 prompts.

Raw skeletal points make poor SAM prompts: oversized clothing extends far past
the skeleton (box too tight), hands resting on garments read as garment pixels
(mask bleeds onto skin), and busy prints fragment the mask. This builder turns
landmarks into a padded zone BOX, a grid of POSITIVE points inside the target
garment area, and NEGATIVE points pinned on face/hands/background — exactly
the (box, point_coords, point_labels) trio SAM2ImagePredictor.predict() wants.
"""

import numpy as np

# MediaPipe PoseLandmarker indices (33-point topology).
LM = {
    "nose": 0,
    "left_eye": 2, "right_eye": 5,
    "left_shoulder": 11, "right_shoulder": 12,
    "left_elbow": 13, "right_elbow": 14,
    "left_wrist": 15, "right_wrist": 16,
    "left_hip": 23, "right_hip": 24,
    "left_knee": 25, "right_knee": 26,
    "left_ankle": 27, "right_ankle": 28,
}

ZONES = ("top", "bottom", "full_body", "wrist")


class SamPromptBuilder:
    """Build SAM 2 prompts for one detected person.

    Args:
        landmarks: MediaPipe normalized landmarks (objects with .x, .y and
            optional .visibility), index-aligned with the 33-point topology.
        width/height: source image dimensions in pixels.
        zone: 'top' | 'bottom' | 'full_body'.
        padding: dynamic box padding as a fraction of box size (default +20%
            per side) — headroom for baggy/oversized garments.
        min_visibility: landmarks below this are treated as MISSING.
    """

    def __init__(self, landmarks, width: int, height: int, zone: str = "full_body",
                 padding: float = 0.20, min_visibility: float = 0.5):
        if zone not in ZONES:
            raise ValueError(f"zone must be one of {ZONES}, got {zone!r}")
        self.lms = landmarks
        self.w, self.h = int(width), int(height)
        self.zone = zone
        self.padding = float(padding)
        self.min_visibility = float(min_visibility)

    # ── landmark access ───────────────────────────────────────────────────────
    def _pt(self, name: str):
        """Pixel coords of a landmark, or None when absent/low-visibility."""
        idx = LM[name]
        if idx >= len(self.lms):
            return None
        lm = self.lms[idx]
        vis = getattr(lm, "visibility", None)
        if vis is not None and vis < self.min_visibility:
            return None
        x = min(max(lm.x, 0.0), 1.0) * self.w
        y = min(max(lm.y, 0.0), 1.0) * self.h
        return (float(x), float(y))

    def _pts(self, *names, required: int = 0):
        found = [p for p in (self._pt(n) for n in names) if p is not None]
        if len(found) < required:
            raise ValueError(
                f"zone '{self.zone}': only {len(found)}/{len(names)} landmarks visible "
                f"(need >= {required})")
        return found

    @staticmethod
    def _lerp(a, b, t: float):
        return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)

    # ── box ───────────────────────────────────────────────────────────────────
    def _padded_box(self, pts):
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
        # Dynamic padding: proportional to the box itself, so a close-up and a
        # far shot both get sensible slack for loose fabric.
        px = (x1 - x0) * self.padding
        py = (y1 - y0) * self.padding
        return (
            max(0.0, x0 - px), max(0.0, y0 - py),
            min(float(self.w), x1 + px), min(float(self.h), y1 + py),
        )

    # ── positive points ───────────────────────────────────────────────────────
    def _torso_grid(self, n: int = 3):
        """3×3 grid spanned by the shoulder and hip lines — rotation-robust
        (follows the body's own axes, not the image's)."""
        ls, rs = self._pt("left_shoulder"), self._pt("right_shoulder")
        lh, rh = self._pt("left_hip"), self._pt("right_hip")
        if None in (ls, rs, lh, rh):
            raise ValueError("torso landmarks not visible")
        pts = []
        for fy in (0.25, 0.5, 0.75):
            left = self._lerp(ls, lh, fy)
            right = self._lerp(rs, rh, fy)
            for fx in (0.3, 0.5, 0.7):
                pts.append(self._lerp(left, right, fx))
        return pts

    def _leg_points(self):
        """Midline points down each leg: hip→knee(→ankle when visible)."""
        pts = []
        for side in ("left", "right"):
            hip, knee = self._pt(f"{side}_hip"), self._pt(f"{side}_knee")
            if hip is None or knee is None:
                continue
            pts += [self._lerp(hip, knee, 0.35), self._lerp(hip, knee, 0.75)]
            ankle = self._pt(f"{side}_ankle")
            if ankle is not None:
                pts.append(self._lerp(knee, ankle, 0.5))
        if not pts:
            raise ValueError("leg landmarks not visible")
        return pts

    # ── negative points ───────────────────────────────────────────────────────
    def _negatives(self, box, include_wrists: bool = True):
        pts = []
        # Face: skin SAM must never include in a garment mask.
        pts += self._pts("nose", "left_eye", "right_eye")
        # Hands/wrists: resting on clothes they bleed into the mask — except
        # when the wrist itself IS the target zone (watch/bracelet try-on).
        if include_wrists:
            pts += self._pts("left_wrist", "right_wrist")
        # Background anchors: image corners (2% inset) that fall OUTSIDE the
        # padded zone box — they pin "not the garment" in cluttered scenes.
        inset_x, inset_y = self.w * 0.02, self.h * 0.02
        for cx, cy in ((inset_x, inset_y), (self.w - inset_x, inset_y),
                       (inset_x, self.h - inset_y), (self.w - inset_x, self.h - inset_y)):
            inside = box[0] <= cx <= box[2] and box[1] <= cy <= box[3]
            if not inside:
                pts.append((float(cx), float(cy)))
        return pts

    # ── public API ────────────────────────────────────────────────────────────
    def build(self) -> dict:
        """Returns {'box', 'point_coords', 'point_labels'} ready to splat into
        SAM2ImagePredictor.predict(). Raises ValueError when the zone's
        required landmarks aren't visible enough to prompt safely."""
        if self.zone == "top":
            anchors = self._pts("left_shoulder", "right_shoulder", "left_hip", "right_hip",
                                required=3)
            # Elbows widen the box for sleeves when visible (never required).
            anchors += self._pts("left_elbow", "right_elbow")
            positives = self._torso_grid()
        elif self.zone == "bottom":
            anchors = self._pts("left_hip", "right_hip", required=2)
            anchors += self._pts("left_knee", "right_knee", "left_ankle", "right_ankle")
            if len(anchors) < 3:
                raise ValueError("bottom zone: legs not visible")
            positives = self._leg_points()
        elif self.zone == "wrist":
            # Accessory try-on (watch/bracelet): hyper-localized to the wrist
            # so the diffusion mask physically cannot reach a locked garment.
            anchors = self._pts("left_wrist", "right_wrist", required=1)
            anchors += self._pts("left_elbow", "right_elbow")
            positives = self._pts("left_wrist", "right_wrist")
            for side in ("left", "right"):
                e, w = self._pt(f"{side}_elbow"), self._pt(f"{side}_wrist")
                if e is not None and w is not None:
                    positives.append(self._lerp(e, w, 0.82))  # lower forearm
        else:  # full_body
            anchors = self._pts(*LM.keys(), required=6)
            positives = self._torso_grid()
            try:
                positives += self._leg_points()
            except ValueError:
                pass  # upper-body shot — torso grid alone is fine

        box = self._padded_box(anchors)
        negatives = self._negatives(box, include_wrists=self.zone != "wrist")
        if self.zone == "wrist":
            # Pin the torso as explicit background — the locked shirt must
            # stay OUT of the mask even when a sleeve touches the wrist.
            ls, rs = self._pt("left_shoulder"), self._pt("right_shoulder")
            lh, rh = self._pt("left_hip"), self._pt("right_hip")
            if None not in (ls, rs, lh, rh):
                negatives.append(self._lerp(self._lerp(ls, rs, 0.5), self._lerp(lh, rh, 0.5), 0.5))

        coords = np.array(positives + negatives, dtype=np.float32)
        labels = np.array([1] * len(positives) + [0] * len(negatives), dtype=np.int32)
        return {
            "box": np.array(box, dtype=np.float32),
            "point_coords": coords,
            "point_labels": labels,
        }
