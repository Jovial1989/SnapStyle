// Gemini call + prompts/schemas. Mirrors backend/src/stylistPrompt.js (critique)
// and backend/src/visionProfile.js (body profiling).
// TRANSPORT NOTE (keep-alive): this runs on Deno (Supabase Edge Functions), not
// Node — `fetch` here pools and reuses TCP/TLS connections per origin within an
// isolate automatically (HTTP/1.1 keep-alive / H2). No https.Agent exists or is
// needed; sequential Gemini calls in one invocation skip the handshake already.
const API_BASE = "https://generativelanguage.googleapis.com/v1beta/models";

export const CRITIQUE_PROMPT_VERSION = "stylist-v2-hotspots";
export const PROFILE_PROMPT_VERSION = "bodyprofile-v1";

export type Inline = { data: string; mimeType: string };

/** Low-level generateContent call. Retries transient failures (5xx, network,
 * empty/invalid-JSON responses) with backoff — Gemini vision 502/overload is
 * common and was surfacing as "analysis failed". 4xx (bad request) fails fast. */
/** INTERNAL MODEL ROUTING (no new vendors): heavy vision/planning stays on
 * the standard flash; bounded JSON micro-tasks (validators, QA verdicts,
 * compare bullets, closed-vocabulary classification) run on the LITE tier —
 * materially cheaper + faster time-to-first-token, same native JSON mode.
 * NOTE: "gemini-1.5-flash" is a RETIRED model id (dead endpoint) — flash-lite
 * is its current-generation equivalent. Both routes are env-overridable. */
const textModel = () => Deno.env.get("GEMINI_MODEL") ?? "gemini-2.5-flash";
// gemini-2.5-flash-lite got RETIRED for this key (404 "no longer available
// to new users") on 20.07.2026 — it silently killed compare-looks AND the
// render validator. 3.1-flash-lite is the living GA successor.
const liteModel = () => Deno.env.get("GEMINI_LITE_MODEL") ?? "gemini-3.1-flash-lite";

async function generate(model: string, body: unknown) {
  const key = Deno.env.get("GEMINI_API_KEY");
  if (!key) throw new Error("GEMINI_API_KEY missing");
  let lastErr: Error | null = null;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      const res = await fetch(`${API_BASE}/${model}:generateContent?key=${key}`, {
        method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
      });
      if (!res.ok) {
        const detail = (await res.text()).slice(0, 300);
        const err = new Error(`gemini ${res.status}: ${detail}`);
        if (res.status < 500 && res.status !== 429) throw err; // client error → don't retry
        lastErr = err; // 5xx / 429 → retry
      } else {
        const j = await res.json();
        const text = j?.candidates?.[0]?.content?.parts?.[0]?.text;
        if (!text) { lastErr = new Error("gemini: no content"); }
        else {
          const parsed = JSON.parse(text); // may throw on malformed JSON → retry below
          logImageUsage(model, j, "text"); // account only successful calls
          return parsed;
        }
      }
    } catch (e) {
      lastErr = e as Error;
      if ((lastErr.message ?? "").startsWith("gemini 4")) throw lastErr; // client error bubbled
    }
    if (attempt < 2) await new Promise((r) => setTimeout(r, 500 * (attempt + 1)));
  }
  throw lastErr ?? new Error("gemini: failed");
}

// ── Flow 1: outfit critique (spatial hotspots) ──────────────────────────────
export const CRITIQUE_SYSTEM = `You are Looktok — an expert personal stylist reviewing a photo of someone's outfit and fit.

VOICE — a sharp friend who tells you the truth: specific, human, honest. Give REAL praise when it's earned (not empty flattery), and be direct only about things that genuinely detract. No exclamation marks. Never use marketing clichés ('elevate', 'unleash', 'effortless', 'versatile', 'staple', 'game-changer', 'good to great') — name the concrete reason instead.

CORE RULE — DON'T MANUFACTURE PROBLEMS. If a piece fits well, SAY it fits (severity 'good') and move on. If the whole outfit works, lead with a confident positive verdict and do NOT pick it apart — suggestions then become "what else you could try", not corrections. Only call something an issue when it actually hurts the look.

OUTPUT MODEL — SPATIAL HOTSPOTS: return an "overall" verdict + "hotspots". Each hotspot is a pin ON the photo with x_percent/y_percent (0–100, top-left origin).

RULES:
- overall.summary: ONE short sentence. Lead with what works; add at most one change that genuinely matters. Never a pile-on.
- overall.score is an INTEGER 1–10 (never a 0–100 percentage).
- 3–6 hotspots. When the fit is good, most are 'good'; 'tip' = an optional idea ("what else"), 'issue' ONLY for things that actually detract. Never all-issues on a look that works.
- title ≤4 words; detail = one sentence; fix = one brand-agnostic action (NEVER brands/stores/prices/links).
- severity: "issue" | "tip" | "good".
- visual_suggestions: 2–3 per hotspot as brand-agnostic image-gen prompts { prompt, caption, alt_text }. No URLs/brands/prices.
- If not a usable full-outfit photo: analyzable=false, note what's needed, no hotspots.
Return ONLY JSON matching the schema.`;

const CRITIQUE_SCHEMA = {
  type: "OBJECT",
  properties: {
    analyzable: { type: "BOOLEAN" },
    note: { type: "STRING" },
    overall: { type: "OBJECT", properties: { summary: { type: "STRING" }, score: { type: "INTEGER" } }, required: ["summary", "score"] },
    hotspots: {
      type: "ARRAY",
      items: {
        type: "OBJECT",
        properties: {
          x_percent: { type: "NUMBER" }, y_percent: { type: "NUMBER" },
          area: { type: "STRING" },
          severity: { type: "STRING", enum: ["issue", "tip", "good"] },
          title: { type: "STRING" }, detail: { type: "STRING" }, fix: { type: "STRING" },
          visual_suggestions: {
            type: "ARRAY",
            items: { type: "OBJECT", properties: { prompt: { type: "STRING" }, caption: { type: "STRING" }, alt_text: { type: "STRING" } }, required: ["prompt", "caption"] },
          },
        },
        required: ["x_percent", "y_percent", "severity", "title", "detail"],
      },
    },
  },
  required: ["analyzable", "overall", "hotspots"],
};

