# Deploying the hybrid VTON worker to a CUDA GPU

Target: RunPod / Vast.ai, RTX 3090 or 4090 (24 GB VRAM).

## Build

```bash
docker build -t looktok/vton-hybrid:sd15 .
```

SDXL instead (bigger image, better cloth realism, slower):

```bash
docker build --build-arg VTON_BASE=sdxl -t looktok/vton-hybrid:sdxl .
```

Skip baking weights (when a network volume is mounted at `/opt/hf`):

```bash
docker build --build-arg PREFETCH=0 -t looktok/vton-hybrid:slim .
```

## Run

```bash
docker run --gpus all -p 8000:8000 --shm-size=8g looktok/vton-hybrid:sd15
```

`--shm-size` matters: the default 64 MB is what dataloader//dev/shm crashes come
from. With a shared weights volume instead of baked weights:

```bash
docker run --gpus all -p 8000:8000 --shm-size=8g -v /workspace/hf:/opt/hf looktok/vton-hybrid:slim
```

## Verify

```bash
curl -s localhost:8000/health
```

```bash
curl -X POST localhost:8000/generate-hybrid -F avatar=@avatar.png -F garment=@top.png -F kind=upper -o out.jpg -D- | grep -i x-render
```

## Push to a registry for RunPod

```bash
docker build --platform linux/amd64 -t <user>/vton-hybrid:sd15 . && docker push <user>/vton-hybrid:sd15
```

`--platform linux/amd64` is mandatory when building on an Apple Silicon Mac —
without it Docker produces an arm64 image that RunPod cannot run.

On RunPod: **Container Image** = that tag, **Container Disk** ≥ 30 GB (sd15) or
≥ 50 GB (sdxl), **Expose HTTP Port** = 8000. Nothing else to configure — the
image warms itself and answers `/health` when it is ready to serve.

## Knobs

| Env | Default | Meaning |
|---|---|---|
| `VTON_BASE` | `sd15` | `sd15` or `sdxl`. Must match what was prefetched. |
| `VTON_STEPS` | `20` | Denoise steps. Measured: 28 and 20 look identical, 12 flattens fabric shading. |
| `VTON_W` / `VTON_H` | `512×768` (sd15), `768×1024` (sdxl) | Working resolution. |
| `VTON_CFG` | `6.5` | Guidance. Above ~8 the garment starts overriding the body. |
| `VTON_IP_SCALE` | `0.75` | How hard the reference garment's texture is imposed. |
| `VTON_XFORMERS` | `1` | CUDA only; ignored elsewhere. |
| `VTON_OFFLOAD` | `0` | Turn on only to squeeze SDXL onto a 12 GB card. |
| `VTON_WARMUP` | `1` in the image | Load + 2-step render before serving. |

## Expected latency

Measured elsewhere, not on this hardware yet — treat as the target to verify,
not as a result:

| Config | 4090, 28 steps | 4090, 20 steps |
|---|---|---|
| sd15 512×768, 2×ControlNet + IP-Adapter | 2.0 s | 1.5 s (measured, RTX 4090) |
| sdxl 768×1024, same | ~12-18 s | ~9-13 s |

Two ControlNets plus an IP-Adapter roughly doubles the per-step cost against a
bare UNet, and CFG doubles the batch again. Sub-2-second renders are a
different architecture (LCM/Turbo distillation at 4-8 steps), not a knob.

## Scaling

One worker per GPU — uvicorn workers do not share VRAM, so `--workers 2` means
two full model copies and an OOM. Add pods, not workers.
