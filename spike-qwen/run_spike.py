#!/usr/bin/env python3
"""Qwen-Image-Edit-2509 VTON spike — is it good enough to replace Gemini for
try-on swaps? Runs every case in ./cases through fal-ai/qwen-image-edit-plus
(person + garment reference, our compact prompt), records latency, and builds
a side-by-side grid (person | garment | Gemini | Qwen) at ./grid.html.

Usage:
  export FAL_KEY=...            # from https://fal.ai/dashboard/keys
  python3 -m venv .venv && .venv/bin/pip install fal-client
  .venv/bin/python run_spike.py [--cases 5]   # start small, then full 20
Cost: ~$0.03-0.05 per render (billed per output megapixel).
"""
import argparse
import base64
import json
import pathlib
import time

import fal_client  # pip install fal-client

ROOT = pathlib.Path(__file__).parent
ENDPOINT = "fal-ai/qwen-image-edit-plus"  # Qwen-Image-Edit-2509, multi-image

# Same contract as our Gemini compact prompt (fix_prompt.ts) — person first,
# garment reference second, identity + full-body + white background mandates.
PROMPT = (
    "Dress the person from the first image in the garment shown in the second "
    "image. Copy the garment EXACTLY — same color, pattern, length, sleeve "
    "length and cut. Keep the SAME person: identical face, hair, skin tone, "
    "body and pose. Change only that garment; keep the rest of the outfit. "
    "Full body head to feet, plain seamless pure-white background. "
    "Photorealistic. No text, no logos."
)


def data_url(path: pathlib.Path) -> str:
    mime = "image/png" if path.suffix == ".png" else "image/jpeg"
    return f"data:{mime};base64,{base64.b64encode(path.read_bytes()).decode()}"


def run_case(case_dir: pathlib.Path) -> dict:
    # person_big.jpg = the stored tryon payload upscaled to fal's 256px minimum
    # (training pairs hold a narrow 187px-wide cutout).
    person = case_dir / "person_big.jpg"
    if not person.exists():
        person = case_dir / "person.jpg"
    garment = case_dir / "garment.jpg"
    t0 = time.time()
    result = fal_client.subscribe(
        ENDPOINT,
        arguments={
            "prompt": PROMPT,
            "image_urls": [
                fal_client.upload_file(str(person)),
                fal_client.upload_file(str(garment)),
            ],
            "num_images": 1,
            "output_format": "png",
        },
        with_logs=False,
    )
    dt = time.time() - t0
    url = result["images"][0]["url"]
    out = case_dir / "qwen.png"
    import urllib.request
    urllib.request.urlretrieve(url, out)
    return {"case": case_dir.name, "seconds": round(dt, 1)}


def build_grid(rows: list[dict]) -> None:
    manifest = {m["case"]: m for m in json.load(open(ROOT / "manifest.json"))}
    cells = []
    for r in rows:
        d = ROOT / "cases" / r["case"]
        instr = manifest.get(r["case"], {}).get("instruction", "")[:220]
        imgs = "".join(
            f'<td><img src="{data_url(d / f)}"><div>{label}</div></td>'
            for f, label in [
                ("person.jpg", "person"), ("garment.jpg", "garment"),
                ("gemini.png", "gemini"), ("qwen.png", f"qwen · {r['seconds']}s"),
            ] if (d / f).exists()
        )
        cells.append(f"<tr>{imgs}</tr><tr><td colspan=4 class=i>{instr}</td></tr>")
    html = (
        "<meta charset=utf-8><style>img{height:340px;display:block}"
        "td{padding:6px;vertical-align:top;font:12px -apple-system}"
        ".i{color:#888;max-width:900px}</style><table>" + "".join(cells) + "</table>"
    )
    (ROOT / "grid.html").write_text(html)
    print("grid → spike-qwen/grid.html")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", type=int, default=20)
    n = ap.parse_args().cases
    dirs = sorted((ROOT / "cases").iterdir())[:n]
    rows, total = [], 0.0
    for d in dirs:
        try:
            r = run_case(d)
            rows.append(r)
            total += r["seconds"]
            print(f"{d.name}: {r['seconds']}s")
        except Exception as e:  # keep going; one bad case shouldn't kill the run
            print(f"{d.name}: FAILED — {e}")
    if rows:
        print(f"\n{len(rows)} ok · avg {total / len(rows):.1f}s")
        build_grid(rows)
