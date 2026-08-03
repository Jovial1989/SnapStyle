// POST /functions/v1/compare-looks  { images: [{data(b64),mimeType}] x2-4 }
// Fitting Room Copilot: the user tries several outfits in a store, snaps a
// mirror selfie of each — Gemini ranks them for THEIR build and explains why.
// Authed; burns one credit on success (one styling read per showdown).
import { admin, burnFree, canAnalyze, getEntitlement, getUser } from "../_shared/supabase.ts";
import { compareLooks } from "../_shared/gemini.ts";
import { json, preflight } from "../_shared/http.ts";

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const db = admin();
  const user = await getUser(req, db);
  if (!user) return json({ error: "unauthorized" }, 401);

  const { images, mode } = await req.json().catch(() => ({}));
  const judgeMode = mode === "piece" ? "piece" : "looks";
  const imgs = Array.isArray(images)
    ? images.filter((i) => i?.data && i?.mimeType).slice(0, 4)
    : [];
  if (imgs.length < 2) return json({ error: "2-4 images required" }, 400);

  const ent = await getEntitlement(db, user.id);
  if (!canAnalyze(ent)) return json({ error: "quota_exhausted" }, 402);

  try {
    const { data: sp } = await db.from("style_profiles")
      .select("body_type, proportions, source_photo_path").eq("user_id", user.id).maybeSingle();
    // IDENTITY GUARD: the ranking is calibrated to THIS user's build — judging
    // someone else's selfies silently would produce garbage advice. Fetch the
    // profile body photo as a reference; the model flags non-matching people.
    let reference: { data: string; mimeType: string } | undefined;
    const refPath = sp?.source_photo_path as string | undefined;
    if (refPath) {
      try {
        const { data: blob } = await db.storage.from("body-photos").download(refPath);
        if (blob) {
          const buf = new Uint8Array(await blob.arrayBuffer());
          let bin = "";
          for (let i = 0; i < buf.length; i += 0x8000) {
            bin += String.fromCharCode(...buf.subarray(i, i + 0x8000));
          }
          reference = { data: btoa(bin), mimeType: "image/jpeg" };
        }
      } catch (e) {
        console.error("[compare-looks] reference fetch", (e as Error).message);
      }
    }
    const result = await compareLooks(imgs, sp ?? undefined, reference, judgeMode);
    const mismatched = (result.looks ?? [])
      .filter((l) => l.same_person === false)
      .map((l) => l.index);
    if (reference && mismatched.length > 0) {
      // No credit burned — nothing useful was produced.
      return json({ error: "identity_mismatch", mismatched }, 422);
    }
    // Belt: sort best-first, clamp scores, drop hallucinated indexes.
    const looks = (result.looks ?? [])
      .filter((l) => Number.isInteger(l.index) && l.index >= 0 && l.index < imgs.length)
      .map((l) => ({ ...l, score: Math.max(0, Math.min(100, l.score | 0)), same_person: undefined }))
      .sort((a, b) => b.score - a.score);
    if (looks.length === 0) throw new Error("empty ranking");
    await burnFree(db, user.id, ent);
    return json({ looks });
  } catch (err) {
    console.error("[compare-looks]", (err as Error).message);
    return json({ error: "compare_failed" }, 502);
  }
});
