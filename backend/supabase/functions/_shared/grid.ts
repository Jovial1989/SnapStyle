// GRID RENDERER — dress one avatar in up to FOUR outfits with ONE image call.
//
// The whole trick, established over nine paid spikes on 28.07.2026:
//   • the canvas is a 2x2 collage of the SAME canonical avatar, so the model
//     only has to change clothes, never invent a person;
//   • the mask is GENEROUS — the whole body below the chin, across the figure's
//     width plus a margin. Tracing only the avatar's own grey clothes cannot
//     express a different silhouette: a long sleeve over a bare arm gets
//     clipped and the seam ghosts (both reported from the device);
//   • identity is not trusted to the model at all: the head and the background
//     are composited back from the original collage over the SAME region the
//     model was given, so there is no boundary left to ghost against;
//   • `input_fidelity: high` is required — without it the body drifts and the
//     composite seams tear.
// Four cells is the ceiling: six collapses (drawn numbers, duplicate outfits).
//
// Used by grid-vton (catalogue ids, Review flow) and render-grid (planned
// looks, Generate my look) — one implementation of the hard part.
import type { Inline } from "./gemini.ts";
import { openaiLookImage } from "./imagegen.ts";

export const GRID_MAX = 4;
export const GUTTER = 4;
// The collage is built at EXACTLY gpt-image-1's output size (1024x1536), so the
// edit comes back pixel-aligned: no resize, the mask matches 1:1, and each cell
// is 510x766. Building it smaller and scaling the answer down was throwing away
// two thirds of the resolution — grid cards came out 341x512 next to 1024x1536
// singles (measured 28.07.2026).
const OUT_W = 1024, OUT_H = 1536;
const CELL_W = (OUT_W - GUTTER) / 2;   // 510
const CELL_H = (OUT_H - GUTTER) / 2;   // 766

// deno-lint-ignore no-explicit-any
type Img = any;

async function imagescript() {
  return (await import("https://deno.land/x/imagescript@1.3.0/mod.ts")).Image;
}

export type GridResult = { cells: Uint8Array[]; width: number; height: number };

/** Render `descriptions.length` (≤4) outfits onto one avatar in a single call.
 * Returns one JPEG per description, in the same order. */
