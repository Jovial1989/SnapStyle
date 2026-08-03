// POST /functions/v1/render-grid  { generation_id }   (service-role only)
//
// Batched worker for Generate my look: instead of one image call per planned
// look, it dresses the avatar in up to FOUR outfits with ONE gpt-image-1 call
// and flips all four look_renders rows together.
//
// Why: five separate renders cost ~$0.39 and five chances for a timeout to
// spoil the set; one grid of the same five costs ~$0.14 (measured token rates,
// 28.07.2026). Identity is safer too — the grid composites the avatar's own
// pixels back over the face instead of asking the model to preserve them.
//
// Contract kept deliberately identical to render-look so the client does not
// change: same rows, same statuses, same Realtime stream, same finalize. The
// only visible difference is that cards complete together rather than one by
// one — generate-look supplies an instant composited board to fill that wait.
//
// Rows beyond the grid ceiling (GRID_MAX=4) are handed to render-look, so a
// 5-look set stays a 5-look set.
import { admin, signedUrl } from "../_shared/supabase.ts";
import { fetchInline } from "../_shared/gemini.ts";
import { GRID_MAX, gridRender } from "../_shared/grid.ts";
import { finalizeGeneration, markRenderFailed } from "../_shared/renders.ts";
import { json, preflight } from "../_shared/http.ts";

const IN_BUCKET = "body-photos";
const OUT_BUCKET = "generations";

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  // Internal-only. The dispatcher passes the function's own service-role env
  // value; an operator can also drive it with `x-cron-secret` (same convention
  // as trend-parser) — the CLI-issued REST key is a DIFFERENT string from this
  // env var under the new API-key scheme, so it cannot be used here.
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const cron = Deno.env.get("CRON_SECRET");
  const internal = req.headers.get("Authorization") === `Bearer ${service}` ||
    (!!cron && req.headers.get("x-cron-secret") === cron);
  if (!internal) return json({ error: "forbidden" }, 403);

  const { generation_id } = await req.json().catch(() => ({}));
  if (!generation_id) return json({ error: "generation_id required" }, 400);

  const db = admin();
  const { data: rows } = await db.from("look_renders")
    .select("id, user_id, look_index, status, meta")
    .eq("generation_id", generation_id).eq("status", "pending")
    .order("look_index", { ascending: true });
  if (!rows?.length) return json({ ok: true, skipped: true }); // idempotent redelivery

  const { data: gen } = await db.from("generations")
    .select("input").eq("id", generation_id).maybeSingle();
  const photoPath = (gen?.input as { photoPath?: string } | null)?.photoPath;
  if (!photoPath) {
    for (const r of rows) await markRenderFailed(db, r.id as string, "parent has no photoPath");
    return json({ error: "no photoPath" }, 422);
  }

  const batch = rows.slice(0, GRID_MAX);
  const overflow = rows.slice(GRID_MAX);
  const userId = String(batch[0].user_id);

  // Any look that keeps garments from the source photo must NOT start from the
  // grey-basics avatar — and the grid's chroma mask only works on that avatar,
  // so those looks go down the per-look path instead of into the grid.
  const keepsPhoto = (m: unknown) =>
    ((m ?? {}) as { kept_from_photo?: string[] }).kept_from_photo?.length ? true : false;
  const gridRows = batch.filter((r) => !keepsPhoto(r.meta));
  const single = [...batch.filter((r) => keepsPhoto(r.meta)), ...overflow];

  try {
    if (gridRows.length) {
      // The avatar is mandatory here: the mask assumes neutral grey basics.
      const av = await db.storage.from(IN_BUCKET)
        .createSignedUrl(`${photoPath}.avatar.png`, 300);
      if (!av.data?.signedUrl) throw new Error("no canonical avatar for grid");
      const avatar = new Uint8Array(
        await (await fetch(av.data.signedUrl, { signal: AbortSignal.timeout(20_000) })).arrayBuffer());

      const descriptions = gridRows.map((r) => {
        const m = (r.meta ?? {}) as { garments?: string[]; title?: string };
        const g = (m.garments ?? []).filter(Boolean);
        return g.length ? g.join(", ") : String(m.title ?? "a complete outfit");
      });

      const { cells } = await gridRender({
        avatar,
        descriptions,
        note: "Full body head-to-toe in every panel, feet visible, plain seamless " +
              "pure-white background.",
      });

      for (let i = 0; i < gridRows.length && i < cells.length; i++) {
        const r = gridRows[i];
        const path = `${userId}/${generation_id}_${r.look_index}.jpg`;
        const { error: upErr } = await db.storage.from(OUT_BUCKET)
          .upload(path, cells[i], { contentType: "image/jpeg", upsert: true });
        if (upErr) throw new Error(`upload: ${upErr.message}`);
        const { error: rowErr } = await db.from("look_renders")
          .update({ status: "completed", image_path: path, updated_at: new Date().toISOString() })
          .eq("id", r.id);
        // A row left pending would hang the client's card forever.
        if (rowErr) throw new Error(`row ${r.look_index}: ${rowErr.message}`);
      }
      console.log(`[render-grid] ${gridRows.length} looks in one call, gen ${generation_id}`);
    }
  } catch (e) {
    const msg = (e as Error).message;
    console.error("[render-grid]", msg);
    // Grid failed → let the proven per-look path try, rather than failing cards.
    single.push(...gridRows);
  }

  // Per-look fallback / overflow, fired the same way generate-look does it.
  if (single.length) {
    const base = Deno.env.get("SUPABASE_URL")!;
    await Promise.allSettled(single.map((r, i) => (async () => {
      if (i) await new Promise((res) => setTimeout(res, i * 300));
      const res = await fetch(`${base}/functions/v1/render-look`, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${service}` },
        body: JSON.stringify({ render_id: r.id }),
      }).catch((err) => {
        markRenderFailed(db, r.id as string, `dispatch: ${(err as Error).message}`);
        return null;
      });
      if (res && !res.ok) await markRenderFailed(db, r.id as string, `dispatch ${res.status}`);
    })()));
  }

  // Grid rows all landed at once, so the set is finished here — render-look
  // finalizes for itself when it handles the overflow.
  await finalizeGeneration(db, String(generation_id), userId).catch(() => {});
  return json({ ok: true, grid: gridRows.length, single: single.length });
});