export async function analyzeFit(image: Inline, profile?: unknown) {
  const model = textModel();
  const ctx = profile && Object.keys(profile as object).length
    ? `User profile (factor into proportion/cut advice):\n${JSON.stringify(profile)}`
    : "No user profile provided. Analyze from the photo alone.";
  const analysis = await generate(model, {
    systemInstruction: { parts: [{ text: CRITIQUE_SYSTEM }] },
    contents: [{ role: "user", parts: [{ text: ctx }, { inlineData: { mimeType: image.mimeType, data: image.data } }] }],
    generationConfig: { responseMimeType: "application/json", responseSchema: CRITIQUE_SCHEMA, temperature: 0.6 },
  });
  return { analysis, model, promptVersion: CRITIQUE_PROMPT_VERSION };
}

// ── Onboarding: body profiling (proportions reliable, measurements as ranges) ─
export function profileSystem(heightCm: number) {
  return `You are a body-proportion analyst for a fashion styling app. You are NOT a medical or tailoring tool.
Given ONE full-body photo and the user's stated height of ${heightCm} cm, infer styling-relevant body data.

USE THE HEIGHT AS A SCALE ANCHOR: estimate everything relative to ${heightCm} cm.

WHAT IS RELIABLE vs NOT — respect this honestly:
- PROPORTIONS & BODY TYPE (shoulder-to-hip balance, torso-to-leg ratio, silhouette shape) are
  readable from a 2D photo → report them with normal confidence.
- ABSOLUTE MEASUREMENTS (chest/waist/hip/inseam in cm) CANNOT be measured from a photo. Report them
  ONLY as a plausible RANGE {min,max} plus a confidence 0..1. NEVER output a single exact cm value as if measured.

If the image is not a clear, single-person, full-body shot (cropped, blurry, multiple people, not a person),
set analyzable=false and explain in "note" exactly what photo is needed. Do not fabricate a profile.

Return ONLY JSON matching the provided schema.`;
}

const PROFILE_SCHEMA = {
  type: "OBJECT",
  properties: {
    analyzable: { type: "BOOLEAN" },
    note: { type: "STRING" },
    body_type: { type: "STRING", enum: ["rectangle", "triangle", "inverted_triangle", "hourglass", "oval", "athletic"] },
    proportions: {
      type: "OBJECT",
      properties: {
        shoulder_to_hip: { type: "STRING", enum: ["narrower", "balanced", "wider"] },
        torso_to_leg: { type: "STRING", enum: ["short_torso", "balanced", "long_torso"] },
        description: { type: "STRING" },
      },
      required: ["description"],
    },
    estimated_measurements: {
      type: "OBJECT",
      properties: {
        chest_cm: { type: "OBJECT", properties: { min: { type: "NUMBER" }, max: { type: "NUMBER" } } },
        waist_cm: { type: "OBJECT", properties: { min: { type: "NUMBER" }, max: { type: "NUMBER" } } },
        hip_cm: { type: "OBJECT", properties: { min: { type: "NUMBER" }, max: { type: "NUMBER" } } },
        inseam_cm: { type: "OBJECT", properties: { min: { type: "NUMBER" }, max: { type: "NUMBER" } } },
      },
    },
    confidence: { type: "NUMBER" },
    styling_notes: { type: "ARRAY", items: { type: "STRING" } },
  },
  required: ["analyzable", "proportions"],
};

export async function analyzeBodyProfile(image: Inline, heightCm: number) {
  const model = Deno.env.get("GEMINI_MODEL_PROFILE") ?? "gemini-2.5-pro";
  const profile = await generate(model, {
    systemInstruction: { parts: [{ text: profileSystem(heightCm) }] },
    contents: [{ role: "user", parts: [{ text: `Analyze this full-body photo. Stated height: ${heightCm} cm.` }, { inlineData: { mimeType: image.mimeType, data: image.data } }] }],
    generationConfig: { responseMimeType: "application/json", responseSchema: PROFILE_SCHEMA, temperature: 0.3 },
  });
  return { profile, model, promptVersion: PROFILE_PROMPT_VERSION };
}

const ITEM_SCHEMA = {
  type: "OBJECT",
  properties: {
    label: { type: "STRING" },
    category: { type: "STRING", enum: ["top", "bottom", "outerwear", "shoes", "accessory", "dress", "other"] },
  },
  required: ["label", "category"],
};

/** Classify a single wardrobe item photo → short label + category. */
export async function classifyItem(image: Inline): Promise<{ label: string; category: string }> {
  const model = liteModel();
  return await generate(model, {
    systemInstruction: { parts: [{ text: "Identify the single main clothing item in this photo. label = a short human name (e.g. 'navy wool blazer', 'white leather sneakers'). category from the enum. If unclear, best guess." }] },
    contents: [{ role: "user", parts: [{ text: "Classify this clothing item." }, { inlineData: { mimeType: image.mimeType, data: image.data } }] }],
    generationConfig: { responseMimeType: "application/json", responseSchema: ITEM_SCHEMA, temperature: 0.2 },
  });
}

// ── Vibe Check: visual "Style DNA" extraction (SDD §14.12) ──────────────────
export const STYLE_DNA_VERSION = "styledna-v1";
const DNA_SCHEMA = {
  type: "OBJECT",
  properties: {
    fit_preference: { type: "STRING", enum: ["slim", "regular", "relaxed", "oversized"] },
    color_palette: { type: "ARRAY", items: { type: "STRING" } }, // 3–5 concrete colours
    aesthetic_tag: { type: "STRING" }, // 1–3 words, e.g. "Elevated Minimalism", "Old-money", "Streetwear"
    keywords: { type: "ARRAY", items: { type: "STRING" } }, // 3–6 styling cues
    summary: { type: "STRING" }, // one sentence, the decoded styling rule
  },
  required: ["fit_preference", "color_palette", "aesthetic_tag", "keywords", "summary"],
};

/** Decode 1–3 reference/moodboard images into a Style DNA. Vision, one call. */
export async function extractStyleDna(images: Inline[]): Promise<{
  fit_preference: string; color_palette: string[]; aesthetic_tag: string; keywords: string[]; summary: string;
}> {
  const model = textModel();
  return await generate(model, {
    systemInstruction: { parts: [{ text: "You are a fashion editor decoding someone's taste from the reference images they saved (their own looks or moodboard screenshots). Extract the STYLE DNA — the recurring styling rules across the images, NOT a description of each photo. fit_preference from the enum (how fitted they like clothes). color_palette = 3–5 concrete colours they gravitate to (e.g. 'ecru', 'charcoal', 'olive'). aesthetic_tag = 1–3 words naming the overall vibe (e.g. 'Elevated Minimalism', 'Old-money', 'Utilitarian', 'Streetwear'). keywords = 3–6 concrete styling cues (silhouettes, fabrics, details). summary = ONE sentence stating the decoded rule, sharp-friend voice, no clichés ('elevate', 'versatile', 'effortless') and no exclamation marks." }] },
    contents: [{ role: "user", parts: [
      { text: "Decode the style DNA across these reference images." },
      ...images.map((im) => ({ inlineData: { mimeType: im.mimeType, data: im.data } })),
    ] }],
    generationConfig: { responseMimeType: "application/json", responseSchema: DNA_SCHEMA, temperature: 0.3 },
  });
}

