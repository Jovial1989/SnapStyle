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
// The queue lives in STORAGE, not in a table. Not because that is prettier —
// a table with FOR UPDATE SKIP LOCKED is the better primitive — but because
// creating one needs DDL, and the operator's tooling could not apply a
// migration. Storage needs only the service role we already hold. With a
// single worker there is no claim race to lose; `migrations/0022_vton_jobs.sql`
// is the drop-in replacement when DDL becomes available, and only the four
// helpers below change.
//
// Callers keep their synchronous contract — this returns pixels — so nothing
// downstream or client-side knows the transport changed.
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

const BUCKET = "generations";
const QUEUE = "_vton/queue";
const DONE = "_vton/done";

// A dressing step is ~1.5s and a look is at most 3-4 steps, so anything past
// ~40s means the worker is down rather than slow. Failing fast lets the caller
// fall back to the hosted provider inside the request the user is waiting on.
const TIMEOUT_MS = Number(Deno.env.get("VTON_QUEUE_TIMEOUT_MS") ?? 40_000);
const POLL_MS = Number(Deno.env.get("VTON_POLL_MS") ?? 350);

export function hybridEnabled(): boolean {
  return (Deno.env.get("VTON_ENGINE") ?? "").toLowerCase() === "hybrid";
}

const enc = new TextEncoder();

async function putJson(db: SupabaseClient, path: string, obj: unknown): Promise<void> {
  const { error } = await db.storage.from(BUCKET).upload(
    path, new Blob([enc.encode(JSON.stringify(obj))], { type: "application/json" }),
    { contentType: "application/json", upsert: true },
  );
  // NEVER swallow this: a silent enqueue failure looks exactly like a slow
  // worker, and we would poll for 40s on a job that was never created.
  if (error) throw new Error(`vton enqueue failed: ${error.message}`);
}

async function getJson(db: SupabaseClient, path: string): Promise<Record<string, unknown> | null> {
  const { data, error } = await db.storage.from(BUCKET).download(path);
  if (error || !data) return null;          // "not yet" is the common case
  try {
    return JSON.parse(await data.text());
  } catch {
    return null;
  }
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
  const id = crypto.randomUUID();

  await putJson(db, `${QUEUE}/${id}.json`, {
    id,
    user_id: userId,
    person_url: personUrl,
    steps: sortSteps(steps),
    created_at: new Date().toISOString(),
  });

  const deadline = Date.now() + TIMEOUT_MS;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, POLL_MS));
    const done = await getJson(db, `${DONE}/${id}.json`);
    if (!done) continue;

    // Read once, then drop the marker — nobody else is waiting on it, and the
    // prefix would otherwise grow forever.
    db.storage.from(BUCKET).remove([`${DONE}/${id}.json`]).catch(() => {});

    if (done.error) throw new Error(`vton render failed: ${done.error}`);
    const path = String(done.result_path ?? "");
    if (!path) throw new Error("vton finished with no result_path");

    const { data: blob, error } = await db.storage.from(BUCKET).download(path);
    if (error || !blob) throw new Error(`vton result unreadable: ${error?.message}`);
    const bytes = new Uint8Array(await blob.arrayBuffer());
    let bin = "";
    for (let i = 0; i < bytes.length; i += 0x8000) {
      bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
    }
    return { data: btoa(bin), mimeType: "image/jpeg" };
  }

  // Withdraw the job so a worker that picks it up late does not spend GPU time
  // on a render nobody is waiting for.
  db.storage.from(BUCKET).remove([`${QUEUE}/${id}.json`]).catch(() => {});
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

/** Dressing order matters: an outer layer must be painted after the torso piece
 *  it covers, and shoes last so the trouser hem is already final. */
const ORDER: Record<Slot, number> = { full: 0, upper: 1, lower: 2, shoes: 3 };

export function sortSteps(steps: DressStep[]): DressStep[] {
  return [...steps].sort((a, b) => ORDER[a.kind] - ORDER[b.kind]);
}
