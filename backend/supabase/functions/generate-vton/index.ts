// POST /generate-vton — photorealistic try-on for the mobile client.
//
// Body: { garmentId: string, category: 'upper_body'|'lower_body'|'dresses',
//         garmentImageUrl?: string,   // optional override; else resolved from affiliate_items
//         humanPath?: string }        // optional body-photos path; else the profile photo
// 200:  { ok: true, url, generationId, ms, entitlement }
//
// This is the Node prototype (pipeline-3d/vton.ts) folded into the platform the
// app already talks to: same Bearer-JWT auth, same quota ledger, same deploy
// path as every other function. The Kolors call itself is the _shared/kolors.ts
// bridge that fix-render has been using in production — one engine, two doors.
//
// Ordering that matters: fal's result URLs die within a day, so the image is
// re-hosted into OUR storage before any row is written; and the free credit is
// burned only after everything (render + upload + insert) succeeded — a failed
// generation must never cost the user a token.
import { json, preflight } from "../_shared/http.ts";
import { NO_BRAND_CLAUSE, promptSafeName } from "../_shared/garment_names.ts";
import {
  admin,
  burnFree,
  canAnalyze,
  entitlementView,
  getEntitlement,
  getUser,
  signedUrl,
} from "../_shared/supabase.ts";
import { kolorsTryOn, kolorsChannel } from "../_shared/kolors.ts";
import { fetchInline, IDENTITY_RETRY_NOTE } from "../_shared/gemini.ts";
import { generateLookImage } from "../_shared/imagegen.ts";
import { samePerson } from "../_shared/vision.ts";

const BUCKET = "vton";
const CATEGORIES = new Set(["upper_body", "lower_body", "dresses"]);
const ID = /^[A-Za-z0-9_-]{1,64}$/;

