// POST /functions/v1/redeem-promo-code  { code }
// User-JWT auth (the user_id is ALWAYS derived from the token — never from the
// payload). MVP codes are hardcoded server-side:
//   FOUNDER26 → pro = true (the existing unlimited quota bypass)
//   BETA3X    → +2×FREE_QUOTA bonus tokens (triples the free tier)
// Every code is once-per-user: the promo_redemptions PK is the atomic guard.
import { admin, getUser, getEntitlement, entitlementView, FREE_QUOTA } from "../_shared/supabase.ts";
import { json, preflight } from "../_shared/http.ts";

const CODES = new Set(["FOUNDER26", "BETA3X"]);

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const db = admin();
  const user = await getUser(req, db);
  if (!user) return json({ error: "unauthorized" }, 401);

  const { code } = await req.json().catch(() => ({}));
  const norm = String(code ?? "").trim().toUpperCase();
  if (!norm) return json({ error: "bad_payload" }, 400);
  // Unknown code first — a typo must not burn anything.
  if (!CODES.has(norm)) return json({ error: "invalid_code" }, 404);

  // Atomic once-per-user claim: the PK insert either wins or 409s.
  const { error: dupe } = await db.from("promo_redemptions")
    .insert({ user_id: user.id, code: norm });
  if (dupe) return json({ error: "already_redeemed" }, 409);

  const e = await getEntitlement(db, user.id);
  const patch = norm === "FOUNDER26"
    ? { pro: true, source: "promo:FOUNDER26" }
    : { bonus_tokens: e.bonus_tokens + 2 * FREE_QUOTA };
  const { error: up } = await db.from("entitlements")
    .update({ ...patch, updated_at: new Date().toISOString() })
    .eq("user_id", user.id);
  if (up) {
    // Roll the claim back so the user can retry after a transient failure.
    await db.from("promo_redemptions").delete().match({ user_id: user.id, code: norm });
    return json({ error: "redeem_failed" }, 500);
  }

  const after = await getEntitlement(db, user.id);
  return json({ ok: true, code: norm, entitlement: entitlementView(after) });
});
