#!/usr/bin/env python3
"""Turn the generated A-pose bodies into engine-ready canonical bases.

WHY THESE EXIST. Every geometric compromise in pipeline.py traces back to one
fact about the base in use: it is a photograph of a person MID-STRIDE. Measured
by check_a_pose, its ankle height difference is 0.056 of the figure's span
against a 0.02 threshold — so the trailing heel is raised, its old shoe's collar
peeked over every rendered shoe until the zone was split per foot, and that
sneaker still shows between the legs under long trousers. Ten A-pose bodies
(five male, five female, generated once inside a hard 10-image budget) remove
the cause instead of the symptoms, and give the sheet real body diversity —
slim to plus — where it has had exactly one physique.

WHAT THIS DOES, in the order that matters:
  1. matte the person with the same segmenter the flat-lays use (rembg
     isnet-general-use) and composite on TRUE #FFFFFF — the generated frames
     have a light-grey studio wall with a floor gradient, and the engine's
     rim-close and silhouette logic both assume white behind the figure;
  2. measure the pose (heel_dy, wrist_gap) and REJECT anything that is not
     actually an A-pose, because the whole point is the number, not the look;
  3. write a contact sheet plus a one-line verdict per body, so the decision to
     adopt is made on numbers and crops rather than on optimism.

Run on the pod (rembg + MediaPipe live there):
    python bases_prep.py --out /workspace/bases_ready
"""
from __future__ import annotations

import argparse
import os
import pathlib
import urllib.request

import cv2
import numpy as np

import pipeline as P

BUCKET = ("https://tnirnwapfgckfypvtooj.supabase.co/storage/v1/object/"
          "public/catalog/_bases")
NAMES = ["m1_slim", "m2_average", "m3_athletic", "m4_heavy", "m5_tall",
         "f1_slim", "f2_average", "f3_curvy", "f4_plus", "f5_tall"]

# Same gate check_a_pose uses; kept here so a rejection reads as a number.
HEEL_MAX = 0.02
WRIST_MIN = 0.30


def fetch(name: str, cache: pathlib.Path) -> np.ndarray:
    dst = cache / f"{name}.png"
    if not dst.exists():
        urllib.request.urlretrieve(f"{BUCKET}/{name}.png", dst)
    return cv2.imread(str(dst))


def on_white(bgr: np.ndarray) -> np.ndarray:
    """Person on pure white, edges feathered by the matte's own alpha.

    The alpha is used as a float, not thresholded: a hard cut leaves the
    staircase that the mask-warp experiment already proved reads as scissors,
    and hair needs the soft half-covered pixels to look like hair.
    """
    from rembg import new_session, remove
    sess = new_session("isnet-general-use")
    a = np.array(remove(bgr[:, :, ::-1], session=sess, only_mask=True,
                        post_process_mask=True)).astype(np.float32) / 255.0
    a = a[:, :, None]
    return (bgr.astype(np.float32) * a + 255.0 * (1.0 - a)).astype(np.uint8)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="/workspace/bases_ready")
    args = ap.parse_args()
    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    cache = out / "raw"
    cache.mkdir(exist_ok=True)

    reader = P.PoseReader()
    tiles, verdicts = [], []
    for name in NAMES:
        raw = fetch(name, cache)
        if raw is None:
            print(f"{name}: DOWNLOAD FAILED")
            continue
        white = on_white(raw)
        try:
            pose = reader.read(white)
        except Exception as e:
            print(f"{name}: no pose ({e})")
            continue
        ap_m = P.check_a_pose(pose)
        heel = ap_m.get("heel_dy", 9.9)
        wrist = ap_m.get("wrist_gap", -1.0)
        ok = heel <= HEEL_MAX and wrist >= WRIST_MIN
        # Feet must sit INSIDE the frame with margin: a base cropped at the
        # sole cannot host a shoe swap, and that is not visible in a thumbnail.
        rows = np.flatnonzero(pose.silhouette.any(axis=1))
        margin = (white.shape[0] - 1 - int(rows[-1])) / white.shape[0]
        if margin < 0.01:
            ok = False
        verdicts.append((name, heel, wrist, margin, ok))
        print(f"{name}: heel_dy={heel:.3f} wrist_gap={wrist:.2f} "
              f"foot_margin={margin:.3f} -> {'ACCEPT' if ok else 'REJECT'}")
        if ok:
            cv2.imwrite(str(out / f"{name}.base.png"), white)
        t = cv2.resize(white, (190, 285))
        cv2.putText(t, f"{name} {'OK' if ok else 'NO'}", (6, 20),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.45,
                    (0, 140, 0) if ok else (0, 0, 200), 1, cv2.LINE_AA)
        cv2.putText(t, f"dy={heel:.3f} wg={wrist:.2f}", (6, 275),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.4, (60, 60, 60), 1, cv2.LINE_AA)
        tiles.append(t)

    if tiles:
        rows_n = (len(tiles) + 4) // 5
        sheet = np.full((rows_n * 285, 5 * 190, 3), 255, np.uint8)
        for i, t in enumerate(tiles):
            r, c = divmod(i, 5)
            sheet[r * 285:(r + 1) * 285, c * 190:(c + 1) * 190] = t
        cv2.imwrite(str(out / "bases_sheet.jpg"), sheet)
    n_ok = sum(1 for v in verdicts if v[4])
    print(f"ACCEPTED {n_ok}/{len(verdicts)} -> {out}")


if __name__ == "__main__":
    main()
