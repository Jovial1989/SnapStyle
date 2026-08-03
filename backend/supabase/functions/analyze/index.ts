// POST /functions/v1/analyze  { image:{data(base64),mimeType}, profile? }
// Flow 1 outfit critique. Auth via Supabase JWT → gate on entitlements →
// Gemini → burn one free credit on success only (SDD §2.4 Pillar 2, §8.2).
import { admin, burnFree, canAnalyze, entitlementView, getEntitlement, getUser } from "../_shared/supabase.ts";
import { analyzeFit } from "../_shared/vision.ts";
import { json, preflight } from "../_shared/http.ts";

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const db = admin();
  const user = await getUser(req, db);
  if (!user) return json({ error: "unauthorized" }, 401);

  // `subject` = an ad-hoc body profile for someone who ISN'T the account owner
  // (guest flow, SDD §14.10). When present it overrides the owner's stored
  // profile for this read, and the saved review is tagged as a guest's.
  const { image, profile, subject } = await req.json().catch(() => ({}));
  if (!image?.data || !image?.mimeType) return json({ error: "image { data, mimeType } required" }, 400);
  const guest = subject && typeof subject === "object" && Object.keys(subject).length > 0;

  // Gate BEFORE spending a Gemini call. 402 → client shows paywall.
  const ent = await getEntitlement(db, user.id);
  if (!canAnalyze(ent)) return json({ error: "quota_exhausted", entitlement: entitlementView(ent) }, 402);

  try {
    // Factor in the user's confirmed body profile (height/type/proportions/ranges)
    // alongside any style preferences the client passed.
    // Guest → use the passed-in subject profile; owner → their stored profile.
    let bodyProfile = subject;
    if (!guest) {
      const { data: sp } = await db.from("style_profiles")
        .select("height_cm, body_type, proportions, estimated_measurements, style_dna")
        .eq("user_id", user.id).maybeSingle();
      bodyProfile = sp; // includes style_dna (taste) → factored into the read
    }
    const ctx = bodyProfile ? { ...(profile ?? {}), body_profile: bodyProfile } : profile;

    const result = await analyzeFit(image, ctx);
    await burnFree(db, user.id, ent); // success only; no-op if pro

    // Persist to history (best-effort — never fail the response on a storage hiccup).
    let generationId: string | null = null;
    try {
      generationId = crypto.randomUUID();
      const path = `${user.id}/${generationId}.jpg`;
      await db.storage.from("generations").upload(
        path, Uint8Array.from(atob(image.data), (c) => c.charCodeAt(0)),
        { contentType: image.mimeType, upsert: true },
      );
      await db.from("generations").insert({
        id: generationId, user_id: user.id, type: "critique", status: "succeeded", provider: "gemini",
        input: guest ? { guest: true } : {}, // named later on save (SDD §14.10)
        output: { image_path: path, analysis: result.analysis, model: result.model, promptVersion: result.promptVersion },
      });
    } catch (e) {
      console.error("[analyze] persist", (e as Error).message);
      generationId = null;
    }

    return json({ ...result, generationId, entitlement: entitlementView({ ...ent, free_used: ent.free_used + (ent.pro ? 0 : 1) }) });
  } catch (err) {
    console.error("[analyze]", (err as Error).message);
    return json({ error: "analysis_failed" }, 502); // quota NOT burned — user shouldn't pay for our failure
  }
});
