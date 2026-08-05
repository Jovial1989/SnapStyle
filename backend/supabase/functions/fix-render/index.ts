// POST /functions/v1/fix-render  { render_id, image, instruction, … }
// INTERNAL worker for Realtime editor swaps (service-role auth only; the
// payload travels in the invocation body — no storage roundtrip).
//
// Lifecycle it writes into fix_renders (each transition = a Realtime push):
//   pending/rendering → completed/verifying (v1 painted on the client)
//     → done                      (QA passed → v1 cached, final)
//     → refining → done           (QA failed → v2 rendered + swapped in place)
//   pending → failed              (render error — client shows tap-to-retry)
import { admin } from "../_shared/supabase.ts";
import { verifyEditApplied, IDENTITY_RETRY_NOTE, type Inline } from "../_shared/gemini.ts";
import { generateLookImage } from "../_shared/imagegen.ts";
import { hybridDress, hybridEnabled, type Slot, slotOf, stageInline, unstage } from "../_shared/vton.ts";
import { samePerson } from "../_shared/vision.ts";
import { kolorsTryOn } from "../_shared/kolors.ts";
import { cachePut } from "../_shared/tryon_cache.ts";
import { buildCompactFixPrompt, buildFixPrompt, FIX_RETRY_NOTE } from "../_shared/fix_prompt.ts";
import { logTrainingPair } from "../_shared/training.ts";
import { json, preflight } from "../_shared/http.ts";

const OUT_BUCKET = "generations";

const b64ToBytes = (b64: string) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));

/** PNG/JPEG dimensions straight from the header bytes — no image libs. */
function imgDims(b64: string): { w: number; h: number } | null {
  const bin = atob(b64.slice(0, 262144));
  if (bin.charCodeAt(0) === 0x89 && bin.charCodeAt(1) === 0x50) {
    const at = (i: number) => bin.charCodeAt(i);
    return {
      w: (at(16) << 24) | (at(17) << 16) | (at(18) << 8) | at(19),
      h: (at(20) << 24) | (at(21) << 16) | (at(22) << 8) | at(23),
    };
  }
  if (bin.charCodeAt(0) === 0xff && bin.charCodeAt(1) === 0xd8) {
    let i = 2;
    while (i < bin.length - 9) {
      if (bin.charCodeAt(i) !== 0xff) { i++; continue; }
      const m = bin.charCodeAt(i + 1);
      if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) {
        return {
          h: (bin.charCodeAt(i + 5) << 8) | bin.charCodeAt(i + 6),
          w: (bin.charCodeAt(i + 7) << 8) | bin.charCodeAt(i + 8),
        };
      }
      i += 2 + ((bin.charCodeAt(i + 2) << 8) | bin.charCodeAt(i + 3));
    }
  }
  return null;
}

