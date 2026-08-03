// POST /functions/v1/muse-feed   → shared archetype looks for the Generate loader.
// Returns muse_looks (public URLs) ordered so the caller's own aesthetic
// (style_dna.aesthetic_tag) leads. Read-only, no credit.
import { admin, getUser } from "../_shared/supabase.ts";
import { json, preflight } from "../_shared/http.ts";
import { interleaveByArchetype } from "../_shared/archetypes.ts";

const BUCKET = "muses";

// Map a free occasion (chip or typed) → one of the muse categories, so the
// Generate loader shows "how others dress for THIS occasion".
function occasionToCategory(occasion?: string | null): string | null {
  if (!occasion) return null;
  const o = occasion.toLowerCase();
  if (/(office|work|meeting|business|interview)/.test(o)) return "work";
  if (/(date|dinner|evening|night|party|drinks|cocktail|wedding|event)/.test(o)) return "evening";
  if (/(weekend|casual|errand|relax|home|travel|active|gym|sport|hot day)/.test(o)) return "weekend";
  if (/(everyday|daily|day)/.test(o)) return "everyday";
  return null; // unknown → don't filter (show all, interleaved)
}

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;

  const db = admin();
  const user = await getUser(req, db);
  if (!user) return json({ error: "unauthorized" }, 401);

  const body = await req.json().catch(() => ({}));
  const category = occasionToCategory(body?.occasion ?? body?.category);

  const sp = (await db.from("style_profiles").select("style_dna").eq("user_id", user.id).maybeSingle()).data;
  const myTag = (sp?.style_dna as { aesthetic_tag?: string } | null)?.aesthetic_tag ?? null;

  let q = db.from("muse_looks").select("archetype, category, image_path, caption").order("created_at", { ascending: false });
  if (category) q = q.eq("category", category);
  const { data: rows } = await q;

  const items = (rows ?? []).map((r) => ({
    archetype: r.archetype as string,
    category: r.category as string,
    caption: (r.caption as string | null) ?? (r.archetype as string),
    url: db.storage.from(BUCKET).getPublicUrl(r.image_path as string).data.publicUrl,
  }));

  // Interleave across archetypes for a diverse strip, caller's aesthetic first.
  return json({ items: interleaveByArchetype(items, myTag), myAesthetic: myTag });
});
