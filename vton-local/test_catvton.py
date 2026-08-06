# Direct CatVTON bench — no FastAPI in the way, so MPS failures surface raw.
# Reuses fit()/build_mask() from main.py (the mask is the interesting part: on a
# canonical grey-basics avatar it is a chroma threshold, no human-parsing net).
#
# Usage:
#   PYTORCH_ENABLE_MPS_FALLBACK=1 ./.venv-catvton/bin/python test_catvton.py \
#       fixtures/his_avatar.png fixtures/test_garment.png upper_body 30
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "CatVTON"))

import torch
from PIL import Image

from vton_core import build_mask, fit

from model.pipeline import CatVTONPipeline
from huggingface_hub import snapshot_download

person_path = sys.argv[1] if len(sys.argv) > 1 else "fixtures/his_avatar.png"
cloth_path = sys.argv[2] if len(sys.argv) > 2 else "fixtures/test_garment.png"
category = sys.argv[3] if len(sys.argv) > 3 else "upper_body"
steps = int(sys.argv[4]) if len(sys.argv) > 4 else 30
RW = int(os.environ.get("VTON_W", 512))
RH = int(os.environ.get("VTON_H", 768))

print(f"[bench] person={person_path} cloth={cloth_path} category={category} steps={steps}")
print(f"[bench] resolution {RW}x{RH}")
t0 = time.time()
attn = snapshot_download("zhengchong/CatVTON")
print(f"[bench] attn ckpt: {attn}  ({time.time() - t0:.0f}s)")

t0 = time.time()
pipe = CatVTONPipeline(
    base_ckpt="booksforcharlie/stable-diffusion-inpainting",
    attn_ckpt=attn,
    attn_ckpt_version="mix",
    device="mps",
    weight_dtype=torch.float16,   # fp32 OOMs on 16 GB unified
    use_tf32=False,               # CUDA-only knob
    skip_safety_check=True,
)
print(f"[bench] pipeline loaded in {time.time() - t0:.0f}s")

person = fit(Image.open(person_path), RW, RH)
cloth = fit(Image.open(cloth_path), RW, RH)
mask = build_mask(person, category)
mask.save("out_mask.png")
import numpy as _np
print(f"[bench] mask editable area: {(_np.asarray(mask) > 127).mean():.1%}")

t0 = time.time()
with torch.inference_mode():
    result = pipe(
        image=person, condition_image=cloth, mask=mask,
        num_inference_steps=steps, guidance_scale=2.5,
        height=RH, width=RW,
        generator=torch.Generator("cpu").manual_seed(42),
    )[0]
dt = time.time() - t0
result.save("out_catvton.jpg", quality=92)
print(f"[bench] RENDER {dt:.1f}s ({dt / steps:.2f}s/step) → out_catvton.jpg")

side = Image.new("RGB", (person.width * 3 + 40, person.height), "white")
side.paste(person, (0, 0))
side.paste(cloth, (person.width + 20, 0))
side.paste(result.resize(person.size), (person.width * 2 + 40, 0))
side.save("out_compare.jpg", quality=88)
print("[bench] side-by-side → out_compare.jpg")