// ── P0-1: outfit slot detection (sectioned avatar editor) ───────────────────
// glasses/watch/jewelry are PREMIUM-only slots — the accessory studio splits
// them out of the grouped 'accessories' entry (schema allows them always;
// the prompt decides whether the model may use them).

/** The slots system prompt, shared by the Gemini and OpenAI branches so the
 * wording never drifts between providers. */
export function slotsSystem(trends: string[] = [], premium = false): string {
  const trendNote = trends.length
    ? ` CURRENT GROUNDED TRENDS (this season, from live fashion sources): ${trends.join(" | ")}. Let these steer your ideas WHERE they fit this person's build and gender — a trend never overrides fit, gender consistency or the occasion.`
    : "";
  const now = new Date();
  const m = now.getUTCMonth();
  const season = (m <= 1 || m === 11) ? "winter" : m <= 4 ? "spring" : m <= 7 ? "summer" : "autumn";
  return `You are a current, up-to-date fashion stylist working in ${season} ${now.getUTCFullYear()} — aware of what reads modern and on-trend right now, not dated. ${trends.length ? `CURRENT SEASON TRENDS (ground your ideas in these when they suit the person): ${trends.join(" | ")}. ` : ""}List ONLY the garment slots actually visible on the person, and return EACH slot at most ONCE — never repeat a slot; ${premium
      ? "ACCESSORY STUDIO (premium): ALWAYS include three dedicated slots — 'glasses', 'watch' and 'jewelry' — even when the person wears none of that kind. When the piece IS visible, item = its short description and the 4 ideas are distinct replacements. When it is NOT visible, item MUST be exactly 'none' and the 4 ideas are pieces to ADD (glasses: sunglasses or optical frames; watch: wristwatches; jewelry: necklaces, chains or bracelets) — matched to the outfit's formality and the person's gender presentation, same rules as garments (brand-agnostic, distinct, best-first). Remaining small items (belt, cap, scarf, bag) group under a SINGLE 'accessories' entry, only when visible."
      : "group all accessories (watch, glasses, cap, jewellery, belt, bag) under a SINGLE 'accessories' entry."} For each: item = a short, specific description of what they wear now (cut + color + fabric); ideas = exactly 4 distinct alternatives for that slot. Each MUST be a genuinely different garment from what they wear now — never repeat, restate or barely-tweak the current piece, and no two ideas may be near-duplicates of each other (vary cut, colour, fabric and formality). ORDERED BEST-FIRST (your strongest, most on-trend recommendation first). Mark EXACTLY ONE idea per slot with recommended=true (your single top pick) and all the others recommended=false. GENDER CONSISTENCY (hard rule): every idea MUST match the person's apparent gender presentation in the photo — NEVER propose womenswear (dresses, skirts, blouses, scoop-neck tops, heels) for a masculine-presenting person, nor menswear-only pieces for a feminine-presenting person; when unsure, stay strictly unisex. Each idea = { garment: brand-agnostic description (cut + color + fabric, NEVER brands/stores/prices), why: ONE short sentence (max ~14 words) that NAMES this alternative and gives the reason it works, e.g. "Slim khaki chinos for a cleaner leg line." Frame it as an option to try, not a criticism of what they currently wear. Concrete, sharp-friend voice, no clichés like 'elevate' or 'versatile', no exclamation marks. recommended: boolean }. Also return gender_presentation: how the person visibly presents in the photo (masculine/feminine/neutral) — downstream renders use it to keep suggestions gender-consistent.${trendNote}`;
}

export const SLOTS = ["top", "bottom", "outerwear", "shoes", "belt", "accessories", "bag", "glasses", "watch", "jewelry"];
const SLOTS_SCHEMA = {
  type: "OBJECT",
  properties: {
    slots: {
      type: "ARRAY",
      items: {
        type: "OBJECT",
        properties: {
          slot: { type: "STRING", enum: SLOTS },
          item: { type: "STRING" },
          ideas: {
            type: "ARRAY",
            items: {
              type: "OBJECT",
              properties: {
                garment: { type: "STRING" },
                why: { type: "STRING" },
                recommended: { type: "BOOLEAN" },
              },
              required: ["garment", "why", "recommended"],
            },
          },
        },
        required: ["slot", "item", "ideas"],
      },
    },
    gender_presentation: { type: "STRING", enum: ["masculine", "feminine", "neutral"] },
  },
  required: ["slots", "gender_presentation"],
};

/** Detect which garment slots exist on the person + 6–7 brand-agnostic
 * alternative ideas per slot. One flash call — powers the look editor. */
export async function detectOutfitSlots(image: Inline, trends: string[] = [], premium = false): Promise<{ slots: { slot: string; item: string; ideas: { garment: string; why: string; recommended: boolean }[] }[]; gender_presentation?: string }> {
  const model = textModel();
  return await generate(model, {
    systemInstruction: { parts: [{ text: slotsSystem(trends, premium) }] },
    contents: [{ role: "user", parts: [{ text: "Catalogue this outfit's slots." }, { inlineData: { mimeType: image.mimeType, data: image.data } }] }],
    generationConfig: { responseMimeType: "application/json", responseSchema: SLOTS_SCHEMA, temperature: 0.4 },
  });
}

// ── P0-2: shopping verdict (in-store item check — advice ONLY, no commerce) ──
const SHOP_SCHEMA = {
  type: "OBJECT",
  properties: {
    verdict: { type: "STRING", enum: ["buy", "skip", "try_other"] },
    reason: { type: "STRING" },
    item: { type: "STRING" },
    body_fit: {
      type: "OBJECT",
      properties: { works: { type: "BOOLEAN" }, note: { type: "STRING" } },
      required: ["works", "note"],
    },
    wardrobe_matches: {
      type: "ARRAY",
      items: { type: "OBJECT", properties: { item: { type: "STRING" }, why: { type: "STRING" } }, required: ["item", "why"] },
    },
    generic_pairings: { type: "ARRAY", items: { type: "STRING" } },
    look_for: { type: "ARRAY", items: { type: "STRING" } },
  },
  required: ["verdict", "reason", "item", "body_fit"],
};

/** Blunt in-store verdict on a garment photo. Uses the body profile + wardrobe
 * labels when available. Advice only — never brands, stores, prices, links. */