Deno.serve(async (req) => {
  const pf = preflight(req);
  if (pf) return pf;
  const started = Date.now();

  const db = admin();
  const user = await getUser(req, db);
  if (!user) return json({ error: "unauthorized" }, 401);

  const ent = await getEntitlement(db, user.id);
  if (!canAnalyze(ent)) return json({ error: "quota_exhausted", ...entitlementView(ent) }, 402);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON" }, 400);
  }
  // Single item {garmentId, category} → Kolors (exact-copy champion).
  // Batch {garmentIds: [..]} → ONE Gemini render of the whole look — the
  // commit path of the two-tier architecture: browse free, commit once.
  const garmentIds = Array.isArray(body.garmentIds)
    ? (body.garmentIds as unknown[]).filter((g): g is string => typeof g === "string" && ID.test(g))
    : [];
  const garmentId = typeof body.garmentId === "string" ? body.garmentId : "";
  const category = typeof body.category === "string" ? body.category : "";
  const batch = garmentIds.length > 1;
  if (!batch) {
    if (!ID.test(garmentIds[0] ?? garmentId)) return json({ error: "invalid garmentId" }, 400);
    if (!CATEGORIES.has(category)) {
      // Kolors renders out-of-scope garments AS clothing (sandals → shorts,
      // verified in the spike) — reject loudly instead of billing a bad image.
      return json({ error: `category must be one of ${[...CATEGORIES].join(", ")}` }, 422);
    }
  } else if (garmentIds.length > 5) {
    return json({ error: "at most 5 garments per look" }, 422);
  }

  try {
    // ── person: explicit path (own folder only) or the profile body photo ──
    let humanPath = typeof body.humanPath === "string" ? body.humanPath : "";
    let photoSince: string | null = null;
    if (humanPath) {
      // The JWT names the caller; a path outside their folder is someone
      // else's photo no matter how well-formed the request is.
      if (!humanPath.startsWith(`${user.id}/`)) return json({ error: "humanPath not yours" }, 403);
    } else {
      const { data: prof } = await db.from("style_profiles")
        .select("source_photo_path, updated_at").eq("user_id", user.id).single();
      humanPath = prof?.source_photo_path ?? "";
      if (!humanPath) return json({ error: "no body photo on profile" }, 409);
      photoSince = prof?.updated_at ?? null;
    }

    const cacheKey = batch ? garmentIds.join("+") : (garmentIds[0] ?? garmentId);
    {
      let q = db.from("look_generations")
        .select("id, image_url, created_at")
        .eq("user_id", user.id).eq("garment_id", cacheKey)
        .order("created_at", { ascending: false }).limit(1);
      if (photoSince) q = q.gte("created_at", photoSince);
      const { data: hit } = await q;
      if (hit && hit.length) {
        // Batch results live in the private bucket — re-sign; single results
        // are public URLs stored verbatim.
        let url = hit[0].image_url as string;
        if (!url.startsWith("http")) url = await signedUrl(db, "generations", url, 3600);
        return json({ ok: true, url, generationId: hit[0].id, cached: true,
                      ms: Date.now() - started, entitlement: entitlementView(ent) });
      }
    }

    // Person source preference (same chain as render-look): canonical grey-
    // basics avatar → cleaned cutout → raw upload. Kills the "fitting-room
    // background" in commits and removes street clothes from under the look.
    let person: Awaited<ReturnType<typeof fetchInline>> | null = null;
    for (const cand of [`${humanPath}.avatar.png`, `${humanPath}.clean.png`, humanPath]) {
      try {
        person = await fetchInline(await signedUrl(db, "body-photos", cand));
        break;
      } catch (_) { /* next candidate */ }
    }
    if (!person) return json({ error: "body photo unreadable" }, 502);

    let render: typeof person;
    let provider: string;
    let ledgerCategory = category;
    let ledgerGarment = garmentIds[0] ?? garmentId;

    if (batch) {
      // ── whole look: one Gemini render grounded on every item's pixels ──
      const { data: items } = await db.from("affiliate_items")
        .select("id, name, category, image_url").in("id", garmentIds);
      if (!items || items.length !== garmentIds.length) {
        return json({ error: "some garments not found" }, 404);
      }
      const refs = await Promise.all(items.map((i) => fetchInline(i.image_url)));
      const list = items.map((i, n) => `${n + 1}. ${promptSafeName(i.name as string)} (${i.category})`).join("\n");
      const prompt =
        `Dress the person from the FIRST image in ALL of these exact garments:\n${list}\n` +
        `The garment photos follow in the same order — COPY each garment exactly ` +
        `(colour, print, cut, length); do not substitute or restyle anything. ` +
        NO_BRAND_CLAUSE +
        `Keep the person's identity, face, body, pose, framing and background ` +
        `completely unchanged. Full body must stay in frame, feet visible.`;
      render = await generateLookImage(person, prompt, refs);
      // one identity retry — the known Gemini failure mode
      if (!(await samePerson(render, person).catch(() => true))) {
        render = await generateLookImage(person, prompt + IDENTITY_RETRY_NOTE, refs);
        // RE-CHECK the retry (28.07 incident: the retry was shipped blind and
        // an impostor reached the user). An honest error beats a wrong face.
        if (!(await samePerson(render, person).catch(() => true))) {
          return json({ error: "identity_failed", message: "Couldn't render this look on you — try again." }, 502);
        }
      }
      provider = "gemini";
      ledgerGarment = garmentIds.join("+");
      ledgerCategory = items.some((i) => i.category === "top" || i.category === "outerwear")
        ? "upper_body" : "lower_body";
    } else {
      // ── single item: Kolors (no cut inheritance, exact copy) ──
      let garmentUrl = typeof body.garmentImageUrl === "string" ? body.garmentImageUrl : "";
      if (garmentUrl) {
        // Only our own storage — this function must not be a proxy that feeds
        // arbitrary internet images into a paid model under our key.
        const origin = `${Deno.env.get("SUPABASE_URL")}/storage/v1/`;
        if (!garmentUrl.startsWith(origin)) return json({ error: "garmentImageUrl must be our storage" }, 400);
      } else {
        const { data: item } = await db.from("affiliate_items")
          .select("image_url").eq("id", ledgerGarment).single();
        garmentUrl = item?.image_url ?? "";
        if (!garmentUrl) return json({ error: "garment not found" }, 404);
      }
      const garment = await fetchInline(garmentUrl);
      // A/B 28.07 on the canonical grey-basics avatar: Gemini matched or beat
      // Kolors on all three fidelity cases (plaid scale, short length+stripe,
      // wide-leg cut) at $0.039 vs $0.07 — Kolors' no-cut-inheritance edge
      // vanishes when the base wears neutral basics. Default = gemini;
      // secret VTON_SINGLE=kolors flips back without a deploy.
      // (fix-render is NOT switched: its inputs are mid-edit photos in street
      // clothes, where Kolors' strength still applies.)
      if (Deno.env.get("VTON_SINGLE") === "kolors") {
        render = await kolorsTryOn(person, garment);
        provider = `kolors-${kolorsChannel()}`;
      } else {
        const { data: item } = await db.from("affiliate_items")
          .select("name, category").eq("id", ledgerGarment).maybeSingle();
        const gname = promptSafeName(item?.name ?? "the garment");
        const keep = (item?.category ?? category) === "bottom" || category === "lower_body"
          ? "keep his current top and shoes" : "keep his current bottoms and shoes";
        const prompt =
          `Dress the person from the FIRST image in this exact garment: ${gname}. ` +
          `COPY the garment from the second image exactly — colour, print, pattern ` +
          `alignment, cut, length. ` + NO_BRAND_CLAUSE +
          `Keep the person's identity, face, body, pose, ` +
          `framing and background completely unchanged; ${keep}. Full body in frame.`;
        render = await generateLookImage(person, prompt, [garment]);
        if (!(await samePerson(render, person).catch(() => true))) {
          render = await generateLookImage(person, prompt + IDENTITY_RETRY_NOTE, [garment]);
          if (!(await samePerson(render, person).catch(() => true))) {
            return json({ error: "identity_failed", message: "Couldn't render this look on you — try again." }, 502);
          }
        }
        provider = "gemini";
      }
    }

    // ── persist: storage first, ledger second (see header) ──
    const ext = render.mimeType.includes("png") ? "png" : render.mimeType.includes("webp") ? "webp" : "jpg";
    const bytes = Uint8Array.from(atob(render.data), (c) => c.charCodeAt(0));

    let publicUrl: string;
    let ledgerUrl = "";
    if (batch) {
      // The COMMIT flow: the finished look belongs in My Looks. That gallery
      // reads generations(type='tryon').output.image_path from the private
      // `generations` bucket — landing there means zero app changes.
      const path = `${user.id}/atelier_${Date.now()}.${ext}`;
      const { error: upErr } = await db.storage.from("generations")
        .upload(path, bytes, { contentType: render.mimeType, upsert: false });
      if (upErr) throw new Error(`storage: ${upErr.message}`);
      await db.from("generations").insert({
        user_id: user.id,
        type: "tryon",
        status: "succeeded",
        input: { occasion: "Atelier", garmentIds },
        output: { image_path: path },
      });
      ledgerUrl = path;                       // private path — re-signed on read
      publicUrl = await signedUrl(db, "generations", path, 3600);
    } else {
      const key = `${user.id}/${Date.now()}.${ext}`;
      const { error: upErr } = await db.storage.from(BUCKET)
        .upload(key, bytes, { contentType: render.mimeType, cacheControl: "31536000", upsert: false });
      if (upErr) throw new Error(`storage: ${upErr.message}`);
      publicUrl = db.storage.from(BUCKET).getPublicUrl(key).data.publicUrl;
    }

    const { data: row, error: dbErr } = await db.from("look_generations")
      .insert({
        user_id: user.id,
        garment_id: ledgerGarment,
        image_url: ledgerUrl || publicUrl,
        provider,
        category: ledgerCategory,
        duration_ms: Date.now() - started,
      })
      .select("id").single();
    if (dbErr) throw new Error(`ledger: ${dbErr.message} (image at ${pub.publicUrl})`);

    await burnFree(db, user.id, ent);

    return json({
      ok: true,
      url: publicUrl,
      savedToLooks: batch,
      generationId: row.id,
      ms: Date.now() - started,
      entitlement: entitlementView({ ...ent, free_used: ent.pro ? ent.free_used : ent.free_used + 1 }),
    });
  } catch (e) {
    console.error("generate-vton:", e);
    return json({ error: String((e as Error).message ?? e) }, 502);
  }
});
