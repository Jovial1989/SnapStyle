// Service-role admin client + per-user auth + server-authoritative quota.
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are auto-injected into every function.
import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";

// Free renders per account. Cut 10 → 5 on 28.07.2026: a render costs us
// ~$0.065, so ten of them was $0.65 of unpaid COGS per signup — the main
// abuse surface of a subscription-only product. Overridable without a deploy.
// NOTE: the BETA3X promo grants 2×FREE_QUOTA, so it now adds 10, not 20.
export const FREE_QUOTA = Number(Deno.env.get("FREE_QUOTA") ?? 5);

export function admin(): SupabaseClient {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
}

/** Resolve the authenticated user from the request's Bearer JWT. null = unauthorized. */
export async function getUser(req: Request, db: SupabaseClient) {
  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!token) return null;
  const { data, error } = await db.auth.getUser(token);
  if (error || !data.user) return null;
  return data.user;
}

export type Ent = { pro: boolean; premium: boolean; free_used: number; bonus_tokens: number };

export async function getEntitlement(db: SupabaseClient, userId: string): Promise<Ent> {
  const { data } = await db.from("entitlements")
    .select("pro, plan, free_used, bonus_tokens").eq("user_id", userId).single();
  return {
    pro: data?.pro === true,
    // Premium = the $19.99 tier (fit controls, accessory studio).
    premium: data?.pro === true && ((data?.plan as string | null) ?? "").startsWith("premium"),
    free_used: data?.free_used ?? 0,
    bonus_tokens: data?.bonus_tokens ?? 0,
  };
}

export const canAnalyze = (e: Ent) => e.pro || e.free_used < FREE_QUOTA + e.bonus_tokens;

/** Burn one free credit — call ONLY after a successful result, and only if not pro. */
export async function burnFree(db: SupabaseClient, userId: string, e: Ent) {
  if (e.pro) return;
  await db.from("entitlements")
    .update({ free_used: e.free_used + 1, updated_at: new Date().toISOString() })
    .eq("user_id", userId);
}

export const entitlementView = (e: Ent) => ({
  pro: e.pro,
  freeRemaining: Math.max(0, FREE_QUOTA + e.bonus_tokens - e.free_used),
});

/** Signed URL for a private bucket object. */
export async function signedUrl(db: SupabaseClient, bucket: string, path: string, expires = 600) {
  const { data, error } = await db.storage.from(bucket).createSignedUrl(path, expires);
  if (error || !data) throw new Error(`signedUrl: ${error?.message ?? "unknown"}`);
  return data.signedUrl;
}
