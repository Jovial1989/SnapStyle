// POST /functions/v1/item-images
//   { image:{data,mimeType}, items:[{instruction, slot}] (≤9) }
// → { images: { [instruction]: {data,mimeType} }, generated, fromCache }
//
// BATCH product-shot thumbnails: all of a review's unmatched idea garments in
// ONE Gemini call as a contact-sheet grid, sliced into cells server-side.
// Spike 28.07: a 3x3 grid of 9 items came back in perfect order with
// e-commerce quality — objects have no identity to lose (the failure that
// killed the try-on grid). 9 thumbs for one $0.039 call ≈ $0.0043/thumb vs
// $0.039 — and one network round-trip instead of nine.
//
// Cache parity: each cell is stored under EXACTLY the key the single
// item-image endpoint uses, so the two endpoints share one thumbnail cache
// and the per-item lazy path keeps working as the fallback.
import { Image } from "https://deno.land/x/imagescript@1.3.0/mod.ts";

import { admin, getUser } from "../_shared/supabase.ts";
import { generateLookImage } from "../_shared/imagegen.ts";
import { cacheGet, cachePut, sha256Hex } from "../_shared/tryon_cache.ts";
import { json, preflight } from "../_shared/http.ts";

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const db = admin();
  const user = await getUser(req, db);
  if (!user) return json({ error: "unauthorized" }, 401);

  const { image, items } = await req.json().catch(() => ({}));
  if (!image?.data || !image?.mimeType) return json({ error: "image { data, mimeType } required" }, 400);
  if (!Array.isArray(items) || !items.length || items.length > 9) {
    return json({ error: "items: 1..9 of {instruction, slot}" }, 400);
  }

  const model = Deno.env.get("GEMINI_IMAGE_MODEL") ?? "gemini-2.5-flash-image";
  const result: Record<string, { data: string; mimeType: string }> = {};
  const misses: { instruction: string; slot: string; key: string }[] = [];

  // Cache lookups in parallel — serially they added ~2s per cached item.
  const probes = await Promise.all(
    (items as { instruction?: unknown; slot?: unknown }[])
      .filter((it) => typeof it?.instruction === "string" && it.instruction)
      .map(async (it) => {
        const instruction = it.instruction as string;
        const key = await sha256Hex(["item:v1", model, image.data, instruction].join("|"));
        return { instruction, slot: String(it.slot ?? "item"), key, hit: await cacheGet(db, key) };
      }),
  );
  for (const pr of probes) {
    if (pr.hit) result[pr.instruction] = pr.hit;
    else misses.push({ instruction: pr.instruction, slot: pr.slot, key: pr.key });
  }

  if (misses.length) {
    try {
      // 2x2 for ≤4 misses, 3x3 otherwise — empty cells are wasted pixels.
      const n = misses.length;
      const dim = n <= 4 ? 2 : 3;
      // The client's instruction already carries the one-item + parity clauses.
      const listing = misses
        .map((m, i) => `${i + 1}. ${m.instruction}`)
        .join("\n");
      const prompt =
        `Create ONE image: a ${dim}x${dim} grid of e-commerce product photographs ` +
        `with thin white gutters. Each cell shows ONE clothing item alone, flat-lay ` +
        `or ghost-mannequin, centered on pure white — never a person, never an ` +
        `outfit, never multiple garments per cell. LENGTH/TYPE PARITY is binding: ` +
        `shorts stay above-knee shorts, trousers stay full-length. Exact order, ` +
        `left-to-right then top-to-bottom:\n${listing}\n` +
        `${n < dim * dim ? `Leave the remaining ${dim * dim - n} cell(s) pure white.\n` : ""}` +
        `NO text, NO labels, NO numbers, NO props, NO logos.`;

      const sheet = await generateLookImage({ data: image.data, mimeType: image.mimeType }, prompt);
      const img = await Image.decode(Uint8Array.from(atob(sheet.data), (c) => c.charCodeAt(0)));
      const cw = Math.floor(img.width / dim), ch = Math.floor(img.height / dim);
      const inset = Math.floor(Math.min(cw, ch) * 0.035);   // stay clear of the gutters

      for (let i = 0; i < misses.length; i++) {
        const r = Math.floor(i / dim), c = i % dim;
        const cell = img.clone().crop(c * cw + inset, r * ch + inset, cw - 2 * inset, ch - 2 * inset);
        const jpg = await cell.encodeJPEG(85);
        let bin = "";
        const CHUNK = 0x8000;
        for (let o = 0; o < jpg.length; o += CHUNK) {
          bin += String.fromCharCode(...jpg.subarray(o, o + CHUNK));
        }
        const out = { data: btoa(bin), mimeType: "image/jpeg" };
        result[misses[i].instruction] = out;
        await cachePut(db, misses[i].key, user.id, "item", out);
      }
    } catch (err) {
      // Batch is an OPTIMIZATION: on any failure the client's lazy per-item
      // path still renders every thumbnail — degrade silently to that.
      console.error("[item-images] grid failed:", (err as Error).message);
    }
  }

  return json({
    images: result,
    generated: misses.length && Object.keys(result).length >= misses.length ? misses.length : 0,
    fromCache: items.length - misses.length,
  });
});
