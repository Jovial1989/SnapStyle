// POST /functions/v1/save-reference-looks   { paths: string[] }
// Stores the 2–10 onboarding "your looks" photos, refreshes Style DNA from ALL
// of them (richer than vibe-check's ≤3), then fires the SILENT personal-feed
// builder in the background. No credit burned. Photos already live in the
// caller's own folder of the private `body-photos` bucket.
import { admin, getUser, signedUrl } from "../_shared/supabase.ts";
import { fetchInline, extractStyleDna } from "../_shared/gemini.ts";
import { json, preflight } from "../_shared/http.ts";

const IN_BUCKET = "body-photos";

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const db = admin();
  const user = await getUser(req, db);
  if (!user) return json({ error: "unauthorized" }, 401);

  const { paths } = await req.json().catch(() => ({}));
  const clean: string[] = Array.isArray(paths)
    ? paths.filter((p) => typeof p === "string" && p.startsWith(`${user.id}/`)).slice(0, 10)
    : [];
  if (clean.length === 0) return json({ error: "paths[] (own folder) required" }, 400);

  const { error: insErr } = await db.from("reference_looks").insert(clean.map((image_path) => ({ user_id: user.id, image_path })));
  if (insErr) { console.error("[save-reference-looks] insert", insErr.message); return json({ error: "db_error" }, 500); }

  // Refresh Style DNA from up to 6 of the reference looks.
  try {
    const inlines = [];
    for (const p of clean.slice(0, 6)) {
      try { inlines.push(await fetchInline(await signedUrl(db, IN_BUCKET, p, 300))); } catch { /* skip unreadable */ }
    }
    if (inlines.length) {
      const dna = await extractStyleDna(inlines);
      const existing = (await db.from("style_profiles").select("style_dna").eq("user_id", user.id).maybeSingle()).data?.style_dna ?? {};
      await db.from("style_profiles").update({
        style_dna: { ...existing, ...dna, source: "reference_looks" },
        updated_at: new Date().toISOString(),
      }).eq("user_id", user.id);
    }
  } catch (e) {
    console.error("[save-reference-looks] dna", (e as Error).message);
  }

  // Kick the silent personal-feed builder without blocking onboarding.
  try {
    const url = `${Deno.env.get("SUPABASE_URL")}/functions/v1/build-personal-feed`;
    const p = fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": req.headers.get("Authorization") ?? "",
        "apikey": Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      },
      body: JSON.stringify({ force: true }), // new taste data → bypass the 12h TTL cache
    }).catch((e) => console.error("[save-reference-looks] kick", (e as Error).message));
    // deno-lint-ignore no-explicit-any
    const rt = (globalThis as any).EdgeRuntime;
    if (rt?.waitUntil) rt.waitUntil(p);
  } catch (e) {
    console.error("[save-reference-looks] kick-setup", (e as Error).message);
  }

  return json({ saved: clean.length });
});
