// Self-hosted VTON engine, reached through a QUEUE rather than an HTTP call.
//
// The GPU worker exposes no port. It connects OUT to Supabase, claims jobs,
// renders, and writes results back. Edge Functions only enqueue and poll.
// Rationale: a public render endpoint on a guessable host is somebody else's
// free GPU, a header secret is one leaked log line from being public, and
// RunPod remaps ports on every pod restart — a pull worker does not care what
// its address is. A dead worker degrades into "jobs stay queued" instead of
// 5xx storms.
//
// The queue is the `vton_jobs` table (migrations/0022). Claiming goes through
// claim_vton_job(), which uses FOR UPDATE SKIP LOCKED: two workers can never
// render the same row, and a row stuck 'running' past its lease is re-offered.
// The earlier Storage-object queue worked but claimed by MOVING a file, which is
// not atomic against a concurrent reader and had no way to count attempts or
// reclaim abandoned work. One transport, not two — the file version is in git
// history if it is ever needed again.
//
// Callers keep their synchronous contract — this returns pixels — so nothing
// downstream or client-side knows the transport changed.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
// STATIC import, deliberately. Behind a dynamic import() this module was
// fetched and compiled INSIDE the first request that needed it: measured
// 3.3s for the first staged image against 0.9s for the second and larger
// one. A static import moves that cost to cold start, where it is paid once
// per instance instead of once per warm-up of every new isolate.
import { Image } from "https://deno.land/x/imagescript@1.3.0/mod.ts";

export type Slot = "upper" | "lower" | "full" | "shoes";

export interface DressStep {
  url: string;      // publicly fetchable or signed garment image URL
  kind: Slot;
  hint?: string;    // short human description; steers the sampler, not the pixels
  seed?: number;
}

export interface Inline {
  data: string;      // base64
  mimeType: string;
}

const BUCKET = "generations";

// A dressing step is ~1.5s and a look is at most 3-4 steps, so anything past
// ~40s means the worker is down rather than slow. Failing fast lets the caller
// fall back to the hosted provider inside the request the user is waiting on.
// 90s, not 40: a caller may queue FOUR looks at once (grid-vton), and they are
// rendered one at a time — so the last one legitimately waits for the whole
// set. Sized for four 3-garment looks; past that the worker really is down.
const TIMEOUT_MS = Number(Deno.env.get("VTON_QUEUE_TIMEOUT_MS") ?? 90_000);
const POLL_MS = Number(Deno.env.get("VTON_POLL_MS") ?? 200);
// How long a job may sit UNCLAIMED before we call the engine asleep. Generous
// next to the sub-second claim a warm worker manages, tight next to the 90s
// render timeout it used to hide behind.
const NO_WORKER_MS = Number(Deno.env.get("VTON_NO_WORKER_MS") ?? 6_000);

export function hybridEnabled(): boolean {
  return (Deno.env.get("VTON_ENGINE") ?? "").toLowerCase() === "hybrid";
}

/** Enqueue a dressing sequence and wait for the rendered image.
 *  Throws on timeout or worker failure — callers are expected to fall back. */
export async function hybridDress(
  db: SupabaseClient,
  userId: string,
  personUrl: string,
  steps: DressStep[],
  // Latent streaming: an opaque client-chosen key. The worker broadcasts TAESD
  // previews to Realtime channel `vton:<key>` while it denoises, and the client
  // that invented the key is already subscribed. Rides inside steps[0] so the
  // queue schema stays untouched — the worker reads it and the engine never
  // sees it.
  streamKey?: string,
): Promise<Inline> {
  if (!steps.length) throw new Error("hybridDress: no steps");

  const sorted = sortSteps(steps);
  if (streamKey && /^[A-Za-z0-9-]{8,64}$/.test(streamKey)) {
    (sorted[0] as Record<string, unknown>).stream_key = streamKey;
  }
  const { data: job, error } = await db
    .from("vton_jobs")
    .insert({ user_id: userId, person_url: personUrl, steps: sorted })
    .select("id")
    .single();
  // NEVER swallow this: a silent insert failure looks exactly like a slow worker,
  // and we would poll for the full timeout on a job that was never created.
  if (error || !job) throw new Error(`vton enqueue failed: ${error?.message}`);

  // A JOB NOBODY EVEN CLAIMS MEANS THE GPU IS ASLEEP, not that the render is
  // slow. The pod is now started per session and stops itself after 15 minutes
  // idle, so "no worker" is a NORMAL state rather than an incident — and waiting
  // out the full timeout for it wastes the user's minute and then reports the
  // wrong cause. A warm worker claims within a second; anything past this and
  // the queue has no reader.
  const claimBy = Date.now() + NO_WORKER_MS;
  const deadline = Date.now() + TIMEOUT_MS;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, POLL_MS));
    const { data: row } = await db
      .from("vton_jobs")
      .select("status, result_path, error")
      .eq("id", job.id)
      .maybeSingle();
    if (!row) continue;
    if (row.status === "queued" && Date.now() > claimBy) {
      await db.from("vton_jobs")
        .update({ status: "failed", error: "no worker" })
        .eq("id", job.id).eq("status", "queued");
      throw new Error("vton engine asleep: no worker claimed the job");
    }
    if (row.status === "failed") throw new Error(`vton render failed: ${row.error}`);
    if (row.status !== "done" || !row.result_path) continue;

    const { data: blob, error: dl } = await db.storage
      .from(BUCKET)
      .download(row.result_path as string);
    if (dl || !blob) throw new Error(`vton result unreadable: ${dl?.message}`);
    const bytes = new Uint8Array(await blob.arrayBuffer());
    let bin = "";
    for (let i = 0; i < bytes.length; i += 0x8000) {
      bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    }
    return { data: btoa(bin), mimeType: "image/jpeg" };
  }

  // Withdraw it so a worker picking it up late does not spend GPU time on a
  // render nobody is waiting for. Guarded on status so a job that finished in
  // the same tick is not marked failed.
  await db.from("vton_jobs")
    .update({ status: "failed", error: "caller timeout" })
    .eq("id", job.id).in("status", ["queued", "running"]);
  throw new Error(`vton timeout after ${TIMEOUT_MS}ms`);
}

