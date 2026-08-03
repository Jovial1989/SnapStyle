// POST /functions/v1/grid-vton — batch pre-render: up to 4 looks in ONE
// gpt-image-1 masked edit on a 2x2 collage of the user's canonical avatar.
//
// Body: { looks: [{ garmentIds: string[2..3] }] }   (1..4 looks)
// 200:  { ok: true, renders: { "<ids.join('+')>": url }, entitlement }
//
// Recipe fixed by 7 paid spikes (28.07.2026, scratchpad openai_compare_v*):
//   - base = full-size 2x2 collage of the SAME avatar, 4px white gutters;
//   - mask = TIGHT chroma segmentation of the grey basics (white=editable),
//     head hard-locked; any dilation of the mask SENT to OpenAI makes the
//     model balloon collars over the chin — dilation belongs in the
//     composite only;
//   - input_fidelity=high is REQUIRED (without it the model misaligns the
//     body and the composite seams garble the neck); token cost of high is
//     per-image and size-independent, so shrinking inputs saves nothing;
//   - refs = one image per garment (a combined contact sheet mushes prints);
//   - quality=medium (low is soft and breaks alignment);
//   - composite = original pixels outside a DOWN/SIDEWAYS-dilated feathered
//     alpha; the face therefore stays the user's literal pixels.
// Measured: ~$0.26/grid of 4 (~$0.065/look), ~34s. Gemini singles are
// cheaper ($0.039) but repaint an approximate face; this engine's face is
// real. Client keeps Gemini as fallback (flag _kGridPrerender).
import { json, preflight } from "../_shared/http.ts";
import {
  admin,
  burnFree,
  canAnalyze,
  entitlementView,
  getEntitlement,
  getUser,
  signedUrl,
} from "../_shared/supabase.ts";
import { promptSafeName } from "../_shared/garment_names.ts";
import { buildCanonicalAvatar } from "../_shared/avatar.ts";
import { gridRender } from "../_shared/grid.ts";
import { type DressStep, hybridDress, hybridEnabled, slotOf } from "../_shared/vton.ts";

