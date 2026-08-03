// POST /functions/v1/vibe-check
// Body: { imagePaths?: string[1..3], locale?, city?, weather?, skip?: bool }
// "Vibe Check" onboarding — decode a visual Style DNA from 1–3 reference images,
// or, if the user skips / gives none, seed a safe fallback anchor from locale +
// coarse geo + season. Persists to style_profiles.style_dna. Authed, no credit
// burned. Writes are service-role (style_profiles is SELECT-only for clients). §14.12
import { admin, getUser, signedUrl } from "../_shared/supabase.ts";
import { extractStyleDna, fetchInline, STYLE_DNA_VERSION } from "../_shared/gemini.ts";
import { json, preflight } from "../_shared/http.ts";

const BUCKET = "body-photos";

function season(): string {
  const m = new Date().getUTCMonth();
  return (m <= 1 || m === 11) ? "winter" : m <= 4 ? "spring" : m <= 7 ? "summer" : "autumn";
}

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const db = admin();
  const user = await getUser(req, db);
  if (!user) return json({ error: "unauthorized" }, 401);

  const { imagePaths, locale, city, weather, skip } = await req.json().catch(() => ({}));

  // A profile row must exist (Vibe Check runs after body onboarding; height is
  // required to create the row, so we never insert here).
  const { data: sp } = await db.from("style_profiles")
    .select("user_id").eq("user_id", user.id).maybeSingle();
  if (!sp) return json({ error: "no_profile" }, 422);

  // Only accept image paths inside the user's own storage folder (RLS parity).
  const paths: string[] = Array.isArray(imagePaths)
    ? imagePaths.filter((p) => typeof p === "string" && p.startsWith(`${user.id}/`)).slice(0, 3)
    : [];

  let dna: Record<string, unknown> | null = null;
  let source = "fallback";

  if (!skip && paths.length > 0) {
    try {
      const imgs = await Promise.all(paths.map(async (p) => await fetchInline(await signedUrl(db, BUCKET, p))));
      dna = await extractStyleDna(imgs);
      source = "images";
    } catch (e) {
      console.error("[vibe-check] extract", (e as Error).message); // fall through to the fallback anchor
      dna = null;
    }
  }

  if (!dna) {
    // ── Smart fallback ────────────────────────────────────────────────────────
    // Locale (device settings — no permission) gives a baseline; a coarse region
    // is parsed from it (or an optional country header). Weather/city are used
    // ONLY if the client passed them (privacy: no silent precise-location grab).
    // Default anchor = "Elevated Minimalism" — the safest premium baseline.
    const region = (typeof locale === "string" ? locale.split(/[-_]/)[1] : "") ||
      req.headers.get("x-country") || null;
    dna = {
      fit_preference: "regular",
      color_palette: ["charcoal", "ecru", "navy", "stone", "black"],
      aesthetic_tag: "Elevated Minimalism",
      keywords: ["clean lines", "neutral base", "considered proportions", "quality basics"],
      summary: "Starting from a safe, globally flattering baseline — it sharpens as you use the app.",
      context: {
        locale: typeof locale === "string" ? locale : null,
        region,
        city: typeof city === "string" ? city : null,
        weather: typeof weather === "string" ? weather : null,
        season: season(),
      },
    };
    source = "fallback";
  }

  const styleDna = { ...dna, source, version: STYLE_DNA_VERSION };
  const { error } = await db.from("style_profiles")
    .update({ style_dna: styleDna, updated_at: new Date().toISOString() })
    .eq("user_id", user.id);
  if (error) {
    console.error("[vibe-check]", error.message);
    return json({ error: "save_failed" }, 502);
  }
  return json({ styleDna });
});
