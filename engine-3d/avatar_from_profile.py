#!/usr/bin/env python3
"""User profile → personalized avatar (figure + skin tone + face).

    python3 avatar_from_profile.py                 # first profile in the DB
    python3 avatar_from_profile.py --user <uuid>

Pipeline: style_profiles (height, body_type, measurements) → morph factors →
body_real.py bake → face_from_selfie.py projects the profile photo's face and
samples its skin tone. Output: assets/avatar_<uid8>.glb + preview PNG.

The morph mapping is deliberately COARSE (±6% bands). Gemini's measurements
are ranges estimated from one photo; pretending centimetre precision would
just amplify its noise. body_type carries the silhouette, measurements nudge.
"""
import argparse
import json
import pathlib
import subprocess
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent
BLENDER = "/Applications/Blender.app/Contents/MacOS/Blender"
SB = "https://tnirnwapfgckfypvtooj.supabase.co"

# Silhouette first: the body_type IS the user-visible shape.
BODY_TYPE = {
    "inverted_triangle": {"shoulders": 1.06, "waist": 0.98, "hips": 0.97},
    "triangle":          {"shoulders": 0.96, "waist": 1.03, "hips": 1.06},
    "rectangle":         {"shoulders": 1.00, "waist": 1.00, "hips": 1.00},
    "hourglass":         {"shoulders": 1.04, "waist": 0.94, "hips": 1.04},
    "oval":              {"shoulders": 1.00, "waist": 1.08, "hips": 1.02},
}
BASE_WAIST_CM = 86.0   # the CC0 base mesh's approximate waist


def service_key() -> str:
    out = subprocess.run(
        ["npx", "supabase", "projects", "api-keys", "--project-ref",
         "tnirnwapfgckfypvtooj", "-o", "json"],
        capture_output=True, text=True, cwd=ROOT.parent / "backend", check=True)
    return next(k["api_key"] for k in json.loads(out.stdout)
                if k.get("name") == "service_role")


def sb(key, path):
    req = urllib.request.Request(SB + path, headers={
        "apikey": key, "Authorization": f"Bearer {key}"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--user", default="")
    args = ap.parse_args()

    key = service_key()
    q = ("/rest/v1/style_profiles?select=user_id,height_cm,body_type,"
         "estimated_measurements,source_photo_path&limit=1")
    if args.user:
        q += f"&user_id=eq.{args.user}"
    prof = sb(key, q)[0]
    uid8 = prof["user_id"][:8]
    print(f"[profile] {uid8} {prof['height_cm']}cm {prof['body_type']}")

    # 1) figure: body_type silhouette + a waist nudge from the measurement.
    m = dict(BODY_TYPE.get(prof["body_type"] or "rectangle", BODY_TYPE["rectangle"]))
    est = prof.get("estimated_measurements") or {}
    waist = est.get("waist_cm") or {}
    if waist:
        mid = (waist.get("min", BASE_WAIST_CM) + waist.get("max", waist.get("min", BASE_WAIST_CM))) / 2
        # Half-weight: trust the silhouette more than a one-photo centimetre guess.
        m["waist"] *= 1 + (mid / BASE_WAIST_CM - 1) * 0.5

    # 2) the profile photo (face + skin tone source)
    photo = ROOT / f"_user_{uid8}.jpg"
    if prof["source_photo_path"]:
        signed = json.loads(subprocess.run(
            ["curl", "-s", "-X", "POST",
             f"{SB}/storage/v1/object/sign/body-photos/{prof['source_photo_path']}",
             "-H", f"apikey: {key}", "-H", f"Authorization: Bearer {key}",
             "-H", "Content-Type: application/json", "-d", '{"expiresIn":600}'],
            capture_output=True, text=True).stdout)
        urllib.request.urlretrieve(SB + "/storage/v1" + signed["signedURL"], photo)

    # 3) bake the figure
    body_out = ROOT / "assets" / f"avatar_{uid8}_body.glb"
    r = subprocess.run(
        [BLENDER, "-b", "-P", str(ROOT / "body_real.py"), "--",
         "--height_m", str(prof["height_cm"] / 100),
         "--shoulders", f"{m['shoulders']:.3f}",
         "--waist", f"{m['waist']:.3f}",
         "--hips", f"{m['hips']:.3f}",
         "--out", str(body_out)],
        capture_output=True, text=True, timeout=600)
    if not body_out.exists():
        raise SystemExit("body bake failed:\n" + (r.stdout + r.stderr)[-600:])
    print(f"[figure] shoulders {m['shoulders']:.2f} waist {m['waist']:.2f} "
          f"hips {m['hips']:.2f} → {body_out.name}")

    # 4) face + tone onto that body
    final = ROOT / "assets" / f"avatar_{uid8}.glb"
    if photo.exists():
        r = subprocess.run(
            [BLENDER, "-b", "-P", str(ROOT / "face_from_selfie.py"), "--",
             "--photo", str(photo), "--body", str(body_out),
             "--out", str(final),
             "--preview", str(ROOT / "assets" / f"avatar_{uid8}_preview.png")],
            capture_output=True, text=True, timeout=600)
        if not final.exists():
            raise SystemExit("face pass failed:\n" + (r.stdout + r.stderr)[-600:])
        print(f"[face] → {final.name}")
    else:
        body_out.rename(final)
        print("[face] no photo on profile — figure only")


if __name__ == "__main__":
    main()