const ID = /^[A-Za-z0-9_-]{1,64}$/;

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const started = Date.now();

  const db = admin();
  const user = await getUser(req, db);
  if (!user) return json({ error: "unauthorized" }, 401);
  const ent = await getEntitlement(db, user.id);
  if (!canAnalyze(ent)) return json({ error: "quota_exhausted", ...entitlementView(ent) }, 402);

  // The OpenAI key is only needed for the GRID FALLBACK. Refusing the request
  // without it would make the self-hosted engine unusable on its own — the whole
  // point of building it was not needing that key.
  const key = Deno.env.get("OPENAI_API_KEY");
  if (!key && !hybridEnabled()) return json({ error: "grid engine not configured" }, 501);

  const { looks } = await req.json().catch(() => ({}));
  if (!Array.isArray(looks) || looks.length < 1 || looks.length > 4) {
    return json({ error: "looks: 1..4 of {garmentIds[2..3]}" }, 400);
  }
  const sets: string[][] = [];
  for (const l of looks) {
    const ids = Array.isArray(l?.garmentIds)
      ? (l.garmentIds as unknown[]).filter((g): g is string => typeof g === "string" && ID.test(g))
      : [];
    if (ids.length < 2 || ids.length > 3) return json({ error: "each look needs 2..3 garmentIds" }, 400);
    sets.push(ids);
  }

  try {
    // ── cache: same ledger-as-cache semantics as generate-vton ──
    const { data: prof } = await db.from("style_profiles")
      .select("source_photo_path, updated_at").eq("user_id", user.id).single();
    const humanPath = prof?.source_photo_path ?? "";
    if (!humanPath) return json({ error: "no body photo on profile" }, 409);
    const photoSince = prof?.updated_at ?? null;

    const renders: Record<string, string> = {};
    const misses: string[][] = [];
    await Promise.all(sets.map(async (ids) => {
      const ck = ids.join("+");
      let q = db.from("look_generations")
        .select("image_url").eq("user_id", user.id).eq("garment_id", ck)
        .order("created_at", { ascending: false }).limit(1);
      if (photoSince) q = q.gte("created_at", photoSince);
      const { data: hit } = await q;
      if (hit?.length) {
        let url = hit[0].image_url as string;
        if (!url.startsWith("http")) url = await signedUrl(db, "generations", url, 3600);
        renders[ck] = url;
      } else {
        misses.push(ids);
      }
    }));
    if (!misses.length) {
      return json({ ok: true, renders, cached: true, ms: Date.now() - started,
                    entitlement: entitlementView(ent) });
    }

    // ── person: canonical avatar ONLY — the chroma mask assumes grey basics
    // on white. No avatar → 409, the client falls back to the Gemini path. ──
    const avatarBytes = await fetchBytes(
      await signedUrl(db, "body-photos", `${humanPath}.avatar.png`));
    if (!avatarBytes) {
      // SELF-HEAL (28.07 incident: photos older than the avatar feature have
      // no avatar → 409 → Gemini fell back to the RAW mirror selfie and
      // shipped a different person). Kick the build now, fire-and-forget —
      // this review falls back, the next one grids properly.
      (globalThis as any).EdgeRuntime?.waitUntil?.(
        buildCanonicalAvatar(db, humanPath).catch(() => {}));
      return json({ error: "grid engine needs the canonical avatar" }, 409);
    }

    // ── garment names + refs ──
    const allIds = [...new Set(misses.flat())];
    const { data: rows } = await db.from("affiliate_items")
      .select("id, name, image_url, category").in("id", allIds);
    const byId = new Map((rows ?? []).map((r) => [r.id as string, r]));
    for (const ids of misses) {
      if (ids.some((id) => !byId.has(id))) return json({ error: "unknown garment id" }, 404);
    }

    // ── ONE call for up to four looks, via the shared renderer ──────────
    // grid-vton used to carry its own copy of the collage/mask/composite code.
    // It drifted: cells came out 341x512 next to Generate's 510x766, the mask
    // still started at 0.21 of the figure so the avatar's grey collar showed as
    // a BAND across the chest of every rendered look (reported from the phone,
    // 28.07), and the figure bbox used the naive threshold that erases faces.
    // One implementation now, in _shared/grid.ts.
    const refsPerCell = await Promise.all(misses.map(async (ids) => {
      const out: { data: string; mimeType: string }[] = [];
      for (const id of ids) {
        const raw = await fetchBytes(byId.get(id)!.image_url as string);
        if (!raw) throw new Error(`ref unreadable: ${id}`);
        out.push({ data: b64(raw), mimeType: "image/png" });
      }
      return out;
    }));

    const descriptions = misses.map((ids) =>
      ids.map((id) => promptSafeName(byId.get(id)!.name as string)).join(" + "));

    // WHY THE GRID IS NO LONGER THE DEFAULT: packing four looks into one image
    // never improved anything except the BILL. gpt-image charges per call, so
    // four looks in one 1024x1536 canvas cost a quarter of four calls — and we
    // paid for that discount in cells cropped to 510x766, a mask/composite stage
    // that had to be reinvented, and the grey-collar band that shipped to the
    // phone. At $0.0003 a render the discount is worth nothing, so each look is
    // simply rendered on its own, at full frame, by the self-hosted engine.
    //
    // The grid stays as the fallback for exactly the case the engine cannot
    // serve: a garment with no usable photo or a category with no mask zone.
    let cells: Uint8Array[] | null = null;
    let usedHybrid = false;
    if (hybridEnabled()) {
      try {
        const perLook: DressStep[][] = misses.map((ids) => {
          const steps: DressStep[] = [];
          for (const id of ids) {
            const g = byId.get(id)!;
            const kind = slotOf(String(g.category ?? ""));
            const url = String(g.image_url ?? "");
            // No zone or no photo → this look cannot be dressed piece by piece.
            if (!kind || !url) return [];
            steps.push({ url, kind, hint: promptSafeName(String(g.name ?? "")) });
          }
          return steps;
        });
        if (perLook.every((st) => st.length)) {
          const personUrl = await signedUrl(db, "body-photos", `${humanPath}.avatar.png`, 900);
          // Sequential, not parallel: the worker renders one job at a time
          // (measured — throughput is flat against concurrency, the GPU is
          // already saturated by a single stream), so firing them together
          // would only deepen the queue and add nothing.
          const out: Uint8Array[] = [];
          for (const steps of perLook) {
            const img = await hybridDress(db, user.id, personUrl, steps);
            out.push(Uint8Array.from(atob(img.data), (c) => c.charCodeAt(0)));
          }
          cells = out;
          usedHybrid = true;
          console.log("[grid-vton] hybrid:", out.length, "looks rendered individually");
        }
      } catch (e) {
        console.error("[grid-vton] hybrid failed, using the grid:", (e as Error).message);
      }
    }
    if (!cells) {
      ({ cells } = await gridRender({
        avatar: avatarBytes,
        descriptions,
        refsPerCell,
        note: "Full body head-to-toe in every panel, feet visible, plain seamless " +
              "pure-white background.",
      }));
    }

    // ── slice per look, store, ledger (same rows the Gemini path writes) ──
    for (let i = 0; i < misses.length && i < cells.length; i++) {
      const jpg = cells[i];
      const path = `${user.id}/atelier_${Date.now()}_${i}.jpg`;
      const { error: upErr } = await db.storage.from("generations")
        .upload(path, jpg, { contentType: "image/jpeg", upsert: false });
      if (upErr) throw new Error(`storage: ${upErr.message}`);
      await db.from("generations").insert({
        user_id: user.id, type: "tryon", status: "succeeded",
        input: { occasion: "Atelier", garmentIds: misses[i] },
        output: { image_path: path },
      });
      // look_generations.category has a CHECK — 'look' was rejected (23514) and
      // because the error was unchecked, EVERY grid silently wrote nothing:
      // credits burned, render cache stayed empty, each wear-tap paid again.
      // Derive a legal value the way generate-vton does, and surface failures.
      const cats = misses[i].map((id) => String(byId.get(id)?.category ?? ""));
      const category = cats.some((c) => c === "top" || c === "outerwear")
        ? "upper_body" : "lower_body";
      const { error: ledErr } = await db.from("look_generations").insert({
        user_id: user.id, garment_id: misses[i].join("+"), image_url: path,
        // Which engine actually rendered it, so cost analysis and a
        // rollback can both be reasoned about from the ledger alone.
        provider: usedHybrid ? "hybrid-sd15" : "gpt-image-1-grid", category,
        duration_ms: Date.now() - started,
      });
      // A missing ledger row means no cache: the next tap re-renders and
      // re-charges. Loud, not silent.
      if (ledErr) throw new Error(`ledger: ${ledErr.message} (image at ${path})`);
      renders[misses[i].join("+")] = await signedUrl(db, "generations", path, 3600);
    }

    await burnFree(db, user.id, ent); // ONE credit per grid, not per look

    return json({
      ok: true, renders, generated: misses.length,
      ms: Date.now() - started,
      entitlement: entitlementView({ ...ent, free_used: ent.pro ? ent.free_used : ent.free_used + 1 }),
    });
  } catch (e) {
    console.error("grid-vton:", e);
    return json({ error: String((e as Error).message ?? e) }, 502);
  }
});

const b64 = (u: Uint8Array) => {
  let s = "";
  for (let o = 0; o < u.length; o += 0x8000) s += String.fromCharCode(...u.subarray(o, o + 0x8000));
  return btoa(s);
};

async function fetchBytes(url: string): Promise<Uint8Array | null> {
  try {
    const r = await fetch(url, { signal: AbortSignal.timeout(20_000) });
    if (!r.ok) return null;
    return new Uint8Array(await r.arrayBuffer());
  } catch (_) {
    return null;
  }
}

// Grey-basics segmentation, the same thresholds the spike proved: clothing =
// low-chroma mid-value pixels; head band hard-locked; shoe band = bottom 10%



