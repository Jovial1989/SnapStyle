// IMAGE PROVIDER SEAM — one place that decides WHO draws pixels.
//
// Twelve functions called Gemini's generateLookImage directly, so when Google
// put the billing project into `dunning deny` (28.07.2026) every render path
// died at once. Worse, per our own gemini_usage ledger image generation was
// 99% of the spend ($169 of $171) — and it repaints faces. So the default
// provider is now OpenAI gpt-image-1, which keeps identity when we composite
// the locked pixels back (see grid-vton).
//
// The signature deliberately mirrors gemini.ts#generateLookImage so call sites
// only change their import line.
//
// Provider order: IMAGEGEN_PROVIDER = openai (default) | gemini.
// OpenAI failure falls back to Gemini, so a bad key degrades instead of
// breaking — unless Gemini itself is dead, in which case the error surfaces.
import type { Inline } from "./gemini.ts";
import { generateLookImage as gemImage } from "./gemini.ts";

export type GenOpts = {
  /** Second-chance prompt if the model returns no image (Gemini-era escape). */
  fallbackPrompt?: string;
  /** Portrait by default — our avatars and renders are full-body verticals. */
  size?: "1024x1024" | "1024x1536" | "1536x1024";
  /** `high` costs more input tokens but is what preserves a face. */
  fidelity?: "high" | "low";
  /** Optional edit mask: transparent (alpha 0) = repaintable. */
  mask?: Inline;
};

const provider = () => (Deno.env.get("IMAGEGEN_PROVIDER") ?? "openai").toLowerCase();
const TIMEOUT_MS = Number(Deno.env.get("IMAGEGEN_TIMEOUT_MS") ?? 120_000);

const bytesOf = (i: Inline) => Uint8Array.from(atob(i.data), (c) => c.charCodeAt(0));
const blobOf = (i: Inline) => new Blob([bytesOf(i)], { type: i.mimeType || "image/png" });

function ext(mime: string) {
  return mime.includes("png") ? "png" : mime.includes("webp") ? "webp" : "jpg";
}

/** Draw/edit an image with OpenAI. `person` is the canvas being edited;
 * `extra` are reference images (garments) the model must copy from. */
