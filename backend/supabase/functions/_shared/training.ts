// Training-pair logger — a fire-and-forget byproduct of every successful
// render. Captures (person + garment references + result + instruction) so we
// accumulate a PROPRIETARY paired dataset for future VTON distillation (teach
// a cheap fast local model what Gemini produces). Costs ~nothing, never blocks
// or breaks a render: every path is wrapped and failures are swallowed.
//
// Storage: bucket `training-pairs` (private, service-role only). The result
// already lives in its own bucket — we store its path, not a copy.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";

const BUCKET = "training-pairs";
const b64ToBytes = (b64: string) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
const ext = (m: string) => (m.includes("png") ? "png" : m.includes("webp") ? "webp" : "jpg");

export interface TrainingPairInput {
  userId: string;
  renderId: string;
  source: "fix" | "look";
  person: { data: string; mimeType: string } | null; // inline b64
  refs: { data: string; mimeType: string }[]; // inline b64 garment references
  resultBucket: string;
  resultPath: string; // already-persisted result image
  instruction: string;
  meta?: Record<string, unknown>;
}

/** Persist one training pair. Fire-and-forget: awaitable, but any error is
 * logged and swallowed so the caller's render is never affected. */
export async function logTrainingPair(db: SupabaseClient, p: TrainingPairInput): Promise<void> {
  try {
    const base = `${p.userId}/${p.renderId}`;
    let personPath: string | null = null;
    if (p.person?.data) {
      personPath = `${base}/person.${ext(p.person.mimeType)}`;
      await db.storage.from(BUCKET).upload(personPath, b64ToBytes(p.person.data), {
        contentType: p.person.mimeType, upsert: true,
      });
    }
    const refPaths: string[] = [];
    for (let i = 0; i < p.refs.length && i < 6; i++) {
      const r = p.refs[i];
      if (!r?.data) continue;
      const rp = `${base}/ref_${i}.${ext(r.mimeType)}`;
      const { error } = await db.storage.from(BUCKET).upload(rp, b64ToBytes(r.data), {
        contentType: r.mimeType, upsert: true,
      });
      if (!error) refPaths.push(rp);
    }
    await db.from("training_pairs").insert({
      user_id: p.userId,
      render_id: p.renderId,
      source: p.source,
      person_path: personPath,
      ref_paths: refPaths,
      result_bucket: p.resultBucket,
      result_path: p.resultPath,
      instruction: p.instruction,
      meta: p.meta ?? {},
    });
  } catch (e) {
    console.error("[training] log skipped:", (e as Error).message);
  }
}
