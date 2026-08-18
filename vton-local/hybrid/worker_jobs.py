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
import base64
import threading
import time
import urllib.error
import urllib.request

import numpy as np
from PIL import Image

import cv2

from pipeline import (DEVICE, HybridVTONPipeline, _flatlay_silhouette,
                      _garment_mask)

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

# FASHN VTON 1.5 — a TRAINED try-on model, next to our warp stack rather than
# instead of it. Apache-2.0 code and weights, 972M MMDiT, and crucially it
# generates in PIXEL space (12x12 patches, 576x864): the wavy-stripe defect this
# engine spent a day on was a latent-resolution limit, and a model with no VAE
# does not have it. Measured on our own cases: stripes come back with a real
# crew collar and straight lines, black jeans clean, blue jeans a draw; 10-11s
# and 3.9 GB VRAM (peak 14.4 GB with our stack loaded beside it, on a 24 GB card).
#
# WHY IT DOES NOT REPLACE THE STACK. It regenerates the WHOLE frame, so chaining
# passes destroys the previous garment — measured: dressing the bottoms then the
# tops returned white shorts with black shins. And it has three categories only,
# no footwear or accessories. So each slot renders from the SAME clean base and
# OUR zone masks decide what is taken, which is exactly what the unified-batch
# composite below already does for our own layers. Shoes stay on the warp.
FASHN_ON = os.getenv("VTON_FASHN", "0") == "1"
FASHN_KINDS = {
    "upper": "tops", "lower": "bottoms", "full": "one-pieces",
}
_fashn = None
_fashn_lock = threading.Lock()


