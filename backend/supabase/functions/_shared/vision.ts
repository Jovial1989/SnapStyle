// VISION PROVIDER SEAM — who answers the text/vision questions.
//
// Order: OpenAI → local worker → Gemini. It used to be local-first with Gemini
// behind it, and that was wrong twice over: the laptop serialises requests (a
// measured 3.2 s call becomes 11.9 s wall for four concurrent ones), and the
// provider standing behind it was the one that had died. A fallback must be
// something that can actually answer.
//
//   VISION_PROVIDER = openai (default) | local | gemini
//   VISION_BASE_URL — local worker origin; without it the local branch is skipped
//   VISION_TOKEN    — shared secret for the local worker
//
// Every function tries the chosen provider, then the others in order. Only
// planLooks skips the local branch: the worker has no /plan endpoint.
import type { Inline } from "./gemini.ts";
import { openaiJson } from "./openai_text.ts";
import {
  CRITIQUE_SYSTEM,
  PLAN_SYSTEM,
  profileSystem,
  slotsSystem,
  SLOTS,
  analyzeBodyProfile as gemBodyProfile,
  analyzeFit as gemAnalyzeFit,
  classifyItem as gemClassifyItem,
  detectOutfitSlots as gemDetectSlots,
  planLooks as gemPlanLooks,
  samePerson as gemSamePerson,
  validateLookImages as gemValidate,
  type PlannedLook,
} from "./gemini.ts";

const base = () => (Deno.env.get("VISION_BASE_URL") ?? "").replace(/\/+$/, "");
export const localVisionEnabled = () => base().length > 0;
const provider = () => (Deno.env.get("VISION_PROVIDER") ?? "openai").toLowerCase();
const TIMEOUT_MS = Number(Deno.env.get("VISION_TIMEOUT_MS") ?? 45_000);

function blob(i: Inline): Blob {
  return new Blob([Uint8Array.from(atob(i.data), (c) => c.charCodeAt(0))], { type: i.mimeType });
}

async function post(path: string, form: FormData): Promise<any> {
  const token = Deno.env.get("VISION_TOKEN") ?? "";
  const res = await fetch(`${base()}${path}`, {
    method: "POST", body: form, signal: AbortSignal.timeout(TIMEOUT_MS),
    headers: token ? { "x-vision-token": token } : undefined,
  });
  if (!res.ok) throw new Error(`vision ${path} ${res.status}: ${(await res.text()).slice(0, 200)}`);
  return await res.json();
}

type Branches<T> = { openai: () => Promise<T>; local?: () => Promise<T>; gemini: () => Promise<T> };

/** Try providers in the configured order; the first that answers wins. Throws
 * the LAST error if every one fails, so the caller sees a real cause. */
async function route<T>(label: string, b: Branches<T>): Promise<T> {
  const wanted = provider();
  const order = wanted === "local" ? ["local", "openai", "gemini"]
    : wanted === "gemini" ? ["gemini", "openai", "local"]
    : ["openai", "local", "gemini"];
  let last: Error | null = null;
  for (const name of order) {
    if (name === "local" && (!b.local || !localVisionEnabled())) continue;
    try {
      return await (name === "openai" ? b.openai() : name === "local" ? b.local!() : b.gemini());
    } catch (e) {
      last = e as Error;
      console.error(`[vision] ${label} via ${name} failed:`, last.message);
    }
  }
  throw last ?? new Error(`vision ${label}: no provider available`);
}

// ── schemas (strict mode fills `required` and additionalProperties itself) ───
const CRITIQUE_SCHEMA = {
  name: "outfit_critique",
  schema: {
    type: "object",
    properties: {
      analyzable: { type: "boolean" },
      note: { type: "string" },
      overall: {
        type: "object",
        properties: { summary: { type: "string" }, score: { type: "integer" } },
      },
      hotspots: {
        type: "array",
        items: {
          type: "object",
          properties: {
            x_percent: { type: "number" }, y_percent: { type: "number" },
            area: { type: "string" },
            severity: { type: "string", enum: ["issue", "tip", "good"] },
            title: { type: "string" }, detail: { type: "string" }, fix: { type: "string" },
            visual_suggestions: {
              type: "array",
              items: {
                type: "object",
                properties: { prompt: { type: "string" }, caption: { type: "string" }, alt_text: { type: "string" } },
              },
            },
          },
        },
      },
    },
  },
};

