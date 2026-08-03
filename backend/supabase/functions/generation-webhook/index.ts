// POST /functions/v1/generation-webhook?gen=<id>  — fal calls this when a job
// finishes. Downloads the result into the private `generations` bucket and flips
// the row to succeeded/failed. Client is watching via Realtime.
// Deploy with --no-verify-jwt (fal has no Supabase JWT).
import { admin } from "../_shared/supabase.ts";
import { json } from "../_shared/http.ts";

const OUT_BUCKET = "generations";

Deno.serve(async (req) => {
  const genId = new URL(req.url).searchParams.get("gen");
  if (!genId) return json({ error: "gen id required" }, 400);

  const payload = await req.json().catch(() => ({}));
  const ok = payload.status === "OK" || payload.status === "COMPLETED";

  const db = admin();
  const { data: gen } = await db.from("generations").select("id, user_id").eq("id", genId).single();
  if (!gen) return json({ error: "generation not found" }, 404);

  if (!ok) {
    await db.from("generations").update({ status: "failed", error: "provider_error", updated_at: new Date().toISOString() }).eq("id", genId);
    return json({ received: true });
  }

  try {
    const resultUrl = payload?.payload?.image?.url || payload?.payload?.images?.[0]?.url;
    if (!resultUrl) throw new Error("no image url in webhook");

    const img = await fetch(resultUrl);
    const bytes = new Uint8Array(await img.arrayBuffer());
    const path = `${gen.user_id}/${genId}.png`;

    const { error: upErr } = await db.storage.from(OUT_BUCKET).upload(path, bytes, { contentType: "image/png", upsert: true });
    if (upErr) throw new Error(upErr.message);

    await db.from("generations").update({ status: "succeeded", output: { image_path: path }, updated_at: new Date().toISOString() }).eq("id", genId);
    return json({ received: true });
  } catch (err) {
    console.error("[generation-webhook]", (err as Error).message);
    await db.from("generations").update({ status: "failed", error: (err as Error).message, updated_at: new Date().toISOString() }).eq("id", genId);
    return json({ error: "webhook_failed" }, 500);
  }
});
