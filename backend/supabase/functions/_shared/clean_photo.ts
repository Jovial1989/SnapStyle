// One-time background removal for a just-uploaded body photo. The cleaned
// cutout lands at `${photoPath}.clean.png` in body-photos; every render
// consumer TRIES that path first and falls back to the raw upload — so the
// avatar starts from a clean silhouette (no halo remnants above the head)
// and workers skip repeated isolation.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";

const BUCKET = "body-photos";

export async function cleanBodyPhoto(db: SupabaseClient, photoPath: string): Promise<void> {
  const base = Deno.env.get("PREPROCESSOR_URL");
  if (!base) return;
  try {
    const { data: blob, error } = await db.storage.from(BUCKET).download(photoPath);
    if (error || !blob) throw new Error(error?.message ?? "download failed");
    const fd = new FormData();
    fd.append("file", blob, "person");
    const r = await fetch(`${base.replace(/\/$/, "")}/preprocess`, {
      method: "POST",
      body: fd,
      signal: AbortSignal.timeout(40_000),
    });
    if (!r.ok) throw new Error(`preprocessor ${r.status}`);
    const out = new Uint8Array(await r.arrayBuffer());
    if (out.length === 0) throw new Error("empty result");
    const { error: up } = await db.storage.from(BUCKET)
      .upload(`${photoPath}.clean.png`, out, { contentType: "image/png", upsert: true });
    if (up) throw new Error(up.message);
    console.log("[clean-photo] ok", photoPath);
  } catch (e) {
    console.error("[clean-photo]", photoPath, (e as Error).message);
  }
}