const SLOTS_JSON_SCHEMA = {
  name: "outfit_slots",
  schema: {
    type: "object",
    properties: {
      gender_presentation: { type: "string", enum: ["masculine", "feminine", "neutral"] },
      slots: {
        type: "array",
        items: {
          type: "object",
          properties: {
            slot: { type: "string", enum: SLOTS },
            item: { type: "string" },
            ideas: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  garment: { type: "string" }, why: { type: "string" }, recommended: { type: "boolean" },
                },
              },
            },
          },
        },
      },
    },
  },
};

const PROFILE_JSON_SCHEMA = {
  name: "body_profile",
  schema: {
    type: "object",
    properties: {
      analyzable: { type: "boolean" },
      note: { type: "string" },
      body_type: { type: "string", enum: ["rectangle", "triangle", "inverted_triangle", "hourglass", "oval", "athletic"] },
      proportions: {
        type: "object",
        properties: {
          shoulder_to_hip: { type: "string", enum: ["narrower", "balanced", "wider"] },
          torso_to_leg: { type: "string", enum: ["short_torso", "balanced", "long_torso"] },
          description: { type: "string" },
        },
      },
      estimated_measurements: {
        type: "object",
        properties: {
          chest_cm: { type: "object", properties: { min: { type: "number" }, max: { type: "number" } } },
          waist_cm: { type: "object", properties: { min: { type: "number" }, max: { type: "number" } } },
          hip_cm: { type: "object", properties: { min: { type: "number" }, max: { type: "number" } } },
          inseam_cm: { type: "object", properties: { min: { type: "number" }, max: { type: "number" } } },
        },
      },
      confidence: { type: "number" },
      styling_notes: { type: "array", items: { type: "string" } },
    },
  },
};

const PLAN_JSON_SCHEMA = {
  name: "look_plan",
  schema: {
    type: "object",
    properties: {
      gender_presentation: { type: "string", enum: ["masculine", "feminine", "neutral"] },
      looks: {
        type: "array",
        items: {
          type: "object",
          properties: {
            tier: { type: "string", enum: ["inspiration", "wardrobe_mix", "affiliate"] },
            title: { type: "string" },
            garments: { type: "array", items: { type: "string" } },
            wardrobe_used: { type: "array", items: { type: "string" } },
            affiliate_ids: { type: "array", items: { type: "string" } },
          },
        },
      },
    },
  },
};

// ── operations ───────────────────────────────────────────────────────────────

export function analyzeFit(image: Inline, profile?: unknown) {
  const ctx = profile && Object.keys(profile as object).length
    ? `User profile (factor into proportion/cut advice):\n${JSON.stringify(profile)}`
    : "No user profile provided. Analyze from the photo alone.";
  return route("critique", {
    openai: async () => ({
      analysis: await openaiJson({ system: CRITIQUE_SYSTEM, user: ctx, images: [image], schema: CRITIQUE_SCHEMA }),
      model: "openai-vision", promptVersion: "openai-critique-v1",
    }),
    local: async () => {
      const f = new FormData();
      f.set("image", blob(image), "photo.jpg");
      if (profile && Object.keys(profile as object).length) f.set("profile", JSON.stringify(profile));
      return { analysis: await post("/critique", f), model: "qwen3-vl-local", promptVersion: "qwen-critique-v1" };
    },
    gemini: () => gemAnalyzeFit(image, profile),
  });
}

export function detectOutfitSlots(image: Inline, trends: string[] = [], premium = false) {
  return route("slots", {
    openai: () => openaiJson({
      system: slotsSystem(trends, premium),
      user: "Catalogue this outfit's slots.",
      images: [image], schema: SLOTS_JSON_SCHEMA,
    }),
    local: async () => {
      const f = new FormData();
      f.set("image", blob(image), "photo.jpg");
      if (trends.length) f.set("trends", trends.join(" | "));
      f.set("premium", String(premium));
      return await post("/slots", f);
    },
    gemini: () => gemDetectSlots(image, trends, premium),
  });
}

const SAME_PERSON_PROMPT =
  "The FIRST image is a full-body try-on render. The SECOND image is the reference person — it MAY " +
  "be a cropped head/face shot. Judge ONLY by the FACE and head: is it clearly the SAME individual? " +
  "Answer same=false ONLY when the face is clearly a DIFFERENT person (different features, a generic " +
  "fashion model, a swapped head). Different clothes, framing, crop, lighting, pose or background are " +
  "NOT a different person; if the face is ambiguous, answer same=true.";

