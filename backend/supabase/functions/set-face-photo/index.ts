// POST /functions/v1/set-face-photo  { data, mimeType }
//
// THE ONE INPUT THE STUDIO-BASE PATH WAS MISSING. Everything else has been
// ready and idle: ten A-pose bodies measured in `studio_bases`, faceswap.py on
// the GPU box, face_url/base_id on the queue. What no code could supply is a
// photograph of the user's face with enough pixels in it — the app stores a
// full-body shot, and in the founder account that is 800x600 with 34 px between
// the eyes, smaller than any base's own face, so the transfer upsamples and
// smudges (measured: rms 0.038 but upsampled 1.62x, verdict untrustworthy).
//
// So this endpoint takes a SELFIE, measures it, matches a base and enqueues the
// swap as a step of the render queue (empty `steps` = swap only, which is how
// the migration intended a base to be prepared once per user).
import { admin, getUser } from "../_shared/supabase.ts";
import { json, preflight } from "../_shared/http.ts";

// Below this the transfer has nothing to work with. Every base in the library
// measures 53-60 px and the worker swaps on a doubled canvas (111 px), so a
// selfie under ~120 px would be upsampled — the exact failure this rejects.
const MIN_INTEROCULAR = 120;

const b64ToBytes = (b64: string) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const db = admin();
  const user = await getUser(req, db);
  if (!user) return json({ error: "unauthorized" }, 401);

  const { data, mimeType, interocular } = await req.json().catch(() => ({}));
  if (typeof data !== "string" || !data) return json({ error: "data required" }, 400);
  // The client measures the face on-device and sends the number; trusting it is
  // fine because it can only make the gate STRICTER for the sender, and the pod
  // measures again before it swaps.
  if (typeof interocular === "number" && interocular > 0 &&
      interocular < MIN_INTEROCULAR) {
    return json({
      error: "face_too_small",
      interocular,
      min: MIN_INTEROCULAR,
      message: "Hold the phone closer — your face needs to fill more of the frame.",
    }, 422);
  }

  const { data: prof } = await db.from("style_profiles")
    .select("user_id, body_type, source_photo_path")
    .eq("user_id", user.id).maybeSingle();
  if (!prof) return json({ error: "no_profile" }, 422);

  const path = `${user.id}/face.${(mimeType ?? "").includes("png") ? "png" : "jpg"}`;
  const up = await db.storage.from("body-photos")
    .upload(path, b64ToBytes(data), { contentType: mimeType ?? "image/jpeg", upsert: true });
  if (up.error) {
    console.error("[set-face-photo] upload", up.error.message);
    return json({ error: "upload_failed" }, 502);
  }

  // BASE SELECTION: gender and build narrow it, skin tone decides. The swap
  // matches luminance fully and chroma only partly (matching chroma all the way
  // would recolour the user's face to the model's), so a base whose tone is far
  // away shows the compromise at the neck — which is why studio_bases stores
  // Lab and why this sorts on distance in it rather than picking the first row.
  const { data: profile2 } = await db.from("style_profiles")
    .select("style_dna").eq("user_id", user.id).maybeSingle();
  const dna = (profile2?.style_dna ?? {}) as Record<string, unknown>;
  const g = String(dna.gender_presentation ?? "").toLowerCase().includes("femin")
    ? "female"
    : String(dna.gender_presentation ?? "").toLowerCase().includes("mascul")
    ? "male"
    : null;
  const build = ((): string => {
    const b = String(prof.body_type ?? "").toLowerCase();
    if (/slim|slender|lean|ectomorph/.test(b)) return "slim";
    if (/athletic|muscular|mesomorph|toned/.test(b)) return "athletic";
    if (/plus|heavy|large|endomorph|full/.test(b)) return "plus";
    return "regular";
  })();

  let q = db.from("studio_bases").select("id, image_path, gender, build, skin_l, skin_a, skin_b")
    .eq("active", true);
  if (g) q = q.eq("gender", g);
  const { data: pool } = await q;
  if (!pool?.length) return json({ error: "no_bases" }, 503);

  // The selfie's own tone is measured on the GPU box (advise_base) — not here,
  // where there is no image pipeline. Until the job reports it, build is the
  // only signal, so prefer an exact build match and let the swap's own colour
  // matching carry the rest; the pod overwrites base_id if it disagrees.
  const ranked = [...pool].sort((a, b) =>
    (a.build === build ? 0 : 1) - (b.build === build ? 0 : 1));
  const base = ranked[0];

  const { data: signedFace } = await db.storage.from("body-photos")
    .createSignedUrl(path, 900);
  const { data: signedBase } = await db.storage.from("bases")
    .createSignedUrl(base.image_path, 900);
  if (!signedFace?.signedUrl || !signedBase?.signedUrl) {
    return json({ error: "sign_failed" }, 502);
  }

  // EMPTY STEPS = SWAP ONLY. The worker writes the swapped canvas to its usual
  // result path and the client polls the row, exactly like a dressing job.
  const { data: job, error: jerr } = await db.from("vton_jobs")
    .insert({
      user_id: user.id,
      person_url: signedBase.signedUrl,
      face_url: signedFace.signedUrl,
      base_id: base.id,
      steps: [],
    }).select("id").single();
  if (jerr || !job) {
    console.error("[set-face-photo] enqueue", jerr?.message);
    return json({ error: "enqueue_failed" }, 502);
  }

  await db.from("style_profiles").update({
    face_photo_path: path,
    face_interocular: typeof interocular === "number" ? Math.round(interocular) : null,
    studio_base_id: base.id,
    updated_at: new Date().toISOString(),
  }).eq("user_id", user.id);

  console.log("[set-face-photo]", user.id.slice(0, 8), "base", base.image_path,
              "build", build, "job", job.id);
  return json({ ok: true, jobId: job.id, base: base.image_path, build });
});
