// Semantic matching between AI garment suggestions and REAL branded inventory
// (affiliate_items + pgvector) — grounds "navy textured knit polo" in an
// actual SKU with a live buy URL, so product cards are authentic and the VTON
// engine can render the real garment image.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { embedText } from "./embed.ts";

/** Embeddings happily bridge "chino shorts" ↔ "Slim Fit Chinos" (the fabric
 * word dominates) — but selling full-length trousers under a shorts render
 * destroys trust at the buy click. Deterministic type-conflict veto:
 * shorts vs long-legwear, dress vs non-dress, skirt vs non-skirt. */
function garmentTypeConflict(query: string, skuName: string): boolean {
  const q = query.toLowerCase(), n = skuName.toLowerCase();
  const isShort = (s: string) => /shorts?/.test(s);
  const isLongLeg = (s: string) =>
    /(trousers|pants|jeans|chinos|joggers|leggings)/.test(s) && !isShort(s);
  if (isShort(q) && isLongLeg(n)) return true;
  if (isShort(n) && isLongLeg(q)) return true;
  const isDress = (s: string) => /dress/.test(s);
  const isSkirt = (s: string) => /skirt/.test(s);
  if (isDress(q) !== isDress(n)) return true;
  if (isSkirt(q) !== isSkirt(n)) return true;
  return false;
}

export interface RealGarment {
  id: string;
  brand: string;
  name: string;
  category: string;
  price: number;
  currency: string;
  buyUrl: string;
  imageUrl: string;
  similarity: number;
}

/** Match one AI recommendation (e.g. "Navy textured knit polo") to the single
 * closest real SKU. Returns null when nothing clears [minSimilarity] — a weak
 * match is WORSE than no match (wrong product under a confident card destroys
 * trust faster than a missing card). Never throws. */
export async function matchRealGarment(
  db: SupabaseClient,
  aiRecommendationContext: string,
  opts: { category?: string; minSimilarity?: number; gender?: string } = {},
): Promise<RealGarment | null> {
  const matches = await matchRealGarments(db, aiRecommendationContext, { ...opts, count: 1 });
  return matches[0] ?? null;
}

/** Top-N variant (product rails, alternatives). Never throws. */
export async function matchRealGarments(
  db: SupabaseClient,
  aiRecommendationContext: string,
  opts: { category?: string; minSimilarity?: number; count?: number; gender?: string } = {},
): Promise<RealGarment[]> {
  try {
    const text = aiRecommendationContext.trim();
    if (!text) return [];
    const embedding = await embedText(text); // gemini-embedding-001 @ 768
    const { data, error } = await db.rpc("match_affiliate_items", {
      query_embedding: embedding,
      match_count: opts.count ?? 1,
      match_category: opts.category ?? null,
      min_similarity: opts.minSimilarity ?? 0.35,
      match_gender: opts.gender ?? null, // male|female → that gender + unisex
    });
    if (error) throw new Error(error.message);
    return ((data ?? []) as Record<string, unknown>[])
      .filter((m) => !garmentTypeConflict(text, String(m.name ?? "")))
      .map((m) => ({
      id: String(m.id),
      brand: String(m.brand_name ?? ""),
      name: String(m.name ?? ""),
      category: String(m.category ?? ""),
      price: Number(m.price ?? 0),
      currency: String(m.currency ?? "USD"),
      buyUrl: String(m.buy_url ?? ""),
      imageUrl: String(m.image_url ?? ""),
      similarity: Number(m.similarity ?? 0),
    }));
  } catch (e) {
    console.error("[affiliate] matchRealGarments", (e as Error).message);
    return []; // grounding is an enhancement — never fail the parent flow
  }
}
