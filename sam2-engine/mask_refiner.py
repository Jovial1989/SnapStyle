"""Mask post-processing between SAM 2 and the inpainting diffusion model.

A raw SAM 2 mask is a hard binary blob: jagged 1-px edges and zero falloff.
Fed straight into inpainting it produces the "sticker / paper-doll" effect —
the model blends nothing, the garment boundary screams. The fix is classic CV:
grow the mask a touch so the OLD garment is fully covered (no leftover cuffs
or collars peeking out), then feather the edge into a smooth alpha ramp the
diffusion model can blend across.
"""

import base64

import cv2
import numpy as np


class MaskRefiner:
    """Binary SAM 2 mask → production alpha mask (uint8, 0–255, soft edges).

    Args:
        dilate_kernel: side of the elliptical dilation kernel, px (odd; even
            values are bumped +1). ~5–7 for 512px masks; scale with resolution.
        dilate_iterations: how many dilation passes (each grows ~kernel/2 px).
        feather_kernel: Gaussian kernel side, px (odd; bumped +1 if even).
            15–21 gives the blending ramp diffusion models want at 512px.
    """

    def __init__(self, dilate_kernel: int = 7, dilate_iterations: int = 1,
                 feather_kernel: int = 21):
        self.dilate_kernel = self._odd(int(dilate_kernel))
        self.dilate_iterations = max(0, int(dilate_iterations))
        self.feather_kernel = self._odd(int(feather_kernel))

    @staticmethod
    def _odd(k: int) -> int:
        return max(1, k if k % 2 == 1 else k + 1)

    @staticmethod
    def _to_binary_u8(mask: np.ndarray) -> np.ndarray:
        """Normalize whatever SAM hands over (bool, 0/1, logits-thresholded
        float, already-0..255 uint8) to a clean {0, 255} single-channel u8."""
        m = np.asarray(mask)
        if m.ndim == 3:  # (1, H, W) from predict(); squeeze extra dims
            m = np.squeeze(m)
        if m.ndim != 2:
            raise ValueError(f"expected a 2D mask, got shape {mask.shape}")
        if m.dtype == np.bool_:
            return m.astype(np.uint8) * 255
        m = m.astype(np.float32)
        # 0/1 float masks and 0..255 masks both land right with a 0.5-of-max cut.
        peak = float(m.max())
        if peak <= 0:
            return np.zeros(m.shape, dtype=np.uint8)
        return ((m >= peak * 0.5).astype(np.uint8)) * 255

    def refine(self, mask: np.ndarray) -> np.ndarray:
        """Raw SAM 2 mask → 8-bit alpha: 0 = background, 255 = mask core,
        smooth gradient at the boundary."""
        binary = self._to_binary_u8(mask)

        # 1) Dilate: cover the old garment COMPLETELY — inpainting can't fix
        # pixels outside the mask, and a sliver of old sleeve ruins the swap.
        if self.dilate_iterations > 0:
            kernel = cv2.getStructuringElement(
                cv2.MORPH_ELLIPSE, (self.dilate_kernel, self.dilate_kernel))
            binary = cv2.dilate(binary, kernel, iterations=self.dilate_iterations)

        # 2) Feather: Gaussian falloff at the edge. The interior of any region
        # wider than the kernel stays saturated at 255; only the boundary ramps.
        feathered = cv2.GaussianBlur(
            binary, (self.feather_kernel, self.feather_kernel), 0)

        return feathered  # uint8 single-channel, 0..255

    def defringe_cutout_alpha(self, mask: np.ndarray,
                              erode_kernel: int = 3, erode_iterations: int = 1,
                              feather_kernel: int = 5) -> np.ndarray:
        """CUTOUT-side counterpart of [refine]: alpha for compositing a subject
        onto dark UI. Direction is INVERTED vs the inpaint mask — we ERODE
        first, stripping the 1–2 px ring of original-background color that
        reads as a white halo on dark cards, then feather just enough (small
        kernel) that the edge is soft without re-growing into the fringe."""
        binary = self._to_binary_u8(mask)
        kernel = cv2.getStructuringElement(
            cv2.MORPH_ELLIPSE, (self._odd(erode_kernel), self._odd(erode_kernel)))
        eroded = cv2.erode(binary, kernel, iterations=max(1, int(erode_iterations)))
        k = self._odd(feather_kernel)
        return cv2.GaussianBlur(eroded, (k, k), 0)

    def to_base64_png(self, refined: np.ndarray) -> str:
        """Refined alpha → base64 PNG string (single channel), for JSON
        responses. For binary endpoints prefer raw PNG bytes — base64 is +33%."""
        ok, png = cv2.imencode(".png", refined)
        if not ok:
            raise ValueError("png encode failed")
        return base64.b64encode(png.tobytes()).decode("ascii")
