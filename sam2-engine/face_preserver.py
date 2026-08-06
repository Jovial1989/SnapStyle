"""Face Preservation Bypass — the user's face never goes through diffusion.

Inpainting/VTON models degrade faces: soft resolution, drifted features,
uncanny skin. The fix is surgical: BEFORE generation, capture the original
head region (located from MediaPipe landmarks); AFTER generation, forcefully
composite the untouched, full-resolution original face back over the output
through a feathered elliptical mask. The face is then 100% source pixels.

Works with the pose topology's face landmarks (nose 0, eyes 2/5, ears 7/8,
mouth 9/10) — already produced by the worker's PoseLandmarker, so no extra
model download. Coordinates scale proportionally when the generated image
comes back at a different resolution (inpainting preserves framing).

Usage in a diffusion pipeline:
    anchor = FacePreserver().capture(original_rgb, pose_landmarks)
    generated_rgb = run_inpainting(...)
    if anchor is not None:
        generated_rgb = FacePreserver().restore(anchor, generated_rgb)
"""

from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np

# MediaPipe pose topology — head landmarks.
_HEAD_LMS = (0, 2, 5, 7, 8, 9, 10)  # nose, eyes, ears, mouth corners


@dataclass
class FaceAnchor:
    """Everything needed to paste the original face back, resolution-agnostic."""
    crop: np.ndarray        # original RGB pixels of the head box
    mask: np.ndarray        # feathered elliptical alpha (u8), same size as crop
    box_frac: tuple         # (x0, y0, x1, y1) as FRACTIONS of the source image


class FacePreserver:
    """Capture/restore of the head region around MediaPipe face landmarks.

    Args:
        margin: box padding as a fraction of the landmark box (default 0.45 —
            generous, so hairline and jaw are inside the preserved region).
        feather: Gaussian kernel for the elliptical mask edge (odd; the blend
            border must be soft or the paste-back reads as a sticker).
        min_visibility: landmarks below this are ignored.
    """

    def __init__(self, margin: float = 0.45, feather: int = 31, min_visibility: float = 0.5):
        self.margin = float(margin)
        self.feather = feather if feather % 2 == 1 else feather + 1
        self.min_visibility = float(min_visibility)

    # ── capture ───────────────────────────────────────────────────────────────
    def capture(self, rgb: np.ndarray, landmarks) -> FaceAnchor | None:
        """Locate the head from [landmarks] and snapshot it. None when the face
        isn't confidently visible — callers simply skip restoration."""
        h, w = rgb.shape[:2]
        pts = []
        for i in _HEAD_LMS:
            if i >= len(landmarks):
                continue
            lm = landmarks[i]
            vis = getattr(lm, "visibility", None)
            if vis is not None and vis < self.min_visibility:
                continue
            pts.append((min(max(lm.x, 0.0), 1.0) * w, min(max(lm.y, 0.0), 1.0) * h))
        if len(pts) < 3:  # need nose + both eyes at minimum for a stable box
            return None

        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        bw, bh = max(xs) - min(xs), max(ys) - min(ys)
        if bw < 8 or bh < 8:
            return None
        # Landmarks cover eyes→mouth; the head extends well above the eyes —
        # pad asymmetrically (more headroom than jaw room).
        x0 = max(0.0, min(xs) - bw * self.margin)
        x1 = min(float(w), max(xs) + bw * self.margin)
        y0 = max(0.0, min(ys) - bh * (self.margin + 0.6))  # forehead + hair
        y1 = min(float(h), max(ys) + bh * self.margin)
        xi0, yi0, xi1, yi1 = int(x0), int(y0), int(x1), int(y1)
        if xi1 - xi0 < 8 or yi1 - yi0 < 8:
            return None

        crop = rgb[yi0:yi1, xi0:xi1].copy()
        ch, cw = crop.shape[:2]
        # Feathered ellipse inscribed in the box: hard center, soft border.
        mask = np.zeros((ch, cw), dtype=np.uint8)
        cv2.ellipse(mask, (cw // 2, ch // 2), (int(cw * 0.46), int(ch * 0.46)),
                    0, 0, 360, 255, -1)
        mask = cv2.GaussianBlur(mask, (self.feather, self.feather), 0)

        return FaceAnchor(crop=crop, mask=mask,
                          box_frac=(xi0 / w, yi0 / h, xi1 / w, yi1 / h))

    # ── restore ───────────────────────────────────────────────────────────────
    def restore(self, anchor: FaceAnchor, generated_rgb: np.ndarray) -> np.ndarray:
        """Paste the original face over [generated_rgb] (any resolution) through
        the feathered mask. Returns a new array; the input is not mutated."""
        gh, gw = generated_rgb.shape[:2]
        fx0, fy0, fx1, fy1 = anchor.box_frac
        x0, y0 = int(fx0 * gw), int(fy0 * gh)
        x1, y1 = min(gw, int(fx1 * gw)), min(gh, int(fy1 * gh))
        tw, th = x1 - x0, y1 - y0
        if tw < 4 or th < 4:
            return generated_rgb

        face = cv2.resize(anchor.crop, (tw, th), interpolation=cv2.INTER_LANCZOS4)
        alpha = cv2.resize(anchor.mask, (tw, th), interpolation=cv2.INTER_LINEAR)
        a = (alpha.astype(np.float32) / 255.0)[..., None]

        out = generated_rgb.copy()
        region = out[y0:y1, x0:x1].astype(np.float32)
        out[y0:y1, x0:x1] = (face.astype(np.float32) * a + region * (1.0 - a)).astype(np.uint8)
        return out
