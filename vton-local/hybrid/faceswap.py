"""Identity transfer: the user's face onto a studio model, before dressing.

Runs BEFORE pipeline.py. The point of the studio base is that everything the
VTON stage depends on is already ideal — frontal pose, even light, nothing
occluding the garment zones — so MediaPipe's pose and matte are reliable and the
inpaint stage stops fighting the input. This module is what makes that base the
user's own.

NO NEURAL SWAPPER, AND THAT IS A LICENCE DECISION, NOT A QUALITY ONE.
`insightface` is MIT in its CODE, but its model packs (buffalo_l and friends)
and the `inswapper_128` swapper are released for academic/non-commercial use
only — `inswapper` was withdrawn from public distribution outright. A commercial
product cannot ship them, and "it's just a research weight" is not a defence
anyone wants to make later. So: no insightface, no IP-Adapter-FaceID (its FaceID
embeddings come from the same insightface recognisers).

What replaces it is geometry, which is free of all that:

  MediaPipe FaceMesh (Apache-2.0, both code and weights, already pinned here for
  Pose) gives 468 landmarks on each face. A piecewise-affine warp over their
  Delaunay triangulation puts the user's face onto the model's face geometry;
  LAB statistics inside the face oval match the lighting; a feathered oval mask
  composites it. Every operation is OpenCV (Apache-2.0). Nothing downloads.

A generative swapper generalises to hard poses, and we do not need that
generalisation: WE own the target photograph. It is frontal, evenly lit and
neutral by construction. Where a geometric warp fails is exactly where we can
refuse the input instead — a three-quarter selfie, sunglasses, a hand on the
chin — and refusing with a reason beats shipping a melted face.

WHAT IS TRANSFERRED, precisely: the face oval — brows, eyes, nose, mouth, chin,
cheeks. NOT hair, NOT ears, NOT the neck. The user keeps the studio model's
haircut. That is the e-commerce convention and it is also the honest boundary of
this method; a user with very different hair will notice, and no amount of
blending changes it.

SKIN TONE IS A PRODUCT DECISION, NOT A BLEND PARAMETER. The composited face has
to sit on the model's neck without a seam, which pulls toward matching the
model; the user's identity pulls the other way. Matching all the way to the
model would recolour a person's face to someone else's tone, which is both wrong
and offensive. So this module matches LUMINANCE fully (that is lighting, and it
belongs to the photograph) and chroma only partly (`tone`, default 0.5), and the
real fix lives upstream: the studio base library must span skin tones and builds,
and selection must pick the nearest one. `advise_base()` returns the measurement
that selection needs.

    swapper = FaceSwapPipeline()
    out = swapper.swap(studio_model_png, user_selfie_jpg)   # -> SwapResult
    # out.image then goes into HybridVTONPipeline.generate(...) as the avatar
"""
from __future__ import annotations

import math
import threading
from dataclasses import dataclass

import cv2
import mediapipe as mp
import numpy as np
from PIL import Image

# ─────────────────────────────── landmark groups ─────────────────────────────

_MESH = mp.solutions.face_mesh
_CONN = mp.solutions.face_mesh_connections

# The five points every alignment in the literature uses, because they are the
# most repeatably localised: outer eye corners, nose tip, mouth corners. The
# global similarity fit runs on these alone, so a wobble in a cheek landmark
# cannot rotate the whole face.
_ANCHORS = (33, 263, 1, 61, 291)

# Points that get a Delaunay triangle. All 468 would work and would also mean
# ~900 triangles warped in Python per swap; this is the semantic subset, which is
# well distributed and stable. Cheek and mid-face fillers are listed explicitly
# because the connection sets are all edges of features, leaving the cheeks bare
# and producing triangles big enough to shear the face.
_NOSE = (1, 2, 4, 5, 6, 19, 94, 98, 168, 195, 197, 327)
_CHEEKS = (50, 93, 116, 123, 187, 205, 234, 280, 323, 345, 352, 411, 425, 454)


def _group(name: str) -> set[int]:
    conn = getattr(_CONN, name, None)
    return {i for edge in conn for i in edge} if conn else set()


