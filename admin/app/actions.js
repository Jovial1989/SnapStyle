"use server";
// Server actions — the ONLY writers. Each one revalidates the table.
import { revalidatePath } from "next/cache";
import { admin } from "./supabase";

const touch = { updated_at: new Date().toISOString() };

export async function setPro(userId, pro) {
  const db = admin();
  await db.from("entitlements")
    .update({ pro, source: pro ? "admin:grant" : "admin:revoke", ...touch })
    .eq("user_id", userId);
  revalidatePath("/");
}

export async function addTokens(userId, delta) {
  const db = admin();
  const { data } = await db.from("entitlements")
    .select("bonus_tokens").eq("user_id", userId).single();
  const next = Math.max(0, (data?.bonus_tokens ?? 0) + delta);
  await db.from("entitlements")
    .update({ bonus_tokens: next, ...touch }).eq("user_id", userId);
  revalidatePath("/");
}
