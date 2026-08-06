#!/usr/bin/env python3
"""Catalog → 3D: run every dressable affiliate item through garment_from_image.

    python3 batch_catalog.py --limit 6          # sample run
    python3 batch_catalog.py                    # full library
    python3 batch_catalog.py --upload           # + push GLBs to storage

Slot comes from the CATALOG category (top/outerwear→top, bottom→bottom) — the
one thing the silhouette guesser kept getting wrong on folded photos. Shoes
and accessories are skipped: the 3D draft doesn't dress them.

Resumable by design: an item whose .glb already exists in --out is skipped, so
a crashed run continues where it stopped. Failures are logged per item and
never kill the batch.
"""
import argparse
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent
BLENDER = "/Applications/Blender.app/Contents/MacOS/Blender"
SB = "https://tnirnwapfgckfypvtooj.supabase.co"
SLOT = {"top": "top", "outerwear": "top", "bottom": "bottom"}


def service_key() -> str:
    """Fetched at runtime, never persisted (project convention)."""
    out = subprocess.run(
        ["npx", "supabase", "projects", "api-keys", "--project-ref",
         "tnirnwapfgckfypvtooj", "-o", "json"],
        capture_output=True, text=True, cwd=ROOT.parent / "backend", check=True)
    keys = json.loads(out.stdout)
    return next(k["api_key"] for k in keys if k.get("name") == "service_role")


def sb(key: str, method: str, path: str, body=None, raw=False, ctype="application/json"):
    data = body if raw else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(
        SB + path, data=data, method=method,
        headers={"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": ctype})
    with urllib.request.urlopen(req, timeout=120) as r:
        payload = r.read()
        return json.loads(payload) if payload.strip() and not raw else payload


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--out", default=str(ROOT / "catalog_glb"))
    ap.add_argument("--imgcache", default=str(ROOT / "catalog_img"))
    ap.add_argument("--upload", action="store_true")
    ap.add_argument("--bucket", default="models-3d")
    args = ap.parse_args()

    out_dir = pathlib.Path(args.out); out_dir.mkdir(exist_ok=True)
    img_dir = pathlib.Path(args.imgcache); img_dir.mkdir(exist_ok=True)
    key = service_key()

    items = sb(key, "GET",
               "/rest/v1/affiliate_items?select=id,category,image_url,name"
               "&source=eq.generated&category=in.(top,bottom,outerwear)"
               "&order=category.asc,id.asc")
    if args.limit:
        items = items[: args.limit]
    print(f"[batch] {len(items)} items → {out_dir}")

    ok = failed = skipped = 0
    report = []
    t_start = time.time()
    for i, it in enumerate(items, 1):
        gid, cat = it["id"], it["category"]
        glb = out_dir / f"{gid}.glb"
        if glb.exists():
            skipped += 1
            continue
        try:
            img = img_dir / f"{gid}.png"
            if not img.exists():
                urllib.request.urlretrieve(it["image_url"], img)
            t0 = time.time()
            r = subprocess.run(
                [BLENDER, "-b", "-P", str(ROOT / "garment_from_image.py"), "--",
                 "--image", str(img), "--slot", SLOT[cat], "--out", str(glb),
                 "--preview", str(out_dir / "_preview_skip.png")],
                capture_output=True, text=True, timeout=300)
            if not glb.exists():
                tail = (r.stdout + r.stderr)[-400:]
                raise RuntimeError(f"no glb produced: …{tail}")
            ok += 1
            print(f"  ✓ {i}/{len(items)} {cat:9s} {it['name'][:40]:40s} "
                  f"{glb.stat().st_size // 1024}KB {time.time() - t0:.0f}s", flush=True)
        except Exception as e:
            failed += 1
            report.append({"id": gid, "error": str(e)[:200]})
            print(f"  ✗ {i}/{len(items)} {gid} {e}", flush=True)

    print(f"[batch] done in {(time.time() - t_start) / 60:.1f} min · "
          f"{ok} built · {failed} failed · {skipped} already existed")
    (out_dir / "_failures.json").write_text(json.dumps(report, indent=1))

    if args.upload:
        # Public bucket, content by item id — the app derives the URL from the
        # id alone, no schema change needed (we cannot run DDL from here).
        try:
            sb(key, "POST", "/storage/v1/bucket",
               {"name": args.bucket, "id": args.bucket, "public": True,
                "file_size_limit": 10485760,
                "allowed_mime_types": ["model/gltf-binary"]})
            print(f"[upload] bucket {args.bucket} created")
        except Exception:
            pass  # already exists
        up = 0
        for glb in sorted(out_dir.glob("*.glb")):
            path = f"/storage/v1/object/{args.bucket}/{glb.name}"
            try:
                sb(key, "POST", path, glb.read_bytes(), raw=True,
                   ctype="model/gltf-binary")
                up += 1
            except urllib.error.HTTPError as e:
                if e.code == 400 and b"exists" in e.read()[:200]:
                    continue  # idempotent re-run
                print(f"  ✗ upload {glb.name}: {e}")
        print(f"[upload] {up} new objects in {args.bucket}")
        manifest = [{"id": it["id"], "category": it["category"], "name": it["name"],
                     "glb": f"{SB}/storage/v1/object/public/{args.bucket}/{it['id']}.glb"}
                    for it in items if (out_dir / f"{it['id']}.glb").exists()]
        sb(key, "POST", f"/storage/v1/object/{args.bucket}/manifest.json",
           json.dumps(manifest).encode(), raw=True, ctype="application/json")
        print(f"[upload] manifest.json: {len(manifest)} entries")


if __name__ == "__main__":
    main()
