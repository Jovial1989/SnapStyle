// POST /functions/v1/look-boards
//   { looks: [{ garmentIds: string[] (2..3) }]  (≤4) }
// → { boards: { [ids.join("+")]: { data, mimeType } }, generated, fromCache }
//
// LOOKS-FIRST Review flow: instead of paying $0.07 per single-garment try-on,
// the editor shows COMPLETE outfits as flat-lay boards — 4 looks in ONE grid
// call (~$0.011/look) — and renders on the person only the look the user
// actually picks (generate-vton batch, $0.039, cached).
//
// Grid law (established 28.07 over three failed spikes): grids hold ORDER and
// GARMENT fidelity perfectly but replace PEOPLE — so boards contain garments
// only, never the user. Outfit-cell spike: 7/8 garments placed correctly;
// the occasional dropped piece is why cells are cached per-look and can be
// re-rendered individually via the same endpoint (1 look = 1x1 "grid").
import { admin, getUser } from "../_shared/supabase.ts";
import { fetchInline } from "../_shared/gemini.ts";
import { generateLookImage } from "../_shared/imagegen.ts";
import { cachePut, sha256Hex } from "../_shared/tryon_cache.ts";
import { NO_BRAND_CLAUSE, promptSafeName } from "../_shared/garment_names.ts";
import { signedUrl } from "../_shared/supabase.ts";
import { json, preflight } from "../_shared/http.ts";

