# Fashion Preprocessing Engine — rembg(u2netp) + OpenCV behind FastAPI.
# Build:  docker build -t fashion-preprocessor .
# Run:    docker run -p 8000:8000 fashion-preprocessor
FROM python:3.11-slim

# opencv-headless still needs libgl-adjacent basics on slim images.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libglib2.0-0 libgomp1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Kill numba entirely: rembg imports pymatting, whose JIT compilation takes
# 8+ minutes on a shared CPU and the cache is builder-CPU-specific. We never
# use alpha matting (u2netp inference is pure onnxruntime), so JIT-off is free.
ENV NUMBA_DISABLE_JIT=1
# Bake the u2netp model download into the image.
RUN python -c "\
from rembg import remove, new_session; import numpy as np; \
s = new_session('u2netp'); \
remove(np.zeros((64, 64, 3), dtype=np.uint8), session=s); \
print('model + numba cache baked')"

COPY main.py .

EXPOSE 8000
# Single worker: the ONNX session is loaded once per process; scale via replicas.
# Fly proxy connects to the machine over IPv4; asyncio binds "::" V6ONLY,
# which refuses the proxy — 0.0.0.0 is the correct bind here.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
