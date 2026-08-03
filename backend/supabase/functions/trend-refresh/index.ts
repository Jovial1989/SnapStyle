// POST /functions/v1/trend-refresh   (monthly cron target)
// Auto-builds the trend RAG store with Gemini Google-Search grounding — NO
// scraping. For each archetype × current season: grounded read → distil to a
// brand-agnostic rule (summarizeTrend) → embed (768-d) → insert trend_insights.
// Only the distilled rule + embedding are persisted, never raw editorial text.
// Cron-gated by CRON_SECRET (x-cron-secret header), like trend-parser.
import { admin } from "../_shared/supabase.ts";
import { generateGroundedTrends, summarizeTrend } from "../_shared/gemini.ts";
import { embedText } from "../_shared/embed.ts";
import { json, preflight } from "../_shared/http.ts";
import { ARCHETYPES, currentSeason } from "../_shared/archetypes.ts";

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const secret = Deno.env.get("CRON_SECRET");
  if (secret && req.headers.get("x-cron-secret") !== secret) return json({ error: "forbidden" }, 403);

  const body = await req.json().catch(() => ({}));
  const season = (body?.season ?? currentSeason()).toString();
  const region: string | null = body?.region ?? null;

  const db = admin();
  let saved = 0;
  const errors: string[] = [];

  for (const a of ARCHETYPES) {
    try {
      const prose = await generateGroundedTrends(a.tag, season);
      const rule = await summarizeTrend(`Aesthetic: ${a.tag}. ${prose}`);
      const embedding = await embedText(`${rule.aesthetic_tag}. ${rule.summary} ${rule.keywords.join(", ")}`);
      const { error } = await db.from("trend_insights").insert({
        source: "gemini-grounded",
        region,
        season,
        aesthetic_tag: rule.aesthetic_tag,
        summary: rule.summary,
        keywords: rule.keywords,
        embedding,
      });
      if (error) throw new Error(error.message);
      saved++;
    } catch (e) {
      console.error("[trend-refresh]", a.tag, (e as Error).message);
      errors.push(`${a.tag}: ${(e as Error).message}`);
    }
  }

  return json({ saved, failed: errors.length, season, errors: errors.slice(0, 10) });
});