def fashn():
    global _fashn
    if _fashn is None:
        with _fashn_lock:
            if _fashn is None:
                from fashn_vton import TryOnPipeline
                _fashn = TryOnPipeline(
                    weights_dir=os.getenv("FASHN_WEIGHTS", "/root/fashn_weights"))
    return _fashn

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

    # THE JOB'S GEOMETRY COMES FROM THE CLEAN BASE, ONCE. Re-reading pose per
    # step computed each slot's mask on a different pixel state, so the upper
    # and lower boundaries did not have to agree — the waist-seam class. The
    # person cannot move between steps of one job. (Read AFTER the face swap
    # would be wrong the other way: the swap only touches the face oval, which
    # no garment mask depends on, so the clean base is the right x0 either way.)
    base_pose = engine.reader.read(
        np.array(current.convert("RGB"))[:, :, ::-1].copy())

    # IDENTITY FIRST, THEN CLOTHES. The order is forced: the swap needs the face
    # unobstructed and the dressing passes never touch the face, so doing it the
    # other way round would only risk a garment's collar crossing the oval. The
    # swap is CPU-only (~0.15s) — it costs nothing next to a diffusion step, and
    # it is what lets the rest of the pipeline assume an ideal body.
    if selfie is not None:
        t = time.time()
        # SWAP ON A DOUBLED CANVAS, THEN COME BACK DOWN. Measured on the
        # A-pose library: a full-body 848x1264 frame puts only 53-60 px between
        # the model's eyes, and the migration's own note says a target under
        # ~90 px reads as a smudge whatever the code does. Nothing about the
        # base needs to change — the face is being REPLACED, so what matters is
        # having room to place the selfie's pixels. At 2x the target measures
        # 111 px and the same transfer went from unusable to trustworthy
        # (rms 0.009, upsampled 0.66), and the downscale afterwards costs
        # nothing because the render works at 512x768 internally anyway.
        big = current.resize((current.width * 2, current.height * 2),
                             Image.LANCZOS)
        res = face_swapper().swap(big, selfie)
        current = res.image.resize((big.width // 2, big.height // 2),
                                   Image.LANCZOS)
        # Report rather than gate. A poor alignment is a caller problem — the
        # selfie was not frontal — and the caller has the user to ask; failing the
        # job here would spend the render and then throw it away.
        print(f"  face rms={res.align_rms} up={res.upsampled}x "
              f"trust={res.trustworthy} in {time.time() - t:.2f}s", flush=True)

    # LATENT STREAMING. If the job carries a stream_key, every few denoise steps a
    # TAESD preview goes out on a Realtime broadcast channel the client is already
    # subscribed to. Fire-and-forget on a thread: a preview that arrives late or not
    # at all costs nothing, a preview that BLOCKS the GPU loop costs everyone.
    stream_key = None
    if steps and isinstance(steps[0], dict):
        raw_key = steps[0].get("stream_key")
        if isinstance(raw_key, str) and raw_key.replace("-", "").isalnum() \
                and 8 <= len(raw_key) <= 64:
            stream_key = raw_key

    sent = {"n": 0, "err": 0}

    def _broadcast(layer_i, total, step_i, jpg: bytes):
        body = json.dumps({"messages": [{
            "topic": f"vton:{stream_key}", "event": "preview",
            "payload": {"layer": layer_i, "layers": total, "step": step_i,
                        "jpg": base64.b64encode(jpg).decode()},
        }]}).encode()
        try:
            _req("POST", "/realtime/v1/api/broadcast", body)
            sent["n"] += 1
        except Exception as e:
            sent["err"] += 1
            if sent["err"] == 1:
                print(f"  preview broadcast failed: {e}", flush=True)

    # UNIFIED BATCH FROM x0, NOT A CHAIN. Every layer is rendered against the
    # SAME clean base with its own mask, and the layers are composited once at the
    # end in the order the Edge Function sorted them. Until now this loop did
    # `current = generate(current, …)`, so layer 2 denoised layer 1's output — a
    # Markov chain, with all three of its costs:
    #
    #   * VAE cascade: the base was encoded and decoded once PER LAYER IN SERIES,
    #     and that autoencoder is lossy, so high-frequency detail (skin, sharp
    #     shadow edges) degraded with every garment added;
    #   * Canny contamination: each layer's conditioning was read from the previous
    #     RESULT, so an artefact became structural ground truth for the next layer
    #     and got drawn around rather than removed;
    #   * error compounding: a bad layer was amplified by every layer after it.
    #
    # The cost of independence is that garments cannot see each other. At the one
    # place that matters — the waist — the Z order still puts the top's hem over
    # the waistband, which is exactly what the sequential ordering bought.
    # (image, coverage, gate_on_change). The third field is what tells the
    # composite whose outline wins: our own layers are deltas on an untouched
    # body, so gating on "did this pixel change" is exactly right; a FASHN layer
    # regenerates the person too, so its background pixels must be allowed to
    # overwrite the base — that is how the sliver of old tank at the flank and
    # the pale gap at the waist disappear.
    layers: list[tuple[np.ndarray, np.ndarray, bool]] = []
    # One-element box so the lower layer can tell the upper layer where the
    # waistband landed; Z order guarantees the lower runs first.
    waist_top: list[int | None] = [None]
    for i, (st, garment) in enumerate(zip(steps, garments)):
        # NO DEFAULT SLOT. A step without a usable `kind` used to be painted onto
        # the torso — jeans came back as a denim jacket in a test that had misnamed
        # the field, which is indistinguishable from a bad render unless the job
        # fails and says so.
        kind = st.get("kind")
        if kind not in ("upper", "lower", "full", "shoes"):
            raise ValueError(f"step {i + 1} has no valid kind: {kind!r}")
        # CONDITIONING WEIGHTS TRAVEL WITH THE STEP. A printed tee and a plain one
        # want different balances — obey the Canny map harder, let the adapter's
        # global colour lead less — and until now those were literals inside the
        # engine, so trying a balance meant editing the pod. Omitted keys fall back
        # to the engine's env defaults, so an unchanged job renders unchanged.
        fashn_cat = FASHN_KINDS.get(kind) if FASHN_ON else None
        if fashn_cat:
            t_f = time.time()
            base_bgr = np.array(current.convert("RGB"))[:, :, ::-1]
            h_b, w_b = base_bgr.shape[:2]
            # 14 STEPS, NOT 30. Swept on the yellow tee at a fixed prompt:
            # 30 → 10.3s, 20 → 7.7s, 14 → 5.9s, 8 → 4.2s, and the crops are
            # indistinguishable down to 14 (at 8 the fabric goes soft). The
            # fixed 2.2s underneath is DWPose and the parser on CPU — the CUDA
            # build of onnxruntime wants a newer CUDA 12 than torch ships, so
            # that stays for now and this is where the time actually was.
            res = fashn()(person_image=current.convert("RGB"),
                          garment_image=garment.convert("RGB"),
                          category=fashn_cat,
                          num_timesteps=int(os.getenv("VTON_FASHN_STEPS", "14")))
            out_img = res.images[0] if hasattr(res, "images") else res
            full = cv2.resize(
                np.array(out_img.convert("RGB"))[:, :, ::-1], (w_b, h_b),
                interpolation=cv2.INTER_LANCZOS4)
            # The zone is ours, the pixels are FASHN's — ALL of them inside it.
            #
            # Taking only the pixels that CHANGED (which is right for our own
            # layers, where the body is untouched) left two seams on the phone: a
            # white strip down the flank and a pale band at the waist. FASHN
            # regenerates the person as well as the garment, so its body is not
            # pixel-identical to the base — a little narrower here, wider there.
            # Where it is narrower the base's own tank survived as a sliver;
            # where the zones met, neither layer claimed the gap.
            #
            # So inside the zone the outline becomes FASHN's outline: its
            # background pixels overwrite the base's sliver, and the zone is
            # dilated past the body so a wider render has somewhere to land. The
            # 15 px feather hides the step where FASHN's silhouette and the
            # base's disagree at the band's edge.
            zone = _garment_mask(base_pose, kind,
                                 np.array(garment)[:, :, ::-1], base_bgr)
            # WHERE THE TROUSERS ACTUALLY START, from the render that drew them.
            # Our band begins at hip less 6% — well above any waistband — so
            # clipping the shirt there would cut it off mid-back. The waistband's
            # real row is the topmost one FASHN changed inside the lower zone.
            if kind == "lower":
                diff_rows = np.flatnonzero(
                    (((np.abs(full.astype(np.float32)
                              - base_bgr.astype(np.float32)).max(axis=2) > 12)
                      & (zone > 20)).sum(axis=1)) > 24)
                if diff_rows.size:
                    waist_top[0] = int(diff_rows[0])
            grow = max(9, int(round(h_b * 0.012))) | 1
            zone = cv2.dilate(zone, np.ones((grow, grow), np.uint8))
            # AND THE WAIST BELONGS TO WHOEVER DRESSES THE LEGS. FASHN's tops
            # render RECOLOURS the bottoms it was not asked about — the base's
            # grey shorts came back white — and with its outline winning inside
            # the zone, those pixels landed over the jeans as a pale band across
            # the waist (seen on the phone). The upper's claim therefore stops
            # just below the hip line; everything under it is the lower slot's,
            # or the base's if nothing dresses it.
            if kind == "upper":
                pts_b = base_pose.pts
                ys_b = [q[1] for q in pts_b if q]
                span_b = max(1, (max(ys_b) - min(ys_b)) if ys_b else h_b)
                # Prefer the waistband the trousers' own render put down, and
                # let the shirt overlap it by 3% so the hem sits ON the band
                # rather than beside it. Falling back to the hip line keeps a
                # top-only job sane, where nothing else claims the waist.
                if waist_top[0] is not None:
                    cut_y = int(waist_top[0] + span_b * 0.03)
                elif True:
                    # NOBODY IS DRESSING THE LEGS, so the base's own waistband is
                    # the boundary — and on the canonical base it is a DARK
                    # elastic band, which is a measurement rather than a guess.
                    # This matters because FASHN recolours those shorts white,
                    # and every pixel the shirt's zone takes below the real hem
                    # is that white: the sliver survived a fixed offset, a
                    # palette veto and a hard edge, because all three were
                    # looking below the line instead of finding the line.
                    hips_b = [pts_b[j][1] for j in (8, 11) if pts_b[j]]
                    hip_y = int(max(hips_b)) if hips_b else int(h_b * 0.55)
                    lo = max(0, int(hip_y - span_b * 0.08))
                    hi = min(h_b - 1, int(hip_y + span_b * 0.10))
                    sil_b = base_pose.silhouette > 0
                    rows = []
                    for y in range(lo, hi):
                        on = sil_b[y]
                        if int(on.sum()) > 40:
                            rows.append((float(base_bgr[y][on].mean()), y))
                    cut_y = None
                    if rows:
                        med = float(np.median([r[0] for r in rows]))
                        dark = [y for lum, y in rows if lum < med - 25]
                        if dark:
                            cut_y = int(min(dark))
                            print(f"  base waistband found at y={cut_y}",
                                  flush=True)
                    if cut_y is None:
                        cut_y = int(hip_y + span_b * float(
                            os.getenv("VTON_FASHN_UPPER_CLIP", "0.04")))
                else:
                    hips_b = [pts_b[j][1] for j in (8, 11) if pts_b[j]]
                    cut_y = int((max(hips_b) if hips_b else h_b)
                                + span_b * float(
                                    os.getenv("VTON_FASHN_UPPER_CLIP", "0.04")))
                if 0 < cut_y < h_b:
                    zone[cut_y:] = 0
                    print(f"  upper zone clipped at y={cut_y}"
                          f"{' (waistband)' if waist_top[0] is not None else ''}"
                          , flush=True)
            # A HARD BOTTOM EDGE. The feather is what let the pale sliver in:
            # FASHN's tops render puts WHITE where the base wears grey shorts,
            # and a 15 px ramp across the hem mixes that white into the base.
            # Sides and shoulders still need the soft edge (that is where the
            # body outlines disagree), so the blur is undone on the last rows —
            # a clean cut at the hem line, nothing to bleed.
            hard = None
            if kind == "upper":
                hard = max(0, cut_y - 2) if 0 < cut_y < h_b else None
            zone_soft = cv2.GaussianBlur(zone, (15, 15), 0)
            if hard is not None:
                zone_soft[hard:] = zone[hard:]
            layers.append((full, zone_soft, False))
            print(f"  step {i + 1}/{len(steps)} {kind} via fashn/{fashn_cat} "
                  f"in {time.time() - t_f:.1f}s", flush=True)
            continue
        img, cover = engine.generate(
            current, garment,
            kind=kind,
            prompt_hint=st.get("hint", "the garment in the reference image"),
            seed=st.get("seed", 7),
            ip_scale=st.get("ip_scale"),
            pose_scale=st.get("pose_scale"),
            canny_scale=st.get("canny_scale"),
            core_protect=st.get("core_protect"),
            pose=base_pose,
            return_mask=True,
            tuck=bool(st.get("tuck")),
            on_preview=(None if stream_key is None else
                        (lambda step_i, jpg, _i=i, _n=len(steps):
                         threading.Thread(target=_broadcast,
                                          args=(_i, _n, step_i, jpg),
                                          daemon=True).start())),
        )
        print(f"  cond {kind}: ip={st.get('ip_scale') or 'env'} "
              f"canny={st.get('canny_scale') or 'env'} "
              f"core={st.get('core_protect') or 'env'} seed={st.get('seed', 7)}",
              flush=True)
        layers.append((np.array(img.convert("RGB"))[:, :, ::-1].copy(), cover, True))
        print(f"  step {i + 1}/{len(steps)} {kind}"
              + (f" previews={sent['n']}" if stream_key else ""), flush=True)

    if layers:
        # EACH LAYER CONTRIBUTES ITS DELTA FROM THE BASE, NOT ITS WHOLE FRAME.
        #
        # Every layer is rendered against the same clean x0, so OUTSIDE its own mask a
        # layer's frame is byte-for-byte the base — including the base's grey basics.
        # Blending the frames (img*a + out*(1-a)) therefore drags those grey pixels
        # back over what earlier layers painted wherever a < 1, and a < 1 is exactly
        # the feathered rim of every mask. That is the grey haze under the tee's hem
        # and at the waist: not the base showing through a gap, but the top layer
        # actively painting the base over the trousers across 29 px of feather. It
        # read as a soft dissolve, and when the hem was made crisp it became a hard
        # grey bar — same cause, two symptoms, and I spent a pass blaming the mask.
        #
        # The fix is NOT to add deltas instead — measured, and it is worse in a way
        # worth recording: at the waist the tee's hem and the trousers' waistband both
        # paint, so two deltas over one pixel sum to (yellow - grey) + (denim - grey)
        # and the belt line came back gold and metallic. Blending is right; the alpha
        # was wrong. So the alpha is corrected to what it claimed to be — where the
        # layer ACTUALLY changed something — and the blend is left alone. In an
        # overlap the later layer still wins outright, which is what Z order means.
        base_f = np.array(current.convert("RGB"))[:, :, ::-1].astype(np.float32)
        out = base_f.copy()
        for img, cover, gate in layers:
            f = img.astype(np.float32)
            a = cover.astype(np.float32) / 255.0
            if gate:
                a = a * (np.abs(f - base_f).max(axis=2) > 6.0)
            a = a[:, :, None]
            out = f * a + out * (1.0 - a)
        current = Image.fromarray(
            np.clip(out, 0, 255).astype(np.uint8)[:, :, ::-1])

    # OSD BURNED INTO THE UPLOADED FRAME, on demand. Normally the telemetry goes only
    # to the dump, because a watermark on somebody's try-on is worse than the bug it
    # diagnoses. But "the fix did not apply" and "the fix applied and did not help" look
    # identical from a phone, and that ambiguity has cost more than one cycle today. With
    # VTON_OSD_BURN=1 the frame states what produced it, so the question stops being a
    # matter of opinion. Turn it off before anything goes near a demo.
    if os.getenv("VTON_OSD_BURN") == "1":
        from pipeline import (CANNY_SCALE, DUAL_CYL, SHOE_SEMANTIC, STEPS as ENGINE_STEPS,
                              TPS_WARP, WARP_STRENGTH, apply_diagnostic_osd)
        frame = np.array(current.convert("RGB"))[:, :, ::-1].copy()
        frame = apply_diagnostic_osd(frame, {
            "TPS": "ON" if TPS_WARP else "OFF",
            "CYL2": "ON" if DUAL_CYL else "OFF",
            "SHOE": "SEM" if SHOE_SEMANTIC else "WARP",
            "SHADING": os.getenv("VTON_SHADING", "2.0"),
            "STR": f"{WARP_STRENGTH}", "CANNY": f"{CANNY_SCALE}",
            # LAYERS, not sampler steps. Calling this "STEPS" read as a 3-step diffusion
            # pass and sent us hunting a debug flag that never existed: it is the number
            # of GARMENT layers in the job — top, bottom, shoes. The sampler's own count
            # is beside it now, from the engine's constant, so the two can never be
            # confused again. A label that can be misread will be.
            "LAYERS": str(len(steps)), "NSTEP": os.getenv("VTON_STEPS", str(ENGINE_STEPS)),
        })
        current = Image.fromarray(frame[:, :, ::-1])

    buf = io.BytesIO()
    current.convert("RGB").save(buf, "JPEG", quality=92)
    path = f"{job['user_id']}/vton/{job['id']}.jpg"
    _req("POST", f"/storage/v1/object/{BUCKET}/{path}", buf.getvalue(),
         ctype="image/jpeg", extra={"x-upsert": "true"})

    # A SWAP-ONLY JOB IS A BASE BEING PREPARED, so it has to land where the
    # renderer looks. Without this the swapped canvas would sit in the render
    # bucket as a one-off image and every dressing job would either re-run the
    # swap or quietly keep using the mid-stride photograph — the exact thing the
    # A-pose library exists to replace. PNG, because this is a source asset that
    # will be re-encoded by every render that starts from it.
    if not steps and face_url:
        # THE GATE LIVES WHERE THE MEASUREMENT IS. The endpoint can only ask the
        # client how big the face was; this is the only place that can check.
        # Below the doubled target's own face size the transfer upsamples and
        # the result is a smudge — measured at 34 px against a 111 px target,
        # rms fine (0.038) but upsampled 1.62x — so a too-small selfie must FAIL
        # with a reason the user can act on, not quietly become their avatar.
        adv = {}
        try:
            adv = face_swapper().advise_base(selfie)
        except Exception as e:
            print(f"  advise failed: {e}", flush=True)
        io_px = adv.get("interocular_px")
        if isinstance(io_px, int):
            _req("PATCH", f"/rest/v1/style_profiles?user_id=eq.{job['user_id']}",
                 json.dumps({"face_interocular": io_px}).encode(),
                 ctype="application/json", extra={"Prefer": "return=minimal"})
            if io_px < int(os.getenv("VTON_FACE_MIN", "120")):
                raise ValueError(
                    f"face_too_small: {io_px}px between the eyes, need "
                    f"{os.getenv('VTON_FACE_MIN', '120')}px — hold the phone "
                    f"closer and fill the frame with your face")
        pbuf = io.BytesIO()
        current.convert("RGB").save(pbuf, "PNG")
        base_path = f"{job['user_id']}/studio.png"
        _req("POST", f"/storage/v1/object/body-photos/{base_path}", pbuf.getvalue(),
             ctype="image/png", extra={"x-upsert": "true"})
        fields = {"studio_base_path": base_path, "updated_at": "now()"}
        _req("PATCH", f"/rest/v1/style_profiles?user_id=eq.{job['user_id']}",
             json.dumps(fields).encode(), ctype="application/json",
             extra={"Prefer": "return=minimal"})
        print(f"  studio base → {base_path} (selfie io={io_px})", flush=True)
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
