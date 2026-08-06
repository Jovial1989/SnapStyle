# Looktok SAM 2 Engine — experimental mask worker (MediaPipe + SAM 2).
# Carries every ops lesson from the rembg worker's Fly.io deployment:
#   * models download at BUILD time, never at request time;
#   * heavy imports stay lazy in main.py (uvicorn binds instantly);
#   * bind 0.0.0.0 — Fly's proxy speaks IPv4 to the machine ("::" is V6ONLY
#     in Python and answers the proxy "connection refused").
FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libglib2.0-0 libgomp1 git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Bake model weights into the image.
RUN mkdir -p /models \
    && python -c "import urllib.request as u; \
u.urlretrieve('https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/latest/pose_landmarker_lite.task', '/models/pose_landmarker_lite.task'); \
u.urlretrieve('https://dl.fbaipublicfiles.com/segment_anything_2/072824/sam2_hiera_small.pt', '/models/sam2_hiera_small.pt')"

COPY main.py .

EXPOSE 8000
# Single worker: both models load once per process; scale via replicas.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
