/**
 * POST /api/generate-3d — 2D flat-lay → textured .glb → R2 → Supabase.
 *
 * Body: { itemId: string, imageUrl: string, category: string }
 * 200:  { ok: true, itemId, model3dUrl, bytes, ms }
 *
 * Everything stays in memory: fetch → Buffer → glTF Document → Uint8Array →
 * S3 PutObject. No temp files, so concurrent requests cannot collide on disk
 * or leave orphans when the process is recycled.
 *
 * Backpressure is the point of the semaphore below. Each in-flight job holds a
 * decoded image plus a glb in RAM; without a cap, a burst of uploads OOM-kills
 * the container and every request fails instead of a few queueing politely.
 */

import { Buffer } from 'node:buffer';
import { createHash } from 'node:crypto';

import { PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import express, { type NextFunction, type Request, type Response } from 'express';

import { buildGarment, loadTemplateBuffer } from './batch.js'; // one implementation, two entry points

/* ────────────────────────────── config ────────────────────────────── */

interface Config {
  port: number;
  r2: { accountId: string; accessKeyId: string; secretAccessKey: string; bucket: string; publicBase: string };
  supabase: { url: string; serviceKey: string; table: string; idColumn: string; urlColumn: string };
  maxConcurrent: number;
  maxImageBytes: number;
  fetchTimeoutMs: number;
  templateDir: string;
  maxTextureSize: number;
}

function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`missing env ${name}`);
  return v;
}

const config: Config = {
  port: Number(process.env.PORT ?? 8080),
  r2: {
    accountId: required('R2_ACCOUNT_ID'),
    accessKeyId: required('R2_ACCESS_KEY_ID'),
    secretAccessKey: required('R2_SECRET_ACCESS_KEY'),
    bucket: required('R2_BUCKET'),
    publicBase: required('R2_PUBLIC_BASE'), // e.g. https://cdn.looktok.co
  },
  supabase: {
    url: required('SUPABASE_URL'),
    serviceKey: required('SUPABASE_SERVICE_ROLE_KEY'),
    table: process.env.ITEMS_TABLE ?? 'affiliate_items',
    idColumn: process.env.ITEMS_ID_COLUMN ?? 'id',
    urlColumn: process.env.ITEMS_MODEL_COLUMN ?? 'model3d_url',
  },
  maxConcurrent: Number(process.env.MAX_CONCURRENT ?? 3),
  maxImageBytes: Number(process.env.MAX_IMAGE_BYTES ?? 12 * 1024 * 1024),
  fetchTimeoutMs: Number(process.env.FETCH_TIMEOUT_MS ?? 20_000),
  templateDir: process.env.TEMPLATE_DIR ?? './templates',
  maxTextureSize: Number(process.env.MAX_TEXTURE_SIZE ?? 1024),
};

/* ─────────────────────────── shared clients ─────────────────────────── */

// R2 speaks S3. `auto` region + the account-scoped endpoint is the whole diff.
const s3 = new S3Client({
  region: 'auto',
  endpoint: `https://${config.r2.accountId}.r2.cloudflarestorage.com`,
  credentials: {
    accessKeyId: config.r2.accessKeyId,
    secretAccessKey: config.r2.secretAccessKey,
  },
});

const supabase: SupabaseClient = createClient(config.supabase.url, config.supabase.serviceKey, {
  auth: { persistSession: false },
});

/* ────────────────────────────── helpers ────────────────────────────── */

class HttpError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

/** Counting semaphore — caps RAM by capping parallel jobs. */
function createSemaphore(limit: number) {
  let active = 0;
  const waiting: Array<() => void> = [];
  return {
    get pending() {
      return waiting.length;
    },
    async acquire(): Promise<() => void> {
      if (active >= limit) await new Promise<void>((r) => waiting.push(r));
      active += 1;
      let released = false;
      return () => {
        if (released) return;
        released = true;
        active -= 1;
        waiting.shift()?.();
      };
    },
  };
}
const gate = createSemaphore(config.maxConcurrent);

const CATEGORY = /^[a-z][a-z0-9_-]{1,31}$/;
const ITEM_ID = /^[A-Za-z0-9_-]{1,64}$/;

interface Payload {
  itemId: string;
  imageUrl: string;
  category: string;
}

function parsePayload(body: unknown): Payload {
  if (typeof body !== 'object' || body === null) throw new HttpError(400, 'JSON body required');
  const { itemId, imageUrl, category } = body as Record<string, unknown>;
  if (typeof itemId !== 'string' || !ITEM_ID.test(itemId)) throw new HttpError(400, 'invalid itemId');
  if (typeof category !== 'string' || !CATEGORY.test(category)) throw new HttpError(400, 'invalid category');
  if (typeof imageUrl !== 'string') throw new HttpError(400, 'invalid imageUrl');
  let url: URL;
  try {
    url = new URL(imageUrl);
  } catch {
    throw new HttpError(400, 'imageUrl is not a URL');
  }
  // SSRF guard: this service holds R2 and service-role credentials, so it must
  // never be usable as a fetcher for arbitrary internal addresses.
  if (url.protocol !== 'https:') throw new HttpError(400, 'imageUrl must be https');
  if (/^(localhost|127\.|10\.|192\.168\.|169\.254\.|\[::1\])/i.test(url.hostname)) {
    throw new HttpError(400, 'imageUrl host not allowed');
  }
  return { itemId, imageUrl, category: category.toLowerCase() };
}

