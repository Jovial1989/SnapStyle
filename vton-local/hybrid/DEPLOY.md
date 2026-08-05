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

## Cost, and running the pod per session

A render is under three seconds and the pod is $0.69/h, so a pod left running
bills about $500 a month to idle through more than 99% of it. Until there is real
traffic the pod goes up for a session and stops itself afterwards:

```bash
vton-local/hybrid/gpu.sh up       # start, pull, run the worker
vton-local/hybrid/gpu.sh logs     # watch renders
vton-local/hybrid/gpu.sh down     # stop now; prints what the session cost
vton-local/hybrid/gpu.sh status   # state, uptime, spend so far
```

`up` starts `autostop.sh`, which runs the worker with `VTON_IDLE_EXIT_SEC=900`:
fifteen minutes with an empty queue and the worker exits, then the pod stops
itself. Stopping keeps the disk and the network volume, so the next `up` has the
weights already there — it is not `terminate`.

Config lives at `~/.config/looktok/runpod.env` (outside the repo, it holds an API
key): `RUNPOD_API_KEY`, `RUNPOD_POD_ID`, `SSH_KEY`. Put `RUNPOD_API_KEY` in
`/workspace/env.sh` on the pod as well, so `autostop.sh` can stop it when
`runpodctl` is not authenticated there.

**The ssh port changes every time the pod starts.** `gpu.sh up` reads the current
host and port from the API and caches them; `gpu.sh ssh` and `gpu.sh logs` use
that cache. Three separate debugging sessions were lost to a stale port.

For a pod serving real traffic set `VTON_IDLE_EXIT_SEC=0`, which disables the
exit. The next step past that is serverless per-second billing, where the same
pull worker becomes a handler that drains the queue and returns —
`claim_vton_job()` already holds `FOR UPDATE SKIP LOCKED`, so concurrent
containers cannot take the same job.

While no worker is running, `hybridDress` fails after `VTON_NO_WORKER_MS` (6 s)
with "engine asleep" instead of waiting out the 90-second render timeout and
blaming the render.
