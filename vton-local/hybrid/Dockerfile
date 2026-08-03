# Hybrid VTON worker — CUDA image for RunPod / Vast.ai (RTX 3090/4090, 24 GB).
#
# Base: the OFFICIAL PyTorch image, not nvidia/cuda + pip install torch. It
# ships torch built against its own CUDA runtime, so there is no cu12x-vs-driver
# roulette at container start. `-runtime` (not `-devel`) omits nvcc and headers:
# ~4 GB smaller, and nothing here compiles CUDA kernels — xformers installs as
# a prebuilt wheel.
FROM pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime

# libGL/libglib: mediapipe links against them even though we use the headless
# OpenCV build. Without these the import dies with a bare "libGL.so.1: cannot
# open shared object file".
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    # One cache root for every HF library, and a path we can mount a RunPod
    # network volume over to share weights across pods.
    HF_HOME=/opt/hf \
    # Compiled-graph cache: torch.compile and SDPA kernel selection persist
    # here, so pod #2 skips warmup work pod #1 already did.
    TORCHINDUCTOR_CACHE_DIR=/opt/hf/inductor

WORKDIR /app

# Dependencies first, in their own layer: source edits then rebuild in seconds
# instead of re-resolving 2 GB of wheels.
COPY requirements-cuda.txt .
RUN pip install --no-cache-dir -r requirements-cuda.txt

# Which weights this image serves. Change with --build-arg VTON_BASE=sdxl.
ARG VTON_BASE=sd15
ENV VTON_BASE=${VTON_BASE}

# Bake the weights in. Costs image size (~7 GB sd15 / ~16 GB sdxl) and buys a
# cold start measured in seconds instead of minutes — the right trade when the
# GPU bills by the second. Skip with --build-arg PREFETCH=0 if you mount a
# network volume at /opt/hf instead.
ARG PREFETCH=1
COPY prefetch.py .
RUN if [ "$PREFETCH" = "1" ]; then python prefetch.py; fi

COPY pipeline.py main.py ./

# Defaults tuned for a 24 GB card: weights stay resident (offload is a
# throughput tax when everything already fits) and xformers is on.
ENV VTON_OFFLOAD=0 \
    VTON_XFORMERS=1 \
    VTON_STEPS=28 \
    PORT=8000

EXPOSE 8000

# Load the pipeline at startup, not on the first request — otherwise the first
# user eats the 20-40 s VRAM load and RunPod's health check may kill the pod
# before it answers.
ENV VTON_WARMUP=1

# One worker per GPU. Uvicorn workers do NOT share VRAM: two workers means two
# full copies of the model. Scale by adding pods, never by --workers.
CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port ${PORT} --workers 1 --timeout-keep-alive 75"]
