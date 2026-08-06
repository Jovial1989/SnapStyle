# Local Qwen3-VL worker — drop-in replacement for the TEXT/VISION half of
# _shared/gemini.ts. Apple Silicon, MLX, 4-bit. Port 8124.
#
# WHY THIS EXISTS: Gemini went dunning-deny on the billing account and took the
# whole app down (critique, slots, identity gate — everything but rendering).
# These calls are cheap for Google but they are the app's spine, so they belong
# on hardware we control. Image GENERATION stays elsewhere: Qwen-Image-Edit is
# 20B and does not fit 16 GB, and its zero-shot try-on already failed (spike-qwen).
#
# Endpoint ↔ gemini.ts mapping (same JSON shapes, so an EF can swap provider):
#   POST /critique      ↔ analyzeFit(image, profile)
#   POST /slots         ↔ detectOutfitSlots(image, trends[], premium)
#   POST /same-person   ↔ samePerson(render, person)      → {"same": bool}
#   POST /validate      ↔ validateLookImages(images[])    → {"valid": [bool]}
#   POST /classify-item ↔ classifyItem(image)             → {label, category}
#   POST /body-profile  ↔ analyzeBodyProfile(image, heightCm)
#   GET  /health
#
# Run:
#   ./.venv-qwen/bin/uvicorn qwen_worker:app --host 0.0.0.0 --port 8124
#
# Licence note: Qwen3-VL is Apache-2.0 — commercial use is fine (unlike the
# CC BY-NC-SA VTON checkpoints in main.py).

import io
import json
import os
import re
import time
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from PIL import Image

# 4B-4bit (~2.5 GB) is the default: on an M1 Pro with 16 GB shared with the OS
# it answers ~2x faster than 8B and leaves headroom for Xcode/simulator.
# Swap up for a quality A/B: QWEN_MODEL=mlx-community/Qwen3-VL-8B-Instruct-4bit
MODEL_ID = os.environ.get("QWEN_MODEL", "mlx-community/Qwen3-VL-4B-Instruct-4bit")
# Vision tokens scale with pixels, and on an M1 Pro that is the whole latency
# budget. One image → 768px long edge; comparisons → 512px (the face/gender
# judgements this worker makes do not need more).
MAX_EDGE_SINGLE = 768
MAX_EDGE_MULTI = 512

_model: Any = None
_processor: Any = None
_config: Any = None


@asynccontextmanager
async def lifespan(_app: FastAPI):
    global _model, _processor, _config
    from mlx_vlm import load
    from mlx_vlm.utils import load_config
    t0 = time.time()
    _model, _processor = load(MODEL_ID)
    _config = load_config(MODEL_ID)
    print(f"[qwen] {MODEL_ID} loaded in {time.time() - t0:.0f}s", flush=True)
    yield


app = FastAPI(title="Looktok local Qwen3-VL worker", lifespan=lifespan)

# Shared-secret gate. The worker is reachable from the public internet whenever
# it is tunnelled, and an open inference endpoint is free compute for whoever
# finds the URL. Set VISION_TOKEN before exposing it; unset = localhost-only use.
VISION_TOKEN = os.environ.get("VISION_TOKEN", "")


@app.middleware("http")
async def require_token(request, call_next):
    from fastapi.responses import JSONResponse
    if VISION_TOKEN and request.url.path != "/health":
        if request.headers.get("x-vision-token") != VISION_TOKEN:
            return JSONResponse({"error": "forbidden"}, status_code=403)
    return await call_next(request)


# ── inference ────────────────────────────────────────────────────────────────
def _shrink(raw: bytes, max_edge: int) -> Image.Image:
    im = Image.open(io.BytesIO(raw)).convert("RGB")
    s = min(1.0, max_edge / max(im.size))
    if s < 1.0:
        im = im.resize((max(1, round(im.width * s)), max(1, round(im.height * s))), Image.LANCZOS)
    return im