export function samePerson(render: Inline, person: Inline): Promise<boolean> {
  return route("same-person", {
    openai: async () => {
      const r = await openaiJson<{ same: boolean }>({
        system: "You verify identity between two photographs. Answer strictly.",
        user: SAME_PERSON_PROMPT, images: [render, person],
        schema: { name: "identity_check", schema: { type: "object", properties: { same: { type: "boolean" } } } },
      });
      return r?.same !== false;
    },
    local: async () => {
      const f = new FormData();
      f.set("render", blob(render), "render.jpg");
      f.set("person", blob(person), "person.jpg");
      return (await post("/same-person", f))?.same !== false;
    },
    gemini: () => gemSamePerson(render, person),
  });
}

export function validateLookImages(images: Inline[]): Promise<boolean[]> {
  const prompt =
    `You are validating AI-generated outfit try-on renders. For each of the ${images.length} images, in ` +
    `order, return true ONLY if ALL hold: (1) a photorealistic full-body person wearing an outfit; ` +
    `(2) the outfit matches the person's visible gender presentation; (3) the background is clean ` +
    `seamless white with no leftover fragments or halos. Return exactly one verdict per image.`;
  return route("validate", {
    openai: async () => {
      const r = await openaiJson<{ valid: boolean[] }>({
        system: "You are a strict QA checker for generated fashion imagery.",
        user: prompt, images,
        schema: { name: "render_validity", schema: { type: "object", properties: { valid: { type: "array", items: { type: "boolean" } } } } },
      });
      const v = r?.valid ?? [];
      return images.map((_, i) => v[i] !== false);
    },
    local: async () => {
      const f = new FormData();
      images.forEach((i, n) => f.append("images", blob(i), `look${n}.jpg`));
      const v = ((await post("/validate", f))?.valid ?? []) as boolean[];
      return images.map((_, i) => v[i] !== false);
    },
    gemini: () => gemValidate(images),
  });
}

const ITEM_CATEGORIES = ["top", "bottom", "outerwear", "shoes", "accessories", "bag", "dress"];

export function classifyItem(image: Inline): Promise<{ label: string; category: string }> {
  return route("classify-item", {
    openai: () => openaiJson({
      system: "Identify the single main clothing item in the photo. label = a short human name " +
              "(e.g. 'navy wool blazer'). If unclear, best guess.",
      user: "Classify this clothing item.", images: [image],
      schema: {
        name: "item_class",
        schema: {
          type: "object",
          properties: { label: { type: "string" }, category: { type: "string", enum: ITEM_CATEGORIES } },
        },
      },
    }),
    local: async () => {
      const f = new FormData();
      f.set("image", blob(image), "item.jpg");
      return await post("/classify-item", f);
    },
    gemini: () => gemClassifyItem(image),
  });
}

export function analyzeBodyProfile(image: Inline, heightCm: number) {
  return route("body-profile", {
    openai: async () => ({
      analysis: await openaiJson({
        system: profileSystem(heightCm),
        user: `Analyse this full-body photo. Stated height: ${heightCm} cm.`,
        images: [image], schema: PROFILE_JSON_SCHEMA,
      }),
      model: "openai-vision", promptVersion: "openai-bodyprofile-v1",
    }),
    local: async () => {
      const f = new FormData();
      f.set("image", blob(image), "photo.jpg");
      f.set("height_cm", String(heightCm));
      return { analysis: await post("/body-profile", f), model: "qwen3-vl-local", promptVersion: "qwen-bodyprofile-v1" };
    },
    gemini: () => gemBodyProfile(image, heightCm),
  });
}

/** The Generate-my-look planner. No local branch: the worker has no /plan. */
export function planLooks(args: {
  occasion: string;
  bodyType: string | null;
  proportionDesc: string | null;
  styleDna: unknown | null;
  wardrobe: string[];
  affiliate: unknown[];
  quotas: { inspiration: number; wardrobe: number; affiliate: number };
  person?: Inline | null;
  trends?: string[];
}): Promise<{ gender_presentation?: string; looks: PlannedLook[] }> {
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
  return route("plan-looks", {
    openai: () => openaiJson({
      system: PLAN_SYSTEM, user: ctx,
      images: args.person ? [args.person] : [], schema: PLAN_JSON_SCHEMA,
    }),
    gemini: () => gemPlanLooks(args),
  });
}
