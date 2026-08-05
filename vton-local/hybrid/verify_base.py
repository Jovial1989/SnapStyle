"""One command to check the minimal base and score the engine after it.

Written to be poured onto a fresh pod and run, because the GPU is rented by the
hour and pasting heredocs into ssh is how a session's first ten minutes get spent:

    cd /workspace/SnapStyle && git pull -q
    set -a; . /workspace/env.sh; set +a
    /workspace/venv/bin/python vton-local/hybrid/verify_base.py --shorts /workspace/shorts.jpg

What it does, in order:

  1. builds the minimal base (bare arms, then bare legs) and uploads it as
     `${photoPath}.min.png`, so the Edge Functions can prefer it exactly as they
     already prefer `.bare.png`;
  2. renders the shorts fixture on it — the case that BLOCKED before, because the
     base's grey trouser showed under every pair;
  3. re-runs the twelve-item acceptance set that scored 5/12 strictly before the
     warp existed, so the warp finally gets measured on the same set rather than
     by eye on single garments.

Everything it prints is a number or a path. Judging the pictures is still a human
job — the sheet lands in /workspace.
"""
from __future__ import annotations

import argparse
import io
import json
import os
import time
import urllib.request

import cv2
import numpy as np
from PIL import Image

import pipeline as P

SUPABASE_URL = os.environ["SUPABASE_URL"].rstrip("/")
KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
H = {"apikey": KEY, "Authorization": f"Bearer {KEY}", "Content-Type": "application/json"}
OUT = os.getenv("VERIFY_OUT", "/workspace")


def req(method: str, path: str, body: bytes | None = None,
        ctype: str = "application/json", extra: dict | None = None) -> bytes:
    r = urllib.request.Request(SUPABASE_URL + path, data=body, method=method,
                               headers={**H, "Content-Type": ctype, **(extra or {})})
    with urllib.request.urlopen(r, timeout=180) as resp:
        return resp.read()


def signed(bucket: str, path: str) -> str:
    s = json.loads(req("POST", f"/storage/v1/object/sign/{bucket}/{path}",
                       json.dumps({"expiresIn": 900}).encode()))
    return SUPABASE_URL + "/storage/v1" + s["signedURL"]


def fetch(url: str) -> Image.Image:
    with urllib.request.urlopen(url, timeout=120) as r:
        return Image.open(io.BytesIO(r.read()))


def acceptance_set() -> list[dict]:
    """The same twelve rows, chosen the same way, so the score is comparable."""
    rows = json.loads(req(
        "GET", "/rest/v1/affiliate_items?select=name,category,image_url"
               "&image_url=not.like.*placehold*&limit=400"))
    slot = {"top": "upper", "outerwear": "upper", "bottom": "lower", "shoes": "shoes"}
    pick: list[dict] = []
    for cat, want in (("top", 5), ("outerwear", 2), ("bottom", 3), ("shoes", 2)):
        for r in [x for x in rows if (x["category"] or "").lower() == cat][:want]:
            pick.append({**r, "kind": slot[cat]})
    return pick


def sheet(paths: list[str], out: str, height: int = 470) -> None:
    tiles = []
    for p in paths:
        im = cv2.imread(p)
        if im is None:
            continue
        s = height / im.shape[0]
        tiles.append(cv2.resize(im, (int(im.shape[1] * s), height)))
    if tiles:
        cv2.imwrite(out, np.hstack(tiles))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--shorts", help="local shorts flat-lay; skipped if absent")
    ap.add_argument("--no-upload", action="store_true",
                    help="build the base but do not publish it")
    a = ap.parse_args()

    prof = json.loads(req(
        "GET", "/rest/v1/style_profiles?select=user_id,source_photo_path"
               "&source_photo_path=not.is.null&limit=1"))[0]
    sp = prof["source_photo_path"]

    # Start from the ORIGINAL avatar, not from `.bare.png`: bare_legs has to see
    # the trousers it is replacing, and running the arms pass twice would repaint
    # skin that is already skin.
    src = fetch(signed("body-photos", f"{sp}.avatar.png"))
    pipe = P.HybridVTONPipeline()
    pipe.warmup()

    t = time.time()
    base = pipe.minimal_base(src)
    print(f"minimal_base   {time.time() - t:5.1f}s")
    base.save(f"{OUT}/base_min.png")

    if not a.no_upload:
        buf = io.BytesIO()
        base.convert("RGB").save(buf, "PNG")
        req("POST", f"/storage/v1/object/body-photos/{sp}.min.png", buf.getvalue(),
            "image/png", {"x-upsert": "true"})
        print(f"uploaded       {sp}.min.png  {len(buf.getvalue()) // 1024} KB")

    if a.shorts and os.path.exists(a.shorts):
        t = time.time()
        pipe.generate(base, Image.open(a.shorts), "lower",
                      "athletic shorts", seed=7).save(f"{OUT}/shorts_on_min.png")
        print(f"shorts         {time.time() - t:5.1f}s  -> {OUT}/shorts_on_min.png")
        # The whole point of bare_legs: nothing of the base's trouser below the hem.
        # Reported, not asserted — a number to read next to the picture.
        r = cv2.imread(f"{OUT}/shorts_on_min.png")
        b = cv2.imread(f"{OUT}/base_min.png")
        if r is not None and b is not None and r.shape == b.shape:
            diff = np.abs(r.astype(int) - b.astype(int)).max(axis=2)
            print(f"  changed pixels vs the base: {int((diff > 18).sum()) // 1000}k")
    elif a.shorts:
        print(f"shorts         MISSING at {a.shorts} — scp one over and rerun")

    items = acceptance_set()
    print(f"acceptance set {len(items)} items")
    paths, t0 = [], time.time()
    for i, it in enumerate(items):
        g = fetch(it["image_url"])
        out = pipe.generate(base, g, it["kind"], it["name"], seed=7)
        p = f"{OUT}/acc_{i:02d}.png"
        out.save(p)
        paths.append(p)
        print(f"  {i:02d} {it['kind']:6s} {it['name'][:44]}")
    print(f"rendered       {len(paths)} in {time.time() - t0:.1f}s")
    sheet(paths[:6], f"{OUT}/acc_sheet_a.png")
    sheet(paths[6:], f"{OUT}/acc_sheet_b.png")
    print(f"sheets         {OUT}/acc_sheet_a.png  {OUT}/acc_sheet_b.png")


if __name__ == "__main__":
    main()
