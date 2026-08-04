// POST /functions/v1/fix-dispatch  { image, instruction, target_zones?,
// locked_zones?, references? } → { renderId } (202) | { image, cached } (200)
//
// Realtime editor swaps: instead of one long HTTP request that hides the
// render + QA + retry behind a 45s-timeout connection, the dispatcher answers
// in <1s — either straight from the try-on cache, or with a fix_renders row id
// whose worker invocation it fires WITHOUT awaiting. The Flutter editor
// subscribes to the row: v1 paints the moment it exists, a QA-refined v2
// silently replaces it, failures land as an honest per-render error.
import { admin, getUser } from "../_shared/supabase.ts";
import { cacheGet, sha256Hex } from "../_shared/tryon_cache.ts";
import { json, preflight } from "../_shared/http.ts";

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const db = admin();
  const user = await getUser(req, db);
  if (!user) return json({ error: "unauthorized" }, 401);

  const { image, instruction, target_zones, locked_zones, references, tucked, identity,
          reference_urls, reference_zones, reference_hints, person_path } = await req.json().catch(() => ({}));
  if (!image?.data || !image?.mimeType) return json({ error: "image { data, mimeType } required" }, 400);
  if (!instruction) return json({ error: "instruction required" }, 400);
  const refs: { data: string; mimeType: string }[] =
    (Array.isArray(references) ? references : [])
      .filter((r) => r?.data && r?.mimeType)
      .slice(0, 4);
  const targetZones: string[] = Array.isArray(target_zones) ? target_zones.map(String) : [];
  const lockedZones: string[] = Array.isArray(locked_zones) ? locked_zones.map(String) : [];

  // "gemini" stays in the fingerprint for continuity with keys written while
  // the (since removed) Fal experiment ran.
  const eng = "gemini";
  const model = Deno.env.get("GEMINI_IMAGE_MODEL") ?? "gemini-2.5-flash-image";
  const cacheKey = await sha256Hex([
    "fix:v12", eng, model, image.data, instruction, // v4: construction-source prompt + no-cache-on-fail-open (v3 held cut-inherited renders)
    targetZones.join(","), lockedZones.join(","),
    ...refs.map((r) => r.data),
  ].join("|"));
  // Optional DUAL-TUCK bundle: instruction+zones for the tucked variant of a
  // top swap. Both states render in ONE worker job (Promise.all) and land on
  // the same row — the client's toggle then swaps sources locally, 0ms.
  const tk = tucked?.instruction
    ? {
      instruction: String(tucked.instruction),
      target_zones: Array.isArray(tucked.target_zones) ? tucked.target_zones.map(String) : [],
      locked_zones: Array.isArray(tucked.locked_zones) ? tucked.locked_zones.map(String) : [],
    }
    : null;
  const cacheKeyTucked = tk
    ? await sha256Hex([
      "fix:v12", eng, model, image.data, tk.instruction,
      tk.target_zones.join(","), tk.locked_zones.join(","),
      ...refs.map((r) => r.data),
    ].join("|"))
    : null;

  const cached = await cacheGet(db, cacheKey);
  const cachedTucked = cacheKeyTucked ? await cacheGet(db, cacheKeyTucked) : null;
  if (cached && (!tk || cachedTucked)) {
    return json({ image: cached, image_tucked: cachedTucked ?? undefined, cached: true, applied: true });
  }

  const { data: row, error: insErr } = await db.from("fix_renders")
    .insert({ user_id: user.id, cache_key: cacheKey })
    .select("id").single();
  if (insErr || !row) {
    console.error("[fix-dispatch] insert", insErr?.message);
    return json({ error: "db_error" }, 500);
  }

  const base = Deno.env.get("SUPABASE_URL")!;
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const work = fetch(`${base}/functions/v1/fix-render`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${service}` },
    body: JSON.stringify({
      render_id: row.id, image, instruction,
      target_zones: targetZones, locked_zones: lockedZones, references: refs,
      // Pass-through for the self-hosted renderer: (zone, garment) pairs, where
      // an empty URL means "take the next entry from references".
      reference_urls: Array.isArray(reference_urls) ? reference_urls : [],
      reference_zones: Array.isArray(reference_zones) ? reference_zones : [],
      reference_hints: Array.isArray(reference_hints) ? reference_hints : [],
      // A Storage path INSTEAD of pixels: our own renders already live there, so
      // a chained swap need not re-upload the look it just received.
      person_path: typeof person_path === "string" ? person_path : undefined,
      identity: identity?.data && identity?.mimeType ? identity : undefined,
      tucked: tk, cache_key_tucked: cacheKeyTucked,
    }),
  }).then(async (r) => {
    if (!r.ok) {
      await db.from("fix_renders")
        .update({ status: "failed", error: `dispatch ${r.status}`, updated_at: new Date().toISOString() })
        .eq("id", row.id).eq("status", "pending");
    }
  }).catch(async (e) => {
    await db.from("fix_renders")
      .update({ status: "failed", error: `dispatch: ${(e as Error).message}`.slice(0, 300), updated_at: new Date().toISOString() })
      .eq("id", row.id).eq("status", "pending");
  });
  // deno-lint-ignore no-explicit-any
  const rt = (globalThis as any).EdgeRuntime;
  if (rt?.waitUntil) rt.waitUntil(work);

  return json({ renderId: row.id }, 202);
});
