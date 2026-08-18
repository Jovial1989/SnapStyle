// CANONICAL AVATAR (the Zara lesson): build the "dressable mannequin" ONCE per
// body photo — the person re-dressed in neutral grey basics on a clean studio
// white — and let every Generate-my-look render start from it. Wins:
//   • identity is anchored once (the avatar already passed samePerson QA),
//     instead of being re-negotiated on every render;
//   • the user's real outfit can't bleed into generated looks (the source
//     garments are physically absent from the canvas);
//   • the input bytes are stable across sessions → deterministic behavior.
// Built fire-and-forget after the photo lands (never blocks onboarding);
// consumers TRY `${photoPath}.avatar.png` and fall back to `.clean.png`/raw,
// so a missing/failed avatar costs nothing.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { fetchInline } from "./gemini.ts";
import { generateLookImage } from "./imagegen.ts";
import { samePerson, validateLookImages } from "./vision.ts";

const BUCKET = "body-photos";
const b64ToBytes = (b64: string) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));

const AVATAR_PROMPT = [
  "MANDATORY EDIT: re-dress the person in this photo as a neutral fitting mannequin:",
  "a plain fitted heather-grey SHORT-SLEEVE crew-neck t-shirt (short set-in sleeves clearly covering the shoulders, hem worn loose),",
  "plain mid-grey straight-leg FULL-LENGTH trousers reaching down to the ankle,",
  "and plain white low-top sneakers. No prints, no logos, no pockets, no accessories added or removed.",
  "IDENTITY LOCK (absolute): the SAME person — same face, same hair, same skin tone, same body proportions. The POSE may be corrected to the standing pose described below; nothing else about the person may change. Rendering a different or generic model is a FAILED generation.",
  // A-POSE, AND THE ENGINE CAN NOW PROVE IT. Measured on the base in use
  // (check_a_pose on the pod): ankle height difference 0.056 of the figure's
  // span against a 0.02 threshold — the person is caught MID-STRIDE, and the
  // footwear compromises all follow from it: the raised heel's old shoe collar
  // peeked over every rendered shoe until the zone was split per foot, and its
  // sneaker still shows between the legs under long trousers. Level feet cost
  // nothing to ask for here and remove the cause upstream of the engine.
  "POSE: standing still and square to the camera, weight even on BOTH feet, both feet flat on the ground and level with each other, feet about shoulder-width apart, arms hanging relaxed and slightly away from the body. Not walking, not mid-step, no raised heel, no crossed legs.",
  "FRAMING: photorealistic, full body head-to-toe, feet and shoes fully visible with clear margin below, centered.",
  "BACKGROUND: the ENTIRE frame is ONE flat, uniform, seamless PURE-WHITE (#FFFFFF) — no leftover scene, no halos, no grey patches.",
  "No text, no watermarks.",
].join(" ");

/** Build (or rebuild) the canonical avatar for [photoPath]. Never throws —
 * failures are logged and the avatar simply doesn't exist (consumers fall
 * back). QA-gated: identity vs the source photo + the standard look validator;
 * ONE retry, then give up (2 renders worst case, once per photo change). */