const ID = /^[A-Za-z0-9_-]{1,64}$/;

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const db = admin();
  const user = await getUser(req, db);
  if (!user) return json({ error: "unauthorized" }, 401);

  const { looks, auto, gender } = await req.json().catch(() => ({}));

  let sets: string[][] = [];
  if (Array.isArray(looks) && looks.length) {
    if (looks.length > 4) return json({ error: "looks: 1..4 of {garmentIds[2..3]}" }, 400);
    for (const l of looks) {
      const ids = Array.isArray(l?.garmentIds)
        ? (l.garmentIds as unknown[]).filter((g): g is string => typeof g === "string" && ID.test(g))
        : [];
      if (ids.length < 2 || ids.length > 3) return json({ error: "each look needs 2..3 garmentIds" }, 400);
      sets.push(ids);
    }
  } else if (!auto) {
    return json({ error: "looks[] or auto required" }, 400);
  }

  // Shared by top-up AND the shoes enrichment below. The app's detector says
  // masculine/feminine; accept both vocabularies.
  const g = gender === "male" || gender === "masculine" ? "male"
    : gender === "female" || gender === "feminine" ? "female" : null;
  const genderOr = g ? `gender.eq.${g},gender.eq.unisex` : "gender.eq.unisex";
  const pickIds = async (cat: string) => {
    const { data } = await db.from("affiliate_items")
      .select("id").eq("source", "generated").eq("active", true)
      .eq("category", cat).or(genderOr).limit(12);
    return (data ?? []).map((r) => r.id as string);
  };
  // Deterministic daily rotation: same user+day = same picks = cache hits.
  const daySeed = Math.floor(Date.now() / 86_400_000) + user.id.charCodeAt(0);
  const rotOf = (arr: string[]) => (k: number) => arr[(daySeed + k * 3) % arr.length];

  // TOP-UP: whatever the entry path, the strip must carry FOUR cards. One
  // matched idea in a review must never collapse the row to one look.
  if (sets.length < 4) {
    const [tops, bottoms] = await Promise.all([pickIds("top"), pickIds("bottom")]);
    if (tops.length && bottoms.length) {
      const rt = rotOf(tops), rb = rotOf(bottoms);
      const seen = new Set(sets.map((ids) => ids.join("+")));
      for (let k = 0; sets.length < 4 && k < 24; k++) {
        const combo = [rt(k), rb(k + 1)];
        const key = combo.join("+");
        if (!seen.has(key)) { seen.add(key); sets.push(combo); }
      }
    }
    if (!sets.length) return json({ error: "catalog too thin for looks" }, 422);
  }

  // SHOES: a look without footwear reads unfinished AND the wearing render
  // undresses the photo's own shoes (observed). Every 2-piece look gets one,
  // daily-rotated. 4 looks × 3 refs = 12 reference images — the edge of the
  // grid's envelope; cells are cached per-look, so a dropped piece costs one
  // cell a re-render, not the whole strip.
  {
    const shoes = await pickIds("shoes");
    if (shoes.length) {
      const rs = rotOf(shoes);
      sets = sets.map((ids, k) => (ids.length >= 3 ? ids : [...ids, rs(k)]));
    }
  }

  const boards: Record<string, string> = {};        // look key → image URL
  const misses: { ids: string[]; key: string; cacheKey: string }[] = [];
  await Promise.all(sets.map(async (ids) => {
    const key = ids.join("+");
    // v3: boards are now COMPOSITED from catalogue cut-outs, not generated —
    // v2 cells are Gemini grids and must not be served alongside them.
    // (v1 predated the de-branded men_top_01 image.)
    const cacheKey = await sha256Hex("board:v3|" + key);
    // URL of the cached blob without downloading it — the whole point.
    const { data: row } = await db.from("tryon_cache")
      .select("image_path").eq("key", cacheKey).maybeSingle();
    if (row?.image_path) {
      boards[key] = await signedUrl(db, "generations", row.image_path as string, 3600);
    } else {
      misses.push({ ids, key, cacheKey });
    }
  }));

  if (misses.length) {
    try {
      // garment names + images for every missing look, reference order = cells
      const allIds = [...new Set(misses.flatMap((m) => m.ids))];
      const { data: rows } = await db.from("affiliate_items")
        .select("id, name, image_url").in("id", allIds);
      const byId = new Map((rows ?? []).map((r) => [r.id as string, r]));
      for (const m of misses) {
        if (m.ids.some((id) => !byId.has(id))) return json({ error: "unknown garment id" }, 404);
      }

      // ── COMPOSITE ENGINE (default) ────────────────────────────────────────
      // A board is a flat-lay of catalogue photos that are ALREADY cut out on
      // white — so pasting them is not an approximation of the generated grid,
      // it is strictly better: exact garments (no dropped or hallucinated
      // pieces), no brand-name bleed, ~300ms instead of ~28s, and $0 instead of
      // $0.039. Generation only ever added risk here. Set BOARDS_ENGINE=gemini
      // to fall back to the old grid call.
      if ((Deno.env.get("BOARDS_ENGINE") ?? "composite") === "composite") {
        const { Image } = await import("https://deno.land/x/imagescript@1.3.0/mod.ts");
        const CW = 780, CH = 1170;                     // 2:3, same as the grid cells

        const cut = async (url: string) => {
          const r = await fetch(url, { signal: AbortSignal.timeout(20_000) });
          if (!r.ok) throw new Error(`ref ${r.status}`);
          const im = await Image.decode(new Uint8Array(await r.arrayBuffer()));
          // Trim the product photo's white margin so layout math sees the
          // garment, not the padding around it.
          let x0 = im.width, y0 = im.height, x1 = 0, y1 = 0;
          for (let i = 0; i < im.width * im.height; i++) {
            const o = i * 4;
            if (Math.max(im.bitmap[o], im.bitmap[o + 1], im.bitmap[o + 2]) < 246) {
              const x = i % im.width, y = (i / im.width) | 0;
              if (x < x0) x0 = x;
              if (x > x1) x1 = x;
              if (y < y0) y0 = y;
              if (y > y1) y1 = y;
            }
          }
          return (x1 > x0 && y1 > y0)
            ? im.clone().crop(x0, y0, x1 - x0 + 1, y1 - y0 + 1) : im;
        };
        const place = (canvas: any, g: any, boxW: number, boxH: number, cx: number, cy: number) => {
          const s = Math.min(boxW / g.width, boxH / g.height);
          const r = g.resize(Math.max(1, Math.round(g.width * s)), Math.max(1, Math.round(g.height * s)));
          canvas.composite(r, Math.round(cx - r.width / 2), Math.round(cy - r.height / 2));
        };

        // Categories for EVERY missing look in one query, and the garment
        // images fetched once — the first version re-queried and re-downloaded
        // per board, serially, which cost 16.6 s for four boards.
        const { data: catRows } = await db.from("affiliate_items")
          .select("id, category").in("id", allIds);
        const catOf = new Map((catRows ?? []).map((r) => [r.id as string, String(r.category)]));
        const cutCache = new Map<string, any>();
        await Promise.all(allIds.map(async (id) => {
          try { cutCache.set(id, await cut(byId.get(id)!.image_url as string)); } catch (_) {}
        }));

        await Promise.all(misses.map(async (m) => {
          const order = ["outerwear", "top", "bottom", "shoes"];
          const ids = [...m.ids].sort((a, b) =>
            order.indexOf(catOf.get(a) ?? "top") - order.indexOf(catOf.get(b) ?? "top"));
          const garments = ids.map((id) => cutCache.get(id)).filter(Boolean);
          if (!garments.length) return;

          const canvas = new Image(CW, CH).fill(0xffffffff);
          const shoeIdx = ids.findIndex((id) => catOf.get(id) === "shoes");
          const wear = garments.filter((_, i) => i !== shoeIdx);
          // Editorial stack: top garment above, bottom below with a slight
          // overlap, footwear tucked beside the hem.
          if (wear.length >= 2) {
            place(canvas, wear[0], CW * 0.62, CH * 0.42, CW * 0.44, CH * 0.26);
            place(canvas, wear[1], CW * 0.58, CH * 0.52, CW * 0.44, CH * 0.68);
          } else if (wear.length === 1) {
            place(canvas, wear[0], CW * 0.72, CH * 0.72, CW * 0.46, CH * 0.46);
          }
          // Squarer box than the first pass: a boot is tall, and a flat 0.16
          // height box shrank it to a speck beside the trousers.
          if (shoeIdx >= 0) place(canvas, garments[shoeIdx], CW * 0.30, CH * 0.22, CW * 0.79, CH * 0.78);

          const jpg = await canvas.encodeJPEG(88);
          let bin = "";
          for (let o = 0; o < jpg.length; o += 0x8000) {
            bin += String.fromCharCode(...jpg.subarray(o, o + 0x8000));
          }
          await cachePut(db, m.cacheKey, user.id, "item",
                         { data: btoa(bin), mimeType: "image/jpeg" });
          boards[m.key] = await signedUrl(db, "generations", `_cache/${m.cacheKey}`, 3600);
        }));
        return json({ boards, generated: misses.length,
                      fromCache: sets.length - misses.length, engine: "composite" });
      }

      const dim = misses.length <= 1 ? 1 : 2;
      const listing = misses.map((m, i) =>
        `Outfit ${i + 1}: ` + m.ids.map((id) => promptSafeName(byId.get(id)!.name as string)).join(" + ")).join("\n");
      // Refs in PARALLEL, RAW urls. (The /render/image transform endpoint
      // hangs on this project — fetchInline has no timeout, and eight stuck
      // fetches took the whole function past the gateway limit. Raw originals
      // measured fine: 27.5s end-to-end for 4 looks.)
      const refs = await Promise.all(
        misses.flatMap((m) =>
          m.ids.map((id) => fetchInline(byId.get(id)!.image_url as string))),
      );
      const prompt =
        `Create ONE image: a ${dim}x${dim} grid of editorial OUTFIT FLAT-LAYS with thin ` +
        `white gutters. Each cell is a styled flat-lay of ONE complete outfit on plain ` +
        `white — top garment above, bottom below, slightly overlapping, magazine style; ` +
        `shoes (if present) beside the bottom. EVERY listed garment MUST appear in its ` +
        `cell — a missing piece is a failure. NO person, NO mannequin, NO text.\n` +
        `The outfits, in order (left-to-right, top-to-bottom):\n${listing}\n` +
        `${misses.length < dim * dim ? `Leave the remaining ${dim * dim - misses.length} cell(s) pure white.\n` : ""}` +
        `Garment reference photos follow grouped per outfit, in the same order — ` +
        `copy each garment exactly (colour, print, cut). ` + NO_BRAND_CLAUSE;

      const first = refs[0];
      const sheet = await generateLookImage(first, prompt, refs.slice(1));
      // Imported HERE: the decoder is a heavy pure-TS module that was costing
      // every CACHE-HIT call its compile time when imported at the top.
      const { Image } = await import("https://deno.land/x/imagescript@1.3.0/mod.ts");
      const img = await Image.decode(Uint8Array.from(atob(sheet.data), (c) => c.charCodeAt(0)));
      const cw = Math.floor(img.width / dim), ch = Math.floor(img.height / dim);
      const inset = Math.floor(Math.min(cw, ch) * 0.03);

      for (let i = 0; i < misses.length; i++) {
        const r = Math.floor(i / dim), c = i % dim;
        const cell = img.clone().crop(c * cw + inset, r * ch + inset, cw - 2 * inset, ch - 2 * inset);
        const jpg = await cell.encodeJPEG(85);
        let bin = "";
        for (let o = 0; o < jpg.length; o += 0x8000) {
          bin += String.fromCharCode(...jpg.subarray(o, o + 0x8000));
        }
        const out = { data: btoa(bin), mimeType: "image/jpeg" };
        await cachePut(db, misses[i].cacheKey, user.id, "item", out);
        boards[misses[i].key] =
          await signedUrl(db, "generations", `_cache/${misses[i].cacheKey}`, 3600);
      }
    } catch (err) {
      console.error("[look-boards]", (err as Error).message);
      // Partial success is fine: the client renders whatever boards arrived
      // and can re-request the rest (1-look calls re-render individually).
    }
  }

  return json({
    boards,
    generated: misses.filter((m) => boards[m.key]).length,
    fromCache: sets.length - misses.length,
  });
});
