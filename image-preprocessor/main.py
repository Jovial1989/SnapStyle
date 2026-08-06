import cv2
import numpy as np
from fastapi import FastAPI, File, UploadFile
from fastapi.responses import StreamingResponse
from io import BytesIO

app = FastAPI(title="Fashion Preprocessing Engine")

# LAZY session init: creating the ONNX session at import took >60s on a shared
# CPU — uvicorn never bound :8000 before Fly's proxy/health checks gave up and
# the idle policy stopped the machine. Bind instantly; load on first use.
_session = None
_remove = None

def get_session():
    # LAZY IMPORT too: `import rembg` triggers numba/pymatting JIT compilation —
    # minutes on a shared CPU. Importing at module level kept uvicorn from ever
    # binding :8000 (Fly health checks + proxy gave up → 502s).
    global _session, _remove
    if _session is None:
        from rembg import remove, new_session
        _remove = remove
        _session = new_session("u2netp")
    return _session

@app.get("/health")
def health():
    return {"ok": True}

def process_image(image_bytes: bytes) -> bytes:
    nparr = np.frombuffer(image_bytes, np.uint8)
    img = cv2.imdecode(nparr, cv2.IMREAD_COLOR)

    session = get_session()
    img_rgba = _remove(img, session=session)

    # DEFRINGE: rembg's raw alpha keeps a 1-2px ring of background color that
    # reads as a harsh white halo on dark UI. Erode the mask past the bleed,
    # then feather slightly — the subject blends into dark backdrops instead
    # of looking like a cardboard cutout. (Worth the extra milliseconds.)
    alpha = img_rgba[:, :, 3]
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3))
    alpha = cv2.erode(alpha, kernel, iterations=1)
    alpha = cv2.GaussianBlur(alpha, (5, 5), 0)
    img_rgba[:, :, 3] = alpha
    contours, _ = cv2.findContours(alpha, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

    if contours:
        x, y, w, h = cv2.boundingRect(np.concatenate(contours))
        cropped = img_rgba[y:y+h, x:x+w]
    else:
        cropped = img_rgba

    desired_size = 512
    h, w = cropped.shape[:2]
    scaling = desired_size / max(h, w)
    resized = cv2.resize(cropped, (int(w * scaling), int(h * scaling)), interpolation=cv2.INTER_AREA)

    h, w = resized.shape[:2]
    top = (desired_size - h) // 2
    bottom = desired_size - h - top
    left = (desired_size - w) // 2
    right = desired_size - w - left

    final_img = cv2.copyMakeBorder(resized, top, bottom, left, right, cv2.BORDER_CONSTANT, value=[0, 0, 0, 0])
    _, encoded_img = cv2.imencode(".png", final_img, [int(cv2.IMWRITE_PNG_COMPRESSION), 9])

    return encoded_img.tobytes()

@app.post("/preprocess")
def preprocess(file: UploadFile = File(...)):
    # Sync endpoint on purpose: FastAPI runs it in a threadpool, so the
    # CPU-bound rembg pass doesn't freeze the event loop (health checks
    # kept 502-ing while a single async request monopolized the loop).
    contents = file.file.read()
    processed_bytes = process_image(contents)
    return StreamingResponse(BytesIO(processed_bytes), media_type="image/png")
