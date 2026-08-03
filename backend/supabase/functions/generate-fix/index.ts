// POST /functions/v1/generate-fix  { image:{data(b64),mimeType}, instruction }
// Preview ONE recommendation applied to the user's own photo (part of a review
// they already ran — no credit burned). Synchronous Gemini image edit.
// Returns { image:{ data(b64), mimeType } }. Inspiration only — never shoppable.
import { admin, getUser } from "../_shared/supabase.ts";
import { verifyEditApplied } from "../_shared/gemini.ts";
import { generateLookImage } from "../_shared/imagegen.ts";
import { hybridDress, hybridEnabled, slotOf, stageInline, unstage } from "../_shared/vton.ts";
import { cacheGet, cachePut, sha256Hex } from "../_shared/tryon_cache.ts";
import { buildCompactFixPrompt, buildFixPrompt, FIX_RETRY_NOTE } from "../_shared/fix_prompt.ts";
import { json, preflight } from "../_shared/http.ts";

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  // Phase timings, because "12s for a 4s render" is unanswerable from the
  // outside and Edge Function logs are not reachable from our CLI.
  const T0 = Date.now();
  const marks: Record<string, number> = {};
  const mark = (k: string) => { marks[k] = Date.now() - T0; };
  const db = admin();
  const user = await getUser(req, db);
  if (!user) return json({ error: "unauthorized" }, 401);

  const { image, instruction, target_zones, locked_zones, references, attempt,
          reference_urls, person_path } = await req.json().catch(() => ({}));
  // BYTES ARE THE EXPENSIVE PART, and most of them never needed to move. A
  // catalogue garment already lives at a public URL and the current look already
  // lives in Storage, yet the client was downloading them, base64-encoding them,
  // POSTing ~2 MB, and we were decoding and re-uploading the same pixels. Measured
  // cost of that round trip: ~2s on the wire, 0.8s hashing it, 1.5s restaging it.
  // Given a URL or a Storage path we hand the worker a reference and touch no
  // pixels at all. `references`/`image` remain for callers that genuinely only
  // hold bytes (a freshly rendered look that was never persisted).
  const refUrls: string[] = (Array.isArray(reference_urls) ? reference_urls : [])
    .filter((u) => typeof u === "string" && /^https?:\/\//.test(u)).slice(0, 4);
  const personPath = typeof person_path === "string" ? person_path : null;
  if (!personPath && (!image?.data || !image?.mimeType)) {
    return json({ error: "image { data, mimeType } or person_path required" }, 400);
  }
  if (!instruction) return json({ error: "instruction required" }, 400);
  // Image-grounded swaps: product shots of the garment(s) to dress. Text-only
  // descriptions kept drifting (white trousers rendered for "denim shorts");
  // a visual reference pins color, wash, length and construction exactly.
  const refs: { data: string; mimeType: string }[] =
    (Array.isArray(references) ? references : [])
      .filter((r) => r?.data && r?.mimeType)
      .slice(0, 4);
  // Anchor Items contract: {"target_zones": ["accessories"], "locked_zones":
  // ["top","bottom","shoes"]} → hard inpainting boundaries. A watch swap is
  // confined to the wrist; locked garments are pixel-frozen.
  const targetZones: string[] = Array.isArray(target_zones) ? target_zones.map(String) : [];
  const lockedZones: string[] = Array.isArray(locked_zones) ? locked_zones.map(String) : [];

  const prompt = buildFixPrompt(String(instruction), refs.length, targetZones, lockedZones);

  // ── Aggressive cache: same person + same instruction + same references ⇒
  // the exact render we already made. Sub-second on hit, Gemini bypassed.
  // The key fingerprints EVERYTHING that shapes the output, model included.
  const model = Deno.env.get("GEMINI_IMAGE_MODEL") ?? "gemini-2.5-flash-image";
  // WHICH ENGINE RENDERED IT is part of the key. Without it, flipping
  // VTON_ENGINE would keep serving the other engine's cached pixels, and a
  // rollback would look like it had no effect.
  const engineTag = hybridEnabled() ? "hybrid" : "hosted";
  const cacheKey = await sha256Hex([
    "fix:v14", engineTag, model, personPath ?? image.data, instruction,
    refUrls.join(","),
    targetZones.join(","), lockedZones.join(","),
    ...refs.map((r) => r.data),
  ].join("|"));
  mark("hash");
  const cached = await cacheGet(db, cacheKey);
  if (cached) return json({ image: cached, cached: true, applied: true });

  // attempt >= 2 = the CLIENT's decisive re-run after a failed QA verdict —
  // the escalation note goes into the prompt, the retry policy stays client-
  // side (the server never hides a 10-20s re-render inside one request).
  const finalPrompt = Number(attempt) >= 2 ? prompt + FIX_RETRY_NOTE : prompt;

  try {
    // SELF-HOSTED ENGINE FIRST when this swap is something it can express: one
    // known zone plus a reference photo of the garment. ~2s against 45-60s, and
    // the head is outside its mask, so the misproportioned-face failure the
    // hosted path produced cannot happen. Anything else — an accessory swap,
    // several zones at once, no reference image — has no mask zone and stays on
    // the hosted provider rather than being forced into the nearest one.
    const slot = targetZones.length === 1 ? slotOf(targetZones[0]) : null;
    let out: { data: string; mimeType: string } | null = null;
    let hybridUsed = false;
    let engineError: string | null = null;
    if (hybridEnabled() && slot && (refs.length || refUrls.length)) {
      const staged: string[] = [];
      try {
        let personUrl: string;
        if (personPath) {
          // Already in Storage: a signed URL costs one round trip, not an upload.
          const { data: t } = await db.storage.from("generations")
            .createSignedUrl(personPath, 900, { transform: { width: 768, quality: 85 } });
          if (!t?.signedUrl) throw new Error(`person_path unreadable: ${personPath}`);
          personUrl = t.signedUrl;
        } else {
          const person = await stageInline(db, { data: image.data, mimeType: image.mimeType });
          staged.push(person.path);
          personUrl = person.url;
        }
        mark("stage_person");
        let refUrl: string;
        if (refUrls.length) {
          refUrl = refUrls[0];          // public catalogue image — nothing to copy
        } else {
          const ref = await stageInline(db, refs[0], "ref");
          staged.push(ref.path);
          refUrl = ref.url;
        }
        mark("stage_ref");
        out = await hybridDress(db, user.id, personUrl, [
          { url: refUrl, kind: slot, hint: String(instruction).slice(0, 200) },
        ]);
        hybridUsed = true;
        mark("render");
      } catch (e) {
        // Falling back is the whole point of the flag: a cold worker, a full
        // queue or a pose the detector cannot read must not fail the request.
        engineError = (e as Error).message;
        console.error("[generate-fix] hybrid engine failed, using hosted:", engineError);
      } finally {
        unstage(db, staged);
      }
    }
    out ??= await generateLookImage({ data: image.data, mimeType: image.mimeType }, finalPrompt, refs,
      { fallbackPrompt: buildCompactFixPrompt(String(instruction), refs.length) });
    // Inline QA verdict (~1s on the lite model): the caller learns HONESTLY
    // whether the edit took and drives its own retry. Only verified renders
    // enter the cache — a no-op can never become an instant replay.
    let applied = true;
    // The verifier exists because the HOSTED path silently no-op'd: it would
    // return the input unchanged and we had no way to know. The self-hosted
    // engine cannot do that — the masked region is resampled by construction,
    // so "the edit did not take" is not one of its failure modes.
    //
    // Keeping the check on that path was actively harmful: it is a Gemini vision
    // call costing 10-15s against a 2s render (measured 19.9s end to end), and
    // it returned applied=false for a render whose jeans were plainly there,
    // which blocks the cache and makes the client offer a pointless retry.
    if (hybridUsed) {
      console.log("[generate-fix] hybrid engine — QA verifier skipped");
    } else try {
      // The reference product shots go to the CHECKER too — construction
      // mismatches (sleeveless vs the reference's sleeves) are visual, and
      // text-only verification kept missing them.
      applied = (await verifyEditApplied(out, instruction, refs, { data: image.data, mimeType: image.mimeType })).applied;
    } catch { /* verifier down → fail open */ }
    if (applied) {
      const put = cachePut(db, cacheKey, user.id, "fix", out);
      // deno-lint-ignore no-explicit-any
      const rt = (globalThis as any).EdgeRuntime;
      if (rt?.waitUntil) rt.waitUntil(put);
      else await put;
    } else {
      console.log("[generate-fix] QA: edit not applied — render NOT cached");
    }
    return json({
      image: out,
      applied,
      engine: hybridUsed ? "hybrid" : "hosted",
      timings: { ...marks, total: Date.now() - T0 },
      ...(engineError ? { engine_error: engineError } : {}),
    });
  } catch (err) {
    console.error("[generate-fix]", (err as Error).message);
    return json({ error: "fix_failed" }, 502);
  }
});