def _oval_polygon(pts: np.ndarray) -> np.ndarray:
    """The face outline as an ordered polygon.

    FACEMESH_FACE_OVAL is a set of EDGES in arbitrary order, so feeding its
    points straight to fillPoly draws a star. Walking the edges recovers the
    cycle, and that keeps working if a mediapipe release renumbers the mesh.
    """
    edges = getattr(_CONN, "FACEMESH_FACE_OVAL", None)
    if not edges:
        return cv2.convexHull(pts.astype(np.int32))
    nbr: dict[int, list[int]] = {}
    for a, b in edges:
        nbr.setdefault(a, []).append(b)
        nbr.setdefault(b, []).append(a)
    start = next(iter(nbr))
    order, prev, cur = [start], None, start
    while True:
        nxt = next((n for n in nbr[cur] if n != prev), None)
        if nxt is None or nxt == start:
            break
        order.append(nxt)
        prev, cur = cur, nxt
    return pts[order].astype(np.int32)


# ─────────────────────────────────── results ─────────────────────────────────


@dataclass
class SwapResult:
    """The composite plus the numbers a caller needs to decide whether to trust it.

    `align_rms` is the residual of the 5-anchor similarity fit, in units of the
    target's inter-ocular distance: it is small when both faces look the same way
    and grows with pose disagreement, which is the failure this method has. Gate
    on it rather than on a visual guess.
    """
    image: Image.Image
    source_face_px: int          # inter-ocular distance in the selfie
    target_face_px: int          # …and in the studio model
    align_rms: float             # 0 = identical geometry; > ~0.12 is a pose clash
    upsampled: float             # >1 means the selfie was smaller than it needed

    @property
    def trustworthy(self) -> bool:
        return self.align_rms <= 0.12 and self.upsampled <= 1.6


class FaceSwapError(RuntimeError):
    """Unusable input. The message is meant to be shown to the user."""


# ──────────────────────────────── the pipeline ───────────────────────────────


