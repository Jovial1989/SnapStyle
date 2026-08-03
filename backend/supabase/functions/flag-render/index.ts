// POST /functions/v1/flag-render
// A user tapped "not right — regenerate" on a try-on render. We capture the
// WRONG result as a NEGATIVE training pair (person + garment refs + the bad
// output + a reason category) — labeled data for the future VTON distillation:
// "given these inputs, this is what a BAD render looks like, and why". The
// regeneration itself is a separate normal render call from the client; this
// endpoint only records the signal. Fire-and-forget, never blocks the client.
import { admin, getUser } from "../_shared/supabase.ts";
import { json, preflight } from "../_shared/http.ts";

const BUCKET = "training-pairs";
const b64ToBytes = (b64: string) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
const ext = (m: string) => (m.includes("png") ? "png" : m.includes("webp") ? "webp" : "jpg");

// Allow-list the reason so meta stays clean/queryable.
const REASONS = new Set(["wrong_item", "bad_fit", "background", "not_me", "other"]);

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const db = admin();
  const user = await getUser(req, db);
  if (!user) return json({ error: "unauthorized" }, 401);

  const body = await req.json().catch(() => ({}));
  const reason = REASONS.has(String(body?.reason)) ? String(body.reason) : "other";
  const instruction = String(body?.instruction ?? "");
  const person = body?.person as { data?: string; mimeType?: string } | undefined;
  const wrong = body?.wrong as { data?: string; mimeType?: string } | undefined;
  const refs = (Array.isArray(body?.refs) ? body.refs : [])
    .filter((r: { data?: string }) => r?.data)
    .slice(0, 6) as { data: string; mimeType: string }[];
  if (!wrong?.data) return json({ error: "wrong image required" }, 400);

  try {
    // Unique id for this negative sample (no crypto needed — user + timestamp).
    const rid = `neg_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
    const base = `${user.id}/${rid}`;

    const resultPath = `${base}/result.${ext(wrong.mimeType ?? "jpg")}`;
    await db.storage.from(BUCKET).upload(resultPath, b64ToBytes(wrong.data), {
      contentType: wrong.mimeType ?? "image/jpeg", upsert: true,
    });

    let personPath: string | null = null;
    if (person?.data) {
      personPath = `${base}/person.${ext(person.mimeType ?? "jpg")}`;
      await db.storage.from(BUCKET).upload(personPath, b64ToBytes(person.data), {
        contentType: person.mimeType ?? "image/jpeg", upsert: true,
      });
    }
    const refPaths: string[] = [];
    for (let i = 0; i < refs.length; i++) {
      const r = refs[i];
      const rp = `${base}/ref_${i}.${ext(r.mimeType)}`;
      const { error } = await db.storage.from(BUCKET).upload(rp, b64ToBytes(r.data), {
        contentType: r.mimeType, upsert: true,
      });
      if (!error) refPaths.push(rp);
    }

    await db.from("training_pairs").insert({
      user_id: user.id,
      render_id: rid,
      source: "fix",
      person_path: personPath,
      ref_paths: refPaths,
      result_bucket: BUCKET,
      result_path: resultPath,
      instruction,
      meta: { label: "negative", reason, flagged: true },
    });
    return json({ ok: true });
  } catch (e) {
    console.error("[flag-render]", (e as Error).message);
    // Never surface an error — the regeneration proceeds regardless.
    return json({ ok: false });
  }
});