def _run(prompt: str, images: list[Image.Image], max_tokens: int, temperature: float) -> str:
    """One MLX-VLM turn. Isolates the parts of its API that move between
    releases (chat-template arity, str vs GenerationResult return)."""
    if _model is None:
        raise HTTPException(503, "model is still loading")
    from mlx_vlm import generate
    from mlx_vlm.prompt_utils import apply_chat_template

    try:
        formatted = apply_chat_template(_processor, _config, prompt, num_images=len(images))
    except TypeError:                                  # older signature
        formatted = apply_chat_template(_processor, _config, prompt, len(images))

    # mlx-vlm 0.6.x type-hints `image` as paths, but load_image() accepts PIL
    # objects too — keeping them in memory avoids a temp-file round trip.
    kw: dict[str, Any] = {"max_tokens": max_tokens, "temperature": temperature, "verbose": False}
    try:
        out = generate(_model, _processor, formatted, images, enable_thinking=False, **kw)
    except TypeError:                                  # build without the thinking switch
        out = generate(_model, _processor, formatted, images, **kw)
    return out if isinstance(out, str) else getattr(out, "text", str(out))


def _json(text: str) -> Any:
    """Parse the model's answer as JSON. MLX has no schema-constrained decoding,
    so tolerate fences and leading prose, then take the first balanced object
    or array. Raises on garbage — callers decide whether to fail open."""
    t = re.sub(r"^\s*```(?:json)?|```\s*$", "", text.strip(), flags=re.M).strip()
    try:
        return json.loads(t)
    except json.JSONDecodeError:
        pass
    for opener, closer in (("{", "}"), ("[", "]")):
        start = t.find(opener)
        if start < 0:
            continue
        depth, in_str, esc = 0, False, False
        for i, ch in enumerate(t[start:], start):
            if in_str:
                if esc:
                    esc = False
                elif ch == "\\":
                    esc = True
                elif ch == '"':
                    in_str = False
                continue
            if ch == '"':
                in_str = True
            elif ch == opener:
                depth += 1
            elif ch == closer:
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(t[start:i + 1])
                    except json.JSONDecodeError:
                        break
    raise ValueError(f"not JSON: {text[:200]}")


def _ask_json(prompt: str, images: list[Image.Image], max_tokens: int,
              temperature: float, retries: int = 1) -> Any:
    """JSON turn with one reprompt — small VLMs occasionally trail prose."""
    last = ""
    for attempt in range(retries + 1):
        raw = _run(prompt if attempt == 0 else prompt +
                   "\n\nYour previous answer was not valid JSON. Output ONLY the JSON object, nothing else.",
                   images, max_tokens, temperature)
        last = raw
        try:
            return _json(raw)
        except ValueError:
            continue
    raise HTTPException(502, f"model did not return JSON: {last[:200]}")


# ── prompts: lifted from _shared/gemini.ts, with the schema stated inline
# because MLX cannot enforce a responseSchema the way the Gemini API does ─────
CRITIQUE_SYSTEM = """You are Looktok — an expert personal stylist reviewing a photo of someone's outfit and fit.

VOICE — a sharp friend who tells you the truth: specific, human, honest. Give REAL praise when it's earned (not empty flattery), and be direct only about things that genuinely detract. No exclamation marks. Never use marketing clichés ('elevate', 'unleash', 'effortless', 'versatile', 'staple', 'game-changer') — name the concrete reason instead.

CORE RULE — DON'T MANUFACTURE PROBLEMS. If a piece fits well, SAY it fits (severity 'good') and move on. If the whole outfit works, lead with a confident positive verdict and do NOT pick it apart.

OUTPUT MODEL — SPATIAL HOTSPOTS: an "overall" verdict plus "hotspots". Each hotspot is a pin ON the photo with x_percent/y_percent (0-100, top-left origin).

RULES:
- overall.summary: ONE short sentence. Lead with what works; add at most one change that genuinely matters.
- overall.score is an INTEGER 1-10 (never 0-100).
- 3-6 hotspots. When the fit is good, most are 'good'; 'tip' = an optional idea, 'issue' ONLY for things that actually detract.
- title <=4 words; detail = one sentence; fix = one brand-agnostic action (NEVER brands/stores/prices/links).
- severity: "issue" | "tip" | "good".
- visual_suggestions: 2-3 per hotspot, each { prompt, caption, alt_text } — brand-agnostic image-gen prompts.
- If not a usable full-outfit photo: analyzable=false, note what's needed, hotspots=[].

Return ONLY JSON:
{"analyzable": bool, "note": string, "overall": {"summary": string, "score": int},
 "hotspots": [{"x_percent": number, "y_percent": number, "area": string,
   "severity": "issue"|"tip"|"good", "title": string, "detail": string, "fix": string,
   "visual_suggestions": [{"prompt": string, "caption": string, "alt_text": string}]}]}"""