export async function buildCanonicalAvatar(db: SupabaseClient, photoPath: string): Promise<void> {
  try {
    // Source: the clean cutout when it exists (halo-free), else the raw upload.
    let person: Awaited<ReturnType<typeof fetchInline>> | undefined;
    for (const p of [`${photoPath}.clean.png`, photoPath]) {
      try {
        const { data: t } = await db.storage.from(BUCKET)
          .createSignedUrl(p, 300, { transform: { width: 768, quality: 80 } });
        if (t?.signedUrl) { person = await fetchInline(t.signedUrl); break; }
      } catch (_) {/* try next */}
    }
    if (!person) {
      const { data: t } = await db.storage.from(BUCKET).createSignedUrl(photoPath, 300);
      if (!t?.signedUrl) throw new Error("no source photo");
      person = await fetchInline(t.signedUrl);
    }

    let avatar = await generateLookImage(person, AVATAR_PROMPT);
    const ok = async (img: typeof avatar) => {
      try {
        if (!(await samePerson(img, person!))) return false;
      } catch (_) {/* gate down → fall through to validator */}
      try {
        return (await validateLookImages([img]))[0] !== false;
      } catch (_) { return true; /* validator down → accept */ }
    };
    if (!(await ok(avatar))) {
      avatar = await generateLookImage(person, AVATAR_PROMPT +
        " NOTE: a previous attempt FAILED — it changed the person or produced an invalid image. Keep the EXACT person from the photo, decisively.");
      if (!(await ok(avatar))) throw new Error("avatar failed QA twice");
    }

    // PORTRAIT REFRAME (28.07 incident): Gemini inherits the SOURCE photo's
    // orientation — a rotated selfie yielded a LANDSCAPE avatar with a tiny
    // figure, and every downstream render lost the face. Normalize: crop to
    // the figure's bounding box on a white 2:3 portrait canvas, 8% margins.
    const framed = await portraitFrame(b64ToBytes(avatar.data));

    const { error } = await db.storage.from(BUCKET).upload(
      `${photoPath}.avatar.png`, framed,
      { contentType: "image/png", upsert: true },
    );
    if (error) throw new Error(error.message);
    console.log("[avatar] built", photoPath);
  } catch (e) {
    console.error("[avatar]", photoPath, (e as Error).message);
  }
}

async function portraitFrame(png: Uint8Array): Promise<Uint8Array> {
  const { Image } = await import("https://deno.land/x/imagescript@1.3.0/mod.ts");
  const im = await Image.decode(png);
  const w = im.width, h = im.height, bmp = im.bitmap;
  // Occupancy, not "any non-white pixel": studio backgrounds are near-white and
  // JPEG softens edges, so the naive test claimed the subject spanned the whole
  // canvas. The crop then centred the WHOLE frame instead of the figure and the
  // person ended up pushed against one edge (28.07.2026).
  const rowN = new Uint32Array(h), colN = new Uint32Array(w);
  for (let i = 0; i < w * h; i++) {
    const mx = Math.max(bmp[i * 4], bmp[i * 4 + 1], bmp[i * 4 + 2]);
    if (mx < 235) { rowN[(i / w) | 0]++; colN[i % w]++; }
  }
  const RUN = 5;
  const span = (counts: Uint32Array, n: number, minHit: number) => {
    const ok = (k: number) => counts[k] > minHit;
    let lo = -1, hi = -1;
    for (let k = 0; k + RUN <= n; k++) {
      let all = true;
      for (let j = 0; j < RUN; j++) if (!ok(k + j)) { all = false; break; }
      if (all) { lo = k; break; }
    }
    for (let k = n - 1; k - RUN + 1 >= 0; k--) {
      let all = true;
      for (let j = 0; j < RUN; j++) if (!ok(k - j)) { all = false; break; }
      if (all) { hi = k; break; }
    }
    return [lo, hi] as const;
  };
  const [y0, y1] = span(rowN, h, Math.max(3, Math.round(w * 0.02)));
  const [x0, x1] = span(colN, w, Math.max(3, Math.round(h * 0.01)));
  if (y0 < 0 || x0 < 0 || y1 <= y0 || x1 <= x0) return png;   // blank → keep as is
  const m = Math.round((y1 - y0) * 0.08);
  const H = (y1 - y0) + 2 * m, W = Math.round(H * 2 / 3);
  const canvas = new Image(W, H).fill(0xffffffff);
  const sy0 = Math.max(0, y0 - m), sy1 = Math.min(h, y1 + m);
  const sx0 = Math.max(0, x0 - m), sx1 = Math.min(w, x1 + m);
  const part = im.clone().crop(sx0, sy0, sx1 - sx0, sy1 - sy0);
  canvas.composite(part, Math.round((W - part.width) / 2), m - (y0 - sy0));
  const out = canvas.height < 1152
    ? canvas.resize(Math.round(canvas.width * 1152 / canvas.height), 1152)
    : canvas;
  return await out.encode();
}

