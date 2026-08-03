"""Hybrid VTON worker.

    uvicorn main:app --host 127.0.0.1 --port 8125

  POST /generate-hybrid   avatar + garment (multipart) → image/jpeg
  POST /debug-mask        avatar (multipart) → pose+mask overlay, no diffusion
  GET  /health            liveness + which base/device is active

First real render triggers the model download (~4 GB for sd15). Renders are
serialised through one worker-side queue: MPS executes kernels serially
anyway, and two concurrent diffusions on 16 GB is how you meet the OOM killer.
"""

from __future__ import annotations

import io
import os
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import Response
from PIL import Image, UnidentifiedImageError

from pipeline import BASE, DEVICE, HybridVTONPipeline

engine = HybridVTONPipeline()


@asynccontextmanager
async def lifespan(_app: FastAPI):
    # VTON_WARMUP=1 (the container default) pulls the weights into VRAM before
    # the port starts serving. Otherwise the FIRST paying user waits 20-40 s for
    # the load, and an orchestrator health check can reap the pod mid-load and
    # restart it into the same trap. Local dev leaves it off for fast reloads.
    if os.getenv("VTON_WARMUP", "0") == "1":
        t = time.time()
        engine.warmup()
        print(f"[vton] warm in {time.time() - t:.1f}s on {DEVICE}", flush=True)
    yield


app = FastAPI(title="hybrid-vton", docs_url=None, redoc_url=None, lifespan=lifespan)

_KINDS = {"upper", "lower", "full", "shoes"}
_MAX_BYTES = 25 * 1024 * 1024


async def _read_image(f: UploadFile, name: str) -> Image.Image:
    data = await f.read()
    if not data:
        raise HTTPException(422, f"{name}: empty file")
    if len(data) > _MAX_BYTES:
        raise HTTPException(413, f"{name}: file too large")
    try:
        return Image.open(io.BytesIO(data))
    except UnidentifiedImageError:
        raise HTTPException(422, f"{name}: not a decodable image")


@app.get("/health")
def health() -> dict:
    return {
        "ok": True,
        "device": DEVICE,
        "base": BASE,
        "loaded": engine._pipe is not None,
    }


@app.post("/generate-hybrid")
async def generate_hybrid(
    avatar: UploadFile = File(...),
    garment: UploadFile = File(...),
    kind: str = Form("upper"),
    prompt_hint: str = Form("the garment in the reference image"),
    steps: int | None = Form(None),
    seed: int | None = Form(None),
) -> Response:
    if kind not in _KINDS:
        raise HTTPException(422, f"kind must be one of {sorted(_KINDS)}")
    person = await _read_image(avatar, "avatar")
    ref = await _read_image(garment, "garment")

    t0 = time.time()
    try:
        result = engine.generate(
            person, ref, kind=kind, prompt_hint=prompt_hint,
            steps=steps, seed=seed,
        )
    except ValueError as e:          # no person / no keypoints — caller's input
        raise HTTPException(422, str(e))

    buf = io.BytesIO()
    result.save(buf, "JPEG", quality=92)
    return Response(
        content=buf.getvalue(),
        media_type="image/jpeg",
        headers={
            "X-Render-Seconds": f"{time.time() - t0:.1f}",
            "X-Device": DEVICE,
            "X-Base": BASE,
        },
    )


@app.post("/debug-mask")
async def debug_mask(
    avatar: UploadFile = File(...),
    kind: str = Form("upper"),
) -> Response:
    if kind not in _KINDS:
        raise HTTPException(422, f"kind must be one of {sorted(_KINDS)}")
    person = await _read_image(avatar, "avatar")
    try:
        overlay = engine.debug(person, kind=kind)
    except ValueError as e:
        raise HTTPException(422, str(e))
    buf = io.BytesIO()
    overlay.save(buf, "JPEG", quality=90)
    return Response(content=buf.getvalue(), media_type="image/jpeg")