export async function shoppingVerdict(image: Inline, bodyProfile: unknown | null, wardrobe: string[], category?: string) {
  const model = textModel();
  const ctx = [
    category ? `The shopper says this item is a ${category}. Judge it AS a ${category}.` : "",
    bodyProfile ? `Shopper's body profile: ${JSON.stringify(bodyProfile)}.` : "No body profile available — judge fit potential from the garment itself.",
    wardrobe.length
      ? `Shopper's wardrobe (their ACTUAL clothes): ${wardrobe.join("; ")}. Pick the top 3 wardrobe_matches from THIS LIST ONLY (verbatim labels) and say why each pairing works. Leave generic_pairings empty.`
      : "Their wardrobe is empty. Leave wardrobe_matches empty and give exactly 3 generic_pairings (brand-agnostic garment descriptions that would pair well).",
  ].join(" ");
  return await generate(model, {
    systemInstruction: { parts: [{ text: "You are a blunt, honest stylist giving a fast in-store verdict on a garment the shopper is holding. verdict: buy | skip | try_other (different size or color). reason: ONE specific sentence, like a sharp friend — honest over flattering, no exclamation marks. Never use marketing clichés ('elevate', 'unleash', 'effortless', 'versatile', 'staple', 'game-changer'); say the concrete reason instead. item: short description of the garment. body_fit: does this cut work for their build, one specific note. look_for: when the verdict is NOT 'buy', give 2-3 concrete, brand-agnostic rules for what to look for INSTEAD, tailored to their body profile (cut, rise, fabric, neckline — e.g. 'a mid-rise straight leg to balance your torso'); empty when it's a buy. NEVER mention brands, stores, prices, links or buying anywhere except the verdict field. This is styling advice, not commerce." }] },
    contents: [{ role: "user", parts: [{ text: ctx }, { inlineData: { mimeType: image.mimeType, data: image.data } }] }],
    generationConfig: { responseMimeType: "application/json", responseSchema: SHOP_SCHEMA, temperature: 0.4 },
  });
}

const RENDER_VALID_SCHEMA = {
  type: "OBJECT",
  properties: { valid: { type: "ARRAY", items: { type: "BOOLEAN" } } },
  required: ["valid"],
};

/** Validate a batch of try-on renders in ONE cheap flash call: true per image
 * only if it shows a photorealistic full-body person wearing an outfit (no
 * landscapes, abstracts, or missing-person failures). Fail-open on error. */
export async function validateLookImages(images: Inline[]): Promise<boolean[]> {
  const model = liteModel();
  const parts = [
    { text: `You are validating AI-generated outfit try-on renders. For each of the ${images.length} images, in order, return true ONLY if BOTH hold: (1) it shows a photorealistic full-body person wearing an outfit — false for landscapes, objects, abstract images, or anything without a clearly visible person; (2) the outfit matches the person's own visible gender presentation — a masculine-presenting person rendered in womenswear (dress, skirt, camisole/spaghetti-strap top, blouse, heels) is false, and vice versa; (3) the background is clean seamless white with NO leftover fragments, fuzzy halos or cloud-like blobs (especially above the head).` },
    ...images.map((i) => ({ inlineData: { mimeType: i.mimeType, data: i.data } })),
  ];
  const r = await generate(model, {
    contents: [{ role: "user", parts }],
    generationConfig: { responseMimeType: "application/json", responseSchema: RENDER_VALID_SCHEMA, temperature: 0 },
  });
  const v = (r?.valid ?? []) as boolean[];
  return images.map((_, i) => v[i] !== false); // missing verdicts pass (fail-open)
}

/** PRE-PAINT identity gate: is the render THE SAME HUMAN as the reference?
 * Lite tier (~1s) — a swapped face/build is a coarse failure it catches well.
 * Used BEFORE a render row flips to completed, so a wrong person is
 * regenerated silently and never reaches the user's screen. */
export async function samePerson(render: Inline, person: Inline): Promise<boolean> {
  const r = await generate(liteModel(), {
    contents: [{
      role: "user",
      parts: [
        {
          text: "The FIRST image is a full-body try-on render. The SECOND image is the reference person — it MAY be a cropped head/face shot, not a full body. Judge ONLY by the FACE and head: is it clearly the SAME individual? " +
            "Answer same=false ONLY when the face is clearly a DIFFERENT person (different features, a generic fashion model, a swapped head). " +
            "Different clothes, body framing, crop, lighting, pose or background are NOT a different person — and if the face is ambiguous or hard to compare, answer same=true (do not reject on uncertainty). Answer strictly.",
        },
        { inlineData: { mimeType: render.mimeType, data: render.data } },
        { inlineData: { mimeType: person.mimeType, data: person.data } },
      ],
    }],
    generationConfig: {
      responseMimeType: "application/json",
      responseSchema: { type: "OBJECT", properties: { same: { type: "BOOLEAN" } }, required: ["same"] },
      temperature: 0,
    },
  });
  return (r?.same as boolean) !== false;
}

export const IDENTITY_RETRY_NOTE =
  " NOTE: a previous attempt REPLACED the person with a DIFFERENT human — that is the worst possible failure. Regenerate with THE EXACT person from the person photo: copy the face, head, hairline, build and skin tone pixel-faithfully. The face in the output must be recognizably the same individual.";

/** QA gate for try-on edits: did the render actually APPLY the requested
 * garment change? The image model stochastically drifts back to the source
 * photo's garment (~1 in 5 renders) — a cheap flash check catches it so the
 * caller can retry once instead of showing the user a no-op. Fail-open. */
export type EditVerdict = { applied: boolean; reason: string };

