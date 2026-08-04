"""Generate catalogue flat-lays on our own GPU. No Gemini, no OpenAI.

A garment laid flat on white is plain txt2img — no ControlNet, no IP-Adapter, no
reference image. The heavy VTON pipeline is not needed and not touched: this
loads only the base SD 1.5 components, ~2.5 GB alongside the worker's 5.3 GB on
a 24 GB card.

Why bother: 42 catalogue rows ship `placehold.co` URLs, so if one is offered in
the editor there is nothing for the renderer to copy. Gemini would charge ~$0.039
an image ($1.6 for the batch, and $7.49 has already gone that way this month).
Here it is ~1.5s of a card we already pay for.

    python flatlay.py --sample 3      # generate, save locally, upload nothing
    python flatlay.py --commit        # generate all placeholders and publish

The garments stay fictional either way — this fixes cost and consistency, not
the fact that no such product exists. A real shoppable catalogue means affiliate
feeds, which is a different job.
"""
from __future__ import annotations

import argparse
import io
import json
import os
import urllib.request

import torch

SUPABASE_URL = os.environ["SUPABASE_URL"].rstrip("/")
SERVICE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
BUCKET = os.getenv("CATALOG_BUCKET", "catalog")
STEPS = int(os.getenv("FLATLAY_STEPS", "28"))
SIZE = int(os.getenv("FLATLAY_PX", "640"))

_AUTH = {"apikey": SERVICE_KEY, "Authorization": f"Bearer {SERVICE_KEY}"}


def _req(method: str, path: str, body: bytes | None = None,
         ctype: str = "application/json", extra: dict | None = None) -> bytes:
    req = urllib.request.Request(
        f"{SUPABASE_URL}{path}", data=body, method=method,
        headers={**_AUTH, "Content-Type": ctype, **(extra or {})},
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


# The engine copies texture from this image, so the frame must contain the
# GARMENT AND NOTHING ELSE. Every clause below removes a thing that would
# otherwise be copied onto the user: a mannequin's shoulders, a hanger's hook,
# a shadow read as fabric, a fold that invents a seam.
# WHITE BACKGROUND GOES FIRST. CLIP weights early tokens more, and SD 1.5's prior
# for "product photograph" is a lifestyle shot on a wooden table — the first
# attempt put a beanie on floorboards while the negative prompt was asking for
# no coloured background. Leading with the background, and raising guidance, is
# what actually binds it.
#
# "fills the frame" is REMOVED: taken literally it produced a macro crop of a
# waistband with no white visible at all. The engine copies texture from this
# image, so it must contain the whole garment and nothing else.
PROMPT = (
    "isolated on a plain seamless pure white background, studio cutout, "
    "{name}, {kind}, "
    "the ENTIRE garment visible with generous white margin on all sides, "
    "flat lay seen from directly above, even soft lighting, no shadows, "
    "sharp fabric texture, true colour, e-commerce catalogue photograph"
)
NEGATIVE = (
    "wood, wooden table, table, floor, desk, backdrop, surface texture, "
    "lifestyle, styled scene, props, plants, coloured background, grey "
    "background, gradient, shadow, reflection, "
    "close-up, macro, detail shot, zoomed in, cropped, out of frame, "
    "person, model, human, body, face, hands, mannequin, torso, legs, "
    "hanger, rack, folded stack, multiple garments, "
    "text, letters, logo, watermark, label, brand tag, price tag, packaging, "
    "blurry, lowres, deformed"
)
# A garment's own proportions. A square frame asked SD 1.5 to fit trousers into
# a box and it cropped them instead; shoes side by side need the opposite.
ASPECT = {
    "top": (640, 640),
    "outerwear": (640, 640),
    "bottom": (512, 768),
    "shoes": (768, 512),
    "accessory": (640, 640),
}
KIND = {
    "top": "single t-shirt or shirt",
    "bottom": "single pair of trousers, full length from waistband to hem",
    "outerwear": "single jacket",
    "shoes": "a pair of shoes side by side",
    "accessory": "single accessory",
}


def build() -> object:
    from diffusers import StableDiffusionPipeline
    dev = "cuda" if torch.cuda.is_available() else "cpu"
    dtype = torch.float16 if dev == "cuda" else torch.float32
    p = StableDiffusionPipeline.from_pretrained(
        "stable-diffusion-v1-5/stable-diffusion-v1-5",
        torch_dtype=dtype, variant="fp16",
        safety_checker=None, requires_safety_checker=False,
    )
    p.set_progress_bar_config(disable=True)
    return p.to(dev)


def placeholders(limit: int | None = None) -> list[dict]:
    q = ("/rest/v1/affiliate_items?select=id,name,category,gender,brand_name"
         "&image_url=like.*placehold*&order=category")
    rows = json.loads(_req("GET", q))
    return rows[:limit] if limit else rows


def render(pipe, row: dict):
    kind = KIND.get((row.get("category") or "").lower(), "single garment")
    prompt = PROMPT.format(name=row.get("name") or "garment", kind=kind)
    # Seed from the row id: the same SKU always yields the same picture, so a
    # rerun cannot quietly change what the user already saw.
    seed = abs(hash(row["id"])) % (2**31)
    w, h = ASPECT.get((row.get("category") or "").lower(), (SIZE, SIZE))
    out = pipe(
        prompt=prompt, negative_prompt=NEGATIVE,
        # 9.0, not 7.5: at 7.5 the background instruction lost to the model's
        # lifestyle prior. Higher guidance costs some fabric softness and buys
        # the plain white that the renderer actually needs.
        num_inference_steps=STEPS, guidance_scale=float(os.getenv("FLATLAY_CFG", "9.0")),
        width=w, height=h,
        generator=torch.Generator(pipe.device).manual_seed(seed),
    )
    return out.images[0]


def publish(row: dict, img) -> str:
    buf = io.BytesIO()
    img.convert("RGB").save(buf, "JPEG", quality=90)
    path = f"flatlay_{row['id']}.jpg"
    _req("POST", f"/storage/v1/object/{BUCKET}/{path}", buf.getvalue(),
         ctype="image/jpeg", extra={"x-upsert": "true"})
    url = f"{SUPABASE_URL}/storage/v1/object/public/{BUCKET}/{path}"
    _req("PATCH", f"/rest/v1/affiliate_items?id=eq.{row['id']}",
         json.dumps({"image_url": url, "source": "flatlay-sd15"}).encode(),
         extra={"Prefer": "return=minimal"})
    return url


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sample", type=int, default=0,
                    help="generate N locally and upload nothing")
    ap.add_argument("--commit", action="store_true",
                    help="generate every placeholder and publish")
    a = ap.parse_args()
    rows = placeholders(a.sample or None)
    print(f"[flatlay] {len(rows)} rows, {STEPS} steps, {SIZE}px", flush=True)
    pipe = build()
    for i, row in enumerate(rows, 1):
        img = render(pipe, row)
        if a.commit:
            url = publish(row, img)
            print(f"  {i}/{len(rows)} {row['name'][:38]} → {url.split('/')[-1]}", flush=True)
        else:
            f = f"/workspace/flatlay_sample_{i}.jpg"
            img.save(f, quality=90)
            print(f"  {i}/{len(rows)} {row['name'][:38]} → {f}", flush=True)


if __name__ == "__main__":
    main()
