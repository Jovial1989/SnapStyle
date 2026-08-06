"""Looktok SAM 2 Engine — experimental body parsing & mask generation worker.

Pipeline: photo → MediaPipe PoseLandmarker (Apache 2.0) finds the person and
yields body keypoints → the keypoints become POINT PROMPTS for Meta SAM 2
(Apache 2.0) → the best mask is composited into a transparent PNG silhouette,
512×512, subject centered — byte-identical contract to the rembg service and
the on-device engines, so the Flutter side can swap engines blindly.

License constraint (hard): Apache 2.0 / BSD only — MediaPipe, SAM 2, OpenCV,
NumPy, FastAPI. NO Ultralytics/YOLO, no GPL/AGPL dependencies.

Ops lessons baked in (from the rembg worker's Fly.io deployment):
- WARM STATE via lifespan, but on a BACKGROUND thread: models load exactly
  once at startup into app.state — never per request — while uvicorn binds
  the port instantly (a blocking startup load = the platform's health checks
  kill the machine before it ever listens; see the rembg worker's 502 saga).
- Bind 0.0.0.0 (Fly's proxy speaks IPv4 to the machine; "::" is V6ONLY in
  Python and refuses it).
- Endpoints that do CPU/GPU-bound work are SYNC `def`s → FastAPI runs them in
  a threadpool and /health stays responsive mid-inference.
"""

import os
import threading
from contextlib import asynccontextmanager

import numpy as np
from fastapi import FastAPI, File, Form, UploadFile
from fastapi.responses import Response

from face_preserver import FacePreserver
from mask_refiner import MaskRefiner
from prompt_builder import ZONES, SamPromptBuilder


@asynccontextmanager
async def lifespan(app: FastAPI):
    """WARM STATE: both models load exactly ONCE, at startup — never per
    request. But the load runs in a daemon thread, NOT inline: a blocking
    startup kept uvicorn from binding the port and the platform's health
    checks killed the machine (the rembg worker's 502 saga). The server
    binds instantly; endpoints block (in FastAPI's threadpool) on _READY
    only until the one-time load lands, then reuse app.state forever."""
    threading.Thread(target=_load_models, args=(app,), daemon=True).start()
    yield


app = FastAPI(title="Looktok SAM 2 Engine", lifespan=lifespan)

# Stateless CV post-processing (no models) — safe as module-level singletons.
refiner = MaskRefiner(dilate_kernel=7, feather_kernel=21)
face_preserver = FacePreserver()

# Model assets — override via env. Download at image-build time (Dockerfile),
# never at request time.
POSE_MODEL_PATH = os.environ.get("POSE_MODEL_PATH", "/models/pose_landmarker_lite.task")
SAM2_CHECKPOINT = os.environ.get("SAM2_CHECKPOINT", "/models/sam2_hiera_small.pt")
SAM2_CONFIG = os.environ.get("SAM2_CONFIG", "sam2_hiera_s.yaml")
OUTPUT_SIZE = 512

MODEL_INPUT_MAX_W = 768  # AI models never see more pixels than this (speed)
WEBP_QUALITY = 85

_READY = threading.Event()
_LOAD_ERROR: str | None = None


def _load_models(app: FastAPI) -> None:
    """One-time startup load into app.state (runs on the lifespan thread)."""
    global _LOAD_ERROR
    try:
        # MediaPipe Tasks — pose landmarks give us grounded point prompts so
        # SAM doesn't wander off to furniture or a second person in a mirror.
        from mediapipe.tasks import python as mp_python
        from mediapipe.tasks.python import vision as mp_vision

        app.state.pose = mp_vision.PoseLandmarker.create_from_options(
            mp_vision.PoseLandmarkerOptions(
                base_options=mp_python.BaseOptions(model_asset_path=POSE_MODEL_PATH),
                running_mode=mp_vision.RunningMode.IMAGE,
                num_poses=1,
            )
        )
        import torch
        from sam2.build_sam import build_sam2
        from sam2.sam2_image_predictor import SAM2ImagePredictor

        device = "cuda" if torch.cuda.is_available() else "cpu"
        app.state.sam = SAM2ImagePredictor(build_sam2(SAM2_CONFIG, SAM2_CHECKPOINT, device=device))
        print(f"[warmup] models ready (device={device})")
    except Exception as e:  # surface via /health + 503s, never a dead port
        _LOAD_ERROR = str(e)
        print(f"[warmup] FAILED: {e}")
    finally:
        _READY.set()


