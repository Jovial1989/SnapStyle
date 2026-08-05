"""Bake the model weights into the image at BUILD time.

Without this, the first request on a fresh RunPod pod spends 3-8 minutes
downloading ~10 GB from HuggingFace while a paying GPU idles — and it repeats
on every autoscale event. Downloading once at build turns cold start into the
time it takes to move weights from disk to VRAM.

Reads the same env (VTON_BASE) the worker does, so the image contains exactly
the weights that image will serve.
"""
import os

from huggingface_hub import snapshot_download

BASE = os.getenv("VTON_BASE", "sd15").lower()

REPOS = {
    "sd15": [
        # allow_patterns keeps the .bin duplicates out: the repos ship both
        # formats and pulling both doubles the image for nothing.
        ("stable-diffusion-v1-5/stable-diffusion-inpainting", None),
        ("lllyasviel/control_v11p_sd15_openpose", None),
        ("lllyasviel/control_v11p_sd15_canny", None),
        # IP-Adapter repo is large (all bases in one repo) — take only what
        # sd15 loads: the adapter weight plus its CLIP-H image encoder.
        ("h94/IP-Adapter", ["models/ip-adapter-plus_sd15.bin",
                            "models/image_encoder/*"]),
    ],
    "sdxl": [
        ("diffusers/stable-diffusion-xl-1.0-inpainting-0.1", None),
        ("thibaud/controlnet-openpose-sdxl-1.0", None),
        ("diffusers/controlnet-canny-sdxl-1.0", None),
        ("h94/IP-Adapter", ["sdxl_models/ip-adapter-plus_sdxl_vit-h.safetensors",
                            "sdxl_models/image_encoder/*"]),
    ],
}

# Skip the fp32 .bin twins of every safetensors file — halves the pull.
SKIP = ["*.ckpt", "*.pth", "*.onnx", "*non_ema*", "*.msgpack", "*.h5"]

for repo, allow in REPOS[BASE]:
    print(f"[prefetch] {repo}", flush=True)
    snapshot_download(
        repo_id=repo,
        allow_patterns=allow,
        ignore_patterns=None if allow else SKIP,
    )
# MEDIAPIPE LAZILY DOWNLOADS ITS SOLUTION WEIGHTS. Observed on a clean venv:
# constructing Pose printed "Downloading model to .../pose_landmark_heavy.tflite".
# That download would otherwise land on the first paying request of a fresh pod,
# in the same place the diffusion weights were moved out of. Constructing each
# solution once here forces the fetch at build time. Both are Apache-2.0, code
# and weights, which is also why the face swap needs nothing else prefetched.
print("[prefetch] mediapipe solutions", flush=True)
try:
    import mediapipe as mp
    import numpy as np

    blank = np.zeros((256, 256, 3), np.uint8)
    with mp.solutions.pose.Pose(static_image_mode=True, model_complexity=2,
                                enable_segmentation=True) as pose:
        pose.process(blank)
    with mp.solutions.face_mesh.FaceMesh(static_image_mode=True,
                                         refine_landmarks=True) as mesh:
        mesh.process(blank)
except Exception as e:  # noqa: BLE001 — a warm cache is an optimisation, not a gate
    print(f"[prefetch] mediapipe warm-up skipped: {type(e).__name__}: {e}", flush=True)

print(f"[prefetch] done for VTON_BASE={BASE}")