export async function verifyEditApplied(out: Inline, editSummary: string, refs: Inline[] = [], person?: Inline): Promise<EditVerdict> {
  // gemini-3.1-flash-lite + 512 thinking: the OLD 2.5-lite waved recolors
  // through; the 3.1 generation with bounded thought holds discrimination at
  // sub-second latency (speed complaint 22.07).
  const model = liteModel();
  try {
    const r = await generate(model, {
      contents: [{
        role: "user",
        parts: [
          {
            text: `You are a STRICT QA checker for an AI outfit try-on edit. The requested edit: "${editSummary}". The FIRST image is the RENDER to judge.${
              person ? " The SECOND image is the CLIENT's own photo — the identity reference." : ""
            }${
              refs.length ? ` The remaining ${refs.length} image(s) are PRODUCT PHOTOS of the exact garment(s) that must be worn.` : ""
            } Judge harshly — applied=true ONLY if ALL checks pass:${
              person ? " (0) IDENTITY: the person in the render is THE SAME person as the client photo — same face, same build, same skin tone; a different, younger, slimmer or generic fashion model, or a cropped/replaced head, is an automatic applied=false;" : ""
            } (1) every requested garment is visibly worn with its EXACT stated construction: sleeve length (sleeveless vs short vs long — inspect the shoulders and upper arms), garment length, garment type, color/pattern. The most common garment failure: the new garment merely REPAINTED onto the ORIGINAL garment's cut — e.g. the description or reference photo has SHORT SLEEVES but the rendered top is SLEEVELESS with bare shoulders → applied=false.${
              refs.length ? " If the worn garment's construction differs from its reference photo in ANY structural way (sleeves, collar, length), applied=false." : ""
            } (2) CUT-INHERITANCE${
              person ? " (compare with the client photo)" : ""
            }: if the rendered garment's silhouette matches the OUTGOING garment the client was wearing (e.g. same sleeveless cut) while the requested garment is structurally different, the model merely recolored the old garment — applied=false. Also verify tuck instructions when present (tucked = hem inside the waistband, waistband visible; untucked = hem hanging over it). (4) TUCK DEFAULT: unless the edit explicitly requests tucking, the top must be worn UNTUCKED — hem hanging over the waistband; an unrequested tuck → applied=false. (5) FRAMING: the render must be full-body head-to-toe — the person's BOTH feet (or shoes) fully visible above the bottom edge of the image; feet cut off by the frame or missing → applied=false. (6) BACKGROUND: the whole background must be ONE flat uniform pure-white — any leftover patch or fragment of a real scene (wall, floor, grey rectangle), any cutout halo or fuzzy matte edge around the head/shoulders/arms → applied=false. When applied=false, reason = ONE short sentence naming the exact failure (e.g. "top rendered sleeveless but the reference has short sleeves" or "different person than the client photo"). Answer strictly.`,
          },
          { inlineData: { mimeType: out.mimeType, data: out.data } },
          ...(person ? [{ inlineData: { mimeType: person.mimeType, data: person.data } }] : []),
          ...refs.map((e) => ({ inlineData: { mimeType: e.mimeType, data: e.data } })),
        ],
      }],
      generationConfig: {
        responseMimeType: "application/json",
        responseSchema: {
          type: "OBJECT",
          properties: {
            applied: { type: "BOOLEAN" },
            reason: { type: "STRING" }, // ≤1 sentence: WHAT failed (empty when applied)
          },
          required: ["applied"],
        },
        temperature: 0,
        thinkingConfig: { thinkingBudget: 512 }, // enough thought to catch cut-inheritance; still fast
      },
    });
    return {
      applied: (r?.applied as boolean) !== false,
      reason: String(r?.reason ?? ""),
    };
  } catch (e) {
    // Verification must never block a render — but the caller must KNOW this
    // was a fail-open (never cache an unverified render).
    throw e;
  }
}

/** Cost audit: log + persist token usage for EVERY Gemini request (unit
 * economics ledger `gemini_usage`, service-role write, fire-and-forget).
 * Never throws — accounting must not break generation. */
function logImageUsage(model: string, j: unknown, kind = "image") {
  try {
    const u = (j as { usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number; totalTokenCount?: number } }).usageMetadata ?? {};
    const parts = (j as { candidates?: { content?: { parts?: { inlineData?: unknown }[] } }[] }).candidates?.[0]?.content?.parts ?? [];
    const images = kind === "image" ? parts.filter((p) => p.inlineData).length : 0;
    const out = u.candidatesTokenCount ?? 0;
    console.log(`[gemini-usage][${kind}][${model}] images=${images} prompt=${u.promptTokenCount ?? 0} output=${out} total=${u.totalTokenCount ?? 0}`);
    import("./supabase.ts").then(({ admin }) =>
      admin().from("gemini_usage").insert({
        kind, model, images,
        prompt_tokens: u.promptTokenCount ?? 0,
        output_tokens: out,
        total_tokens: u.totalTokenCount ?? 0,
      }).then(({ error }) => { if (error) console.error("[gemini-usage] insert", error.message); })
    ).catch(() => {});
  } catch { /* never break generation over accounting */ }
}

/** Exponential backoff with FULL JITTER around a fetch. Retries 429 (rate
 * limit) / 5xx / network errors, honors Retry-After, caps at ~16s per wait.
 * The async fan-out fires 5 concurrent image renders — exactly the burst that
 * trips Gemini's per-minute 429s; jitter de-synchronizes the retries so the
 * workers don't stampede the limiter again in lockstep. */
async function backoffFetch(label: string, doFetch: () => Promise<Response>, attempts = 4): Promise<Response> {
  for (let i = 0; ; i++) {
    let res: Response | null = null;
    let err: Error | null = null;
    try {
      res = await doFetch();
    } catch (e) {
      err = e as Error;
    }
    if (res?.ok) return res;
    const status = res?.status ?? 0;
    const retriable = err !== null || status === 429 || status >= 500;
    if (!retriable || i >= attempts - 1) {
      const body = res ? (await res.text()).slice(0, 300) : (err?.message ?? "");
      throw new Error(`${label} ${status || "network"}: ${body}`);
    }
    const retryAfter = res ? Number(res.headers.get("retry-after") ?? 0) * 1000 : 0;
    const delay = Math.max(retryAfter, Math.random() * Math.min(16_000, 1000 * 2 ** i));
    if (res) await res.body?.cancel().catch(() => {});
    console.log(`[backoff][${label}] ${status || err?.message} — attempt ${i + 1}/${attempts}, waiting ${Math.round(delay)}ms`);
    await new Promise((r) => setTimeout(r, delay));
  }
}

/** Image edit/generation (Journey B try-on): dress the person per `prompt`,
 * preserving identity. Returns the generated image inline. Synchronous. */
