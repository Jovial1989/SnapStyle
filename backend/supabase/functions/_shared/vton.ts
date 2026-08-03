// Self-hosted VTON engine, reached through a QUEUE rather than an HTTP call.
//
// The GPU worker exposes no port (see migrations/0022_vton_jobs.sql). We insert
// a job, then poll the row until the worker fills in `result_path`. That is
// still far faster end to end than the hosted alternative it replaces: ~1.5s
// per dressing step against 45-60s per gpt-image render.
//
// Callers keep their synchronous contract — this function returns pixels — so
// nothing downstream or client-side has to know the transport changed.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";

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

const OUT_BUCKET = "generations";
// A dressing step is ~1.5s and a look is at most 3-4 steps, so anything past
// ~40s means the worker is down rather than slow. Failing fast lets the caller
// fall back to the hosted provider inside the request the user is waiting on.
const TIMEOUT_MS = Number(Deno.env.get("VTON_QUEUE_TIMEOUT_MS") ?? 40_000);
const POLL_MS = Number(Deno.env.get("VTON_POLL_MS") ?? 350);

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
): Promise<Inline> {
  if (!steps.length) throw new Error("hybridDress: no steps");

  const { data: job, error } = await db
    .from("vton_jobs")
    .insert({ user_id: userId, person_url: personUrl, steps })
    .select("id")
    .single();
  // NEVER swallow this: a silent insert failure would look exactly like a slow
  // worker, and we would poll for 40s on a job that does not exist.
  if (error || !job) throw new Error(`vton enqueue failed: ${error?.message}`);

  const deadline = Date.now() + TIMEOUT_MS;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, POLL_MS));
    const { data: row } = await db
      .from("vton_jobs")
      .select("status, result_path, error")
      .eq("id", job.id)
      .maybeSingle();
    if (!row) continue;
    if (row.status === "failed") throw new Error(`vton render failed: ${row.error}`);
    if (row.status === "done" && row.result_path) {
      const { data: blob, error: dl } = await db.storage
        .from(OUT_BUCKET)
        .download(row.result_path);
      if (dl || !blob) throw new Error(`vton result unreadable: ${dl?.message}`);
      const bytes = new Uint8Array(await blob.arrayBuffer());
      let bin = "";
      for (let i = 0; i < bytes.length; i += 0x8000) {
        bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
      }
      return { data: btoa(bin), mimeType: "image/jpeg" };
    }
  }
  // Mark it abandoned so the worker does not render something nobody awaits.
  await db.from("vton_jobs").update({ status: "failed", error: "caller timeout" })
    .eq("id", job.id).in("status", ["queued", "running"]);
  throw new Error(`vton timeout after ${TIMEOUT_MS}ms`);
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
      return "upper";
    case "outerwear":
    case "jacket":
    case "coat":
      return "upper";       // worn over the torso; same zone, later in the order
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

/** Dressing order matters: an outer layer must be painted after the torso piece
 *  it covers, and shoes last so the trouser hem is already final. */
const ORDER: Record<Slot, number> = { full: 0, upper: 1, lower: 2, shoes: 3 };

export function sortSteps(steps: DressStep[]): DressStep[] {
  return [...steps].sort((a, b) => ORDER[a.kind] - ORDER[b.kind]);
}
