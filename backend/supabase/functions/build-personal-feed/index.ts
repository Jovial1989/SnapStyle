// POST /functions/v1/build-personal-feed
// SILENT backend job — builds the user's personal loader feed (feed_looks) shown
// while "Review my outfit" runs. HYBRID: REMIX the user's own garments from their
// reference looks when there's enough signal, else ASPIRATIONAL looks (their Style
// DNA × current trend) — all rendered on their OWN body photo. Never surfaced to
// the client as "generating". No credit burned (background enrichment).
import { admin, getUser, signedUrl } from "../_shared/supabase.ts";
import { fetchInline, type Inline } from "../_shared/gemini.ts";
import { embedText } from "../_shared/embed.ts";
import { generateLookImage } from "../_shared/imagegen.ts";
import { validateLookImages } from "../_shared/vision.ts";
import { json, preflight } from "../_shared/http.ts";

const REF_BUCKET = "body-photos";
const OUT_BUCKET = "generations";
const TARGET = 6;      // total feed size
const REMIX_MIN = 2;   // need ≥2 reference looks to attempt a remix
const b64ToBytes = (b64: string) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const db = admin();
  const user = await getUser(req, db);
  if (!user) return json({ error: "unauthorized" }, 401);

  // TTL cache — the feed_looks rows ARE the cache. If the newest one is younger
  // than 12h, the existing feed stands; skip ~6 Gemini image calls entirely.
  // Pass { force: true } to rebuild regardless (e.g. after new reference looks).
  const { force } = await req.json().catch(() => ({} as { force?: boolean }));
  if (!force) {
    const { data: newest } = await db.from("feed_looks")
      .select("created_at").eq("user_id", user.id)
      .order("created_at", { ascending: false }).limit(1).maybeSingle();
    if (newest && Date.now() - new Date(newest.created_at as string).getTime() < 12 * 60 * 60 * 1000) {
      console.log("[build-personal-feed] cache hit — feed younger than 12h, skipping generation");
      return json({ saved: 0, cached: true });
    }
  }

  // Need a body photo to render looks ON them.
  const sp = (await db.from("style_profiles").select("source_photo_path, body_type, proportions, style_dna").eq("user_id", user.id).maybeSingle()).data;
  const photoPath = sp?.source_photo_path as string | undefined;
  if (!photoPath) return json({ error: "no_body_photo" }, 409);

  const dna = (sp?.style_dna ?? {}) as { aesthetic_tag?: string; keywords?: string[]; color_palette?: string[] };
  const bodyType = sp?.body_type as string | null;
  const proportionDesc = (sp?.proportions as { description?: string } | null)?.description ?? null;
  const fit = [
    bodyType ? `Choose cuts and proportions that flatter a ${String(bodyType).replace(/_/g, " ")} build.` : "",
    proportionDesc ? `Their proportions: ${proportionDesc}.` : "",
  ].filter(Boolean).join(" ");

  // Trend rule via RAG (aesthetic-targeted). Fine if empty.
  let trendCue = "";
  let trendTag = dna.aesthetic_tag ?? "Elevated Minimalism";
  try {
    const emb = await embedText(`${dna.aesthetic_tag ?? ""}. ${(dna.keywords ?? []).join(", ")}`);
    const { data: matches } = await db.rpc("match_trend_insights", { query_embedding: emb, match_region: null, match_count: 1 });
    if (matches && matches.length) { trendCue = matches[0].summary; trendTag = matches[0].aesthetic_tag ?? trendTag; }
  } catch (e) {
    console.error("[build-personal-feed] rag", (e as Error).message);
  }

  const person = await fetchInline(await signedUrl(db, REF_BUCKET, photoPath, 300));

  // Reference looks for the remix path.
  const { data: refs } = await db.from("reference_looks").select("image_path").eq("user_id", user.id).order("created_at", { ascending: false }).limit(10);
  const refPaths = (refs ?? []).map((r) => r.image_path as string);
  const canRemix = refPaths.length >= REMIX_MIN;

  const tasks: { source: "remix" | "aspirational"; prompt: string; extra: Inline[] }[] = [];

  if (canRemix) {
    const refInlines: Inline[] = [];
    for (const p of refPaths.slice(0, 4)) {
      try { refInlines.push(await fetchInline(await signedUrl(db, REF_BUCKET, p, 300))); } catch { /* skip */ }
    }
    if (refInlines.length >= REMIX_MIN) {
      const dirs = [
        "Recombine their garments into a fresh everyday outfit.",
        "Recombine their garments into a sharper, dressed-up outfit.",
        "Recombine their garments into a relaxed weekend outfit.",
      ];
      for (const dir of dirs) {
        tasks.push({
          source: "remix",
          extra: refInlines,
          prompt: [
            "Using ONLY garments visible in the provided reference outfit photos, dress the person in the FIRST image in a new combination.",
            dir,
            trendCue ? `Lean into current direction: ${trendCue}.` : "",
            "Do not invent garments that are not present in the references. Keep the person's face, hair, body, pose and identity unchanged.",
            fit,
            "Photorealistic, full-body head-to-toe, plain seamless pure-white (#FFFFFF) studio background, soft even lighting. No logos, no text, no watermarks.",
          ].filter(Boolean).join(" "),
        });
      }
    }
  }

  // Aspirational fill to reach TARGET (also the whole feed when there are no refs).
  const aspDirs = ["a polished everyday outfit", "a smart evening outfit", "a relaxed weekend outfit", "a sharp, elevated outfit"];
  let ai = 0;
  while (tasks.length < TARGET) {
    const d = aspDirs[ai % aspDirs.length]; ai++;
    tasks.push({
      source: "aspirational",
      extra: [],
      prompt: [
        `Restyle the person into ${d} in the "${trendTag}" aesthetic.`,
        (dna.color_palette && dna.color_palette.length) ? `Favour their palette: ${dna.color_palette.join(", ")}.` : "",
        trendCue ? `Reflect current direction: ${trendCue}.` : "",
        "Keep their face, hair, body, pose and identity completely unchanged — only change the clothing.",
        fit,
        "Photorealistic, full-body head-to-toe, plain seamless pure-white (#FFFFFF) studio background, soft even lighting. No logos, no text, no watermarks.",
      ].filter(Boolean).join(" "),
    });
  }

  // Generate in parallel; tolerate partial failure.
  const settled = await Promise.allSettled(tasks.map((t) => generateLookImage(person, t.prompt, t.extra)));
  let produced: { source: "remix" | "aspirational"; img: Inline }[] = [];
  settled.forEach((r, i) => { if (r.status === "fulfilled") produced.push({ source: tasks[i].source, img: r.value }); });
  if (produced.length === 0) return json({ error: "all_failed" }, 502);

  // Validity gate — drop non-person renders (fail open if it nukes everything).
  try {
    const valid = await validateLookImages(produced.map((p) => p.img));
    const kept = produced.filter((_, i) => valid[i]);
    if (kept.length) produced = kept;
  } catch (e) {
    console.error("[build-personal-feed] validate", (e as Error).message);
  }

  // Refresh the feed: clear old, then store new + insert rows.
  await db.from("feed_looks").delete().eq("user_id", user.id);
  const ts = Date.now();
  let saved = 0;
  for (let i = 0; i < produced.length; i++) {
    const path = `${user.id}/feed-${ts}-${i}.png`;
    const { error: upErr } = await db.storage.from(OUT_BUCKET).upload(path, b64ToBytes(produced[i].img.data), { contentType: produced[i].img.mimeType, upsert: true });
    if (upErr) { console.error("[build-personal-feed] upload", upErr.message); continue; }
    const { error } = await db.from("feed_looks").insert({
      user_id: user.id,
      image_path: path,
      source: produced[i].source,
      aesthetic_tag: trendTag,
      caption: produced[i].source === "remix" ? "From your wardrobe" : "Fits your style",
    });
    if (!error) saved++;
  }

  return json({ saved, remix: canRemix });
});
