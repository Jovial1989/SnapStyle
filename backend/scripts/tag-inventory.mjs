// ASYNC inventory tagger — the ONLY place the LLM touches the Fast
// Recommendation Engine. Runs offline (manually or on a feed-sync cron),
// batch-tags SKUs with the pre-computed metadata the hot path filters on:
// brand_tier, style_tags, occasion_tags. The /recommend endpoint itself
// never calls an LLM.
//
// Usage:  node scripts/tag-inventory.mjs [--all]   (--all re-tags everything)
import fs from 'node:fs';
import { Client } from 'pg';

const env = fs.readFileSync(new URL('../.env', import.meta.url), 'utf8');
const DB_URL = env.match(/^SUPABASE_DB_URL=(.+)$/m)[1].trim();
const GEMINI_KEY = env.match(/^GEMINI_API_KEY=(.+)$/m)[1].trim();
const MODEL = 'gemini-2.5-flash';

// Closed vocabularies — free-form LLM tags would fragment the hard filters.
const TIERS = ['premium', 'mid', 'value'];
const STYLES = ['minimalist', 'casual', 'smart', 'sporty', 'streetwear', 'classic'];
const OCCASIONS = ['date', 'office', 'party', 'beach', 'gym', 'travel', 'everyday'];

async function tagBatch(items) {
  const prompt = `You tag fashion inventory for a recommendation engine.
For EACH item below, assign:
- brand_tier: exactly one of ${JSON.stringify(TIERS)} (by brand positioning/price)
- style_tags: 1-3 from ${JSON.stringify(STYLES)}
- occasion_tags: 1-3 from ${JSON.stringify(OCCASIONS)}
- gender: exactly one of ["male","female","unisex"] (who the piece is cut/marketed for; unisex when genuinely either)
- attributes: {"sleeve_length": one of ["long","short","sleeveless","na"] (na for
  bottoms/shoes/accessories), "fabric": one word (e.g. linen, denim, knit, leather,
  cotton; "na" if unknowable), "color": the item's primary color or "na"}
Use ONLY the allowed values. Reply with a JSON array, one object per item:
{"id": "...", "brand_tier": "...", "style_tags": [...], "occasion_tags": [...], "gender": "...", "attributes": {...}}

Items:
${items.map((i) => `- id ${i.id}: ${i.name} by ${i.brand_name} (${i.category}, ${i.currency} ${i.price})`).join('\n')}`;

  const r = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${GEMINI_KEY}`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        contents: [{ parts: [{ text: prompt }] }],
        generationConfig: { responseMimeType: 'application/json' },
      }),
    },
  );
  if (!r.ok) throw new Error(`gemini ${r.status}: ${(await r.text()).slice(0, 160)}`);
  const out = JSON.parse((await r.json()).candidates[0].content.parts[0].text);
  if (!Array.isArray(out)) throw new Error('tagger returned non-array');
  return out;
}

const clean = (arr, vocab) =>
  [...new Set((Array.isArray(arr) ? arr : []).filter((t) => vocab.includes(t)))];

const c = new Client({ connectionString: DB_URL });
await c.connect();
const where = process.argv.includes('--all') ? '' : 'where brand_tier is null';
const { rows } = await c.query(
  `select id, brand_name, name, category, price, currency from affiliate_items ${where} order by brand_name`,
);
console.log(`to tag: ${rows.length}`);

let tagged = 0;
for (let i = 0; i < rows.length; i += 20) { // 20 per call — well inside limits
  const batch = rows.slice(i, i + 20);
  const tags = await tagBatch(batch);
  for (const t of tags) {
    const tier = TIERS.includes(t.brand_tier) ? t.brand_tier : 'mid';
    const styles = clean(t.style_tags, STYLES);
    const occasions = clean(t.occasion_tags, OCCASIONS);
    if (!batch.some((b) => b.id === t.id)) continue; // ignore hallucinated ids
    const a = t.attributes ?? {};
    const attrs = {
      sleeve_length: ['long', 'short', 'sleeveless', 'na'].includes(a.sleeve_length) ? a.sleeve_length : 'na',
      fabric: typeof a.fabric === 'string' ? a.fabric.slice(0, 24) : 'na',
      color: typeof a.color === 'string' ? a.color.slice(0, 24) : 'na',
    };
    const gender = ['male', 'female', 'unisex'].includes(t.gender) ? t.gender : 'unisex';
    await c.query(
      'update affiliate_items set brand_tier=$1, style_tags=$2, occasion_tags=$3, attributes=$4, gender=$5 where id=$6',
      [tier, styles.length ? styles : ['casual'], occasions.length ? occasions : ['everyday'], JSON.stringify(attrs), gender, t.id],
    );
    tagged++;
  }
  console.log(`tagged ${Math.min(i + 20, rows.length)}/${rows.length}`);
}
const chk = await c.query(
  'select count(*) filter (where brand_tier is not null) as done, count(*) as total from affiliate_items',
);
console.log(`done: ${tagged} updated | coverage: ${chk.rows[0].done}/${chk.rows[0].total}`);
await c.end();