export async function generateLookImage(
  person: Inline,
  prompt: string,
  extra: Inline[] = [],
  opts: { fallbackPrompt?: string } = {},
): Promise<Inline> {
  const model = Deno.env.get("GEMINI_IMAGE_MODEL") ?? "gemini-2.5-flash-image";
  const key = Deno.env.get("GEMINI_API_KEY");
  if (!key) throw new Error("GEMINI_API_KEY missing");
  const bodyFor = (p: string) => JSON.stringify({
    contents: [{
      role: "user",
      parts: [
        { text: p },
        { inlineData: { mimeType: person.mimeType, data: person.data } },
        ...extra.map((e) => ({ inlineData: { mimeType: e.mimeType, data: e.data } })),
      ],
    }],
    // imageConfig: portrait 2:3 fits full-body looks. NOTE (verified live):
    // gemini-2.5-flash-image bills a FLAT 1290 output tokens per image at any
    // aspect/size — no 512px tier exists on this model (imageSize is
    // gemini-3-pro-image only), so output-token cost can't be reduced here;
    // the savings come from smaller INPUTS and fewer calls.
    generationConfig: { responseModalities: ["IMAGE"], imageConfig: { aspectRatio: "2:3" } },
  });
  // NO-IMAGE RESILIENCE: backoffFetch handles HTTP 429/5xx, but Gemini also
  // returns a 200 with NO image part (finishReason IMAGE_OTHER / IMAGE_SAFETY /
  // empty) — this "dies mid-swap" and surfaced as a hard error. Two causes:
  // transient capacity, AND an over-long prompt the image model gives up on.
  // So attempt 1 = the full prompt; attempts 2-3 = the COMPACT fallback (much
  // likelier to render). Only failures pay the extra wall-clock.
  const prompts = [prompt, opts.fallbackPrompt ?? prompt, opts.fallbackPrompt ?? prompt];
  let lastReason = "";
  for (let attempt = 0; attempt < prompts.length; attempt++) {
    const res = await backoffFetch("gemini-image", () => fetch(`${API_BASE}/${model}:generateContent?key=${key}`, {
      method: "POST", headers: { "Content-Type": "application/json" }, body: bodyFor(prompts[attempt]),
    }));
    const j = await res.json();
    logImageUsage(model, j); // EF name is in the Supabase log stream; model tags the call
    const parts = j?.candidates?.[0]?.content?.parts ?? [];
    const d = parts.find((p: { inlineData?: { data?: string; mimeType?: string } }) => p.inlineData)?.inlineData;
    if (d?.data) return { mimeType: d.mimeType ?? "image/png", data: d.data };
    lastReason = String(j?.candidates?.[0]?.finishReason ?? j?.promptFeedback?.blockReason ?? "empty");
    console.warn(`[gemini-image] no image (attempt ${attempt + 1}/${prompts.length}, reason=${lastReason})`);
    if (attempt < prompts.length - 1) await new Promise((r) => setTimeout(r, 400 + Math.random() * 700));
  }
  throw new Error(`gemini-image: no image in response (${lastReason})`);
}

/** Text-to-image generation (NO source person) — used for the generic archetype
 * "muse" imagery. The prompt must specify an anonymous, non-identifiable model. */
export async function generateImage(prompt: string): Promise<Inline> {
  const model = Deno.env.get("GEMINI_IMAGE_MODEL") ?? "gemini-2.5-flash-image";
  const key = Deno.env.get("GEMINI_API_KEY");
  if (!key) throw new Error("GEMINI_API_KEY missing");
  const res = await backoffFetch("gemini-image", () => fetch(`${API_BASE}/${model}:generateContent?key=${key}`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      contents: [{ role: "user", parts: [{ text: prompt }] }],
      // imageConfig: portrait 2:3 fits full-body looks. NOTE (verified live):
      // gemini-2.5-flash-image bills a FLAT 1290 output tokens per image at any
      // aspect/size — no 512px tier exists on this model (imageSize is
      // gemini-3-pro-image only), so output-token cost can't be reduced here;
      // the savings come from smaller INPUTS and fewer calls.
      generationConfig: { responseModalities: ["IMAGE"], imageConfig: { aspectRatio: "2:3" } },
    }),
  }));
  const j = await res.json();
  logImageUsage(model, j); // EF name is in the Supabase log stream; model tags the call
  const parts = j?.candidates?.[0]?.content?.parts ?? [];
  const d = parts.find((p: { inlineData?: { data?: string; mimeType?: string } }) => p.inlineData)?.inlineData;
  if (!d?.data) throw new Error("gemini-image: no image in response");
  return { mimeType: d.mimeType ?? "image/png", data: d.data };
}

// ── Look planner (3-2-2 recommendation engine) ──────────────────────────────
const PLAN_SCHEMA = {
  type: "OBJECT",
  properties: {
    gender_presentation: { type: "STRING", enum: ["masculine", "feminine", "neutral"] },
    looks: {
      type: "ARRAY",
      items: {
        type: "OBJECT",
        properties: {
          tier: { type: "STRING", enum: ["inspiration", "wardrobe_mix", "affiliate"] },
          title: { type: "STRING" },
          garments: { type: "ARRAY", items: { type: "STRING" } },
          wardrobe_used: { type: "ARRAY", items: { type: "STRING" } },
          affiliate_ids: { type: "ARRAY", items: { type: "STRING" } },
        },
        required: ["tier", "title", "garments"],
      },
    },
  },
  required: ["gender_presentation", "looks"],
};

export const PLAN_SYSTEM = `You are the outfit recommendation engine of a fashion app. Plan a set of complete outfits for the given occasion and person, as STRICT JSON matching the schema.

GENDER PRESENTATION — RULE #1, BEFORE ANYTHING ELSE: look at the person photo (the attached image) and set gender_presentation (masculine/feminine/neutral). EVERY garment in EVERY look MUST match it. For a masculine-presenting person, womenswear is BANNED: no dresses, no skirts, no camisoles or spaghetti-strap tops, no blouses, no heels, no shirt-dresses. For a feminine-presenting person, ban menswear-only pieces likewise. If no photo is attached or you are unsure, set "neutral" and plan STRICTLY unisex pieces. A single cross-gender garment makes the whole plan a failure.

DISTRIBUTION — follow the requested quota EXACTLY, in this order:
1. "inspiration" looks FIRST: completely new, trend-focused outfits, PRECISELY aimed at the stated occasion — its formality, setting and season drive every piece; no generic filler. You MUST NOT use any item from the user's wardrobe list here — invent fresh pieces that fit the occasion, their body and taste.
2. "wardrobe_mix" looks NEXT: practical looks. Each MUST incorporate 1-2 items VERBATIM from the provided wardrobe list (copy the exact strings into wardrobe_used AND include them in garments), mixed with new complementary pieces. If the wardrobe list is empty, output "inspiration" looks instead.
3. "affiliate" looks LAST: composed ENTIRELY from the provided affiliate catalogue. CONTEXT GATE: if the available affiliate items do not logically and semantically match the user's requested context (e.g., do NOT suggest sneakers or trackpants for a sauna, a beach, or a black-tie event), you MUST NOT use them — output "inspiration" looks with generic, unbranded clothing appropriate for the context instead. A branded look is only allowed when every chosen item genuinely suits the occasion. Prefer a single-brand story when the catalogue allows (e.g. a total look from one brand — reflect it in the title). Copy the chosen items' ids into affiliate_ids (only ids that exist in the catalogue) and describe each chosen item in garments as "<name> by <brand>". If the catalogue is empty or lacks pieces for a wearable outfit, output "inspiration" looks instead.

RULES:
- Every look = a complete, wearable outfit for the occasion (top/bottom/shoes minimum, outerwear/accessories when they help).
- garments: concrete descriptions (cut, colour, fabric) — no vague "nice shirt".
- title: short editorial name, no exclamation marks, no clichés ('elevate', 'effortless', 'versatile').
- Respect the body profile (cuts that flatter) and the style DNA (palette, aesthetic) in every tier.
- TRENDS: when CURRENT SEASON TRENDS are provided, every inspiration look must visibly express ONE of them (silhouette, palette or fabric direction) — pick the trend that genuinely suits this person and occasion; never force one that doesn't.
- Brand names appear ONLY in affiliate looks. Never invent brands or ids.
Return ONLY JSON matching the schema, with looks in the exact quota order.
GENDER: affiliate catalogue entries may carry a gender tag (male/female/unisex). NEVER assign items tagged for a different gender than the client's presentation (infer from body/style context); unisex is always safe.`;

