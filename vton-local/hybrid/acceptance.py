"""The acceptance sheet: every fixed look, both engines, one contact strip.

Six regressions reached the phone in one week because every fix was eyeballed on
the one look it was written against. This is the counterweight: a FIXED set of
looks covering every slot and every known failure class, rendered at seed 7,
tiled into one image a human scans in thirty seconds. The rule it enforces is
procedural, not technical: no cache bump, no build, no default flip until the
sheet has been looked at.

    python acceptance.py [--engines sd15,xl] [--out /workspace/acceptance]

Cases are (file, kind, hint, why-it-is-here). Add a case when a defect class is
discovered; never remove one because it is inconvenient.
"""
from __future__ import annotations

import argparse
import os
import time

import cv2
import numpy as np
from PIL import Image

import pipeline as P

BASE = os.getenv("ACCEPT_BASE", "/workspace/bare9_cand_7.png")

CASES = [
    ("men_top_03.png",    "upper", "light yellow t-shirt with sun print",
     "print survival + hem + collar"),
    ("wi_3.jpg",          "upper", "black and white striped t-shirt",
     "pattern continuation + sleeves + collar"),
    ("men_bottom_01.png", "lower", "Straight-leg blue denim jeans",
     "full-length lower + arm/hip separation"),
    ("shorts_synth.png",  "lower", "plain grey athletic knee-length shorts, bare lower legs",
     "shorts hem gate + skin flood"),
    ("wi_1.jpg",          "full",  "white polka dot mini dress",
     "full slot + legs below the hem"),
    ("men_shoes_01.png",  "shoes", "black leather oxford",
     "cover warp + foot boundary"),
    # Wardrobe-card garments: grey gradient background + baked-in label. The
    # phone renders THESE, the catalogue renders above — and the cardboard-box
    # hem lived only here, which is why the sheet missed it until this case.
    ("wi_2.jpg",          "upper", "light yellow t-shirt",
     "wardrobe card background survival"),
]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--engines", default="sd15,xl")
    ap.add_argument("--out", default="/workspace/acceptance")
    args = ap.parse_args()
    engines = [e.strip() for e in args.engines.split(",") if e.strip()]
    os.makedirs(args.out, exist_ok=True)

    base = cv2.imread(BASE)
    pose = P.PoseReader().read(base)
    eng = P.HybridVTONPipeline()
    eng.warmup()
    cur = Image.open(BASE)

    tiles: list[np.ndarray] = []
    for fname, kind, hint, why in CASES:
        row = []
        for e in engines:
            # The engine toggle must actually toggle: XL_KINDS overrides P.XL
            # per slot, so the sd15 column silently rendered 'lower' through XL
            # and the two lower tiles came out identical. The sheet compares
            # engines, so for the sheet the per-slot default is suspended.
            P.XL = (e == "xl")
            P.XL_KINDS = set() if e == "sd15" else {"upper", "lower", "full", "shoes"}
            t0 = time.time()
            img, _ = eng.generate(cur, Image.open("/workspace/" + fname), kind,
                                  hint, seed=7, pose=pose, return_mask=True)
            dt = time.time() - t0
            a = np.array(img.convert("RGB"))[:, :, ::-1].copy()
            cv2.imwrite(f"{args.out}/{fname.split('.')[0]}_{e}.jpg", a)
            tile = cv2.resize(a, (256, 384), interpolation=cv2.INTER_AREA)
            cv2.putText(tile, f"{kind}/{e} {dt:.1f}s", (6, 20),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 0, 0), 1)
            row.append(tile)
        tiles.append(np.hstack(row))
        print(f"[accept] {fname} done ({why})", flush=True)

    rows = [np.hstack(tiles[i:i + 2]) if i + 1 < len(tiles) else
            np.hstack([tiles[i], np.full_like(tiles[i], 255)])
            for i in range(0, len(tiles), 2)]
    sheet = np.vstack(rows)
    cv2.imwrite(f"{args.out}/sheet.jpg", sheet)
    print(f"[accept] sheet -> {args.out}/sheet.jpg", flush=True)


if __name__ == "__main__":
    main()
