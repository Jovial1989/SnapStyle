// POST /functions/v1/trend-parser   (monthly cron target — SDD §14.14)
// The Monthly Trend Parser's INGESTION step. Takes curated editorial/trend
// snippets, distils each into a brand-agnostic styling RULE (Gemini), embeds it
// (text-embedding-004, 768-dim), and upserts into `trend_insights` (pgvector).
// The RAG retrieval side lives in the styling prompt build (see §14.14).
//
// SOURCING / ToS — IMPORTANT: this function does NOT scrape SSENSE, Vogue Runway,
// Lyst, Highsnobiety or Mr Porter. Those sites' ToS forbid scraping and much of
// the content is paywalled/copyrighted. Feed this endpoint via LICENSED routes
// only — official APIs/partnerships, permitted RSS/press feeds, or human-curated
// season notes. `items[].rawText` is that already-permitted text. Keep raw
// editorial text OUT of storage — we persist only the distilled, brand-agnostic
// rule + embedding.
//
// Auth: cron-only. If CRON_SECRET is set, require header `x-cron-secret` to match.
import { admin } from "../_shared/supabase.ts";
import { summarizeTrend } from "../_shared/gemini.ts";
import { embedText } from "../_shared/embed.ts";
import { json, preflight } from "../_shared/http.ts";

type Item = { source: string; region?: string | null; season?: string | null; rawText: string };

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const secret = Deno.env.get("CRON_SECRET");
  if (secret && req.headers.get("x-cron-secret") !== secret) {
    return json({ error: "forbidden" }, 403);
  }

  const { items, season } = await req.json().catch(() => ({}));
  if (!Array.isArray(items) || items.length === 0) {
    return json({ error: "items[] (curated, licensed trend snippets) required" }, 400);
  }

  const db = admin();
  let saved = 0;
  const errors: string[] = [];

  for (const raw of items as Item[]) {
    if (!raw?.rawText || !raw?.source) continue;
    try {
      const rule = await summarizeTrend(raw.rawText);
      const embedding = await embedText(`${rule.aesthetic_tag}. ${rule.summary} ${rule.keywords.join(", ")}`);
      const { error } = await db.from("trend_insights").insert({
        source: raw.source,
        region: raw.region ?? null,
        season: raw.season ?? season ?? null,
        aesthetic_tag: rule.aesthetic_tag,
        summary: rule.summary,
        keywords: rule.keywords,
        embedding,
      });
      if (error) throw new Error(error.message);
      saved++;
    } catch (e) {
      console.error("[trend-parser]", raw.source, (e as Error).message);
      errors.push(`${raw.source}: ${(e as Error).message}`);
    }
  }

  return json({ saved, failed: errors.length, errors: errors.slice(0, 10) });
});
