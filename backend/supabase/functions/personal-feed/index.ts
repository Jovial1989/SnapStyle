// POST /functions/v1/personal-feed   → the user's Review-loader feed.
// Returns their silently pre-generated feed_looks (signed URLs). If none exist
// yet (not uploaded / still building), SILENTLY falls back to trend-targeted
// muse looks by the user's aesthetic. The client can't tell which path served it.
// Read-only, no credit.
import { admin, getUser, signedUrl } from "../_shared/supabase.ts";
import { json, preflight } from "../_shared/http.ts";
import { interleaveByArchetype } from "../_shared/archetypes.ts";

const GEN_BUCKET = "generations";
const MUSE_BUCKET = "muses";

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;

  const db = admin();
  const user = await getUser(req, db);
  if (!user) return json({ error: "unauthorized" }, 401);

  // 1) Personalized feed, if ready.
  const { data: looks } = await db.from("feed_looks")
    .select("image_path, source, caption")
    .eq("user_id", user.id)
    .order("created_at", { ascending: false })
    .limit(12);
  if (looks && looks.length) {
    const items = [];
    for (const l of looks) {
      try {
        items.push({
          url: await signedUrl(db, GEN_BUCKET, l.image_path as string, 600),
          caption: (l.caption as string | null) ?? "Fits your style",
          source: l.source as string,
        });
      } catch { /* skip unreadable */ }
    }
    if (items.length) return json({ items, personalized: true });
  }

  // 2) Fallback: trend-targeted muses (public URLs). Interleave across archetypes
  // so the strip is DIVERSE (colours/cuts/styles), the caller's aesthetic first.
  const sp = (await db.from("style_profiles").select("style_dna").eq("user_id", user.id).maybeSingle()).data;
  const myTag = (sp?.style_dna as { aesthetic_tag?: string } | null)?.aesthetic_tag ?? null;
  const { data: rows } = await db.from("muse_looks")
    .select("archetype, image_path, caption")
    .order("created_at", { ascending: false });
  const all = (rows ?? []).map((r) => ({
    url: db.storage.from(MUSE_BUCKET).getPublicUrl(r.image_path as string).data.publicUrl,
    caption: (r.caption as string | null) ?? (r.archetype as string),
    source: "trend",
    archetype: r.archetype as string,
  }));
  // Style-matched: lead with the caller's own aesthetic (looks like their taste),
  // then a diverse interleave of the rest so scrolling still shows variety.
  const mine = all.filter((i) => i.archetype === myTag);
  const rest = interleaveByArchetype(all.filter((i) => i.archetype !== myTag));
  return json({ items: [...mine, ...rest].slice(0, 12), personalized: false });
});