SLOT_NAMES = ["top", "bottom", "outerwear", "shoes", "belt", "accessories", "bag", "glasses", "watch", "jewelry"]


def _season() -> tuple[str, int]:
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc)
    m = now.month - 1
    s = "winter" if (m <= 1 or m == 11) else "spring" if m <= 4 else "summer" if m <= 7 else "autumn"
    return s, now.year


# ── endpoints ────────────────────────────────────────────────────────────────
@app.post("/critique")
async def critique(image: UploadFile = File(...), profile: str = Form("")):
    im = _shrink(await image.read(), MAX_EDGE_SINGLE)
    ctx = (f"User profile (factor into proportion/cut advice):\n{profile}"
           if profile.strip() else "No user profile provided. Analyze from the photo alone.")
    t0 = time.time()
    data = _ask_json(f"{CRITIQUE_SYSTEM}\n\n{ctx}\n\nReview this outfit.", [im], 1400, 0.6)

    # coerce to the shape callers already handle (gemini.ts guarantees these)
    hot = [h for h in (data.get("hotspots") or []) if isinstance(h, dict)]
    for h in hot:
        if h.get("severity") not in ("issue", "tip", "good"):
            h["severity"] = "tip"
        # The hotspot overlay positions pins by percentage; a missing or
        # out-of-range coordinate would paint outside the photo.
        for axis in ("x_percent", "y_percent"):
            try:
                h[axis] = max(0.0, min(100.0, float(h.get(axis))))
            except (TypeError, ValueError):
                h[axis] = 50.0
        h.setdefault("area", "")
        h.setdefault("fix", "")
        h["visual_suggestions"] = [
            s for s in (h.get("visual_suggestions") or [])
            if isinstance(s, dict) and s.get("prompt") and s.get("caption")
        ][:3]
    overall = data.get("overall") if isinstance(data.get("overall"), dict) else {}
    score = overall.get("score")
    try:
        score = max(1, min(10, int(round(float(score)))))
    except (TypeError, ValueError):
        score = 6
    out = {
        "analyzable": bool(data.get("analyzable", True)),
        "note": str(data.get("note") or ""),
        "overall": {"summary": str(overall.get("summary") or ""), "score": score},
        "hotspots": hot[:6],
    }
    print(f"[qwen] /critique {time.time() - t0:.1f}s score={score} hotspots={len(out['hotspots'])}", flush=True)
    return out