export async function gridRender(args: {
  avatar: Uint8Array;
  /** One per cell: what to dress the person in, in plain words. */
  descriptions: string[];
  /** Reference photos grouped per cell — garment pixels to copy. */
  refsPerCell?: Inline[][];
  /** Extra sentence appended to the prompt (framing, gender, occasion). */
  note?: string;
}): Promise<GridResult> {
  const n = Math.min(args.descriptions.length, GRID_MAX);
  if (n < 1) throw new Error("gridRender needs at least one description");
  const Image = await imagescript();

  const avatar = await Image.decode(args.avatar);
  // Fit the avatar into the cell on white, preserving aspect — the avatar is
  // already portrait-framed, so this is usually a straight resize.
  const cw = CELL_W, ch = CELL_H;
  const s = Math.min(cw / avatar.width, ch / avatar.height);
  const fitted = avatar.resize(Math.max(1, Math.round(avatar.width * s)),
                               Math.max(1, Math.round(avatar.height * s)));
  const cell = new Image(cw, ch).fill(0xffffffff);
  cell.composite(fitted, Math.round((cw - fitted.width) / 2), Math.round((ch - fitted.height) / 2));
  const W = OUT_W, H = OUT_H;
  const anchors: [number, number][] = [
    [0, 0], [cw + GUTTER, 0], [0, ch + GUTTER], [cw + GUTTER, ch + GUTTER],
  ];
  const collage = new Image(W, H).fill(0xffffffff);
  for (const [ax, ay] of anchors) collage.composite(cell, ax, ay);

  // tight mask, tiled — the alpha channel is what OpenAI reads (0 = editable)
  const cellMask = segmentClothes(cell.bitmap, cw, ch);
  const mask = new Uint8Array(W * H);
  for (const [ax, ay] of anchors) {
    for (let y = 0; y < ch; y++) {
      mask.set(cellMask.subarray(y * cw, (y + 1) * cw), (ay + y) * W + ax);
    }
  }
  const maskImg = collage.clone();
  for (let i = 0; i < W * H; i++) maskImg.bitmap[i * 4 + 3] = mask[i] ? 0 : 255;

  const quad = ["top-left", "top-right", "bottom-left", "bottom-right"];
  const refs: Inline[] = [];
  const mapping = args.descriptions.slice(0, n).map((d, i) => {
    const cellRefs = args.refsPerCell?.[i] ?? [];
    const from = refs.length + 2;                 // image[0] is the collage
    refs.push(...cellRefs);
    return `- ${quad[i]} panel: ${d}` +
      (cellRefs.length ? ` (reference images ${from}-${from + cellRefs.length - 1}).` : ".");
  }).join("\n");

  const prompt =
    `The first image is a 2x2 collage of the same person. Edit ONLY the ` +
    `transparent (masked) clothing areas: dress them in a different outfit per panel:\n${mapping}\n` +
    (n < GRID_MAX ? `Leave the remaining panel(s) exactly as they are.\n` : "") +
    (refs.length
      ? `Copy each garment exactly from its reference image — colour, print, cut. `
      : `Render each outfit photorealistically, as real garments on this body. `) +
    `Collars sit at the natural neckline, chin and neck fully visible. The face, ` +
    `skin tone, pose, hair and background must remain pixel-identical to the first ` +
    `image. Keep the 2x2 layout with white gutters. Do not swap outfits between panels.` +
    (args.note ? ` ${args.note}` : "");

  const out = await openaiLookImage(
    { data: b64(await collage.encode()), mimeType: "image/png" },
    prompt,
    refs,
    { size: "1024x1536", fidelity: "high", mask: { data: b64(await maskImg.encode()), mimeType: "image/png" } },
  );

  // Composite the model's clothing over OUR pixels, not the reverse. The answer
  // is already W x H; resize only if OpenAI ever returns something else.
  let edited = await Image.decode(bytes(out.data));
  if (edited.width !== W || edited.height !== H) edited = edited.resize(W, H);
  // Composite over the SAME generous region the model was given. Blending only
  // the old garment's silhouette was the source of both device-reported
  // artefacts: a long sleeve drawn where the avatar has a bare arm got clipped,
  // and the dilated fringe mixed model-arm with avatar-arm into a ghost. With
  // the whole body below the chin coming from one source there is nothing to
  // ghost against; the head and the background stay original.
  const alpha = featherAlpha(mask, W, H);
  const comp = collage.clone();
  for (let i = 0; i < W * H; i++) {
    const a = alpha[i];
    if (a === 0) continue;
    const o = i * 4, t = a / 255, u = 1 - t;
    comp.bitmap[o] = comp.bitmap[o] * u + edited.bitmap[o] * t;
    comp.bitmap[o + 1] = comp.bitmap[o + 1] * u + edited.bitmap[o + 1] * t;
    comp.bitmap[o + 2] = comp.bitmap[o + 2] * u + edited.bitmap[o + 2] * t;
  }

  const cells: Uint8Array[] = [];
  for (let i = 0; i < n; i++) {
    const [ax, ay] = anchors[i];
    cells.push(await comp.clone().crop(ax, ay, cw, ch).encodeJPEG(90));
  }
  return { cells, width: cw, height: ch };
}

const b64 = (u: Uint8Array) => {
  let s = "";
  for (let o = 0; o < u.length; o += 0x8000) s += String.fromCharCode(...u.subarray(o, o + 0x8000));
  return btoa(s);
};
const bytes = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));

// NECK_FRAC: where the editable zone starts, as a fraction of figure height.
// 0.21 left the AVATAR's own grey crew-neck collar above the mask, so every new
// garment met a grey band under the chin (visible seam, 28.07.2026). Starting
// just under the jaw hands the whole neckline to the model; the head stays
// locked by the composite, so identity is unaffected.
const NECK_FRAC = Number(Deno.env.get("GRID_NECK_FRAC") ?? 0.15);

