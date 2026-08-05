"""Pull-based render worker: no inbound port, no public endpoint.

The GPU box holds NOTHING open. It connects OUT to Supabase, claims a job from
the Storage queue, pulls the input images from the URLs the job carries,
renders, uploads the result and drops a completion marker. Edge Functions only
ever enqueue and poll.

Why this shape rather than "expose the worker and let the EF POST to it":

  * Nothing to attack or to leak. A public render endpoint on a guessable host
    is somebody else's free GPU, and a shared secret in a header is one leaked
    log line away from being public.
  * The worker survives its own address changing. RunPod remaps ports on every
    pod restart; a pull worker does not care what its IP is.
  * A dead worker degrades into "jobs stay queued", not into 5xx storms in the
    EFs. Recovery is: start the worker again, the backlog drains.

Claiming goes through claim_vton_job(), which holds FOR UPDATE SKIP LOCKED:
two workers can never take the same row, and a row left 'running' past its
lease is re-offered with its attempt count carried forward, so a worker killed
mid-render does not strand the job. NOTE the empty-queue shape — PostgREST
serialises the unset composite as a row of NULLs, not as null, so "no work"
must be detected by a missing id rather than by falsiness of the response.

    python worker_jobs.py
"""
from __future__ import annotations

import concurrent.futures as cf
import io
import json
import os
import threading
import time
import urllib.error
import urllib.request

from PIL import Image

from pipeline import DEVICE, HybridVTONPipeline

SUPABASE_URL = os.environ["SUPABASE_URL"].rstrip("/")
SERVICE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
BUCKET = os.getenv("VTON_BUCKET", "generations")
# Idle poll interval: one small list call per tick, p50 dispatch under ~0.5s.
IDLE_SLEEP = float(os.getenv("VTON_POLL_SEC", "0.2"))
MAX_STEPS = int(os.getenv("VTON_MAX_STEPS_PER_JOB", "4"))
# EXIT WHEN NOBODY IS ASKING. The GPU costs $0.69/h whether it renders or waits,
# and a render takes under three seconds — at development volume the card idles
# through more than 99% of what we pay for. Exiting on a quiet queue lets
# autostop.sh stop the pod, which is the difference between ~$40 and ~$500 a
# month. 0 disables it, which is what a pod serving real traffic wants.
IDLE_EXIT = float(os.getenv("VTON_IDLE_EXIT_SEC", "0"))

engine = HybridVTONPipeline()

_swapper = None
_swapper_lock = threading.Lock()


def face_swapper():
    """Built on first use. Most jobs never swap — the base is prepared once and
    cached — so three mediapipe solutions do not need to load in every worker."""
    global _swapper
    if _swapper is None:
        with _swapper_lock:
            if _swapper is None:
                from faceswap import FaceSwapPipeline
                _swapper = FaceSwapPipeline()
    return _swapper


_AUTH = {
    "apikey": SERVICE_KEY,
    "Authorization": f"Bearer {SERVICE_KEY}",
}