@app.post("/slots")
async def slots(image: UploadFile = File(...), trends: str = Form(""),
                premium: bool = Form(False)):
    im = _shrink(await image.read(), MAX_EDGE_SINGLE)
    season, year = _season()
    trend_list = [t.strip() for t in trends.split("|") if t.strip()]
    trend_note = (f" CURRENT SEASON TRENDS (ground ideas in these when they suit the person): "
                  f"{' | '.join(trend_list)}." if trend_list else "")
    accessories = (
        "ACCESSORY STUDIO (premium): ALWAYS include three dedicated slots — 'glasses', 'watch' and "
        "'jewelry' — even when the person wears none. When the piece IS visible, item = its short "
        "description and the 4 ideas are distinct replacements. When NOT visible, item MUST be exactly "
        "'none' and the 4 ideas are pieces to ADD. Remaining small items (belt, cap, scarf, bag) group "
        "under a SINGLE 'accessories' entry, only when visible."
        if premium else
        "Group all accessories (watch, glasses, cap, jewellery, belt, bag) under a SINGLE 'accessories' entry."
    )
    prompt = (
        f"You are a current, up-to-date fashion stylist working in {season} {year}.{trend_note}\n"
        f"List ONLY the garment slots actually visible on the person, each slot at most ONCE. {accessories}\n"
        "For each slot: item = a short specific description of what they wear now (cut + colour + fabric); "
        "ideas = exactly 4 distinct alternatives. Each MUST be a genuinely different garment from what they "
        "wear now, and no two ideas may be near-duplicates (vary cut, colour, fabric, formality). "
        "ORDERED BEST-FIRST. Mark EXACTLY ONE idea recommended=true per slot.\n"
        "GENDER CONSISTENCY (hard rule): every idea MUST match the person's apparent gender presentation — "
        "never womenswear for a masculine-presenting person, nor menswear-only pieces for a feminine-presenting "
        "one; when unsure stay strictly unisex.\n"
        "why = ONE short sentence (max ~14 words) naming the alternative and the reason it works, framed as an "
        "option to try, not a criticism. No brands, stores, prices, clichés or exclamation marks.\n"
        f"slot must be one of: {', '.join(SLOT_NAMES)}.\n\n"
        'Return ONLY JSON: {"slots": [{"slot": string, "item": string, "ideas": '
        '[{"garment": string, "why": string, "recommended": bool}]}], '
        '"gender_presentation": "masculine"|"feminine"|"neutral"}\n\nCatalogue this outfit\'s slots.'
    )
    t0 = time.time()
    data = _ask_json(prompt, [im], 2000, 0.4)

    seen, clean = set(), []
    for s in (data.get("slots") or []):
        if not isinstance(s, dict):
            continue
        name = str(s.get("slot") or "").lower().strip()
        if name not in SLOT_NAMES or name in seen:
            continue                                   # enum + the "each slot once" rule
        ideas = [i for i in (s.get("ideas") or []) if isinstance(i, dict) and i.get("garment")][:4]
        if not ideas:
            continue
        if not any(i.get("recommended") for i in ideas):
            ideas[0]["recommended"] = True             # exactly-one-recommended invariant
        else:
            first = True
            for i in ideas:
                if i.get("recommended") and first:
                    first = False
                elif i.get("recommended"):
                    i["recommended"] = False
        seen.add(name)
        clean.append({"slot": name, "item": str(s.get("item") or ""), "ideas": ideas})
    gender = str(data.get("gender_presentation") or "").lower()
    if gender not in ("masculine", "feminine", "neutral"):
        gender = "neutral"
    print(f"[qwen] /slots {time.time() - t0:.1f}s slots={len(clean)} gender={gender}", flush=True)
    return {"slots": clean, "gender_presentation": gender}


@app.post("/same-person")
async def same_person(render: UploadFile = File(...), person: UploadFile = File(...)):
    a = _shrink(await render.read(), MAX_EDGE_MULTI)
    b = _shrink(await person.read(), MAX_EDGE_MULTI)
    prompt = (
        "The FIRST image is a full-body try-on render. The SECOND image is the reference person — it MAY be "
        "a cropped head/face shot, not a full body. Judge ONLY by the FACE and head: is it clearly the SAME "
        "individual? Answer same=false ONLY when the face is clearly a DIFFERENT person (different features, "
        "a generic fashion model, a swapped head). Different clothes, body framing, crop, lighting, pose or "
        "background are NOT a different person — and if the face is ambiguous or hard to compare, answer "
        'same=true (do not reject on uncertainty).\n\nReturn ONLY JSON: {"same": true|false}'
    )
    t0 = time.time()
    try:
        data = _ask_json(prompt, [a, b], 40, 0.0)
        same = data.get("same") is not False
    except HTTPException:
        same = True                                    # fail-open, like gemini.ts
    print(f"[qwen] /same-person {time.time() - t0:.1f}s same={same}", flush=True)
    return {"same": same}


@app.post("/validate")
async def validate(images: list[UploadFile] = File(...)):
    ims = [_shrink(await f.read(), MAX_EDGE_MULTI) for f in images]
    prompt = (
        f"You are validating AI-generated outfit try-on renders. For each of the {len(ims)} images, in order, "
        "return true ONLY if ALL hold: (1) it shows a photorealistic full-body person wearing an outfit — false "
        "for landscapes, objects, abstract images, or anything without a clearly visible person; (2) the outfit "
        "matches the person's own visible gender presentation; (3) the background is clean seamless white with "
        "no leftover fragments, fuzzy halos or cloud-like blobs.\n\n"
        'Return ONLY JSON: {"valid": [true|false, ...]} with exactly one entry per image.'
    )
    t0 = time.time()
    try:
        data = _ask_json(prompt, ims, 120, 0.0)
        v = data.get("valid") or []
    except HTTPException:
        v = []
    out = [bool(v[i]) if i < len(v) and isinstance(v[i], bool) else True for i in range(len(ims))]
    print(f"[qwen] /validate {time.time() - t0:.1f}s {out}", flush=True)
    return {"valid": out}


