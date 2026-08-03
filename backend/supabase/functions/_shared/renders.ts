// Shared finalization for the async fan-out render pipeline (migration 0010).
// Each render-look worker (and the dispatcher, on a failed dispatch) calls
// finalizeGeneration after flipping its row; only the caller that atomically
// moves the parent generations row out of 'processing' performs the terminal
// work (output snapshot + credit burn), so concurrent finishers can't double it.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { burnFree, getEntitlement } from "./supabase.ts";

type RenderRow = {
  id: string;
  look_index: number;
  status: string;
  image_path: string | null;
  meta: {
    tier?: string;
    title?: string;
    wardrobe_used?: unknown[];
    affiliate?: unknown[];
  } | null;
};

export async function finalizeGeneration(db: SupabaseClient, generationId: string, userId: string) {
  const { data } = await db.from("look_renders")
    .select("id, look_index, status, image_path, meta")
    .eq("generation_id", generationId)
    .order("look_index");
  const sibs = (data ?? []) as RenderRow[];
  if (sibs.length === 0 || sibs.some((s) => s.status === "pending")) return;

  const done = sibs.filter((s) => s.status === "completed" && s.image_path);
  // Burn-once guard: a per-card RETRY re-opens an already-finalized set, and
  // its finalize must not charge a second credit. The flag rides in output.
  const { data: prev } = await db.from("generations")
    .select("output").eq("id", generationId).maybeSingle();
  const credited = (prev?.output as { credited?: boolean } | null)?.credited === true;

  const update: Record<string, unknown> = {
    status: done.length ? "succeeded" : "failed",
    updated_at: new Date().toISOString(),
  };
  if (done.length) {
    // Legacy-compatible snapshot: My Looks and keepLook read generations.output.
    update.output = {
      image_path: done[0].image_path,
      image_paths: done.map((d) => d.image_path),
      looks: done.map((d) => ({
        image_path: d.image_path,
        tier: d.meta?.tier,
        title: d.meta?.title,
        wardrobe_used: d.meta?.wardrobe_used ?? [],
        affiliate: d.meta?.affiliate ?? [],
      })),
      credited: true,
    };
  } else {
    update.error = "all looks failed";
  }

  // Atomic winner: only the processing→terminal transition proceeds.
  const { data: won } = await db.from("generations")
    .update(update)
    .eq("id", generationId).eq("status", "processing")
    .select("id");
  if (!won?.length) return;

  if (done.length && !credited) {
    // One credit per SET, burned only when it actually produced looks —
    // matches the old synchronous semantics (failure = no burn).
    const ent = await getEntitlement(db, userId);
    await burnFree(db, userId, ent);
  }
}

/** Rebuild the parent's output snapshot from the CURRENT rows regardless of
 * its status — used when late (off-critical-path) validation demotes an
 * already-completed render after the set was finalized. Preserves the
 * credited flag: losing it would let a later retry finalize burn a second
 * credit. */
export async function refreshGenerationOutput(db: SupabaseClient, generationId: string) {
  const { data } = await db.from("look_renders")
    .select("id, look_index, status, image_path, meta")
    .eq("generation_id", generationId)
    .order("look_index");
  const sibs = (data ?? []) as RenderRow[];
  if (sibs.some((s) => s.status === "pending")) return; // finalize will handle it
  const done = sibs.filter((s) => s.status === "completed" && s.image_path);
  const { data: prev } = await db.from("generations")
    .select("output").eq("id", generationId).maybeSingle();
  const credited = (prev?.output as { credited?: boolean } | null)?.credited === true;
  await db.from("generations").update(
    done.length
      ? {
        status: "succeeded",
        output: {
          image_path: done[0].image_path,
          image_paths: done.map((d) => d.image_path),
          looks: done.map((d) => ({
            image_path: d.image_path,
            tier: d.meta?.tier,
            title: d.meta?.title,
            wardrobe_used: d.meta?.wardrobe_used ?? [],
            affiliate: d.meta?.affiliate ?? [],
          })),
          credited,
        },
        updated_at: new Date().toISOString(),
      }
      : { status: "failed", error: "all looks failed", updated_at: new Date().toISOString() },
  ).eq("id", generationId);
}

/** Flip a still-pending row to failed (dispatch error, dead worker) and run
 * finalization — otherwise a set whose every dispatch failed would hang in
 * 'processing' forever with the client waiting on Realtime. */
export async function markRenderFailed(db: SupabaseClient, renderId: string, error: string) {
  const { data: row } = await db.from("look_renders")
    .update({ status: "failed", error: error.slice(0, 300), updated_at: new Date().toISOString() })
    .eq("id", renderId).eq("status", "pending")
    .select("generation_id, user_id")
    .maybeSingle();
  if (row) await finalizeGeneration(db, row.generation_id as string, row.user_id as string);
}
