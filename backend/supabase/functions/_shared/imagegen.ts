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

/** Drop-in replacement for gemini.ts#generateLookImage. */
export async function generateLookImage(
  person: Inline,
  prompt: string,
  extra: Inline[] = [],
  opts: GenOpts = {},
): Promise<Inline> {
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
      throw new Error(`openai: ${(e as Error).message} || gemini: ${(e2 as Error).message.slice(0, 160)}`);
    }
  }
}