@app.post("/classify-item")
async def classify_item(image: UploadFile = File(...)):
    im = _shrink(await image.read(), MAX_EDGE_MULTI)
    prompt = (
        "Identify the single main clothing item in this photo. label = a short human name "
        "(e.g. 'navy wool blazer', 'white leather sneakers'). category = one of: "
        "top, bottom, outerwear, shoes, accessories, bag, dress. If unclear, best guess.\n\n"
        'Return ONLY JSON: {"label": string, "category": string}'
    )
    data = _ask_json(prompt, [im], 120, 0.2)
    cats = ("top", "bottom", "outerwear", "shoes", "accessories", "bag", "dress")
    cat = str(data.get("category") or "").lower().strip()
    return {"label": str(data.get("label") or "clothing item"),
            "category": cat if cat in cats else "accessories"}


@app.post("/body-profile")
async def body_profile(image: UploadFile = File(...), height_cm: float = Form(...)):
    im = _shrink(await image.read(), MAX_EDGE_SINGLE)
    prompt = (
        "You are a body-proportion analyst for a fashion styling app. You are NOT a medical or tailoring tool. "
        f"Given ONE full-body photo and the user's stated height of {height_cm:.0f} cm, infer styling-relevant "
        f"body data, using the height as a scale anchor.\n"
        "PROPORTIONS & BODY TYPE (shoulder-to-hip balance, torso-to-leg ratio, silhouette) are readable from a "
        "2D photo — report them normally. ABSOLUTE MEASUREMENTS cannot be measured from a photo: report them "
        "ONLY as plausible RANGES {min,max} with a confidence 0..1. Never output a single exact cm value.\n"
        "If the image is not a clear, single-person, full-body shot, set analyzable=false and say in 'note' "
        "exactly what photo is needed. Do not fabricate a profile.\n\n"
        'Return ONLY JSON: {"analyzable": bool, "note": string, "body_type": '
        '"rectangle"|"triangle"|"inverted_triangle"|"hourglass"|"oval"|"athletic", '
        '"proportions": {"shoulder_to_hip": "narrower"|"balanced"|"wider", '
        '"torso_to_leg": "short_torso"|"balanced"|"long_torso", "description": string}, '
        '"estimated_measurements": {"chest_cm": {"min": number, "max": number}, '
        '"waist_cm": {"min": number, "max": number}, "hip_cm": {"min": number, "max": number}, '
        '"inseam_cm": {"min": number, "max": number}}, "confidence": number, '
        '"styling_notes": [string]}'
    )
    t0 = time.time()
    data = _ask_json(prompt, [im], 900, 0.3)
    # The 4B model reliably nests shoulder_to_hip/torso_to_leg but hoists
    # `description` to the root (observed on the founder's photo). The EF writes
    # proportions verbatim into style_profiles, so relocate stray keys here
    # rather than teaching every consumer about two shapes.
    prop = data.get("proportions")
    if not isinstance(prop, dict):
        prop = {}
    for k in ("description", "shoulder_to_hip", "torso_to_leg"):
        if k not in prop and isinstance(data.get(k), str):
            prop[k] = data.pop(k)
    prop.setdefault("description", "")
    data["proportions"] = prop
    data["analyzable"] = bool(data.get("analyzable", True))
    print(f"[qwen] /body-profile {time.time() - t0:.1f}s type={data.get('body_type')}", flush=True)
    return data


@app.get("/")
async def ui():
    """Click-to-test bench: drop a photo, run any endpoint, see it rendered.
    Kept as a separate file so it can be edited without restarting the model."""
    return FileResponse(os.path.join(os.path.dirname(os.path.abspath(__file__)), "ui.html"))


@app.get("/fixtures/{name}")
async def fixture(name: str):
    """Sample photos for the bench's one-click test. Dev convenience only —
    the directory is gitignored (it holds real user photos)."""
    if "/" in name or ".." in name:
        raise HTTPException(400, "bad name")
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", name)
    if not os.path.isfile(path):
        raise HTTPException(404, "no such fixture")
    return FileResponse(path)


@app.get("/health")
async def health():
    return {"ok": _model is not None, "model": MODEL_ID}
