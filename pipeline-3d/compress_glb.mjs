// Shrink batch GLBs: raw embedded PNGs → 1024px WebP. Same recipe the
// template pipeline ships (batch.ts), applied to already-built garments.
import { readdir, readFile, writeFile } from 'node:fs/promises';
import { join, basename } from 'node:path';
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { dedup, prune, textureCompress, TextureResizeFilter } from '@gltf-transform/functions';
import sharp from 'sharp';

const dir = process.argv[2];
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);
let before = 0, after = 0, n = 0;
for (const f of (await readdir(dir)).filter((f) => f.endsWith('.glb'))) {
  const path = join(dir, f);
  const src = await readFile(path);
  const doc = await io.readBinary(new Uint8Array(src));
  await doc.transform(
    textureCompress({ encoder: sharp, targetFormat: 'webp', resize: [1024, 1024],
                      resizeFilter: TextureResizeFilter.LANCZOS3, quality: 85 }),
    dedup(), prune(),
  );
  const out = await io.writeBinary(doc);
  if (out.byteLength < src.byteLength) await writeFile(path, out);
  before += src.byteLength; after += Math.min(out.byteLength, src.byteLength); n++;
}
console.log(`[compress] ${n} files: ${(before/1e6).toFixed(1)}MB → ${(after/1e6).toFixed(1)}MB`);