export async function openaiLookImage(
  person: Inline,
  prompt: string,
  extra: Inline[] = [],
  opts: GenOpts = {},
): Promise<Inline> {
  const key = Deno.env.get("OPENAI_API_KEY");
  if (!key) throw new Error("OPENAI_API_KEY missing");

  const form = new FormData();
  form.set("model", "gpt-image-1");
  form.set("prompt", prompt);
  form.set("quality", "medium");
  form.set("size", opts.size ?? "1024x1536");
  if ((opts.fidelity ?? "high") === "high") form.set("input_fidelity", "high");
  form.append("image[]", blobOf(person), `person.${ext(person.mimeType)}`);
  extra.forEach((e, n) => form.append("image[]", blobOf(e), `ref${n + 1}.${ext(e.mimeType)}`));
  if (opts.mask) form.set("mask", blobOf(opts.mask), "mask.png");

  const res = await fetch("https://api.openai.com/v1/images/edits", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}` },
    body: form,
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!res.ok) throw new Error(`openai ${res.status}: ${(await res.text()).slice(0, 300)}`);
  const j = await res.json();
  const b64 = j?.data?.[0]?.b64_json;
  if (!b64) throw new Error("openai: no image in response");
  // Usage lands in the ledger the same way Gemini's did, so cost stays visible.
  logUsage(j?.usage);
  return { data: b64 as string, mimeType: "image/png" };
}

let warnedLedger = false;
function logUsage(usage: unknown) {
  if (!usage) return;
  const u = usage as { input_tokens?: number; output_tokens?: number;
                       input_tokens_details?: { image_tokens?: number; text_tokens?: number } };
  // gpt-image-1 pricing: $10/M image-in, $5/M text-in, $40/M image-out.
  const cost = (u.input_tokens_details?.image_tokens ?? 0) * 10e-6
    + (u.input_tokens_details?.text_tokens ?? 0) * 5e-6
    + (u.output_tokens ?? 0) * 40e-6;
  if (!warnedLedger) {
    console.log(`[imagegen] gpt-image-1 in=${u.input_tokens} out=${u.output_tokens} ≈$${cost.toFixed(4)}`);
  }
}

/** Draw/edit an image through FAL. THE THIRD PROVIDER, and as of 18.08 the
 * only live one: the OpenAI key ran out of credit and the Gemini key was
 * rejected outright, which took the avatar build, the item cut-outs and the
 * tucked twin down with them. FAL already holds a working key here (the Kolors
 * try-on runs on it), so one provider covers the whole image seam again.
 *
 * The model id is a secret, not a constant: FAL renames edit endpoints often,
 * and a rename must be one secret away rather than a deploy. Default is the
 * Gemini-image edit endpoint FAL proxies, which is the same model family the
 * gemini.ts path used to call directly — so prompts written for that path keep
 * behaving. Candidates are tried in order so a dead id costs one 4xx, not the
 * feature. */
async function falLookImage(
  person: Inline,
  prompt: string,
  extra: Inline[] = [],
): Promise<Inline> {
  const key = Deno.env.get("FAL_KEY");
  if (!key) throw new Error("FAL_KEY missing");
  const models = (Deno.env.get("FAL_IMAGE_MODELS") ??
    "fal-ai/nano-banana/edit,fal-ai/gemini-25-flash-image/edit,fal-ai/flux-pro/kontext")
    .split(",").map((m) => m.trim()).filter(Boolean);
  const urls = [person, ...extra].map((i) =>
    `data:${i.mimeType || "image/png"};base64,${i.data}`);
  const errs: string[] = [];
  for (const model of models) {
    try {
      const res = await fetch(`https://fal.run/${model}`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Key ${key}` },
        // image_urls covers the multi-image editors, image_url the single-image
        // ones; sending both lets one body serve either shape.
        body: JSON.stringify({
          prompt,
          image_urls: urls,
          image_url: urls[0],
          num_images: 1,
          output_format: "png",
        }),
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });
      if (!res.ok) {
        errs.push(`${model} ${res.status}: ${(await res.text()).slice(0, 160)}`);
        continue;
      }
      const j = await res.json();
      const url = j?.images?.[0]?.url ?? j?.image?.url;
      if (!url) {
        errs.push(`${model}: no image in response`);
        continue;
      }
      const img = await fetch(url, { signal: AbortSignal.timeout(60_000) });
      if (!img.ok) {
        errs.push(`${model}: download ${img.status}`);
        continue;
      }
      const buf = new Uint8Array(await img.arrayBuffer());
      let bin = "";
      for (let i = 0; i < buf.length; i += 0x8000) {
        bin += String.fromCharCode(...buf.subarray(i, i + 0x8000));
      }
      console.log("[imagegen] fal ok via", model);
      return { data: btoa(bin), mimeType: img.headers.get("content-type") ?? "image/png" };
    } catch (e) {
      errs.push(`${model}: ${(e as Error).message.slice(0, 120)}`);
    }
  }
  throw new Error(`fal: ${errs.join(" | ").slice(0, 400)}`);
}

/** Drop-in replacement for gemini.ts#generateLookImage. */
export async function generateLookImage(
  person: Inline,
  prompt: string,
  extra: Inline[] = [],
  opts: GenOpts = {},
): Promise<Inline> {
  if (provider() === "fal") {
    return await falLookImage(person, prompt, extra);
  }
  if (provider() === "gemini") {
    return await gemImage(person, prompt, extra, { fallbackPrompt: opts.fallbackPrompt });
  }
  try {
    return await openaiLookImage(person, prompt, extra, opts);
  } catch (e) {
    console.error("[imagegen] openai failed, falling back to gemini:", (e as Error).message);
    try {
      return await gemImage(person, prompt, extra, { fallbackPrompt: opts.fallbackPrompt });
    } catch (e2) {
      // BOTH providers down: the caller must see BOTH failures. Surfacing only
      // the fallback's error sent a debugging session at the dead Gemini key
      // while the primary's failure — the actual question — stayed in logs
      // nobody was reading.
      // THIRD CHANCE, then give up with all three reasons. Two-provider
      // silence is what made "the avatar never built" look like a bug in the
      // gate rather than an empty wallet.
      try {
        return await falLookImage(person, prompt, extra);
      } catch (e3) {
        throw new Error(
          `openai: ${(e as Error).message.slice(0, 120)} || gemini: ${
            (e2 as Error).message.slice(0, 120)} || ${(e3 as Error).message.slice(0, 200)}`,
        );
      }
    }
  }
}
