// POST /functions/v1/onboarding-profile  { photoPath, heightCm }
// Onboarding body profiling. Auth via JWT → signed URL for the user's own photo →
// Gemini pro profiling → upsert style_profiles. Synchronous (single call). SDD §5.5.
import { admin, getUser, signedUrl } from "../_shared/supabase.ts";
import { fetchInline } from "../_shared/gemini.ts";
import { analyzeBodyProfile } from "../_shared/vision.ts";
import { cleanBodyPhoto } from "../_shared/clean_photo.ts";
import { buildCanonicalAvatar } from "../_shared/avatar.ts";
import { json, preflight } from "../_shared/http.ts";

const BUCKET = "body-photos";

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const db = admin();
  const user = await getUser(req, db);
  if (!user) return json({ error: "unauthorized" }, 401);

  // `ephemeral` = estimate only, do NOT persist to style_profiles. Used to
  // profile a *guest* (someone who isn't the account owner) without clobbering
  // the owner's saved profile (SDD §14.10).
  const { photoPath, heightCm, ephemeral } = await req.json().catch(() => ({}));
  if (!photoPath) return json({ error: "photoPath required" }, 400);
  const h = Number(heightCm);
  if (!h || h < 100 || h > 250) return json({ error: "valid heightCm required" }, 400);
  // Enforce the user can only reference their own storage folder (<uid>/...).
  if (!String(photoPath).startsWith(`${user.id}/`)) return json({ error: "photoPath must be in your own folder" }, 403);

  // Mark processing so the client can show the analyzing state immediately.
  // Skipped for guest (ephemeral) estimates — we never touch the owner's row.
  if (!ephemeral) {
    await db.from("style_profiles").upsert({
      user_id: user.id, height_cm: h, source_photo_path: photoPath,
      status: "processing", updated_at: new Date().toISOString(),
    });
  }

  try {
    const url = await signedUrl(db, BUCKET, photoPath);
    const { profile, model, promptVersion } = await analyzeBodyProfile(await fetchInline(url), h);

    if (profile.analyzable === false) {
      if (!ephemeral) await db.from("style_profiles").update({ status: "failed" }).eq("user_id", user.id);
      return json({ error: "unanalyzable_photo", note: profile.note }, 422);
    }

    const row = {
      user_id: user.id, height_cm: h, source_photo_path: photoPath,
      body_type: profile.body_type ?? null,
      proportions: profile.proportions ?? {},
      estimated_measurements: profile.estimated_measurements ?? {},
      confidence: profile.confidence ?? null,
      model, prompt_version: promptVersion, status: "ready",
      updated_at: new Date().toISOString(),
    };
    // Ephemeral: return the estimate without persisting (guest never overwrites owner).
    if (ephemeral) return json({ profile: row, stylingNotes: profile.styling_notes ?? [] });
    await db.from("style_profiles").upsert(row);
    // Fire-and-forget: clean cutout + CANONICAL AVATAR for the onboarding
    // photo. (cleanBodyPhoto was imported here but never actually called —
    // onboarding photos silently skipped isolation until set-body-photo ran.)
    // deno-lint-ignore no-explicit-any
    (globalThis as any).EdgeRuntime?.waitUntil?.(
      cleanBodyPhoto(db, String(photoPath))
        .then(() => buildCanonicalAvatar(db, String(photoPath))),
    );
    return json({ profile: row, stylingNotes: profile.styling_notes ?? [] });
  } catch (err) {
    console.error("[onboarding-profile]", (err as Error).message);
    if (!ephemeral) await db.from("style_profiles").update({ status: "failed" }).eq("user_id", user.id);
    return json({ error: "profiling_failed" }, 502);
  }
});
