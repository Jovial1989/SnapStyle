// POST /functions/v1/set-body-photo  { photoPath }
// Update the user's default body photo. style_profiles is service-role-write
// only (clients have SELECT-only RLS), so this runs under admin(). The client
// uploads the image to its own body-photos folder first, then calls this. §14.11
import { admin, getUser } from "../_shared/supabase.ts";
import { cleanBodyPhoto } from "../_shared/clean_photo.ts";
import { buildCanonicalAvatar } from "../_shared/avatar.ts";
import { json, preflight } from "../_shared/http.ts";

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const db = admin();
  const user = await getUser(req, db);
  if (!user) return json({ error: "unauthorized" }, 401);

  const { photoPath } = await req.json().catch(() => ({}));
  if (!photoPath) return json({ error: "photoPath required" }, 400);
  // Enforce the user can only reference their own storage folder.
  if (!String(photoPath).startsWith(`${user.id}/`)) {
    return json({ error: "photoPath must be in your own folder" }, 403);
  }

  // A profile row must already exist (height is required to create one).
  const { data: existing } = await db.from("style_profiles")
    .select("user_id").eq("user_id", user.id).maybeSingle();
  if (!existing) return json({ error: "no_profile" }, 422);

  const { error } = await db.from("style_profiles")
    .update({ source_photo_path: photoPath, updated_at: new Date().toISOString() })
    .eq("user_id", user.id);
  if (error) {
    console.error("[set-body-photo]", error.message);
    return json({ error: "update_failed" }, 502);
  }
  // Fire-and-forget: isolate the silhouette once, then build the CANONICAL
  // AVATAR from it (person in neutral grey basics, QA-gated) — every future
  // Generate-my-look render starts from that stable, identity-anchored canvas
  // instead of re-editing the raw photo. Neither step blocks this response.
  // deno-lint-ignore no-explicit-any
  (globalThis as any).EdgeRuntime?.waitUntil?.(
    cleanBodyPhoto(db, String(photoPath))
      .then(() => buildCanonicalAvatar(db, String(photoPath))),
  );
  return json({ ok: true, photoPath });
});