export function segmentClothes(bmp: Uint8Array | Uint8ClampedArray, w: number, h: number): Uint8Array {
  const m = new Uint8Array(w * h);
  // Figure bbox by ROW OCCUPANCY, not "any non-white pixel". Studio backgrounds
  // are near-white and JPEG softens edges, so the naive test made `top` = 0, the
  // neck line landed INSIDE the head and the mask erased the face (28.07.2026).
  const rowCount = new Uint32Array(h), colCount = new Uint32Array(w);
  for (let i = 0; i < w * h; i++) {
    const mx = Math.max(bmp[i * 4], bmp[i * 4 + 1], bmp[i * 4 + 2]);
    if (mx < 235) { rowCount[(i / w) | 0]++; colCount[i % w]++; }
  }
  const RUN = 5;
  const span = (c: Uint32Array, n: number, minHit: number) => {
    const ok = (k: number) => c[k] > minHit;
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
  const [y0, y1] = span(rowCount, h, Math.max(3, Math.round(w * 0.02)));
  const [x0, x1] = span(colCount, w, Math.max(3, Math.round(h * 0.01)));
  if (y0 < 0 || x0 < 0 || y1 <= y0 || x1 <= x0) return m;   // blank cell

  // GENEROUS agnostic region: everything below the chin, across the figure's
  // width plus a margin. A mask that traced only the avatar's own grey clothes
  // could not express a different silhouette — a long sleeve over a bare arm
  // was clipped, and the seam ghosted (both seen on device 28.07). Same lesson
  // the CatVTON bench gave: these models expect a loose agnostic mask.
  const fh = y1 - y0;
  const neck = Math.round(y0 + fh * NECK_FRAC);
  const pad = Math.max(4, Math.round((x1 - x0) * 0.12));
  const mx0 = Math.max(0, x0 - pad), mx1 = Math.min(w - 1, x1 + pad);
  const bottom = Math.min(h - 1, y1 + Math.round(fh * 0.02));   // room under the shoe
  for (let y = neck; y <= bottom; y++) {
    m.fill(1, y * w + mx0, y * w + mx1 + 1);
  }
  return m;
}

function morph5(src: Uint8Array, w: number, h: number, max: boolean): Uint8Array {
  const mid = new Uint8Array(w * h), out = new Uint8Array(w * h);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let v = max ? 0 : 1;
      for (let d = -2; d <= 2; d++) {
        const xx = x + d;
        if (xx < 0 || xx >= w) continue;
        const s = src[y * w + xx];
        v = max ? Math.max(v, s) : Math.min(v, s);
      }
      mid[y * w + x] = v;
    }
  }
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let v = max ? 0 : 1;
      for (let d = -2; d <= 2; d++) {
        const yy = y + d;
        if (yy < 0 || yy >= h) continue;
        const s = mid[yy * w + x];
        v = max ? Math.max(v, s) : Math.min(v, s);
      }
      out[y * w + x] = v;
    }
  }
  return out;
}

/** Grow the editable zone down/sideways only — never up toward the chin. */
export function dilateDownSide(m: Uint8Array, w: number, h: number, down: number, side: number): Uint8Array {
  const out = new Uint8Array(m);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      if (out[y * w + x]) continue;
      let hit = 0;
      for (let dy = 0; dy <= down && !hit; dy++) {
        const yy = y - dy;
        if (yy < 0) break;
        for (let dx = -side; dx <= side; dx += 3) {
          const xx = x + dx;
          if (xx >= 0 && xx < w && m[yy * w + xx]) { hit = 1; break; }
        }
      }
      out[y * w + x] = hit;
    }
  }
  return out;
}

/** 0..255 alpha with a ~2px soft edge. */
export function featherAlpha(m: Uint8Array, w: number, h: number): Uint8Array {
  let a = Uint8Array.from(m, (v) => v ? 255 : 0);
  for (let pass = 0; pass < 2; pass++) {
    const b = new Uint8Array(w * h);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        let s = 0, n = 0;
        for (let dy = -1; dy <= 1; dy++) {
          const yy = y + dy;
          if (yy < 0 || yy >= h) continue;
          for (let dx = -1; dx <= 1; dx++) {
            const xx = x + dx;
            if (xx < 0 || xx >= w) continue;
            s += a[yy * w + xx]; n++;
          }
        }
        b[y * w + x] = s / n;
      }
    }
    a = b;
  }
  return a;
}
