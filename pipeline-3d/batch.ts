/**
 * Batch: 2D flat-lays → textured .glb garments (Template Mapping).
 *
 *   npx tsx batch.ts --in ./input_images --out ./output_glbs --templates ./templates
 *
 * Each PNG's filename prefix selects a base template (`tee_001.png` →
 * `templates/tee_base.glb`); the image becomes that template's base-colour map.
 *
 * ── Two things worth knowing before reading the code ───────────────────────
 * 1. COLOUR SPACE. glTF *mandates* that `baseColorTexture` is sRGB — there is
 *    no colour-space flag to write into the file. Three.js applies sRGB to it
 *    automatically on load. Anyone "setting SRGBColorSpace" in the exporter is
 *    setting nothing; the place that matters is the viewer, and only for maps
 *    that are NOT base colour (normal/roughness must stay linear).
 * 2. TRANSPARENCY. A cut-out PNG needs `alphaMode`. MASK is the right default
 *    for garments (hard silhouette, no sorting cost); BLEND is only for real
 *    translucency and forces depth sorting on mobile.
 */

import { existsSync } from 'node:fs';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { basename, extname, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { parseArgs } from 'node:util';

import { Document, Material, NodeIO, TextureInfo } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { dedup, prune, textureCompress, TextureResizeFilter } from '@gltf-transform/functions';
import sharp from 'sharp';

interface Options {
  inputDir: string;
  outputDir: string;
  templateDir: string;
  /** Longest texture edge kept in the shipped asset. */
  maxTextureSize: number;
  /** Files processed at once. Each holds a full image + glb in memory. */
  concurrency: number;
}

interface Result {
  file: string;
  status: 'ok' | 'skipped' | 'failed';
  out?: string;
  bytes?: number;
  reason?: string;
}

const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);

/** Template buffers are cached, template DOCUMENTS are not: a Document is
 *  mutable, so every item must parse its own copy or items would inherit each
 *  other's textures. Parsing a small glb is microseconds; re-reading from disk
 *  for 300 items is not. */
const templateCache = new Map<string, Uint8Array>();

export async function loadTemplateBuffer(dir: string, category: string): Promise<Uint8Array> {
  const cached = templateCache.get(category);
  if (cached) return cached;
  const path = join(dir, `${category}_base.glb`);
  if (!existsSync(path)) {
    throw new Error(`no template for category "${category}" (expected ${path})`);
  }
  const buf = new Uint8Array(await readFile(path));
  templateCache.set(category, buf);
  return buf;
}

/** `tee_001.png` → `tee`. Everything before the first underscore. */
function categoryOf(file: string): string | null {
  const stem = basename(file, extname(file));
  const [category] = stem.split('_');
  return category && category.length > 1 ? category.toLowerCase() : null;
}

/**
 * Which materials get the flat-lay.
 *
 * A garment template is ONE garment, but it often carries several materials:
 * ours ships `tee_cloth` + `sleeve_l_cloth` + `sleeve_r_cloth` because the
 * pieces are modelled separately and joined. Texturing only the "primary" one
 * left the sleeves flat grey — caught by the smoke test, not by the types.
 * So: texture every material by default, and keep the primary-material
 * heuristic for templates that legitimately mix fabric with hardware
 * (a zip, a buckle) via `primaryOnly`.
 */
function targetMaterials(doc: Document, primaryOnly: boolean): Material[] {
  const all = doc.getRoot().listMaterials();
  if (all.length === 0) throw new Error('template has no materials');
  return primaryOnly ? [primaryMaterial(doc)] : all;
}

function primaryMaterial(doc: Document): Material {
  const materials = doc.getRoot().listMaterials();
  const first = materials[0];
  if (!first) throw new Error('template has no materials');
  if (materials.length === 1) return first;
  const usage = new Map<Material, number>();
  for (const mesh of doc.getRoot().listMeshes()) {
    for (const prim of mesh.listPrimitives()) {
      const mat = prim.getMaterial();
      if (mat) usage.set(mat, (usage.get(mat) ?? 0) + (prim.getIndices()?.getCount() ?? 0));
    }
  }
  return [...usage.entries()].sort((a, b) => b[1] - a[1])[0]?.[0] ?? first;
}

/** Reject anything that isn't a decodable image before it reaches the GPU. */
async function validateImage(buf: Buffer): Promise<{ width: number; height: number; hasAlpha: boolean }> {
  const meta = await sharp(buf).metadata();
  if (!meta.width || !meta.height) throw new Error('unreadable image');
  if (meta.width < 64 || meta.height < 64) throw new Error(`image too small (${meta.width}x${meta.height})`);
  return { width: meta.width, height: meta.height, hasAlpha: Boolean(meta.hasAlpha) };
}