class FaceSwapPipeline:
    """Face-oval transfer, CPU-only, no weights to download.

    Thread-safe by lock, matching PoseReader: the mediapipe solution object is
    stateful and a shared worker will call this concurrently.
    """

    def __init__(self, tone: float = 0.5) -> None:
        self._mesh = _MESH.FaceMesh(
            static_image_mode=True,
            max_num_faces=1,
            refine_landmarks=True,      # adds iris points; steadies eye alignment
            min_detection_confidence=0.4,
        )
        self._lock = threading.Lock()
        self.tone = float(tone)
        # Built once: the union of the semantic groups, as a sorted index list.
        idx = set(_NOSE) | set(_CHEEKS)
        for g in ("FACEMESH_FACE_OVAL", "FACEMESH_LEFT_EYE", "FACEMESH_RIGHT_EYE",
                  "FACEMESH_LEFT_EYEBROW", "FACEMESH_RIGHT_EYEBROW",
                  "FACEMESH_LIPS", "FACEMESH_NOSE"):
            idx |= _group(g)
        self._warp_idx = sorted(idx)

    # -- landmarks -----------------------------------------------------------

    def _landmarks(self, bgr: np.ndarray, what: str) -> np.ndarray:
        h, w = bgr.shape[:2]
        with self._lock:
            res = self._mesh.process(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB))
        if not res.multi_face_landmarks:
            raise FaceSwapError(f"no face found in the {what}")
        lm = res.multi_face_landmarks[0].landmark
        return np.array([[p.x * w, p.y * h] for p in lm], np.float32)

    @staticmethod
    def _interocular(pts: np.ndarray) -> float:
        a, b = pts[33], pts[263]
        return float(math.hypot(a[0] - b[0], a[1] - b[1]))

    # -- geometry ------------------------------------------------------------

    def _piecewise_warp(self, src: np.ndarray, src_pts: np.ndarray,
                        dst_pts: np.ndarray, shape: tuple[int, int]) -> np.ndarray:
        """Warp `src` so its landmarks land on `dst_pts`, triangle by triangle.

        Delaunay over the TARGET points, so the triangulation matches the frame we
        are filling and no triangle degenerates on the destination side.
        """
        h, w = shape
        out = np.zeros((h, w, 3), np.uint8)
        rect = (0, 0, w, h)
        subdiv = cv2.Subdiv2D(rect)
        lookup: dict[tuple[int, int], int] = {}
        for i, (x, y) in enumerate(dst_pts):
            xi, yi = int(round(x)), int(round(y))
            if not (0 <= xi < w and 0 <= yi < h):
                continue          # a landmark off-frame cannot anchor a triangle
            subdiv.insert((float(xi), float(yi)))
            lookup[(xi, yi)] = i

        for t in subdiv.getTriangleList():
            tri = [(int(round(t[0])), int(round(t[1]))),
                   (int(round(t[2])), int(round(t[3]))),
                   (int(round(t[4])), int(round(t[5])))]
            try:
                ids = [lookup[p] for p in tri]
            except KeyError:
                continue          # Subdiv2D's outer bounding triangles
            d = np.float32([dst_pts[i] for i in ids])
            s = np.float32([src_pts[i] for i in ids])
            r = cv2.boundingRect(d)
            if r[2] <= 0 or r[3] <= 0:
                continue
            d_local = d - np.float32([r[0], r[1]])
            m = cv2.getAffineTransform(s, d_local)
            patch = cv2.warpAffine(src, m, (r[2], r[3]), flags=cv2.INTER_LINEAR,
                                   borderMode=cv2.BORDER_REFLECT_101)
            tri_mask = np.zeros((r[3], r[2]), np.uint8)
            cv2.fillConvexPoly(tri_mask, d_local.astype(np.int32), 255, cv2.LINE_AA)
            roi = out[r[1]:r[1] + r[3], r[0]:r[0] + r[2]]
            np.copyto(roi, patch, where=tri_mask[:, :, None] > 0)
        return out

    # -- photometry ----------------------------------------------------------

    def _match_colour(self, warped: np.ndarray, target: np.ndarray,
                      skin: np.ndarray) -> np.ndarray:
        """Match lighting fully, tone partly. See the note in the module docstring.

        Statistics come from SKIN only — eyes, nostrils and the mouth line are
        dark and small, and letting them into the mean drags the whole face.
        """
        if int(skin.sum()) < 50:
            return warped
        w_lab = cv2.cvtColor(warped, cv2.COLOR_BGR2LAB).astype(np.float32)
        t_lab = cv2.cvtColor(target, cv2.COLOR_BGR2LAB).astype(np.float32)
        m = skin > 0
        out = w_lab.copy()
        for c, weight in ((0, 1.0), (1, self.tone), (2, self.tone)):
            ws, wm = w_lab[..., c][m].std(), w_lab[..., c][m].mean()
            ts, tm = t_lab[..., c][m].std(), t_lab[..., c][m].mean()
            if ws < 1e-3:
                continue
            scale = 1.0 + weight * ((ts / ws) - 1.0)
            shift = wm + weight * (tm - wm)
            out[..., c] = (w_lab[..., c] - wm) * scale + shift
        return cv2.cvtColor(np.clip(out, 0, 255).astype(np.uint8), cv2.COLOR_LAB2BGR)

    # -- public --------------------------------------------------------------

    def swap(self, target_image: Image.Image, source_image: Image.Image,
             blend: str = "feather") -> SwapResult:
        """Put the face from `source_image` onto the body in `target_image`.

        `blend="feather"` is the default: an alpha ramp over the eroded oval. It
        preserves the source's own contrast, which is where identity lives.
        `blend="poisson"` uses seamlessClone — better continuity when the two
        photographs disagree on lighting, at the cost of Poisson blending
        propagating the target's gradients into the face and flattening it.
        """
        target = np.array(target_image.convert("RGB"))[:, :, ::-1].copy()
        source = np.array(source_image.convert("RGB"))[:, :, ::-1].copy()
        t_pts = self._landmarks(target, "studio model")
        s_pts = self._landmarks(source, "selfie")

        t_eye, s_eye = self._interocular(t_pts), self._interocular(s_pts)
        if t_eye < 8 or s_eye < 8:
            raise FaceSwapError("the face is too small to transfer; move closer")

        # GLOBAL FIT FIRST, on the five anchors only, and MEASURE ITS RESIDUAL.
        # This is the honest test of "are these two faces even looking the same
        # way": a similarity transform cannot absorb a pose difference, so what it
        # cannot fit shows up here instead of showing up as a melted cheek later.
        sim, _ = cv2.estimateAffinePartial2D(
            np.float32([s_pts[i] for i in _ANCHORS]),
            np.float32([t_pts[i] for i in _ANCHORS]),
            method=cv2.LMEDS)
        if sim is None:
            raise FaceSwapError("could not align the selfie to the model")
        pred = (np.hstack([np.float32([s_pts[i] for i in _ANCHORS]),
                           np.ones((len(_ANCHORS), 1), np.float32)]) @ sim.T)
        rms = float(np.sqrt(((pred - np.float32([t_pts[i] for i in _ANCHORS])) ** 2)
                            .sum(axis=1).mean()) / t_eye)

        idx = [i for i in self._warp_idx if i < len(s_pts)]
        warped = self._piecewise_warp(source, s_pts[idx], t_pts[idx],
                                      target.shape[:2])

        # THE MASK IS THE TARGET'S OVAL, pulled in. Eroded because the oval runs
        # along the jaw and hairline, exactly where a mismatch is visible, and
        # feathered so the boundary is a ramp rather than a cut. Scaled to the
        # face, so a 400 px portrait and a 900 px one behave the same.
        oval = _oval_polygon(t_pts)
        mask = np.zeros(target.shape[:2], np.uint8)
        cv2.fillConvexPoly(mask, cv2.convexHull(oval), 255, cv2.LINE_AA)
        k = max(3, int(t_eye * 0.18)) | 1
        mask = cv2.erode(mask, np.ones((k, k), np.uint8), iterations=1)

        skin = mask.copy()
        for g in ("FACEMESH_LEFT_EYE", "FACEMESH_RIGHT_EYE", "FACEMESH_LIPS"):
            grp = sorted(_group(g))
            if grp:
                cv2.fillConvexPoly(
                    skin, cv2.convexHull(t_pts[grp].astype(np.int32)), 0, cv2.LINE_AA)
        warped = self._match_colour(warped, target, skin)

        if blend == "poisson":
            m = cv2.moments(mask)
            centre = (int(m["m10"] / max(m["m00"], 1)), int(m["m01"] / max(m["m00"], 1)))
            out = cv2.seamlessClone(warped, target, mask, centre, cv2.NORMAL_CLONE)
        else:
            f = max(3, int(t_eye * 0.12)) | 1
            a = (cv2.GaussianBlur(mask, (f, f), 0).astype(np.float32) / 255.0)[:, :, None]
            out = np.clip(warped.astype(np.float32) * a +
                          target.astype(np.float32) * (1 - a), 0, 255).astype(np.uint8)

        return SwapResult(
            image=Image.fromarray(out[:, :, ::-1]),
            source_face_px=int(s_eye),
            target_face_px=int(t_eye),
            align_rms=round(rms, 4),
            # The selfie's face has to be stretched to the model's size. Past ~1.6
            # there is no detail left to stretch and the face reads as soft — the
            # caller should ask for a closer photo rather than ship a blur.
            upsampled=round(t_eye / s_eye, 2),
        )

    def advise_base(self, source_image: Image.Image) -> dict:
        """What the studio-base SELECTION needs from the selfie.

        Returns the face's mean skin colour in LAB plus its width in pixels, so a
        caller can pick the model whose tone is nearest instead of recolouring a
        person's face to somebody else's — see the note in the module docstring.
        Selection is where tone belongs; blending is not.
        """
        src = np.array(source_image.convert("RGB"))[:, :, ::-1].copy()
        pts = self._landmarks(src, "selfie")
        mask = np.zeros(src.shape[:2], np.uint8)
        cv2.fillConvexPoly(mask, cv2.convexHull(_oval_polygon(pts)), 255, cv2.LINE_AA)
        for g in ("FACEMESH_LEFT_EYE", "FACEMESH_RIGHT_EYE", "FACEMESH_LIPS"):
            grp = sorted(_group(g))
            if grp:
                cv2.fillConvexPoly(
                    mask, cv2.convexHull(pts[grp].astype(np.int32)), 0, cv2.LINE_AA)
        lab = cv2.cvtColor(src, cv2.COLOR_BGR2LAB)
        mean = cv2.mean(lab, mask=mask)[:3]
        return {"skin_lab": [round(c, 1) for c in mean],
                "interocular_px": int(self._interocular(pts))}