export type PlannedLook = { tier: string; title: string; garments: string[]; wardrobe_used?: string[]; affiliate_ids?: string[] };

/** Plan the tiered look set (inspiration / wardrobe mix / affiliate) before any
 * image is generated. Quotas are enforced again in code by the caller. */
export async function planLooks(args: {
  occasion: string;
  bodyType: string | null;
  proportionDesc: string | null;
  styleDna: unknown | null;
  wardrobe: string[];
  affiliate: { id: string; brand: string; name: string; category: string }[];
  quotas: { inspiration: number; wardrobe: number; affiliate: number };
  person?: Inline; // the client photo — the planner MUST see who it dresses
  trends?: string[]; // grounded seasonal rules from trend_insights
}): Promise<{ gender_presentation?: string; looks: PlannedLook[] }> {
  const model = textModel();
  const ctx = [
    `Occasion: "${args.occasion}".`,
    `Quota: ${args.quotas.inspiration} inspiration, then ${args.quotas.wardrobe} wardrobe_mix, then ${args.quotas.affiliate} affiliate.`,
    args.bodyType ? `Body type: ${args.bodyType}.` : "",
    args.proportionDesc ? `Proportions: ${args.proportionDesc}.` : "",
    args.styleDna ? `Style DNA: ${JSON.stringify(args.styleDna)}.` : "",
    `Wardrobe list (verbatim strings): ${args.wardrobe.length ? JSON.stringify(args.wardrobe) : "EMPTY"}.`,
    `Affiliate catalogue: ${args.affiliate.length ? JSON.stringify(args.affiliate) : "EMPTY"}.`,
    args.trends?.length
      ? `CURRENT GROUNDED TRENDS (live fashion sources, this season): ${args.trends.join(" | ")}. Fold them in where they suit this person's build, gender presentation and the occasion — never at their expense.`
      : "",
  ].filter(Boolean).join("\n");
  return await generate(model, {
    systemInstruction: { parts: [{ text: PLAN_SYSTEM }] },
    contents: [{
      role: "user",
      parts: [
        { text: ctx },
        ...(args.person ? [{ inlineData: { mimeType: args.person.mimeType, data: args.person.data } }] : []),
      ],
    }],
    generationConfig: { responseMimeType: "application/json", responseSchema: PLAN_SCHEMA, temperature: 0.5 },
  });
}

// ── Fitting Room Copilot: compare 2-4 mirror selfies, rank, explain ─────────
const COMPARE_SCHEMA = {
  type: "OBJECT",
  properties: {
    looks: {
      type: "ARRAY",
      items: {
        type: "OBJECT",
        properties: {
          index: { type: "INTEGER" },
          score: { type: "INTEGER" },
          title: { type: "STRING" },
          why_bullets: { type: "ARRAY", items: { type: "STRING" } },
          same_person: { type: "BOOLEAN" },
        },
        required: ["index", "score", "why_bullets", "same_person"],
      },
    },
  },
  required: ["looks"],
};

const COMPARE_SYSTEM = `You are Looktok — an objective personal stylist judging a FITTING-ROOM SHOWDOWN: the same person tries on several outfits (one photo each) and you rank them.

RULES:
- When a REFERENCE portrait of the client is provided (it is labeled and does NOT participate in the ranking), set same_person=false for any look photo whose person is clearly a DIFFERENT human than the reference (different face). Lighting, angle, glasses or haircut changes are NOT a different person — when unsure, same_person=true. Without a reference, always same_person=true.
- Rank ALL provided LOOK photos best-first. index = the look photo's position among the look photos (0-based).
- score: INTEGER 0-100 per look. Be honest and SPREAD the scores — a real ranking, not everyone at 80. Below 70 means you would not buy it.
- title: a short editorial name for the outfit (≤4 words, no exclamation marks).
- why_bullets: EXACTLY 2 or 3 short, punchy statements (each ≤9 words, no ending period). Scannable, specific, concrete — e.g. ["Structured shoulders balance your silhouette", "Tapered leg sharpens the line", "Tone-on-tone reads expensive"]. For the winner — what exactly works; for the others — polite concrete critique ("Too baggy through the torso for your frame"). Never vague, never cruel, no marketing clichés ('elevate', 'effortless', 'versatile').
- Judge fit for THIS person's build (use the body profile if given): proportion, colour against skin tone, occasion coherence.
- NEVER mention brands, stores or prices.
Return ONLY JSON matching the schema, looks sorted best-first.`;

const PIECE_SYSTEM = `You are Looktok — an objective personal stylist judging a PURCHASE DECISION: the same person tries VARIANTS of one garment (e.g. three different blouses with the same rest of the outfit) and you rank WHICH VARIANT suits them best.

RULES:
- First identify the piece that DIFFERS between the photos — that piece is what you judge. The rest of the outfit is context, not the subject.
- When a REFERENCE portrait of the client is provided (labeled, not ranked), set same_person=false for any photo showing a clearly DIFFERENT human. Lighting/angle changes are NOT a different person; without a reference, always same_person=true.
- Rank ALL photos best-first by how the DIFFERING piece works for THIS person: cut against their build, colour against their skin tone, proportion, how it sits with the rest of the outfit. index = photo position (0-based).
- score: INTEGER 0-100 for the VARIANT (not the whole look). Spread the scores — this is a buying decision, someone wins.
- title: name the variant itself (≤4 words, e.g. "Sage linen shirt").
- why_bullets: EXACTLY 2-3 short statements (≤9 words, no ending period) about the PIECE: why it flatters or fails — e.g. ["Warm tone lifts your complexion", "Boxier cut hides the waistline"].
- NEVER mention brands, stores or prices.
Return ONLY JSON matching the schema, best variant first.`;