def get_engines():
    """Instant after warm-up. Endpoints are sync `def`s (threadpool), so an
    early request parks here briefly instead of triggering a reload."""
    _READY.wait(timeout=300)
    if _LOAD_ERROR:
        raise RuntimeError(f"model load failed: {_LOAD_ERROR}")
    if not hasattr(app.state, "sam"):
        raise RuntimeError("models not ready")
    return app.state.pose, app.state.sam


def _downsample(rgb: np.ndarray) -> np.ndarray:
    """Cap the model input at MODEL_INPUT_MAX_W wide (aspect preserved) —
    MediaPipe/SAM gain nothing from more pixels, and inference cost scales
    with area. The 512px output canvas is untouched by this."""
    import cv2

    h, w = rgb.shape[:2]
    if w <= MODEL_INPUT_MAX_W:
        return rgb
    scale = MODEL_INPUT_MAX_W / w
    return cv2.resize(rgb, (MODEL_INPUT_MAX_W, max(1, int(h * scale))),
                      interpolation=cv2.INTER_AREA)


@app.get("/health")
def health():
    return {"ok": True, "engine": "mediapipe+sam2",
            "warm": _READY.is_set() and _LOAD_ERROR is None}


@app.post("/warmup")
def warmup():
    """Optional explicit warm-up so the first real request doesn't pay init."""
    get_engines()
    return {"ok": True, "warm": True}


def _pose_prompts(pose, rgb: np.ndarray, zone: str) -> dict | None:
    """MediaPipe pose → SamPromptBuilder → {box, point_coords, point_labels}.
    None when no person is found; ValueError bubbles when the zone's landmarks
    are too occluded to prompt safely."""
    import mediapipe as mp

    result = pose.detect(mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb))
    if not result.pose_landmarks:
        return None
    h, w = rgb.shape[:2]
    return SamPromptBuilder(result.pose_landmarks[0], w, h, zone=zone).build()


def _cutout_payload(rgb: np.ndarray, mask: np.ndarray) -> bytes:
    """Binary mask → tight-cropped, 512×512-padded transparent WEBP (q85 —
    ~5-8× lighter on the wire than the old PNG; alpha survives). Same visual
    contract as every Looktok mask engine."""
    import cv2

    # Defringe: erode 1–2 px of background-colored edge ring + soft feather —
    # without this the cutout wears a white halo on dark UI backgrounds.
    alpha = refiner.defringe_cutout_alpha(mask)
    ys, xs = np.where(alpha > 0)
    if len(xs) == 0 or (xs.max() - xs.min()) * (ys.max() - ys.min()) < rgb.shape[0] * rgb.shape[1] * 0.02:
        raise ValueError("no confident subject")
    x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    rgba = np.dstack([rgb[y0:y1, x0:x1], alpha[y0:y1, x0:x1]])

    h, w = rgba.shape[:2]
    scale = OUTPUT_SIZE / max(h, w)
    rgba = cv2.resize(rgba, (max(1, int(w * scale)), max(1, int(h * scale))), interpolation=cv2.INTER_AREA)
    h, w = rgba.shape[:2]
    top, left = (OUTPUT_SIZE - h) // 2, (OUTPUT_SIZE - w) // 2
    canvas = np.zeros((OUTPUT_SIZE, OUTPUT_SIZE, 4), dtype=np.uint8)
    canvas[top:top + h, left:left + w] = rgba
    ok, buf = cv2.imencode(".webp", cv2.cvtColor(canvas, cv2.COLOR_RGBA2BGRA),
                           [int(cv2.IMWRITE_WEBP_QUALITY), WEBP_QUALITY])
    if not ok:
        raise ValueError("webp encode failed")
    return buf.tobytes()


