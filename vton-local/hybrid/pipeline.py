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
STEPS = int(os.getenv("VTON_STEPS", "28"))
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


def _garment_mask(p: Pose, kind: str) -> np.ndarray:
    """AGNOSTIC mask — the region to repaint, not a trace of the current
    clothes.

    Tracing what the person is already wearing is the classic trap: the mask
    then physically cannot express a different silhouette, so a tee can never
    become a jacket and every result quietly regresses toward the input
    garment. The mask has to be GENEROUS — the whole body zone for that slot,
    intersected with the person matte so the background stays untouched.
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

    box = np.zeros((h, w), np.uint8)
    box[max(0, int(y0)):int(y1) + 1, x0:x1 + 1] = 255

    mask = cv2.bitwise_and(box, p.silhouette)
    # Dilate past the silhouette edge: garments sit OUTSIDE the body outline
    # (sleeves, drape, a coat's shoulder line). A mask clipped to the skin
    # cannot grow one.
    k = max(5, round(span * dilate_frac)) | 1
    mask = cv2.dilate(mask, np.ones((k, k), np.uint8), iterations=1)
    mask = cv2.bitwise_and(mask, box)   # …but never past the slot's own band
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
    ) -> Image.Image:
        avatar = _fix_exif(avatar).convert("RGB")
        garment = _fix_exif(garment).convert("RGB")
        full = np.array(avatar)[:, :, ::-1].copy()          # RGB → BGR

        # A — geometry at the ORIGINAL resolution, so the mask lines up with
        # the pixels we composite back onto later.
        pose = self.reader.read(full)
        mask_full = _garment_mask(pose, kind)

        # B — conditioning, then everything down to the model's working size.
        control_pose = _draw_openpose(pose)
        gray = cv2.cvtColor(full, cv2.COLOR_BGR2GRAY)
        edges = cv2.Canny(cv2.bilateralFilter(gray, 7, 60, 60), 80, 170)
        # Erase edges inside the repaint zone: they describe the OLD garment
        # and would drag its outline into the new one.
        edges[mask_full > 20] = 0
        control_canny = cv2.cvtColor(edges, cv2.COLOR_GRAY2RGB)

        init_s = _to_pil(full[:, :, ::-1]).resize((WORK_W, WORK_H), Image.LANCZOS)
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
        alpha = (mask_full.astype(np.float32) / 255.0)[:, :, None]
        blended = gen_full * alpha + base * (1.0 - alpha)
        return Image.fromarray(np.clip(blended, 0, 255).astype(np.uint8))

    # -- introspection ------------------------------------------------------

    def debug(self, avatar: Image.Image, kind: str = "upper") -> Image.Image:
        """Pose + mask overlay, no diffusion. Every mask bug this session was
        found by LOOKING at this, and every one that shipped was found by not
        looking. Free and instant — use it before spending a render."""
        avatar = _fix_exif(avatar).convert("RGB")
        full = np.array(avatar)[:, :, ::-1].copy()
        pose = self.reader.read(full)
        mask = _garment_mask(pose, kind)
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
