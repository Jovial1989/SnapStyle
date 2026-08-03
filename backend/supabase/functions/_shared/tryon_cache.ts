// Aggressive try-on cache (migration 0011): deterministic SHA-256 key over
// the full generation input → stored render in the 'generations' bucket under
// _cache/ (a prefix no client RLS path can reach; the service role bypasses).
// Same input ⇒ same key ⇒ the render is served back sub-second, no Gemini hop.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";

const BUCKET = "generations";

export type Inline = { data: string; mimeType: string };

/** Deterministic fingerprint of a generation input. Feed it EVERYTHING that
 * changes the output: person payload, instruction, reference payloads, model. */
export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const b64ToBytes = (b64: string) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));

function bytesToB64(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) {
    bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(bin);
}

/** Cache lookup. Returns the stored render inline, or null on miss. Never
 * throws — a broken cache must never break generation. */
export async function cacheGet(db: SupabaseClient, key: string): Promise<Inline | null> {
  try {
    const { data: row } = await db.from("tryon_cache")
      .select("image_path, mime_type, hits").eq("key", key).maybeSingle();
    if (!row) return null;
    const { data: blob } = await db.storage.from(BUCKET).download(row.image_path as string);
    if (!blob) return null;
    // Fire-and-forget hit accounting.
    db.from("tryon_cache")
      .update({ hits: (row.hits as number) + 1, last_hit_at: new Date().toISOString() })
      .eq("key", key).then(() => {}, () => {});
    return { data: bytesToB64(new Uint8Array(await blob.arrayBuffer())), mimeType: row.mime_type as string };
  } catch (e) {
    console.error("[tryon-cache] get", (e as Error).message);
    return null;
  }
}

/** Persist a fresh render under its key. Best-effort — failures only cost a
 * future cache miss. */
export async function cachePut(
  db: SupabaseClient, key: string, userId: string, kind: "fix" | "item", img: Inline,
): Promise<void> {
  try {
    const path = `_cache/${key}`;
    const { error: upErr } = await db.storage.from(BUCKET)
      .upload(path, b64ToBytes(img.data), { contentType: img.mimeType, upsert: true });
    if (upErr) throw new Error(upErr.message);
    await db.from("tryon_cache").upsert({
      key, user_id: userId, kind, image_path: path, mime_type: img.mimeType,
    });
  } catch (e) {
    console.error("[tryon-cache] put", (e as Error).message);
  }
}