// MINIMAL BASE: the same mannequin wearing as little as any garment we render —
// a fitted sleeveless tank and SHORT shorts, bare arms and bare shins. This is
// the upstream answer to the whole family of "old clothes under the new ones"
// defects: the shorts veto (grey trousers showed under every pair), dress legs
// (the sampler kept trouser structure at 0.55 and post-hoc skin flooding came
// back as flat salmon), the bare_arms/bare_legs repaint passes (measured dead:
// prompt bug fixed, zones widened, selection fixed — trousers still came back
// trousers). Editing the base AFTER a render failed twice; generating the base
// BEFORE any render is the same trick as the avatar itself, one layer less.
const BARE_PROMPT = [
  "MANDATORY EDIT: re-dress the person in this photo in neutral summer GYM WEAR, like a runner on a hot day:",
  "a plain fitted heather-grey SLEEVELESS tank top,",
  "plain mid-grey knee-length ATHLETIC SHORTS (loose gym shorts, hem at the knee),",
  "and plain white low-top sneakers. No prints, no logos, no accessories added or removed.",
  "IDENTITY LOCK (absolute): the SAME person — same face, same hair, same skin tone, same body proportions. The POSE may be corrected to the standing pose described below; nothing else about the person may change. Rendering a different or generic model is a FAILED generation.",
  // A-POSE, AND THE ENGINE CAN NOW PROVE IT. Measured on the base in use
  // (check_a_pose on the pod): ankle height difference 0.056 of the figure's
  // span against a 0.02 threshold — the person is caught MID-STRIDE, and the
  // footwear compromises all follow from it: the raised heel's old shoe collar
  // peeked over every rendered shoe until the zone was split per foot, and its
  // sneaker still shows between the legs under long trousers. Level feet cost
  // nothing to ask for here and remove the cause upstream of the engine.
  "POSE: standing still and square to the camera, weight even on BOTH feet, both feet flat on the ground and level with each other, feet about shoulder-width apart, arms hanging relaxed and slightly away from the body. Not walking, not mid-step, no raised heel, no crossed legs.",
  "FRAMING: photorealistic, full body head-to-toe, feet and shoes fully visible with clear margin below, centered.",
  "BACKGROUND: the ENTIRE frame is ONE flat, uniform, seamless PURE-WHITE (#FFFFFF) — no leftover scene, no halos, no grey patches.",
  "No text, no watermarks.",
].join(" ");

/** Build (or rebuild) the minimal base for [photoPath] → `${photoPath}.bare.png`.
 * SOURCED FROM THE AVATAR when it exists, not the raw photo: identity and the
 * canonical pose are already locked there, so this edit only has to change the
 * clothes — one variable instead of three. Same QA gates, same two-attempt
 * budget, same portrait reframe. Never throws. */