export async function buildGarment(
  imageBuffer: Buffer,
  templateBuffer: Uint8Array,
  opts: { maxTextureSize: number; primaryOnly?: boolean },
): Promise<Uint8Array> {
  const { hasAlpha } = await validateImage(imageBuffer);
  const doc = await io.readBinary(templateBuffer);
  const materials = targetMaterials(doc, opts.primaryOnly ?? false);

  // ONE texture object shared by every material — creating one per material
  // would embed the same pixels N times and triple the file size.
  const texture = doc
    .createTexture('albedo')
    .setImage(new Uint8Array(imageBuffer))
    .setMimeType('image/png');

  for (const material of materials) {
    material
      .setBaseColorTexture(texture)
      // White factor: the texture must not be tinted by whatever colour the
      // template shipped with.
      .setBaseColorFactor([1, 1, 1, 1])
      .setDoubleSided(true)        // cloth shells are single-thickness
      .setRoughnessFactor(0.9)
      .setMetallicFactor(0.0)
      // A cut-out flat-lay carries its silhouette in the alpha channel.
      .setAlphaMode(hasAlpha ? 'MASK' : 'OPAQUE')
      .setAlphaCutoff(0.5);

    // A flat-lay is a one-off atlas, never a tile: clamping stops edge pixels
    // from wrapping around and showing a seam of background on the far side.
    const info = material.getBaseColorTextureInfo();
    if (info) {
      const { CLAMP_TO_EDGE } = TextureInfo.WrapMode;
      info
        .setWrapS(CLAMP_TO_EDGE!)
        .setWrapT(CLAMP_TO_EDGE!)
        .setMagFilter(TextureInfo.MagFilter.LINEAR!)
        .setMinFilter(TextureInfo.MinFilter.LINEAR_MIPMAP_LINEAR!);
    }
  }

  await doc.transform(
    // Downscale + re-encode: a 4K flat-lay is 8 MB of VRAM on a phone.
    textureCompress({
      encoder: sharp,
      targetFormat: 'webp',
      resize: [opts.maxTextureSize, opts.maxTextureSize],
      resizeFilter: TextureResizeFilter.LANCZOS3,
      quality: 88,
    }),
    dedup(),   // templates often ship duplicate samplers/accessors
    prune(),   // drop anything the swap orphaned
  );

  return io.writeBinary(doc);
}

async function run(opts: Options): Promise<Result[]> {
  await mkdir(opts.outputDir, { recursive: true });
  const files = (await readdir(opts.inputDir)).filter((f) => /\.(png|webp|jpe?g)$/i.test(f));
  if (files.length === 0) {
    console.warn(`[batch] no images in ${opts.inputDir}`);
    return [];
  }
  console.log(`[batch] ${files.length} images → ${opts.outputDir}`);

  const results: Result[] = [];
  const queue = [...files];

  // Fixed-size worker pool: 300 concurrent sharp pipelines would exhaust
  // memory, and 300 sequential ones waste every core but the first.
  const worker = async () => {
    for (;;) {
      const file = queue.shift();
      if (!file) return;
      const category = categoryOf(file);
      if (!category) {
        results.push({ file, status: 'skipped', reason: 'no category prefix in filename' });
        continue;
      }
      try {
        const [image, template] = await Promise.all([
          readFile(join(opts.inputDir, file)),
          loadTemplateBuffer(opts.templateDir, category),
        ]);
        const glb = await buildGarment(image, template, { maxTextureSize: opts.maxTextureSize });
        const out = join(opts.outputDir, `${basename(file, extname(file))}.glb`);
        await writeFile(out, glb);
        results.push({ file, status: 'ok', out, bytes: glb.byteLength });
        console.log(`  ✓ ${file} → ${basename(out)} (${(glb.byteLength / 1024).toFixed(0)} KB)`);
      } catch (err) {
        const reason = err instanceof Error ? err.message : String(err);
        results.push({ file, status: 'failed', reason });
        console.error(`  ✗ ${file}: ${reason}`);
      }
    }
  };

  await Promise.all(Array.from({ length: opts.concurrency }, worker));

  const ok = results.filter((r) => r.status === 'ok').length;
  const failed = results.filter((r) => r.status === 'failed');
  const skipped = results.filter((r) => r.status === 'skipped');
  console.log(`\n[batch] ${ok} built · ${failed.length} failed · ${skipped.length} skipped`);
  // Never let a partial run look like a clean one in CI.
  if (failed.length) process.exitCode = 1;
  return results;
}

// Run-as-script check via pathToFileURL, NOT string concatenation: any space
// in the path ("My Apps/") is percent-encoded in import.meta.url, so the naive
// comparison silently fails and the script exits 0 having done nothing.
const invokedDirectly =
  process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;

if (invokedDirectly) {
  const { values } = parseArgs({
    options: {
      in: { type: 'string', default: './input_images' },
      out: { type: 'string', default: './output_glbs' },
      templates: { type: 'string', default: './templates' },
      size: { type: 'string', default: '1024' },
      jobs: { type: 'string', default: '4' },
    },
  });
  run({
    inputDir: values.in!,
    outputDir: values.out!,
    templateDir: values.templates!,
    maxTextureSize: Number(values.size),
    concurrency: Math.max(1, Number(values.jobs)),
  }).catch((err) => {
    console.error('[batch] fatal:', err);
    process.exit(1);
  });
}