const FRAMING_RETRY_NOTE =
  " NOTE: the previous attempt CROPPED the person — the output frame did not match the person photo's proportions and the feet were cut off. Re-render with EXACTLY the input photo's framing: full body, head to feet INSIDE the frame, same aspect.";

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  if (req.headers.get("Authorization") !== `Bearer ${service}`) {
    return json({ error: "forbidden" }, 403);
  }

  const { render_id, image, instruction, target_zones, locked_zones, references, identity, tucked, cache_key_tucked,
          reference_urls, reference_zones, reference_hints, person_path } =
    await req.json().catch(() => ({}));
  // Pixels are OPTIONAL now: `person_path` points at a look already in Storage
  // (our own renders land there), so a chained swap need not re-upload what it
  // was just handed. ~2s of mobile uplink and ~1s of restaging per tap.
  if (!render_id || !instruction || (!image?.data && !person_path)) {
    return json({ error: "bad_payload" }, 400);
  }

  const db = admin();
  const { data: row } = await db.from("fix_renders")
    .select("id, user_id, status, cache_key").eq("id", render_id).maybeSingle();
  if (!row) return json({ error: "not_found" }, 404);
  if (row.status !== "pending") return json({ ok: true, skipped: true }); // idempotent

  const refs: { data: string; mimeType: string }[] = Array.isArray(references) ? references : [];
  const targetZones: string[] = Array.isArray(target_zones) ? target_zones.map(String) : [];
  // THIS is the function the editor's swaps actually reach — fix-dispatch queues
  // and fix-render renders. Wiring the engine into generate-fix left every real
  // per-item swap on the hosted path (nothing in vton_jobs for a whole session
  // while a warm GPU sat idle), because generate-fix is only used by callers that
  // want a synchronous preview.
  const refUrls: string[] = Array.isArray(reference_urls) ? reference_urls.map(String) : [];
  const refZones: string[] = Array.isArray(reference_zones) ? reference_zones.map(String) : [];
  // The SHORT garment name per zone. Slicing `instruction` for this handed the
  // renderer 200 chars of composed-prompt boilerplate ('MANDATORY EDIT — this is
  // the entire point…') with no garment named in it. IP-Adapter still transferred
  // texture from the reference photo, but the text said nothing about a white
  // linen shirt, so the two conditionings disagreed and the previous black top's
  // colour survived with only its sleeves redrawn.
  const refHints: string[] = Array.isArray(reference_hints) ? reference_hints.map(String) : [];
  const personPath = typeof person_path === "string" ? person_path : null;
  const pairs: { kind: Slot; hint: string; url?: string; bytes?: { data: string; mimeType: string } }[] = [];
  {
    let byteAt = 0;
    for (let i = 0; i < refZones.length; i++) {
      const kind = slotOf(refZones[i]);
      const url = refUrls[i] ?? "";
      const bytes = url ? undefined : refs[byteAt++];
      if (!kind || (!url && !bytes)) continue;
      pairs.push({
        kind,
        // Fall back to the sliced instruction only when the client is older than
        // reference_hints — a weak hint still beats an empty one.
        hint: (refHints[i] || String(instruction).slice(0, 120)).trim(),
        url: url || undefined,
        bytes,
      });
    }
  }
  const lockedZones: string[] = Array.isArray(locked_zones) ? locked_zones.map(String) : [];
  // FACE IDENTITY ANCHOR: a head crop travels as the LAST reference image —
  // a photographic anchor beats any text clause.
  const idRef = identity?.data && identity?.mimeType
    ? { data: String(identity.data), mimeType: String(identity.mimeType) }
    : null;
  const genRefs = idRef ? [...refs, idRef] : refs;
  const prompt = buildFixPrompt(String(instruction), refs.length, targetZones, lockedZones, idRef !== null);
  // Lean fallback the image model falls back to when the full prompt returns
  // no image (IMAGE_OTHER) — see generateLookImage.
  const compact = buildCompactFixPrompt(String(instruction), refs.length);
  // LAZY. The self-hosted path never needs the person's bytes — it hands the
  // worker a signed URL, and the framing gate, QA verifier and identity gate are
  // all skipped on it. Only the hosted fallback and the training log read pixels,
  // so fetch them at most once and only if something actually asks.
  let _person: Inline | null = image?.data
    ? { data: String(image.data), mimeType: String(image.mimeType) }
    : null;
  const person = async (): Promise<Inline> => {
    if (_person) return _person;
    const { data, error } = await db.storage.from(OUT_BUCKET).download(personPath!);
    if (error || !data) throw new Error(`person_path unreadable: ${error?.message}`);
    const b = new Uint8Array(await data.arrayBuffer());
    let bin = "";
    for (let i = 0; i < b.length; i += 0x8000) bin += String.fromCharCode(...b.subarray(i, i + 0x8000));
    return (_person = { data: btoa(bin), mimeType: "image/jpeg" });
  };

  // NOTE: no separate identity gate here — verifyEditApplied (which runs
  // BEFORE the row flips completed) already includes the identity check, so
  // a wrong person still never paints, one model call cheaper.

  /// HARD RENDER BUDGET: at most 3 Gemini image renders per swap, TOTAL,
  /// across the framing gate, the QA retry and the identity retry. The stacked
  /// retries were multiplying one tap into 5-6 renders — burning the per-minute
  /// quota (429s → empties) and pushing swaps past 40s. Past the budget we ship
  /// the best frame we have; the user's "Not right?" button is the honest
  /// escalation path, not another silent minute.
  const BUDGET = 3;
  /// The engine being ASLEEP is not a render failure and must not be dressed up as
  /// one. Its own error type so the hosted fallback can distinguish "the pod is
  /// off" from "the render broke" — see the throw site below.
  class EngineOffline extends Error {}
  let renders = 0;

  /// DETERMINISTIC FRAMING GATE: model-QA kept missing cut-off feet, but a
  /// zoom-crop can't hide from arithmetic — an output whose aspect drifts
  /// >12% from the person photo IS a reframe. One silent retry.
  let hybridUsed = false;
  const renderFramed = async (p: string) => {
    renders++;
    // Self-hosted engine when the swap resolves to (zone, garment) pairs. The
    // framing gate below is a no-op for it — it repaints inside a mask and
    // composites back over the original, so the aspect cannot drift.
    if (hybridEnabled() && pairs.length) {
      const staged: string[] = [];
      try {
        // CANONICAL AVATAR AS THE BASE, not the raw upload. The mask repaints the
        // whole torso band intersected with the person matte, and MediaPipe counts
        // an object held against the chest as part of the body — so a phone in the
        // hand landed inside the repaint zone and came back as a grey slab, with
        // the hand beside it mangled. The avatar is the same person re-dressed in
        // neutral grey basics on white, arms down, nothing held: every render on it
        // has been clean. It also removes the previous garment from the canvas, so
        // a new one cannot read as a second layer over it.
        //
        // Falls through to whatever the client sent when no avatar exists yet
        // (it is built fire-and-forget after the first photo upload).
        let avatarPath: string | null = null;
        if (!personPath) {
          try {
            const { data: sp } = await db.from("style_profiles")
              .select("source_photo_path").eq("user_id", row.user_id).maybeSingle();
            const src = sp?.source_photo_path as string | undefined;
            // PREFER THE BARE-ARM BASE. The engine's masks must reach past the
            // base garment to cover it, and the sampler ends a sleeve where its
            // prior ends — so on the sleeved avatar the gap between the two came
            // back as the basics' grey cuff, measured on five of seven catalogue
            // tops. The `.bare.png` sibling has nothing to cover, so a short
            // sleeve resolves to a bare arm. Falls back to `.avatar.png` for any
            // avatar that predates it.
            if (src) {
              for (const cand of [`${src}.bare.png`, `${src}.avatar.png`]) {
                const { data: t } = await db.storage.from("body-photos")
                  .createSignedUrl(cand, 900, { transform: { width: 768, quality: 85 } });
                if (t?.signedUrl) { avatarPath = t.signedUrl; break; }
              }
            }
          } catch (_) {/* no avatar → use the client's pixels */}
        }
        // Already in Storage? Sign it. Staging would copy bytes we own into a
        // scratch object for no reason — measured ~1s of a ~7s server path.
        let personUrl: string;
        if (avatarPath) {
          personUrl = avatarPath;
        } else if (personPath) {
          const { data: t } = await db.storage.from(OUT_BUCKET)
            .createSignedUrl(personPath, 900, { transform: { width: 768, quality: 85 } });
          if (!t?.signedUrl) throw new Error(`person_path unreadable: ${personPath}`);
          personUrl = t.signedUrl;
        } else {
          // await person(): it is a lazy RESOLVER, not a value. Reading .data off
          // the function returned undefined, atob choked on it, the hybrid branch
          // threw, and the swap fell through to the hosted provider — which is
          // how a Gemini "API key not valid" surfaced on a path that is supposed
          // to touch no external API at all.
          const pr = await stageInline(db, await person());
          staged.push(pr.path);
          personUrl = pr.url;
        }
        const steps = [];
        for (const g of pairs) {
          let url = g.url;
          if (!url) {
            const ref = await stageInline(db, g.bytes!, "ref");
            staged.push(ref.path);
            url = ref.url;
          }
          // g.hint is the SHORT garment name (reference_hints), already resolved
          // when `pairs` was built. Rebuilding it from `instruction` here — which
          // is what this line used to do — threw that away and fed the renderer
          // 200 chars of composed-prompt boilerplate instead.
          steps.push({ url, kind: g.kind, hint: g.hint });
        }
        const img = await hybridDress(db, String(row.user_id), personUrl, steps);
        hybridUsed = true;
        console.log("[fix-render] hybrid:", steps.length, "steps");
        return img;
      } catch (e) {
        const why = (e as Error).message;
        console.error("[fix-render] hybrid failed:", why);
        // DO NOT FALL THROUGH TO THE HOSTED PROVIDER WHEN THE ENGINE IS SIMPLY
        // ASLEEP. The GPU pod is started per session, so "no worker" is a normal
        // state — and falling back put "gemini-image 400: API key not valid" on the
        // user's screen twice in one evening. That message is worse than useless: it
        // names a provider we deliberately turned off, for a request that never
        // reached one, and it reads as a broken app rather than an engine that needs
        // a minute. A hosted fallback is still right for a genuine render failure,
        // which is why only the asleep case rethrows.
        // Marked, not returned: this runs inside a function that owes the caller
        // an image, so the signal travels as a typed throw and the handler below
        // turns it into a 503.
        if (/asleep|no worker/i.test(why)) throw new EngineOffline(why);
      } finally {
        unstage(db, staged);
      }
    }
    const src = await person();
    let out = await generateLookImage(src, p, genRefs, { fallbackPrompt: compact });
    try {
      const din = imgDims(src.data);
      const dout = imgDims(out.data);
      if (din && dout && din.w > 0 && dout.h > 0) {
        const ain = din.w / din.h;
        const aout = dout.w / dout.h;
        if (Math.abs(aout - ain) / ain > 0.12 && renders < BUDGET) {
          console.error("[fix-render]", render_id, `framing gate: ${ain.toFixed(2)} → ${aout.toFixed(2)}, regenerating`);
          renders++;
          out = await generateLookImage(src, p + FRAMING_RETRY_NOTE, genRefs);
        }
      }
    } catch { /* parser hiccup → let model QA carry it */ }
    return out;
  };
  // DUAL TUCK: the tucked variant renders IN PARALLEL with the primary — one
  // job, one 'completed' event, both paths on the row. Zones travel per state
  // (tucking legally repaints the bottoms' waistband; the primary keeps them
  // frozen).
  const tk = tucked?.instruction
    ? buildFixPrompt(
      String(tucked.instruction),
      refs.length,
      Array.isArray(tucked.target_zones) ? tucked.target_zones.map(String) : [],
      Array.isArray(tucked.locked_zones) ? tucked.locked_zones.map(String) : [],
    )
    : null;

  const touch = (fields: Record<string, unknown>) => db.from("fix_renders")
    .update({ ...fields, updated_at: new Date().toISOString() }).eq("id", render_id);

  const upload = async (suffix: string, img: { data: string; mimeType: string }) => {
    const path = `${row.user_id}/_fix/${render_id}${suffix}.png`;
    const { error } = await db.storage.from(OUT_BUCKET)
      .upload(path, b64ToBytes(img.data), { contentType: img.mimeType, upsert: true });
    if (error) throw new Error(`upload: ${error.message}`);
    return path;
  };

  try {
    // ── FAST-FIRST PAINT: show v1 the moment it renders (~20s). QA, the
    // retry and the identity check keep running below and SWAP the image
    // (a new path → the client re-fetches, brief "Perfecting" badge) only if
    // they produce a better one. Holding the loader for a verified final was
    // the ~40s wait the user kept hitting. The client paints off Realtime row
    // updates, so this touch shows v1 immediately regardless of when the
    // function returns. ──────────────────────────────────────────────────
    // ENGINE ROUTING: a single-zone TOP/BOTTOM swap with a garment reference
    // goes to Kolors VTON first (exact garment copy, no cut inheritance,
    // ~14s, doesn't spend Gemini quota). Any Kolors failure falls back to the
    // classic Gemini path; QA below runs on either result, and QA/identity
    // retries always re-render via Gemini (renderFramed).
    const kolorsEligible = refs.length >= 1 && targetZones.length === 1 &&
      (targetZones[0] === "top" || targetZones[0] === "bottom");
    let v1: Inline;
    if (kolorsEligible) {
      try {
        v1 = await kolorsTryOn(person, refs[0]);
        console.log("[fix-render]", render_id, "engine=kolors");
      } catch (e) {
        console.error("[fix-render] kolors fallback:", (e as Error).message);
        v1 = await renderFramed(prompt);
      }
    } else {
      v1 = await renderFramed(prompt);
    }
    const p0 = await upload("", v1);
    await touch({ status: "completed", phase: "verifying", image_path: p0, applied: true });
    let final = v1;
    let applied = true;
    let failReason = "";
    let verified = true; // false = verifier down → fail open for UX, NO cache
    // verifyEditApplied gets the FULL-BODY `person` — its garment / cut-
    // inheritance / framing checks compare against the worn source, so a head
    // crop would blind them. IDENTITY is judged separately below by
    // samePerson(final, idRef) against the real face — the right tool per job.
    // SKIP IT ENTIRELY on our engine — do not merely ignore the verdict. The call
    // itself is a Gemini vision round trip, 10-15s against a 2.7s render, so
    // running it and discarding the answer would leave the whole cost in place.
    if (!hybridUsed) {
      try {
        const v = await verifyEditApplied(v1, String(instruction), refs, await person());
        applied = v.applied;
        failReason = v.reason;
      } catch {
        verified = false;
      }
    }
    // THE VERIFIER IS FOR THE HOSTED PATH. It exists because gpt-image could
    // silently return the input unchanged. Our engine resamples the masked region
    // by construction, so "the edit did not take" is not one of its failure modes
    // — and running it anyway cost 10-15s against a 2.7s render AND returned
    // applied=false on correct output, which fired a second paid render. Six jobs
    // and 25s for one tap, with the GPU idle between them.
    if (hybridUsed) applied = true;
    let didRetry = false; // cap the server at ONE re-render total (QA or identity)
    if (!applied && renders < BUDGET) {
      didRetry = true;
      // v1 failed QA → the user NEVER sees it. Refine in place; ship whatever
      // the retry produces (v2 failing too still beats an endless loader).
      await touch({ phase: "refining", applied: false }); // loader stays up
      try {
        const reasonNote = failReason
          ? ` THE PREVIOUS ATTEMPT FAILED SPECIFICALLY BECAUSE: ${failReason}. Fix exactly that.`
          : "";
        const v2 = await renderFramed(prompt + FIX_RETRY_NOTE + reasonNote);
        let applied2 = true;
        let verified2 = true;
        try {
          applied2 = (await verifyEditApplied(v2, String(instruction), refs, person)).applied;
        } catch {
          verified2 = false;
        }
        final = v2;
        applied = applied2;
        verified = verified2;
      } catch (e) {
        console.error("[fix-render] refine", (e as Error).message);
        verified = false; // fell back to the unverified v1 — never cache it
      }
    }
    // ── IDENTITY GATE (fail-OPEN): catch an obvious wrong-person drift and
    // regenerate ONCE against the real face crop. If it still looks off we
    // SHIP anyway rather than hard-failing — a rare slip beats a constant
    // "Couldn't render" from a face-crop comparison that's only ~reliable.
    // …and NOT on our engine, for the same structural reason. The face sits
    // ABOVE the mask, so those pixels are composited back from the original
    // untouched: identity cannot drift, and there is nothing for a face-crop
    // comparison to catch. Keeping it here was another Gemini vision round trip
    // per swap — the last big chunk of a tap that measured 18s while the render
    // itself took 2.9s and the queue 0.3s.
    if (!hybridUsed && idRef && !didRetry && renders < BUDGET) {
      try {
        if (!(await samePerson(final, idRef))) {
          await touch({ phase: "refining", applied: false });
          const retry = await renderFramed(prompt + IDENTITY_RETRY_NOTE);
          // Only adopt the retry if it's at least as good on identity.
          if (await samePerson(retry, idRef)) {
            final = retry;
            try {
              applied = (await verifyEditApplied(final, String(instruction), refs, await person())).applied;
            } catch { /* keep prior verified flag */ }
          } else {
            console.error("[fix-render]", row.id, "identity still off after retry — shipping");
          }
        }
      } catch (e) {
        console.error("[fix-render] identity gate:", (e as Error).message);
      }
    }
    // Swap the painted v1 ONLY if the refine produced a different image — a
    // NEW path so the client re-fetches. If final === v1 (v1 already passed),
    // v1 stays on screen; just clear the badge with the real `applied`.
    let finalPath = p0;
    if (final !== v1) {
      finalPath = await upload("-v2", final);
      await touch({ image_path: finalPath, applied });
    } else {
      await touch({ applied });
    }
    if (applied && verified) {
      await cachePut(db, row.cache_key as string, row.user_id as string, "fix", final);
    }
    // Training-pair capture (fire-and-forget): person + garment refs + result
    // + instruction → proprietary VTON dataset for future distillation.
    // No bytes fetched (pure hybrid path) → nothing to log; a training pair
    // without its input image is not a training pair.
    if (applied && _person) {
      const logP = logTrainingPair(db, {
        userId: row.user_id as string, renderId: String(render_id), source: "fix",
        person: _person!, refs, resultBucket: OUT_BUCKET, resultPath: finalPath, instruction: String(instruction),
        meta: { targetZones, verified },
      });
      // deno-lint-ignore no-explicit-any
      const rt = (globalThis as any).EdgeRuntime;
      if (rt?.waitUntil) rt.waitUntil(logP);
    }

    // ── STRICT-ANCHOR tucked twin: an EDIT OF THE FINAL PRIMARY RENDER ───
    // Generating the twin from scratch let the garment drift (a different
    // shirt tucked vs untucked). Editing the finished render pins the item
    // BY CONSTRUCTION: the only degree of freedom is the hem.
    // Twin only when the primary path stayed within budget — a struggling swap
    // must not spend two MORE renders on a toggle asset (the client renders the
    // tucked state on demand when the user actually flips it).
    // NOT on our engine. This twin is a HOSTED render (generateLookImage) run
    // INLINE on every swap — 20-45s and a paid call, to pre-bake a toggle asset.
    // That made sense when rendering on demand also cost 45s. It no longer does:
    // a dressing pass is ~3s, so the client renders the tucked state when the
    // user actually flips FIT, exactly as the comment above already claims.
    // Measured: swaps completing in ~11s with one 41.2s outlier — this was it.
    if (!hybridUsed && tucked?.instruction && renders < BUDGET) {
      try {
        renders++;
        const TUCK_EDIT = [
          "MANDATORY EDIT — change ONLY how the top is worn in this photo: tuck the top's hem fully INSIDE the bottoms' waistband, so the waistband is clearly VISIBLE all the way across and NO fabric of the top hangs below it.",
          "STRICT ANCHOR (zero tolerance): every garment stays EXACTLY as in this photo — the SAME top (same collar, same neckline, same sleeves, same buttons, same fabric, same color), the SAME bottoms (same color, pattern, length), the SAME shoes and accessories. Do NOT swap, restyle, recolor or redesign ANY piece; the ONLY difference between input and output is the hem position at the waist. The waistband area of the bottoms may be redrawn to show the tuck.",
          "IDENTITY LOCK (absolute): the SAME person — same face, same head fully in frame, same body proportions, same skin tone, same pose.",
          "Photorealistic, full-body head-to-toe, centered, on the same plain seamless PURE-WHITE studio background. No logos, no text, no watermarks.",
        ].join(" ");
        const TUCK_CHECK =
          "the exact same outfit as in the reference photo (same top, same bottoms, same shoes), with the ONLY change being the top tucked fully into the waistband";
        let vt = await generateLookImage(final, TUCK_EDIT);
        let okT = true;
        try {
          okT = (await verifyEditApplied(vt, TUCK_CHECK, [], final)).applied;
        } catch { /* fail open */ }
        if (!okT && renders < BUDGET + 1) {
          renders++;
          vt = await generateLookImage(final,
            TUCK_EDIT + " NOTE: a previous attempt FAILED — either the top stayed untucked or a garment changed. Tuck it decisively and change NOTHING else.");
          try {
            okT = (await verifyEditApplied(vt, TUCK_CHECK, [], final)).applied;
          } catch { okT = true; }
        }
        const pt = await upload("-t", vt);
        await touch({ image_path_tucked: pt, applied_tucked: okT });
        if (okT && cache_key_tucked) {
          await cachePut(db, String(cache_key_tucked), row.user_id as string, "fix", vt);
        }
      } catch (e) {
        console.error("[fix-render] tucked twin:", (e as Error).message);
      }
    }

    await touch({ phase: "done" });
    return json({ ok: true });
  } catch (err) {
    console.error("[fix-render]", render_id, (err as Error).message);
    // AN OFFLINE ENGINE GETS ITS OWN MESSAGE. The pod is started per session, so
    // this is a normal state, and the client should say so rather than surface the
    // last provider that happened to be tried: twice this evening the screen read
    // "gemini-image 400: API key not valid" — a provider we deliberately turned
    // off, for a request that never reached one. That reads as a broken app instead
    // of an engine that needs a minute, and at a demo it would be the worst
    // possible sentence on screen.
    const offline = err instanceof EngineOffline;
    await touch({
      status: "failed",
      error: offline
        ? "engine_offline: the render engine is not running"
        : (err as Error).message.slice(0, 300),
    });
    return json({ ok: false, error: offline ? "engine_offline" : "render_failed" },
                offline ? 503 : 200);
  }
});
