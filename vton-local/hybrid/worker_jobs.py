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

The queue is Storage objects rather than a table because creating the table
needs DDL that the operator's tooling could not apply. Claiming is a MOVE:
whoever moves the object out of the queue prefix owns the job, and a move that
fails means somebody else got there first. That is weaker than FOR UPDATE SKIP
LOCKED — it is not atomic against a concurrent reader — but with one worker
there is no race to lose. Swap in `claim_vton_job()` when the table exists.

    python worker_jobs.py
"""
from __future__ import annotations

import io
import json
import os
import time
import urllib.error
import urllib.request

from PIL import Image

from pipeline import DEVICE, HybridVTONPipeline

SUPABASE_URL = os.environ["SUPABASE_URL"].rstrip("/")
SERVICE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
BUCKET = os.getenv("VTON_BUCKET", "generations")
QUEUE, CLAIMED, DONE = "_vton/queue", "_vton/claimed", "_vton/done"
# Idle poll interval: one small list call per tick, p50 dispatch under ~0.5s.
IDLE_SLEEP = float(os.getenv("VTON_POLL_SEC", "0.4"))
MAX_STEPS = int(os.getenv("VTON_MAX_STEPS_PER_JOB", "4"))

engine = HybridVTONPipeline()

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


def list_queue() -> list[dict]:
    """Oldest first — a queue that serves newest-first starves under load."""
    body = json.dumps({
        "prefix": QUEUE + "/", "limit": 20,
        "sortBy": {"column": "created_at", "order": "asc"},
    }).encode()
    raw = _req("POST", f"/storage/v1/object/list/{BUCKET}", body)
    return [o for o in json.loads(raw or "[]") if o.get("name", "").endswith(".json")]


def claim(name: str) -> dict | None:
    """Take ownership by MOVING the object out of the queue prefix.
    A failed move means another worker already owns it — skip, do not render."""
    src, dst = f"{QUEUE}/{name}", f"{CLAIMED}/{name}"
    payload = json.dumps({"bucketId": BUCKET, "sourceKey": src, "destinationKey": dst}).encode()
    try:
        _req("POST", "/storage/v1/object/move", payload)
    except urllib.error.HTTPError:
        return None
    raw = _req("GET", f"/storage/v1/object/{BUCKET}/{dst}")
    return json.loads(raw)


def finish(job_id: str, name: str, **fields: object) -> None:
    _req("POST", f"/storage/v1/object/{BUCKET}/{DONE}/{job_id}.json",
         json.dumps(fields).encode(), extra={"x-upsert": "true"})
    try:
        _req("DELETE", f"/storage/v1/object/{BUCKET}/{CLAIMED}/{name}")
    except urllib.error.HTTPError:
        pass


def _fetch_image(url: str) -> Image.Image:
    with urllib.request.urlopen(url, timeout=60) as r:
        return Image.open(io.BytesIO(r.read()))


def render(job: dict) -> str:
    person = _fetch_image(job["person_url"])
    steps = job.get("steps") or []
    if not steps:
        raise ValueError("job has no steps")

    # SEQUENTIAL DRESSING: each render's output is the next one's input. That is
    # how a full outfit is built from single-slot masks — top, then bottom, then
    # shoes — and why order matters. Each pass repaints only its own slot, so an
    # earlier garment cannot be undone by a later one.
    current = person
    for i, st in enumerate(steps[:MAX_STEPS]):
        current = engine.generate(
            current, _fetch_image(st["url"]),
            kind=st.get("kind", "upper"),
            prompt_hint=st.get("hint", "the garment in the reference image"),
            seed=st.get("seed"),
        )
        print(f"  step {i + 1}/{len(steps)} {st.get('kind')}", flush=True)

    buf = io.BytesIO()
    current.convert("RGB").save(buf, "JPEG", quality=92)
    path = f"{job['user_id']}/vton/{job['id']}.jpg"
    _req("POST", f"/storage/v1/object/{BUCKET}/{path}", buf.getvalue(),
         ctype="image/jpeg", extra={"x-upsert": "true"})
    return path


def main() -> None:
    print(f"[worker] polling {BUCKET}/{QUEUE} on {DEVICE}", flush=True)
    engine.warmup()
    print("[worker] warm", flush=True)
    while True:
        try:
            pending = list_queue()
        except Exception as e:  # noqa: BLE001 — a transient list must not stop the loop
            print(f"[worker] list failed ({e}); retrying", flush=True)
            time.sleep(2)
            continue
        if not pending:
            time.sleep(IDLE_SLEEP)
            continue

        for obj in pending:
            name = obj["name"].rsplit("/", 1)[-1]
            job = claim(name)
            if not job:
                continue
            jid = job.get("id", name[:-5])
            t0 = time.time()
            try:
                path = render(job)
                finish(jid, name, result_path=path)
                print(f"[worker] {jid[:8]} done in {time.time() - t0:.1f}s → {path}", flush=True)
            except Exception as e:  # noqa: BLE001 — one bad job must not stop the loop
                msg = f"{type(e).__name__}: {e}"[:400]
                print(f"[worker] {jid[:8]} FAILED {msg}", flush=True)
                try:
                    finish(jid, name, error=msg)
                except Exception:
                    pass


if __name__ == "__main__":
    main()