@app.post("/preserve-face")
def preserve_face(original: UploadFile = File(...), generated: UploadFile = File(...)):
    """Face Preservation Bypass as a standalone service: the ORIGINAL photo +
    a diffusion OUTPUT in → the output with the untouched original face
    composited back (feathered ellipse located via pose landmarks) as PNG.
    422 when no confident face — callers keep the generated image as-is."""
    import cv2

    def _decode(f):
        arr = cv2.imdecode(np.frombuffer(f.file.read(), np.uint8), cv2.IMREAD_COLOR)
        return None if arr is None else cv2.cvtColor(arr, cv2.COLOR_BGR2RGB)

    src, gen = _decode(original), _decode(generated)
    if src is None or gen is None:
        return Response(status_code=422, content=b"undecodable image")
    try:
        pose, _sam_unused = get_engines()
        import mediapipe as mp
        det = pose.detect(mp.Image(image_format=mp.ImageFormat.SRGB, data=src))
        if not det.pose_landmarks:
            return Response(status_code=422, content=b"no person detected")
        anchor = face_preserver.capture(src, det.pose_landmarks[0])
        if anchor is None:
            return Response(status_code=422, content=b"face not confidently visible")
        # NOTE: no downsampling here — full-resolution face fidelity is the
        # entire point of this endpoint. Only the wire format is webp.
        out = face_preserver.restore(anchor, gen)
        ok, buf = cv2.imencode(".webp", cv2.cvtColor(out, cv2.COLOR_RGB2BGR),
                               [int(cv2.IMWRITE_WEBP_QUALITY), WEBP_QUALITY])
        if not ok:
            raise ValueError("webp encode failed")
        return Response(content=buf.tobytes(), media_type="image/webp")
    except Exception as e:
        return Response(status_code=503, content=f"engine error: {e}".encode())


@app.post("/generate-mask")
def generate_mask(file: UploadFile = File(...), zone: str = Form("full_body"),
                  output: str = Form("cutout")):
    """Multipart photo (+ optional `zone`: top | bottom | full_body, and
    `output`: cutout | inpaint_mask) in → PNG out. `cutout` (default) is the
    transparent silhouette every Looktok engine returns; `inpaint_mask` is the
    dilated + feathered single-channel alpha for the inpainting diffusion
    model. Any failure → 422/503 (the Flutter controller treats every non-200
    as 'fall back to legacy')."""
    import cv2

    if zone not in ZONES:
        return Response(status_code=422, content=f"bad zone {zone!r}".encode())
    if output not in ("cutout", "inpaint_mask"):
        return Response(status_code=422, content=f"bad output {output!r}".encode())
    data = file.file.read()
    bgr = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
    if bgr is None:
        return Response(status_code=422, content=b"undecodable image")
    # Smart downsampling: the models only ever see <=768px-wide pixels —
    # inference cost scales with area, quality of a 512px cutout doesn't.
    rgb = _downsample(cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB))

    try:
        pose, sam = get_engines()
        prompts = _pose_prompts(pose, rgb, zone)
        if prompts is None:
            return Response(status_code=422, content=b"no person detected")

        sam.set_image(rgb)
        masks, scores, _ = sam.predict(
            box=prompts["box"],
            point_coords=prompts["point_coords"],
            point_labels=prompts["point_labels"],
            multimask_output=True,
        )
        best = masks[int(np.argmax(scores))]
        if output == "inpaint_mask":
            refined = refiner.refine(best)
            ok, buf = cv2.imencode(".webp", cv2.cvtColor(refined, cv2.COLOR_GRAY2BGR),
                                   [int(cv2.IMWRITE_WEBP_QUALITY), WEBP_QUALITY])
            if not ok:
                raise ValueError("webp encode failed")
            return Response(content=buf.tobytes(), media_type="image/webp")
        return Response(content=_cutout_payload(rgb, best), media_type="image/webp")
    except ValueError as e:
        return Response(status_code=422, content=str(e).encode())
    except Exception as e:  # never 500 with a stack trace to the app
        return Response(status_code=503, content=f"engine error: {e}".encode())