/** Download with a hard timeout and a size ceiling, streamed so an oversized
 *  body is aborted mid-flight rather than after it has filled memory. */
async function fetchImage(url: string): Promise<Buffer> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), config.fetchTimeoutMs);
  try {
    const res = await fetch(url, { signal: ctrl.signal, redirect: 'follow' });
    if (!res.ok) throw new HttpError(502, `image fetch ${res.status}`);
    const declared = Number(res.headers.get('content-length') ?? 0);
    if (declared > config.maxImageBytes) throw new HttpError(413, 'image too large');
    if (!res.body) throw new HttpError(502, 'empty image response');

    const chunks: Uint8Array[] = [];
    let total = 0;
    for await (const chunk of res.body as unknown as AsyncIterable<Uint8Array>) {
      total += chunk.byteLength;
      if (total > config.maxImageBytes) {
        ctrl.abort();
        throw new HttpError(413, 'image exceeds size limit');
      }
      chunks.push(chunk);
    }
    return Buffer.concat(chunks, total);
  } catch (err) {
    if (err instanceof HttpError) throw err;
    if ((err as Error).name === 'AbortError') throw new HttpError(504, 'image fetch timed out');
    throw new HttpError(502, `image fetch failed: ${(err as Error).message}`);
  } finally {
    clearTimeout(timer);
  }
}

async function uploadGlb(key: string, glb: Uint8Array): Promise<string> {
  await s3.send(
    new PutObjectCommand({
      Bucket: config.r2.bucket,
      Key: key,
      Body: Buffer.from(glb),
      ContentType: 'model/gltf-binary',
      // Content-addressed keys below make this safe and free on the CDN.
      CacheControl: 'public, max-age=31536000, immutable',
    }),
  );
  return `${config.r2.publicBase.replace(/\/$/, '')}/${key}`;
}

/* ──────────────────────────── the endpoint ──────────────────────────── */

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '64kb' })); // the payload is 3 short strings

app.get('/health', (_req, res) => {
  res.json({ ok: true, inFlightQueue: gate.pending });
});

app.post('/api/generate-3d', async (req: Request, res: Response, next: NextFunction) => {
  const started = Date.now();
  let release: (() => void) | null = null;
  try {
    const { itemId, imageUrl, category } = parsePayload(req.body);
    release = await gate.acquire();

    const [image, template] = await Promise.all([
      fetchImage(imageUrl),
      // Same loader the batch script uses; caches template buffers in-process,
      // so the second request for a category never touches the disk again.
      loadTemplateBuffer(config.templateDir, category),
    ]);

    const glb = await buildGarment(image, template, { maxTextureSize: config.maxTextureSize });

    // Content-addressed key: re-running the job for an unchanged image
    // overwrites the same object instead of littering the bucket, and lets the
    // CDN cache it forever.
    // node:crypto over WebCrypto here: it takes the Uint8Array directly, with
    // no ArrayBufferLike/SharedArrayBuffer typing dance, and is faster on big
    // buffers because it streams rather than copying.
    const hash = createHash('sha256').update(glb).digest('hex').slice(0, 16);
    const key = `garments/${category}/${itemId}-${hash}.glb`;
    const model3dUrl = await uploadGlb(key, glb);

    const { error } = await supabase
      .from(config.supabase.table)
      .update({ [config.supabase.urlColumn]: model3dUrl })
      .eq(config.supabase.idColumn, itemId);
    if (error) {
      // The asset exists and is addressable; surface the DB failure without
      // pretending the whole job died, so the caller can retry just the write.
      throw new HttpError(500, `asset uploaded to ${model3dUrl} but DB update failed: ${error.message}`);
    }

    res.json({ ok: true, itemId, model3dUrl, bytes: glb.byteLength, ms: Date.now() - started });
  } catch (err) {
    next(err);
  } finally {
    release?.();
  }
});

app.use((err: unknown, _req: Request, res: Response, _next: NextFunction) => {
  const status = err instanceof HttpError ? err.status : 500;
  const message = err instanceof Error ? err.message : 'unknown error';
  if (status >= 500) console.error('[generate-3d]', message);
  res.status(status).json({ ok: false, error: message });
});

app.listen(config.port, () => {
  console.log(`[generate-3d] listening on :${config.port} (max ${config.maxConcurrent} concurrent)`);
});

export default app;
