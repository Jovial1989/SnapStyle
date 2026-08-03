// POST /functions/v1/recommend — the FAST middleware.
//
// HARD RULE: NO LLM in this file. No gemini.ts import, no text generation,
// nothing that can add seconds or hallucinate a product. Real-time requests
// are ONE hybrid pgvector RPC (cosine <=> + strict metadata WHERE) against
// inventory whose tags/embeddings were pre-computed OFFLINE by the async
// Gemini tagger (scripts/tag-inventory.mjs). Budget: <100ms in-region.
//
// Body: {
//   anchor_id?: uuid            — a SKU to match against (embedding looked up in-query)
//   embedding?: number[768]     — OR a raw pre-computed anchor embedding
//   category?, occasion?, style?, brand_tier?: string   — hard filters
//   in_stock?: boolean (default true), count?: number (default 6)
// }
// → { items: [{id, brand, name, category, price, currency, buyUrl, imageUrl,
//              similarity}], took_ms }
import { admin } from "../_shared/supabase.ts";
import { json, preflight } from "../_shared/http.ts";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const t0 = performance.now();
  // AUTH: the platform already verifies the JWT before invoking (verify_jwt
  // is ON) — a getUser() here would add a whole extra edge→DB round trip for
  // an identity this endpoint never uses (the catalog is global). The RPC is
  // the single DB hop in this function.
  const db = admin();

  const body = await req.json().catch(() => ({}));
  const anchorId = typeof body.anchor_id === "string" && UUID_RE.test(body.anchor_id)
    ? body.anchor_id : null;
  const embedding = Array.isArray(body.embedding) && body.embedding.length === 768
    ? body.embedding : null;
  if (!anchorId && !embedding) {
    return json({ error: "anchor_id (uuid) or embedding (number[768]) required" }, 400);
  }

  const filters = {
    match_category: typeof body.category === "string" ? body.category : null,
    match_occasion: typeof body.occasion === "string" ? body.occasion.toLowerCase() : null,
    match_style: typeof body.style === "string" ? body.style.toLowerCase() : null,
    match_brand_tier: typeof body.brand_tier === "string" ? body.brand_tier : null,
    match_gender: ["male", "female"].includes(body.gender) ? body.gender : null,
    require_stock: body.in_stock !== false, // default: only purchasable inventory
    match_count: Math.min(Math.max(Number(body.count) || 6, 1), 24),
  };

  const { data, error } = anchorId
    ? await db.rpc("recommend_items", { anchor_id: anchorId, ...filters })
    : await db.rpc("recommend_items_by_embedding", { query_embedding: embedding, ...filters });
  if (error) {
    console.error("[recommend]", error.message);
    return json({ error: "search_failed" }, 500);
  }

  return json({
    items: ((data ?? []) as Record<string, unknown>[]).map((m) => ({
      id: m.id,
      brand: m.brand_name,
      name: m.name,
      category: m.category,
      price: m.price,
      currency: m.currency,
      buyUrl: m.buy_url,
      imageUrl: m.image_url,
      similarity: m.similarity,
    })),
    took_ms: Math.round(performance.now() - t0),
  });
});
