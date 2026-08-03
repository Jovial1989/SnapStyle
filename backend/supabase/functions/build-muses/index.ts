// POST /functions/v1/build-muses   (admin/cron target)
// Generates the SHARED archetype "muse" image library (Generate loader feed).
// For each archetype × category: pull the freshest trend rule (match_trend_insights)
// to steer, generate a full-outfit shot of an ANONYMOUS, non-identifiable model,
// store in the public `muses` bucket + upsert muse_looks. Unnamed archetypes
// only — no real people or likenesses. Cron-gated by CRON_SECRET.
// Body (optional): { season?, archetype? } — archetype rebuilds just one.
import { admin } from "../_shared/supabase.ts";
import { generateImage } from "../_shared/gemini.ts";
import { embedText } from "../_shared/embed.ts";
import { json, preflight } from "../_shared/http.ts";
import { ARCHETYPES, CATEGORIES, currentSeason } from "../_shared/archetypes.ts";

const BUCKET = "muses";
const b64ToBytes = (b64: string) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
const slug = (s: string) => s.replace(/[^a-z0-9]+/gi, "-").toLowerCase().replace(/^-|-$/g, "");
// Distinct colour families + silhouettes so every card looks different (not near-identical).
const COLORS = ["charcoal grey", "navy", "olive green", "camel/tan", "ecru/off-white", "deep burgundy", "stone/beige", "all black", "rust brown", "slate blue", "forest green", "warm grey"];
const SILHOUETTES = ["relaxed and oversized", "sharp and tailored", "straight and clean", "layered", "cropped and structured", "long and fluid"];

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const secret = Deno.env.get("CRON_SECRET");
  if (secret && req.headers.get("x-cron-secret") !== secret) return json({ error: "forbidden" }, 403);

  const body = await req.json().catch(() => ({}));
  const season = (body?.season ?? currentSeason()).toString();
  const onlyArch: string | null = body?.archetype ?? null;
  const gender: string = body?.gender === "female" ? "female" : "male"; // menswear default
  const who = gender === "female" ? "woman" : "man";
  const wear = gender === "female" ? "women's" : "men's";
  const db = admin();

  let saved = 0;
  let n = 0;
  const errors: string[] = [];

  for (const a of ARCHETYPES) {
    if (onlyArch && a.tag !== onlyArch) { n += CATEGORIES.length; continue; }

    // Steer the imagery with the freshest matching trend rule (RAG). Optional.
    let cue = a.desc;
    try {
      const emb = await embedText(`${a.tag}. ${a.desc}`);
      const { data: matches } = await db.rpc("match_trend_insights", { query_embedding: emb, match_region: null, match_count: 1 });
      if (matches && matches.length) {
        cue = `${a.desc}. Current direction: ${matches[0].summary} (${(matches[0].keywords ?? []).join(", ")})`;
      }
    } catch (e) {
      console.error("[build-muses] rag", a.tag, (e as Error).message);
    }

    for (const category of CATEGORIES) {
      try {
        const color = COLORS[n % COLORS.length];
        const sil = SILHOUETTES[n % SILHOUETTES.length];
        n++;
        const prompt = [
          `Full-body editorial fashion photograph of an anonymous ${who} (a fashion model, NOT a real or recognizable person) wearing a complete ${wear} ${category} outfit in the "${a.tag}" aesthetic.`,
          cue,
          `Make THIS look distinct: build it around a ${color} palette with a ${sil} silhouette, and choose specific garments that differ from a generic version.`,
          "Head-to-toe framing, photorealistic, plain seamless pure-white (#FFFFFF) studio background, soft even lighting.",
          "No logos, no brand names, no text, no watermarks.",
        ].join(" ");

        const img = await generateImage(prompt);
        const path = `${slug(a.tag)}/${category}-${season}.png`;
        const { error: upErr } = await db.storage.from(BUCKET).upload(path, b64ToBytes(img.data), { contentType: img.mimeType, upsert: true });
        if (upErr) throw new Error(`upload: ${upErr.message}`);

        // Replace any prior row for this archetype+category to keep the library current.
        await db.from("muse_looks").delete().eq("archetype", a.tag).eq("category", category);
        const { error } = await db.from("muse_looks").insert({
          archetype: a.tag, category, image_path: path, caption: `${a.tag} · ${category}`, season,
        });
        if (error) throw new Error(error.message);
        saved++;
      } catch (e) {
        console.error("[build-muses]", a.tag, category, (e as Error).message);
        errors.push(`${a.tag}/${category}: ${(e as Error).message}`);
      }
    }
  }

  return json({ saved, failed: errors.length, season, errors: errors.slice(0, 10) });
});
