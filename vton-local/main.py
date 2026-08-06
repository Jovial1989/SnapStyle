# Local VTON worker — CatVTON on Apple Silicon (MPS), FastAPI.
#
# ROLE: Stage C evaluation bench. CatVTON weights are CC BY-NC-SA
# (non-commercial) — this worker is for measuring local quality/latency
# BEFORE we train our own weights. It must NOT serve Looktok production
# traffic. Production stays on the hybrid until own weights exist.
#
# Why CatVTON over OOTDiffusion for this box:
#   - single UNet over SD1.5-inpainting: ~4 GB in fp16, fits 16 GB unified;
#   - no OpenPose / human-parsing preprocessors (OOTD needs both, and
#     detectron2 on arm64 is its own project);
#   - mask-based inpainting = the same sampler-level identity guarantee the
#     FLUX-fill spike proved (locked pixels are copied, the face is safe);
#   - our person input is the canonical grey-basics avatar, so the
#     cloth-agnostic mask is a chroma threshold — no ML segmentation needed.
#
# Run:
#   PYTORCH_ENABLE_MPS_FALLBACK=1 uvicorn main:app --host 0.0.0.0 --port 8123
#
# The CatVTON repo must be cloned NEXT TO this file (see README.md):
#   git clone https://github.com/Zheng-Chong/CatVTON.git

import io
import os
import sys
import time
from contextlib import asynccontextmanager

import numpy as np
import torch
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import Response
from PIL import Image

from vton_core import NoFigure, build_mask, fit

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "CatVTON"))
from model.pipeline import CatVTONPipeline  # noqa: E402  (from the cloned repo)

# ── hard constraints for M1 Pro / 16 GB ──────────────────────────────────────
DEVICE = "mps"
DTYPE = torch.float16          # fp32 OOMs on 16 GB — non-negotiable

BASE_CKPT = "booksforcharlie/stable-diffusion-inpainting"  # CatVTON's pinned base
ATTN_REPO = "zhengchong/CatVTON"

pipe: CatVTONPipeline | None = None


@asynccontextmanager
async def lifespan(_app: FastAPI):
    global pipe
    if not torch.backends.mps.is_available():
        raise RuntimeError("MPS is not available — this worker targets Apple Silicon.")
    from huggingface_hub import snapshot_download
    attn_path = snapshot_download(ATTN_REPO)   # ~400 MB, cached in ~/.cache/huggingface
    t0 = time.time()
    pipe = CatVTONPipeline(
        base_ckpt=BASE_CKPT,                   # ~4 GB fp16, auto-downloaded once
        attn_ckpt=attn_path,
        attn_ckpt_version="mix",               # trained on VITON-HD + DressCode
        device=DEVICE,
        weight_dtype=DTYPE,
        use_tf32=False,                        # CUDA-only knob
        skip_safety_check=True,
    )
    print(f"[vton] CatVTON ready on {DEVICE}/{DTYPE} in {time.time() - t0:.0f}s")
    yield


app = FastAPI(title="Looktok local VTON (eval bench)", lifespan=lifespan)


@app.post("/generate")
async def generate(
    avatar: UploadFile = File(...),
    garment: UploadFile = File(...),
    category: str = Form("upper_body"),        # upper_body | lower_body | overall
    steps: int = Form(30),
    guidance: float = Form(2.5),
    seed: int = Form(42),
):
    if pipe is None:
        raise HTTPException(503, "model is still loading")
    if category not in ("upper_body", "lower_body", "overall"):
        raise HTTPException(422, "category must be upper_body | lower_body | overall")

    try:
        person = fit(Image.open(io.BytesIO(await avatar.read())))
        cloth = fit(Image.open(io.BytesIO(await garment.read())))
    except HTTPException:
        raise
    except Exception:
        raise HTTPException(422, "avatar/garment is not a readable image")

    try:
        mask = build_mask(person, category)
    except NoFigure as e:
        raise HTTPException(422, str(e))

    t0 = time.time()
    with torch.inference_mode():
        result = pipe(
            image=person,
            condition_image=cloth,
            mask=mask,
            num_inference_steps=steps,
            guidance_scale=guidance,
            # MPS generators are flaky — seed on CPU, diffusers accepts it
            generator=torch.Generator("cpu").manual_seed(seed),
        )[0]
    print(f"[vton] {category} {steps} steps in {time.time() - t0:.1f}s")

    buf = io.BytesIO()
    result.save(buf, "JPEG", quality=92)
    return Response(buf.getvalue(), media_type="image/jpeg")


@app.get("/health")
async def health():
    return {"ok": pipe is not None, "device": DEVICE, "dtype": str(DTYPE)}
