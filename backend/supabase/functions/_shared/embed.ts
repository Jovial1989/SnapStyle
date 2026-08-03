// EMBEDDING PROVIDER SEAM — the last live Gemini dependency in the critical
// path. Garment matching (_shared/affiliate.ts) embeds the stylist's idea text
// and searches affiliate_items by cosine similarity; with Gemini in
// `dunning deny` that call threw, matching silently returned [] and every
// review fell back to auto-picked looks.
//
// OpenAI text-embedding-3-small is 1536-d natively but accepts a `dimensions`
// argument, so we keep the existing pgvector(768) columns unchanged.
//
// IMPORTANT: vectors from different models are NOT comparable. Whenever this
// provider changes, every stored embedding must be recomputed
// (affiliate_items.embedding, trend_insights.embedding) or similarity search
// returns noise. See scripts/reembed.py.
import { embedText as gemEmbed } from "./gemini.ts";

export const EMBED_DIMS = 768;
const provider = () => (Deno.env.get("EMBED_PROVIDER") ?? "openai").toLowerCase();

export async function embedText(text: string): Promise<number[]> {
  if (provider() === "gemini") return await gemEmbed(text);
  const key = Deno.env.get("OPENAI_API_KEY");
  if (!key) return await gemEmbed(text);
  const model = Deno.env.get("OPENAI_EMBED_MODEL") ?? "text-embedding-3-small";
  const res = await fetch("https://api.openai.com/v1/embeddings", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ model, input: text, dimensions: EMBED_DIMS }),
    signal: AbortSignal.timeout(30_000),
  });
  if (!res.ok) {
    // No silent fallback to Gemini here: mixing vector spaces would poison
    // similarity search far more subtly than an outright failure.
    throw new Error(`openai embed ${res.status}: ${(await res.text()).slice(0, 200)}`);
  }
  const j = await res.json();
  const v = j?.data?.[0]?.embedding;
  if (!Array.isArray(v) || v.length !== EMBED_DIMS) {
    throw new Error(`openai embed: expected ${EMBED_DIMS} dims, got ${v?.length}`);
  }
  return v as number[];
}
