"""Pull-based render worker: no inbound port, no public endpoint.

The GPU box holds NOTHING open. It connects OUT to Supabase, claims a row from
`vton_jobs`, pulls the input images from the signed URLs the row carries,
renders, uploads the result to Storage and marks the row done. Edge Functions
only ever enqueue and poll.

Why this shape rather than "expose the worker and let the EF POST to it":

  * Nothing to attack or to leak. A public render endpoint on a guessable host
    is somebody else's free GPU, and a shared secret in a header is one leaked
    log line away from being public.
  * The worker survives its own address changing. RunPod remaps ports on every
    pod restart; a pull worker does not care what its IP is.
  * A dead worker degrades into "jobs stay queued", not into 5xx storms in the
    EFs. Recovery is: start the worker again, the backlog drains.

Run it alongside the HTTP worker (they share the loaded pipeline only if run in
the same process — here they are separate, so budget VRAM for one each, or run
only this one in production).

    VTON_JOBS=1 python worker_jobs.py
"""
from __future__ import annotations

import io
import os
import time
import urllib.error
import urllib.request

from PIL import Image

from pipeline import DEVICE, HybridVTONPipeline

SUPABASE_URL = os.environ["SUPABASE_URL"].rstrip("/")
SERVICE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
OUT_BUCKET = os.getenv("VTON_OUT_BUCKET", "generations")
# Idle poll interval. Realtime would be instant but adds a websocket dependency
# for a worker whose whole point is having no moving parts; 0.4s costs one tiny
# RPC call per tick and keeps p50 dispatch under half a second.
IDLE_SLEEP = float(os.getenv("VTON_POLL_SEC", "0.4"))
MAX_STEPS = int(os.getenv("VTON_MAX_STEPS_PER_JOB", "4"))

engine = HybridVTONPipeline()


def _rpc(path: str, body: dict | None = None, method: str = "POST") -> object:
    import json
    req = urllib.request.Request(
        f"{SUPABASE_URL}{path}",
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers={
            "apikey": SERVICE_KEY,
            "Authorization": f"Bearer {SERVICE_KEY}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read().decode()
    return json.loads(raw) if raw else None


def _patch(job_id: str, fields: dict) -> None:
    import json
    req = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/vton_jobs?id=eq.{job_id}",
        data=json.dumps(fields).encode(), method="PATCH",
        headers={
            "apikey": SERVICE_KEY,
            "Authorization": f"Bearer {SERVICE_KEY}",
            "Content-Type": "application/json",
            "Prefer": "return=minimal",
        },
    )
    urllib.request.urlopen(req, timeout=30).read()


def _fetch_image(url: str) -> Image.Image:
    with urllib.request.urlopen(url, timeout=60) as r:
        return Image.open(io.BytesIO(r.read()))


def _upload(path: str, data: bytes) -> None:
    req = urllib.request.Request(
        f"{SUPABASE_URL}/storage/v1/object/{OUT_BUCKET}/{path}",
        data=data, method="POST",
        headers={
            "Authorization": f"Bearer {SERVICE_KEY}",
            "Content-Type": "image/jpeg",
            "x-upsert": "true",
        },
    )
    urllib.request.urlopen(req, timeout=120).read()


def handle(job: dict) -> None:
    jid = job["id"]
    person = _fetch_image(job["person_url"])
    steps = job.get("steps") or []
    if not steps:
        raise ValueError("job has no steps")

    # SEQUENTIAL DRESSING: each render's output is the next one's input. That is
    # how a full outfit is built from single-slot masks — top, then bottom, then
    # shoes — and it is why order matters. Each pass only ever repaints its own
    # slot, so an earlier garment cannot be undone by a later one.
    current = person
    for i, st in enumerate(steps[:MAX_STEPS]):
        garment = _fetch_image(st["url"])
        current = engine.generate(
            current, garment,
            kind=st.get("kind", "upper"),
            prompt_hint=st.get("hint", "the garment in the reference image"),
            seed=st.get("seed"),
        )
        print(f"[job {jid[:8]}] step {i + 1}/{len(steps)} {st.get('kind')}", flush=True)

    buf = io.BytesIO()
    current.convert("RGB").save(buf, "JPEG", quality=92)
    path = f"{job['user_id']}/vton/{jid}.jpg"
    _upload(path, buf.getvalue())
    _patch(jid, {"status": "done", "result_path": path, "finished_at": "now()"})
    print(f"[job {jid[:8]}] done → {path}", flush=True)


def main() -> None:
    print(f"[worker] polling on {DEVICE}, bucket={OUT_BUCKET}", flush=True)
    engine.warmup()
    print("[worker] warm", flush=True)
    while True:
        try:
            job = _rpc("/rest/v1/rpc/claim_vton_job")
        except urllib.error.URLError as e:
            print(f"[worker] claim failed ({e}); retrying", flush=True)
            time.sleep(2)
            continue
        # claim_vton_job returns the row, or a null/empty shape when idle.
        if not job or not isinstance(job, dict) or not job.get("id"):
            time.sleep(IDLE_SLEEP)
            continue
        t0 = time.time()
        try:
            handle(job)
            print(f"[worker] {job['id'][:8]} in {time.time() - t0:.1f}s", flush=True)
        except Exception as e:  # noqa: BLE001 — one bad job must not stop the loop
            msg = f"{type(e).__name__}: {e}"[:500]
            print(f"[worker] {job['id'][:8]} FAILED {msg}", flush=True)
            # Give up after the third attempt; claim_vton_job stops re-offering
            # it, so a permanently-bad job cannot spin the GPU forever.
            final = "failed" if job.get("attempts", 0) >= 3 else "queued"
            try:
                _patch(job["id"], {"status": final, "error": msg})
            except Exception:
                pass


if __name__ == "__main__":
    main()
