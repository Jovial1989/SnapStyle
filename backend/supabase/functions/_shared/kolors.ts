// Kling Kolors Virtual Try-On — the specialist engine for single-garment
// TOP/BOTTOM swaps. Spike verdict (26.07.2026, spike-qwen/): exact garment
// copy with NO source-cut inheritance (Gemini's #1 failure), identity +
// framing preserved, ~14s. Limits: tops/bottoms/dresses ONLY (given sandals
// it dressed them as shorts) — shoes, accessories, fit instructions and
// multi-zone swaps stay on Gemini.
//
// TWO CHANNELS, same weights upstream:
//   VTON_CHANNEL=fal    (default) — fal.run proxy, $0.07/render, sync API
//   VTON_CHANNEL=kling  — Kling official Open Platform, ~$0.02/render,
//                         async task API (create → poll), Bearer API key
// fal stays as the wired fallback: flipping one secret moves ALL callers
// (fix-render swaps + generate-vton commits) between channels — no deploys.
import type { Inline } from "./gemini.ts";

const FAL_ENDPOINT = "https://fal.run/fal-ai/kling/v1-5/kolors-virtual-try-on";
const KLING_BASE = Deno.env.get("KLING_BASE") ?? "https://api-singapore.klingai.com";

/** Which upstream this process is using — callers log it into the ledger. */
export function kolorsChannel(): "fal" | "kling" {
  return Deno.env.get("VTON_CHANNEL") === "kling" ? "kling" : "fal";
}

/** One try-on: person photo + garment product shot → person wearing it.
 * No prompt — the model takes only the two images. Throws on any failure so
 * the caller can fall back to the Gemini path. */
export async function kolorsTryOn(person: Inline, garment: Inline): Promise<Inline> {
  return kolorsChannel() === "kling"
    ? klingTryOn(person, garment)
    : falTryOn(person, garment);
}

/* ── channel: fal (sync) ─────────────────────────────────────────────────── */

async function falTryOn(person: Inline, garment: Inline): Promise<Inline> {
  const key = Deno.env.get("FAL_KEY");
  if (!key) throw new Error("FAL_KEY missing");
  const res = await fetch(FAL_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Key ${key}` },
    body: JSON.stringify({
      human_image_url: `data:${person.mimeType};base64,${person.data}`,
      garment_image_url: `data:${garment.mimeType};base64,${garment.data}`,
    }),
    signal: AbortSignal.timeout(90_000),
  });
  if (!res.ok) {
    throw new Error(`kolors(fal) ${res.status}: ${(await res.text()).slice(0, 200)}`);
  }
  const j = await res.json();
  const url = j?.image?.url ?? j?.images?.[0]?.url;
  if (!url) throw new Error("kolors(fal): no image in response");
  return download(url);
}

/* ── channel: Kling official (async task) ────────────────────────────────── */

async function klingTryOn(person: Inline, garment: Inline): Promise<Inline> {
  const key = Deno.env.get("KLING_API_KEY");
  if (!key) throw new Error("KLING_API_KEY missing");
  const auth = { "Content-Type": "application/json", Authorization: `Bearer ${key}` };

  // Kling takes RAW base64 (no data: prefix) or a URL.
  const create = await fetch(`${KLING_BASE}/v1/images/kolors-virtual-try-on`, {
    method: "POST",
    headers: auth,
    body: JSON.stringify({
      model_name: "kolors-virtual-try-on-v1-5",
      human_image: person.data,
      cloth_image: garment.data,
    }),
    signal: AbortSignal.timeout(30_000),
  });
  if (!create.ok) {
    throw new Error(`kolors(kling) submit ${create.status}: ${(await create.text()).slice(0, 200)}`);
  }
  const submitted = await create.json();
  const taskId = submitted?.data?.task_id;
  if (submitted?.code !== 0 || !taskId) {
    throw new Error(`kolors(kling) submit: ${JSON.stringify(submitted).slice(0, 200)}`);
  }

  // Poll until the task settles. Typical render ~10-15s; 90s ceiling matches
  // the fal channel so callers see identical timeout behaviour.
  const deadline = Date.now() + 90_000;
  for (;;) {
    await new Promise((r) => setTimeout(r, 2_000));
    if (Date.now() > deadline) throw new Error("kolors(kling): task timed out");
    const poll = await fetch(`${KLING_BASE}/v1/images/kolors-virtual-try-on/${taskId}`, {
      headers: auth,
      signal: AbortSignal.timeout(15_000),
    });
    if (!poll.ok) continue;                       // transient poll errors: retry
    const state = await poll.json();
    const status = state?.data?.task_status;
    if (status === "succeed") {
      const url = state?.data?.task_result?.images?.[0]?.url;
      if (!url) throw new Error("kolors(kling): succeed but no image url");
      return download(url);
    }
    if (status === "failed") {
      throw new Error(`kolors(kling) failed: ${state?.data?.task_status_msg ?? "no reason"}`);
    }
  }
}

/* ── shared ──────────────────────────────────────────────────────────────── */

async function download(url: string): Promise<Inline> {
  const img = await fetch(url, { signal: AbortSignal.timeout(30_000) });
  if (!img.ok) throw new Error(`kolors download ${img.status}`);
  const buf = new Uint8Array(await img.arrayBuffer());
  let bin = "";
  const CHUNK = 0x8000; // String.fromCharCode arg-limit-safe chunking
  for (let i = 0; i < buf.length; i += CHUNK) {
    bin += String.fromCharCode(...buf.subarray(i, i + CHUNK));
  }
  return { mimeType: img.headers.get("content-type") ?? "image/png", data: btoa(bin) };
}