def _req(method: str, path: str, body: bytes | None = None,
         ctype: str = "application/json", extra: dict | None = None) -> bytes:
    req = urllib.request.Request(
        f"{SUPABASE_URL}{path}", data=body, method=method,
        headers={**_AUTH, "Content-Type": ctype, **(extra or {})},
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def claim() -> dict | None:
    """Atomically take the oldest queued job, or None when idle."""
    raw = _req("POST", "/rest/v1/rpc/claim_vton_job", b"{}")
    job = json.loads(raw or "null")
    # A row of NULLs is how an empty queue comes back — not a job.
    if not isinstance(job, dict) or not job.get("id"):
        return None
    return job


def patch(job_id: str, fields: dict) -> None:
    _req("PATCH", f"/rest/v1/vton_jobs?id=eq.{job_id}", json.dumps(fields).encode(),
         extra={"Prefer": "return=minimal"})


def _fetch_image(url: str) -> Image.Image:
    with urllib.request.urlopen(url, timeout=60) as r:
        return Image.open(io.BytesIO(r.read()))


def render(job: dict) -> str:
    steps = (job.get("steps") or [])[:MAX_STEPS]
    face_url = job.get("face_url")
    # A job with neither a garment nor a face has nothing to do; one with a face
    # and no garments is the "prepare this user's base" job, which is how the
    # swap gets done and cached once instead of on every render.
    if not steps and not face_url:
        raise ValueError("job has no steps and no face_url")

    # PREFETCH EVERY INPUT AT ONCE. Downloading each garment just before its own
    # render put N-1 round trips on the critical path, and this box is a
    # continent away from Storage — 200-300ms each. The GPU accounts for ~1.5s of
    # a ~5s job, so the win here is not the card going faster, it is the waiting
    # overlapping. (Rendering itself stays serial: one stream already saturates
    # the GPU, so concurrent diffusions would only trade order for nothing.)
    urls = ([job["person_url"]] + ([face_url] if face_url else [])
            + [st["url"] for st in steps])
    with cf.ThreadPoolExecutor(min(8, len(urls))) as ex:
        imgs = list(ex.map(_fetch_image, urls))
    current = imgs[0]
    selfie = imgs[1] if face_url else None
    garments = imgs[2:] if face_url else imgs[1:]

    # IDENTITY FIRST, THEN CLOTHES. The order is forced: the swap needs the face
    # unobstructed and the dressing passes never touch the face, so doing it the
    # other way round would only risk a garment's collar crossing the oval. The
    # swap is CPU-only (~0.15s) — it costs nothing next to a diffusion step, and
    # it is what lets the rest of the pipeline assume an ideal body.
    if selfie is not None:
        t = time.time()
        res = face_swapper().swap(current, selfie)
        current = res.image
        # Report rather than gate. A poor alignment is a caller problem — the
        # selfie was not frontal — and the caller has the user to ask; failing the
        # job here would spend the render and then throw it away.
        print(f"  face rms={res.align_rms} up={res.upsampled}x "
              f"trust={res.trustworthy} in {time.time() - t:.2f}s", flush=True)

    # SEQUENTIAL DRESSING: each render's output is the next one's input. That is
    # how a full outfit is built from single-slot masks — top, then bottom, then
    # shoes — and why order matters. Each pass repaints only its own slot, so an
    # earlier garment cannot be undone by a later one.
    for i, (st, garment) in enumerate(zip(steps, garments)):
        # NO DEFAULT SLOT. This used to fall back to "upper", and a step that
        # arrived without a usable `kind` was silently painted onto the torso —
        # a pair of jeans came back as a denim jacket, trousers untouched, in a
        # test that had misnamed the field. That is exactly the signature of
        # "it dresses me in random things", and it is indistinguishable from a
        # bad render unless the job fails and says so. A wrong slot is a caller
        # bug; guessing hides it, and the guess costs a GPU render either way.
        kind = st.get("kind")
        if kind not in ("upper", "lower", "full", "shoes"):
            raise ValueError(f"step {i + 1} has no valid kind: {kind!r}")
        current = engine.generate(
            current, garment,
            kind=kind,
            prompt_hint=st.get("hint", "the garment in the reference image"),
            # DETERMINISTIC BY DEFAULT. The app sends no seed, so every tap was a
            # lottery — and the diag lines exposed it: the verified-clean renders
            # were all seed=7 while the phone's waist ridge came from random seeds
            # landing badly in the 90px hem/waistband overlap. Same outfit must
            # give the same picture: it makes quality reproducible, bugs
            # re-renderable, and the cache honest. A caller can still pass its own.
            seed=st.get("seed", 7),
            ip_scale=st.get("ip_scale"),
        )
        print(f"  step {i + 1}/{len(steps)} {kind}", flush=True)

    buf = io.BytesIO()
    current.convert("RGB").save(buf, "JPEG", quality=92)
    path = f"{job['user_id']}/vton/{job['id']}.jpg"
    _req("POST", f"/storage/v1/object/{BUCKET}/{path}", buf.getvalue(),
         ctype="image/jpeg", extra={"x-upsert": "true"})
    return path


def main() -> None:
    print(f"[worker] polling vton_jobs on {DEVICE}", flush=True)
    engine.warmup()
    print("[worker] warm", flush=True)
    if IDLE_EXIT:
        print(f"[worker] will exit after {IDLE_EXIT:.0f}s idle", flush=True)
    last_job = time.time()
    while True:
        try:
            job = claim()
        except Exception as e:  # noqa: BLE001 — a transient claim must not stop the loop
            print(f"[worker] claim failed ({e}); retrying", flush=True)
            time.sleep(2)
            continue
        if not job:
            # A claim that FAILS must not count as idle — a Supabase outage would
            # otherwise shut the pod down and look like an idle timeout.
            if IDLE_EXIT and time.time() - last_job > IDLE_EXIT:
                print(f"[worker] idle {IDLE_EXIT:.0f}s, exiting", flush=True)
                return
            time.sleep(IDLE_SLEEP)
            continue

        last_job = time.time()
        jid = job["id"]
        t0 = time.time()
        try:
            path = render(job)
            patch(jid, {"status": "done", "result_path": path,
                        "finished_at": "now()"})
            print(f"[worker] {jid[:8]} done in {time.time() - t0:.1f}s → {path}", flush=True)
        except Exception as e:  # noqa: BLE001 — one bad job must not stop the loop
            msg = f"{type(e).__name__}: {e}"[:400]
            print(f"[worker] {jid[:8]} FAILED {msg}", flush=True)
            # Back to 'queued' so claim_vton_job can re-offer it; give up at 3
            # attempts so a permanently-bad job cannot spin the GPU forever.
            final = "failed" if job.get("attempts", 0) >= 3 else "queued"
            try:
                patch(jid, {"status": final, "error": msg})
            except Exception:
                pass
        # Count idle from when the work ENDED, not when it started.
        last_job = time.time()


if __name__ == "__main__":
    main()