export async function buildMinimalBase(
  db: SupabaseClient, photoPath: string,
): Promise<{ built: boolean; attempts: number; reason?: string }> {
  try {
    // A stale .bare.png from a build that predates the shin gate is worse than
    // none: fix-render prefers the file's mere existence. Clear it first, so
    // after this call the object exists if and only if a build PASSED.
    await db.storage.from(BUCKET).remove([`${photoPath}.bare.png`]).catch(() => {});
    let person: Awaited<ReturnType<typeof fetchInline>> | undefined;
    for (const p of [`${photoPath}.avatar.png`, `${photoPath}.clean.png`, photoPath]) {
      try {
        const { data: t } = await db.storage.from(BUCKET)
          .createSignedUrl(p, 300, { transform: { width: 768, quality: 80 } });
        if (t?.signedUrl) { person = await fetchInline(t.signedUrl); break; }
      } catch (_) {/* try next */}
    }
    if (!person) throw new Error("no source image");

    // THE GATE THAT ACTUALLY MATTERS HERE IS THE SHINS. The first build returned
    // the source avatar untouched — full-length trousers and all — and passed,
    // because samePerson and the look validator check identity and integrity,
    // which an unedited image satisfies perfectly. An edit model declining the
    // edit is a normal failure mode, and the gate for it has to test the thing
    // the edit was FOR: warm skin, not neutral grey, in the lower-leg band.
    const ok = async (img: { data: string; mimeType: string }) => {
      try {
        if (!(await samePerson(img, person!))) return false;
      } catch (_) {/* gate down → fall through */}
      try {
        if ((await validateLookImages([img]))[0] === false) return false;
      } catch (_) {/* validator down → accept */}
      return await bareShins(b64ToBytes(img.data));
    };
    const prompts = [
      BARE_PROMPT,
      BARE_PROMPT + " NOTE: a previous attempt FAILED because long trousers were kept. The person is dressed for a summer run: SHORTS, not trousers. Replace the trousers with knee-length grey gym shorts.",
      BARE_PROMPT + " CRITICAL: the lower legs (from the knee down to the sneakers) must be uncovered, as is normal in gym shorts. Long trousers = FAILED generation.",
    ];
    let bare: { data: string; mimeType: string } | undefined;
    let attempts = 0;
    for (const pr of prompts) {
      attempts++;
      const cand = await generateLookImage(person, pr);
      if (await ok(cand)) { bare = cand; break; }
      console.log("[bare] attempt", attempts, "rejected (identity or shins)");
    }
    if (!bare) return { built: false, attempts, reason: "all attempts failed the gates" };

    const framed = await portraitFrame(b64ToBytes(bare.data));
    const { error } = await db.storage.from(BUCKET).upload(
      `${photoPath}.bare.png`, framed,
      { contentType: "image/png", upsert: true },
    );
    if (error) throw new Error(error.message);
    console.log("[bare] built", photoPath);
    return { built: true, attempts };
  } catch (e) {
    console.error("[bare]", photoPath, (e as Error).message);
    return { built: false, attempts: 0, reason: (e as Error).message };
  }
}

/** Are the lower legs bare skin? Pixel arithmetic, no model call: in the band
 * between 74% and 90% of the figure's height, count occupied (non-white)
 * pixels that read WARM — red clearly above blue — against ones that read
 * NEUTRAL grey. Trousers on this mannequin are neutral by construction; skin
 * of any tone is warmer than fabric dyed grey. The threshold is deliberately
 * low (35%) because sneakers and shadow legitimately occupy part of the band. */
async function bareShins(png: Uint8Array): Promise<boolean> {
  try {
    const { Image } = await import("https://deno.land/x/imagescript@1.3.0/mod.ts");
    const im = await Image.decode(png);
    const w = im.width, h = im.height, bmp = im.bitmap;
    // The figure's vertical extent (same occupancy test as portraitFrame).
    const rowN = new Uint32Array(h);
    for (let i = 0; i < w * h; i++) {
      if (Math.max(bmp[i * 4], bmp[i * 4 + 1], bmp[i * 4 + 2]) < 235) rowN[(i / w) | 0]++;
    }
    let top = -1, bot = -1;
    for (let y = 0; y < h; y++) if (rowN[y] > w * 0.02) { top = y; break; }
    for (let y = h - 1; y >= 0; y--) if (rowN[y] > w * 0.02) { bot = y; break; }
    if (top < 0 || bot <= top) return false;
    const y0 = top + Math.round((bot - top) * 0.74);
    const y1 = top + Math.round((bot - top) * 0.90);
    let warm = 0, occupied = 0;
    for (let y = y0; y <= y1; y++) {
      for (let x = 0; x < w; x++) {
        const i = (y * w + x) * 4;
        const r = bmp[i], g = bmp[i + 1], b = bmp[i + 2];
        if (Math.max(r, g, b) >= 235) continue;      // background
        occupied++;
        if (r - b > 14 && r > 80) warm++;
      }
    }
    if (occupied < 200) return false;
    const frac = warm / occupied;
    console.log(`[bare] shin band warm fraction: ${(frac * 100).toFixed(0)}%`);
    return frac > 0.35;
  } catch (e) {
    console.error("[bare] shin gate error:", (e as Error).message);
    return false;   // an ungateable image is a failed image; the edit is cheap
  }
}