/** Rank 2-4 try-on photos of the same person. Returns looks sorted best-first.
 * mode 'looks' = whole-outfit showdown; 'piece' = which garment VARIANT suits
 * them best (purchase-decision framing). */
export async function compareLooks(images: Inline[], bodyProfile?: unknown, reference?: Inline, mode = "looks"): Promise<{ looks: { index: number; score: number; title?: string; why: string; why_bullets: string[]; same_person?: boolean }[] }> {
  const model = liteModel();
  const ctx = [
    `There are ${images.length} looks, in this exact order (first look photo = index 0).`,
    bodyProfile ? `Body profile: ${JSON.stringify(bodyProfile)}.` : "",
  ].filter(Boolean).join(" ");
  const parts: unknown[] = [{ text: ctx }];
  if (reference) {
    parts.push({ text: "REFERENCE portrait of the client (identity check only — not a look, do not rank):" });
    parts.push({ inlineData: { mimeType: reference.mimeType, data: reference.data } });
    parts.push({ text: "The LOOK photos to rank follow:" });
  }
  parts.push(...images.map((i) => ({ inlineData: { mimeType: i.mimeType, data: i.data } })));
  const out = await generate(model, {
    systemInstruction: { parts: [{ text: mode === "piece" ? PIECE_SYSTEM : COMPARE_SYSTEM }] },
    contents: [{ role: "user", parts }],
    generationConfig: { responseMimeType: "application/json", responseSchema: COMPARE_SCHEMA, temperature: 0.4 },
  });
  // Back-compat: older clients read `why` as one string — compose it.
  for (const l of out.looks ?? []) {
    l.why_bullets = (l.why_bullets ?? []).slice(0, 3);
    l.why = l.why ?? l.why_bullets.join(". ");
  }
  return out;
}

const TREND_SCHEMA = {
  type: "OBJECT",
  properties: {
    aesthetic_tag: { type: "STRING" },
    summary: { type: "STRING" },
    keywords: { type: "ARRAY", items: { type: "STRING" } },
  },
  required: ["aesthetic_tag", "summary", "keywords"],
};

/** Distil a piece of editorial/trend copy into a brand-agnostic styling RULE
 * (for the Monthly Trend Parser RAG store). No brands, no products, no prices. */
export async function summarizeTrend(rawText: string): Promise<{ aesthetic_tag: string; summary: string; keywords: string[] }> {
  const model = liteModel();
  return await generate(model, {
    systemInstruction: { parts: [{ text: "You are a fashion editor distilling trend/editorial copy into ONE actionable, brand-agnostic styling rule a stylist can apply. aesthetic_tag = 1–3 words. summary = ONE sentence stating the rule (silhouette/proportion/colour/fabric), no brands, no store names, no prices, no product links, no clichés ('elevate', 'must-have', 'versatile'). keywords = 3–6 concrete cues. Strip all commercial references." }] },
    contents: [{ role: "user", parts: [{ text: rawText.slice(0, 6000) }] }],
    generationConfig: { responseMimeType: "application/json", responseSchema: TREND_SCHEMA, temperature: 0.3 },
  });
}

/** Grounded (Google Search) trend read. Lets Gemini pull CURRENT direction from
 * the live web WITHOUT us scraping — it does the retrieval; we keep only the
 * distilled, brand-agnostic rule downstream (feed this into `summarizeTrend`).
 * Grounding forbids responseSchema/JSON mode, so this returns raw prose.
 * The named sources steer vocabulary only — no scraping, no quoting. */
export async function generateGroundedTrends(archetype: string, season: string): Promise<string> {
  const key = Deno.env.get("GEMINI_API_KEY");
  if (!key) throw new Error("GEMINI_API_KEY missing");
  const model = textModel();
  const sys = "You are a fashion editor. Using current editorial direction (draw on sources like Vogue Runway, SSENSE editorial, Mr Porter Journal, Highsnobiety and Lyst trend data as reference vocabulary only — never quote or copy them), describe what is trending RIGHT NOW for the given aesthetic and season. Give 3–5 short directional cues covering silhouette, proportion, colour, fabric and styling. Strictly brand-agnostic — no store names, no brand names, no prices, no product links, no buy language. Plain prose, no preamble, no headings.";
  const res = await fetch(`${API_BASE}/${model}:generateContent?key=${key}`, {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      systemInstruction: { parts: [{ text: sys }] },
      contents: [{ role: "user", parts: [{ text: `Aesthetic: ${archetype}. Season: ${season}. What is the current direction?` }] }],
      tools: [{ google_search: {} }],
      generationConfig: { temperature: 0.5 },
    }),
  });
  if (!res.ok) throw new Error(`gemini-grounded ${res.status}: ${(await res.text()).slice(0, 300)}`);
  const j = await res.json();
  const parts = j?.candidates?.[0]?.content?.parts ?? [];
  const text = parts.map((p: { text?: string }) => p.text ?? "").join(" ").trim();
  if (!text) throw new Error("gemini-grounded: no content");
  return text;
}

/** Embed text at 768-dim — for the trend RAG store (`trend_insights.embedding`
 * is vector(768)). Uses `gemini-embedding-001` with outputDimensionality=768
 * (its native default is 3072). The legacy `text-embedding-004` is no longer
 * served for this key, hence the explicit model + dim. */
export async function embedText(text: string): Promise<number[]> {
  const key = Deno.env.get("GEMINI_API_KEY");
  if (!key) throw new Error("GEMINI_API_KEY missing");
  const model = Deno.env.get("GEMINI_EMBED_MODEL") ?? "gemini-embedding-001";
  const res = await fetch(`${API_BASE}/${model}:embedContent?key=${key}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ model: `models/${model}`, content: { parts: [{ text }] }, outputDimensionality: 768 }),
  });
  if (!res.ok) throw new Error(`embed ${res.status}: ${(await res.text()).slice(0, 200)}`);
  const j = await res.json();
  const values = j?.embedding?.values;
  if (!Array.isArray(values)) throw new Error("embed: no values");
  return values as number[];
}

/** Fetch a (signed) URL and return base64 inline for Gemini. */
export async function fetchInline(url: string): Promise<Inline> {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`image fetch ${r.status}`);
  const mimeType = r.headers.get("content-type") || "image/jpeg";
  const buf = new Uint8Array(await r.arrayBuffer());
  let bin = "";
  for (let i = 0; i < buf.length; i++) bin += String.fromCharCode(buf[i]);
  return { data: btoa(bin), mimeType };
}
