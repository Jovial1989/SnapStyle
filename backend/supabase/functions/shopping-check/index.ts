// POST /functions/v1/shopping-check  { image:{data(b64),mimeType} }
// P0-2 Shopping mode: fast in-store verdict on a garment the user is holding.
// ADVICE ONLY — no commerce: never brands, stores, prices or links. Gated;
// burns ONE credit on success (the follow-up avatar render is free).
import { admin, burnFree, canAnalyze, entitlementView, getEntitlement, getUser } from "../_shared/supabase.ts";
import { shoppingVerdict } from "../_shared/gemini.ts";
import { json, preflight } from "../_shared/http.ts";

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const db = admin();
  const user = await getUser(req, db);
  if (!user) return json({ error: "unauthorized" }, 401);

  const { image, category } = await req.json().catch(() => ({}));
  if (!image?.data || !image?.mimeType) return json({ error: "image { data, mimeType } required" }, 400);
  const cat = typeof category === "string" ? category : undefined;

  const ent = await getEntitlement(db, user.id);
  if (!canAnalyze(ent)) return json({ error: "quota_exhausted", entitlement: entitlementView(ent) }, 402);

  try {
    const [{ data: sp }, { data: items }] = await Promise.all([
      db.from("style_profiles").select("height_cm, body_type, proportions").eq("user_id", user.id).maybeSingle(),
      db.from("wardrobe_items").select("label").eq("user_id", user.id),
    ]);
    const wardrobe = (items ?? []).map((i: { label?: string }) => i.label ?? "").filter(Boolean);

    const verdict = await shoppingVerdict({ data: image.data, mimeType: image.mimeType }, sp ?? null, wardrobe, cat);
    await burnFree(db, user.id, ent); // success only

    return json({
      ...verdict,
      wardrobe_empty: wardrobe.length === 0,
      entitlement: entitlementView({ ...ent, free_used: ent.free_used + (ent.pro ? 0 : 1) }),
    });
  } catch (err) {
    console.error("[shopping-check]", (err as Error).message);
    return json({ error: "check_failed" }, 502); // quota NOT burned on failure
  }
});
