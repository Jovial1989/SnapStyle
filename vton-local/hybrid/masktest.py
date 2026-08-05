"""Check the mask for any slot WITHOUT a GPU, on any machine.

Stages A (pose) and B (mask) are CPU-only — only stage C needs the card. Every
mask bug this engine has had was found by looking at an overlay, and every one
that shipped was found by not looking; doing that on a rented GPU means paying
$0.69/h to run OpenCV. This runs on a laptop with mediapipe and cv2 alone.

    python masktest.py avatar.png upper:tee.png lower:jeans.png shoes:boots.png

Prints, per case, the measured ratios and four numbers worth reading:

    area      mask size — a jacket must come out larger than a tee
    rows      top and bottom of the mask, against the collar and the hem
    blobs     >1 means mask floating free of the figure, except for shoes (2 feet)
    outside   % of the mask off the body — this is where halos get painted

It IMPORTS the real functions out of pipeline.py rather than copying them, so it
cannot drift from what the worker runs, and skips the torch import that would
otherwise demand a GPU box. Requires only `pip install mediapipe==0.10.21
opencv-python-headless` (0.10.35 and 1.x dropped the legacy solutions API).
"""
import math
import pathlib
import sys
import threading
import __future__
from dataclasses import dataclass

import cv2
import mediapipe as mp
import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
src = (HERE / "pipeline.py").read_text()
ns = {"cv2": cv2, "np": np, "math": math, "mp": mp, "dataclass": dataclass,
      "threading": threading}
FLAG = __future__.annotations.compiler_flag


def grab(name: str, kind: str = "def") -> None:
    i = src.index(f"{kind} {name}")
    # Keep any decorator above it — Pose is a @dataclass, and slicing from the
    # `class` line silently yields a class with no __init__.
    head = src.rfind("\n@", 0, i)
    if head != -1 and src[head:i].count("\n") <= 2:
        i = head + 1
    exec(compile(src[i:src.index("\n\n\n", i)], name, "exec", FLAG), ns)


for const in ("_COCO_FROM_MP", "_LIMBS", "_COLORS", "_VIS"):
    i = src.index(f"\n{const} ")
    exec(compile(src[i:src.index("\n\n", i)], const, "exec", FLAG), ns)
for cls in ("Pose", "PoseReader"):
    grab(cls, "class")
for fn in ("_draw_openpose", "_split", "_flatlay_silhouette", "_garment_color",
           "_garment_metrics", "_garment_mask"):
    grab(fn)


def main() -> None:
    if len(sys.argv) < 3:
        print(__doc__.strip().splitlines()[6], file=sys.stderr)
        sys.exit(2)
    avatar = cv2.imread(sys.argv[1])
    if avatar is None:
        sys.exit(f"cannot read {sys.argv[1]}")
    pose = ns["PoseReader"]().read(avatar)
    tiles = []
    for arg in sys.argv[2:]:
        kind, _, path = arg.partition(":")
        g = cv2.imread(path)
        if g is None:
            sys.exit(f"cannot read {path}")
        met = ns["_garment_metrics"](g, kind)
        mm = ns["_garment_mask"](pose, kind, g) > 20
        n, _, _, _ = cv2.connectedComponentsWithStats(mm.astype(np.uint8), 8)
        outside = int((mm & (pose.silhouette == 0)).sum())
        rows = np.nonzero(mm.any(axis=1))[0]
        print(f"{kind:6s} {pathlib.Path(path).name:26s} area={mm.sum() // 1000}k "
              f"rows={rows.min()}..{rows.max()} blobs={n - 1} "
              f"outside={100 * outside / max(1, mm.sum()):.0f}% met={met}")
        vis = avatar.copy()
        vis[mm] = vis[mm] * 0.45 + np.array([0, 0, 200]) * 0.55
        tiles.append(cv2.resize(vis, (avatar.shape[1] // 3, avatar.shape[0] // 3)))
    cv2.imwrite("mask_slots.png", np.hstack(tiles))
    print("saved mask_slots.png")


if __name__ == "__main__":
    main()
