// POST /functions/v1/render-look  { render_id }
// INTERNAL fan-out worker (one invocation = one look). The generate-look
// dispatcher fires N of these concurrently, each with the service-role key —
// this is the "GPU worker + webhook" of the async architecture collapsed into
// one hop: Gemini responds synchronously, so the worker updates the row itself
// (status pending → completed/failed) and Supabase Realtime pushes the flip to
// the Flutter client. The last sibling to finish finalizes the parent set.
import { admin, getUser, signedUrl } from "../_shared/supabase.ts";
import { fetchInline, IDENTITY_RETRY_NOTE } from "../_shared/gemini.ts";
import { generateLookImage } from "../_shared/imagegen.ts";
import { type DressStep, hybridDress, hybridEnabled, slotOf } from "../_shared/vton.ts";
import { samePerson, validateLookImages } from "../_shared/vision.ts";
import { finalizeGeneration, refreshGenerationOutput } from "../_shared/renders.ts";
import { logTrainingPair } from "../_shared/training.ts";
import { json, preflight } from "../_shared/http.ts";

const IN_BUCKET = "body-photos";
const OUT_BUCKET = "generations";

const b64ToBytes = (b64: string) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  // Two callers: the dispatcher (service-role key, renders pending rows) and
  // the app itself (user JWT, per-card RETRY of the user's OWN failed row —
  // fault isolation: one dead look re-runs without touching the rest).
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const internal = req.headers.get("Authorization") === `Bearer ${service}`;

  const { render_id } = await req.json().catch(() => ({}));
  if (!render_id) return json({ error: "render_id required" }, 400);

  const db = admin();
  const { data: row } = await db.from("look_renders")
    .select("id, generation_id, user_id, look_index, status, meta")
    .eq("id", render_id).maybeSingle();
  if (!row) return json({ error: "not_found" }, 404);

  if (internal) {
    if (row.status !== "pending") return json({ ok: true, skipped: true }); // idempotent redelivery
  } else {
    const user = await getUser(req, db);
    if (!user || user.id !== row.user_id) return json({ error: "forbidden" }, 403);
    if (row.status !== "failed") return json({ error: "not_retryable", status: row.status }, 409);
    // failed → pending flows through Realtime, so the card flips back to its
    // shimmer on every subscribed device before the re-render starts. Also
    // re-opens the parent set (finalize may have already closed it).
    await db.from("look_renders")
      .update({ status: "pending", error: null, updated_at: new Date().toISOString() })
      .eq("id", render_id).eq("status", "failed");
    await db.from("generations")
      .update({ status: "processing", updated_at: new Date().toISOString() })
      .eq("id", row.generation_id).in("status", ["failed", "succeeded"]);
  }

  try {
    const { data: gen } = await db.from("generations")
      .select("input").eq("id", row.generation_id).maybeSingle();
    const photoPath = (gen?.input as { photoPath?: string } | null)?.photoPath;
    if (!photoPath) throw new Error("parent generation has no photoPath");

    const meta = (row.meta ?? {}) as {
      prompt?: string;
      reference_paths?: string[];
      dress?: { path: string; slot: string; label: string }[];
      kept_from_photo?: string[];
    };
    // 768px transform of the body photo (Storage Image Transformation):
    // smaller input = fewer input tokens = a visibly faster Gemini response.
    // Raw-URL fallback keeps working if the transform endpoint rejects.
    // Source preference: CANONICAL AVATAR (person in neutral grey basics,
    // QA-gated once per photo — identity anchored, no source-outfit bleed)
    // → clean cutout → raw upload. The avatar is SKIPPED when the look keeps
    // garments from the photo (closet kept_from_photo): "keep what they wear"
    // must see the real outfit, not the mannequin basics.
    const keepsPhotoGarments = (meta.kept_from_photo ?? []).length > 0;
    const sources = [
      ...(keepsPhotoGarments ? [] : [`${photoPath}.avatar.png`]),
      `${photoPath}.clean.png`,
    ];
    let person;
    for (const p of sources) {
      try {
        const { data: t } = await db.storage.from(IN_BUCKET)
          .createSignedUrl(p, 300, { transform: { width: 768, quality: 80 } });
        if (t?.signedUrl) { person = await fetchInline(t.signedUrl); break; }
      } catch (_) {/* try the next source */}
    }
    if (!person) {
      try {
        const { data: t } = await db.storage.from(IN_BUCKET)
          .createSignedUrl(photoPath, 300, { transform: { width: 768, quality: 80 } });
        person = await fetchInline(t!.signedUrl);
      } catch {
        person = await fetchInline(await signedUrl(db, IN_BUCKET, photoPath, 300));
      }
    }
    const prompt = String(meta.prompt ?? "");
    if (!prompt) throw new Error("row meta has no prompt");

    // CLOSET GROUNDING: the wardrobe pieces' own images are attached AFTER the
    // person so the prompt's "reproduce these exact garments" has real pixels
    // to copy — this is what stops the model inventing shoes or turning a tee
    // into a shirt. Best-effort per image; a missing one just renders text-only.
    const references: Awaited<ReturnType<typeof fetchInline>>[] = [];
    for (const p of (meta.reference_paths ?? []).slice(0, 5)) {
      try {
        const { data: t } = await db.storage.from("wardrobe")
          .createSignedUrl(p, 300, { transform: { width: 512, quality: 80 } });
        if (t?.signedUrl) references.push(await fetchInline(t.signedUrl));
      } catch (_) {
        try {
          references.push(await fetchInline(await signedUrl(db, "wardrobe", p, 300)));
        } catch (_) {/* this piece renders text-only */}
      }
    }

    // SELF-HOSTED ENGINE for looks built from REAL garments. It dresses one
    // zone at a time from a photo of the piece, so it needs (image, zone) pairs
    // — `meta.dress`, written by the planner. A look INVENTED from text has no
    // garment photo for the adapter to transfer, so those stay hosted; that is a
    // property of the approach, not a gap to paper over.
    let img: Awaited<ReturnType<typeof generateLookImage>> | null = null;
    if (hybridEnabled() && (meta.dress ?? []).length) {
      try {
        const steps: DressStep[] = [];
        for (const d of meta.dress!) {
          const kind = slotOf(d.slot);
          if (!kind) continue;   // accessories have no mask zone — skip, don't guess
          const { data: t } = await db.storage.from("wardrobe")
            .createSignedUrl(d.path, 900, { transform: { width: 768, quality: 85 } });
          if (t?.signedUrl) steps.push({ url: t.signedUrl, kind, hint: d.label });
        }
        if (steps.length) {
          // Start from the CANONICAL AVATAR (the person re-dressed in neutral
          // grey basics) for the same reason the hosted path prefers it: each
          // dressing pass repaints one zone, so any garment still on the body in
          // an uncovered zone survives into the result. Grey basics are the
          // neutral base; the raw photo would leave the old outfit showing.
          // Skipped when the look deliberately keeps garments from the photo.
          let personUrl: string | null = null;
          for (const cand of keepsPhotoGarments ? [photoPath] : [`${photoPath}.avatar.png`, photoPath]) {
            try {
              const { data: t } = await db.storage.from(IN_BUCKET)
                .createSignedUrl(cand, 900, { transform: { width: 768, quality: 85 } });
              if (t?.signedUrl) { personUrl = t.signedUrl; break; }
            } catch (_) {/* try the next source */}
          }
          if (!personUrl) throw new Error("no person image for hybrid render");
          img = await hybridDress(db, row.user_id, personUrl, steps);
          console.log("[render-look]", row.id, `hybrid: ${steps.length} steps`);
        }
      } catch (e) {
        console.error("[render-look] hybrid failed, using hosted:", (e as Error).message);
      }
    }
    img ??= await generateLookImage(person, prompt, references);
    // PRE-PAINT IDENTITY GATE: never let a different human reach the grid.
    try {
      if (!(await samePerson(img, person))) {
        console.error("[render-look]", row.id, "identity gate: regenerating");
        img = await generateLookImage(person, prompt + IDENTITY_RETRY_NOTE, references);
      }
    } catch { /* gate down → validateLookImages still runs */ }

    const path = `${row.user_id}/${row.generation_id}-${row.look_index}.png`;
    const { error: upErr } = await db.storage.from(OUT_BUCKET)
      .upload(path, b64ToBytes(img.data), { contentType: img.mimeType, upsert: true });
    if (upErr) throw new Error(`upload: ${upErr.message}`);

    await db.from("look_renders")
      .update({ status: "completed", image_path: path, updated_at: new Date().toISOString() })
      .eq("id", render_id);

    // Training-pair capture (fire-and-forget): INPUT person + closet refs +
    // result + prompt → proprietary VTON dataset for future distillation.
    // deno-lint-ignore no-explicit-any
    const rtLog = (globalThis as any).EdgeRuntime;
    const logP = logTrainingPair(db, {
      userId: row.user_id as string, renderId: String(render_id), source: "look",
      person: { data: person.data, mimeType: person.mimeType }, refs: references,
      resultBucket: OUT_BUCKET, resultPath: path, instruction: prompt,
      meta: { tier: (meta as { tier?: string }).tier ?? null },
    });
    if (rtLog?.waitUntil) rtLog.waitUntil(logP); else await logP;

    // Validation runs OFF the critical path: before, every card paid the
    // validator's ~1.5-2s before it could flip. Now the card completes the
    // moment the upload lands; the RARE invalid render is demoted to failed
    // afterwards (Realtime flips the card back, per-card Retry applies).
    const demote = (async () => {
      let valid = true;
      try {
        valid = (await validateLookImages([img]))[0] !== false;
      } catch { /* validator down ≠ render failed */ }
      if (valid) return;
      await db.from("look_renders")
        .update({ status: "failed", error: "invalid render (validator rejected)", updated_at: new Date().toISOString() })
        .eq("id", render_id);
      await refreshGenerationOutput(db, row.generation_id as string);
    })();
    // deno-lint-ignore no-explicit-any
    const rt = (globalThis as any).EdgeRuntime;
    if (rt?.waitUntil) rt.waitUntil(demote);
    else await demote;
  } catch (err) {
    console.error("[render-look]", render_id, (err as Error).message);
    await db.from("look_renders")
      .update({ status: "failed", error: (err as Error).message.slice(0, 300), updated_at: new Date().toISOString() })
      .eq("id", render_id);
  }

  await finalizeGeneration(db, row.generation_id as string, row.user_id as string);
  return json({ ok: true });
});