/** Park a base64 image in Storage and hand back a URL the worker can fetch.
 *
 * The queue carries URLs, not bytes: the worker pulls its own inputs, so a job
 * record stays a few hundred bytes however large the images are. Callers that
 * already hold pixels inline (the editor posts the current look as base64) need
 * this bridge. Objects land under a scratch prefix and are removed by
 * [unstage] once the render is done — best-effort, since a leaked scratch file
 * is harmless while a failed cleanup that threw would lose a good render. */
export async function stageInline(
  db: SupabaseClient,
  img: Inline,
  tag = "in",
): Promise<{ url: string; path: string }> {
  const path = `_vton/${tag}/${crypto.randomUUID()}.jpg`;
  const bytes = await shrink(Uint8Array.from(atob(img.data), (c) => c.charCodeAt(0)));
  const { error } = await db.storage.from(BUCKET).upload(
    path, new Blob([bytes], { type: "image/jpeg" }),
    { contentType: "image/jpeg", upsert: true },
  );
  if (error) throw new Error(`vton stage failed: ${error.message}`);
  const { data, error: se } = await db.storage.from(BUCKET).createSignedUrl(path, 900);
  if (se || !data?.signedUrl) throw new Error(`vton sign failed: ${se?.message}`);
  return { url: data.signedUrl, path };
}

export function unstage(db: SupabaseClient, paths: string[]): void {
  if (paths.length) db.storage.from(BUCKET).remove(paths).catch(() => {});
}

// Every staged byte is paid for three times: this upload, the worker's download,
// and the storage itself. A 1 MB catalogue PNG cost ~3.5s of a 5.5s job while the
// render was 2s — and it was waste, because the engine resamples to 512×768
// regardless. JPEG at 768px is visually identical at the working resolution.
const STAGE_MAX = Number(Deno.env.get("VTON_STAGE_PX") ?? 768);

async function shrink(bytes: Uint8Array): Promise<Uint8Array> {
  try {
    const im = await Image.decode(bytes);
    const longest = Math.max(im.width, im.height);
    const out = longest > STAGE_MAX
      ? im.resize(
        im.width >= im.height ? STAGE_MAX : Image.RESIZE_AUTO,
        im.height > im.width ? STAGE_MAX : Image.RESIZE_AUTO,
      )
      : im;
    return await out.encodeJPEG(88);
  } catch (e) {
    // A decode failure must not fail the render — ship the original bytes and
    // pay the transfer. Worth logging: it means an input format we cannot read.
    console.error("[vton] shrink failed, staging original:", (e as Error).message);
    return bytes;
  }
}

/** Map the app's garment categories onto the engine's four mask zones.
 *  Anything the engine has no zone for (hats, bags, jewellery) returns null and
 *  the caller must keep that piece on the hosted provider — pretending a bag is
 *  an "upper" garment is how trousers ended up painted leather-brown. */
export function slotOf(category: string | undefined | null): Slot | null {
  switch ((category ?? "").toLowerCase().trim()) {
    case "top":
    case "tops":
    case "upper_body":
    case "shirt":
    case "tshirt":
    case "outerwear":       // worn over the torso: same zone, later in the order
    case "jacket":
    case "coat":
      return "upper";
    case "bottom":
    case "bottoms":
    case "lower_body":
    case "pants":
    case "trousers":
    case "jeans":
    case "skirt":
      return "lower";
    case "shoes":
    case "footwear":
    case "sneakers":
    case "boots":
      return "shoes";
    case "dress":
    case "full_body":
    case "overall":
      return "full";
    default:
      return null;
  }
}

/** Dressing order matters, and UPPER GOES AFTER LOWER — measured both ways on
 *  the same look at a fixed seed. With the trousers painted last, the waistband
 *  repainted the tee's hem and left a hard blue band across the waist (the
 *  defect chased across three phone sessions). With the top painted last its hem
 *  drapes OVER the waistband, which is how an untucked shirt actually hangs, and
 *  the band is gone. The earlier pre-warp test that favoured upper-first is
 *  obsolete: back then the sampler invented both garments, now the warp pins
 *  them. Shoes stay last so the trouser hem is final before footwear. */
const ORDER: Record<Slot, number> = { full: 0, lower: 1, upper: 2, shoes: 3 };

export function sortSteps(steps: DressStep[]): DressStep[] {
  return [...steps].sort((a, b) => ORDER[a.kind] - ORDER[b.kind]);
}
