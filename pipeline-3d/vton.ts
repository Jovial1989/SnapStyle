/**
 * POST /api/generate-vton — photorealistic try-on: selfie + flat-lay → image.
 *
 * Body: { userId, garmentId, humanImageUrl, garmentImageUrl, category }
 * 200:  { ok: true, url, provider, ms, generationId }
 *
 * The provider is swappable behind one interface. That is not over-design: we
 * benchmarked two of them on our own 20-case set (spike-qwen/grid.html) and the
 * ranking was not what the marketing said, so the code must let us re-route
 * without a rewrite.
 *
 *   PROVIDER=kolors  (default) — fal-ai/kling/v1-5/kolors-virtual-try-on
 *       Won our spike: exact garment copy, no cut inheritance (the #1 failure
 *       of prompt-driven models), identity and framing intact, ~14s, $0.07.
 *       Tops/bottoms/dresses only — it dressed sandals AS shorts.
 *   PROVIDER=idm-vton — fal-ai/idm-vton
 *       The open-source reference. Cheaper per call and takes an explicit
 *       category, which is why it stays wired up.
 *
 * Licensing note worth keeping in view: IDM-VTON's own weights are CC BY-NC.
 * Using it through fal's hosted endpoint puts that arrangement on fal, but
 * self-hosting those weights commercially later would NOT be clean — the
 * migration path off managed APIs is a trained-by-us model, not that checkout.
 */

import { Buffer } from 'node:buffer';
import { createHash } from 'node:crypto';

import { PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import * as fal from '@fal-ai/serverless-client';
import express, { type NextFunction, type Request, type Response } from 'express';
import WebSocket from 'ws';

/* ────────────────────────────── config ────────────────────────────── */

type Category = 'upper_body' | 'lower_body' | 'dresses';
type ProviderName = 'kolors' | 'idm-vton';
/** Where finished renders live. Supabase needs no extra credentials (the
 *  service-role key already in use covers Storage); R2 is cheaper on egress
 *  and is the destination once traffic justifies a second vendor. */
type StorageName = 'supabase' | 'r2';

function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`missing env ${name}`);
  return v;
}

const storageName = (process.env.VTON_STORAGE ?? 'supabase') as StorageName;

const config = {
  port: Number(process.env.VTON_PORT ?? 8081),
  provider: (process.env.VTON_PROVIDER ?? 'kolors') as ProviderName,
  storage: storageName,
  falKey: required('FAL_KEY'),
  // Only demanded when R2 is actually selected — requiring them always meant
  // the service could not boot on the storage we already have.
  r2: storageName === 'r2'
    ? {
        accountId: required('R2_ACCOUNT_ID'),
        accessKeyId: required('R2_ACCESS_KEY_ID'),
        secretAccessKey: required('R2_SECRET_ACCESS_KEY'),
        bucket: required('R2_BUCKET'),
        publicBase: required('R2_PUBLIC_BASE'),
      }
    : null,
  supabaseBucket: process.env.VTON_BUCKET ?? 'vton',
  supabase: {
    url: required('SUPABASE_URL'),
    serviceKey: required('SUPABASE_SERVICE_ROLE_KEY'),
    table: process.env.VTON_TABLE ?? 'look_generations',
  },
  maxConcurrent: Number(process.env.VTON_MAX_CONCURRENT ?? 4),
  generateTimeoutMs: Number(process.env.VTON_TIMEOUT_MS ?? 120_000),
  downloadTimeoutMs: Number(process.env.VTON_DOWNLOAD_TIMEOUT_MS ?? 30_000),
  maxImageBytes: Number(process.env.VTON_MAX_IMAGE_BYTES ?? 20 * 1024 * 1024),
} as const;

fal.config({ credentials: config.falKey });

const s3 = config.r2
  ? new S3Client({
      region: 'auto',
      endpoint: `https://${config.r2.accountId}.r2.cloudflarestorage.com`,
      credentials: {
        accessKeyId: config.r2.accessKeyId,
        secretAccessKey: config.r2.secretAccessKey,
      },
    })
  : null;

const supabase: SupabaseClient = createClient(config.supabase.url, config.supabase.serviceKey, {
  auth: { persistSession: false },
  // supabase-js boots its Realtime client eagerly and Node < 22 has no native
  // WebSocket, so the process dies on import even though this service only
  // ever touches Storage and PostgREST.
  realtime: { transport: WebSocket as unknown as never },
});

/* ────────────────────────────── providers ────────────────────────────── */

interface VtonRequest {
  humanImageUrl: string;
  garmentImageUrl: string;
  category: Category;
}

interface Provider {
  readonly name: ProviderName;
  /** Slots this engine actually handles — anything else must not be sent. */
  readonly supports: ReadonlySet<Category>;
  run(req: VtonRequest): Promise<string>;
}

/**
 * Wall-clock ceiling on a provider call.
 *
 * The fal client exposes a `timeout` option whose own typings say it is "not
 * enforced", and `subscribe()` takes no AbortSignal — so the guard has to live
 * here. Caveat worth knowing: losing the race stops us WAITING, it does not
 * cancel the job, so a timed-out generation is still billed. That is an
 * argument for a generous timeout, not a tight one.
 */
function withTimeout<T>(work: Promise<T>, ms: number, label: string): Promise<T> {
  let timer: NodeJS.Timeout;
  const bell = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new HttpError(504, `${label} timed out after ${ms}ms`)), ms);
  });
  return Promise.race([work, bell]).finally(() => clearTimeout(timer)) as Promise<T>;
}

/** Narrow the untyped fal payload down to the one field we need. */
function firstImageUrl(result: unknown): string {
  const r = result as { image?: { url?: string }; images?: Array<{ url?: string }> };
  const url = r?.image?.url ?? r?.images?.[0]?.url;
  if (!url) throw new HttpError(502, 'provider returned no image');
  return url;
}

const kolors: Provider = {
  name: 'kolors',
  // Verified in our spike: given footwear it renders it as shorts, so shoes
  // and accessories must never reach this endpoint.
  supports: new Set<Category>(['upper_body', 'lower_body', 'dresses']),
  async run({ humanImageUrl, garmentImageUrl }) {
    // No prompt and no category input — the model takes the two images only.
    const result = await fal.subscribe('fal-ai/kling/v1-5/kolors-virtual-try-on', {
      input: { human_image_url: humanImageUrl, garment_image_url: garmentImageUrl },
      logs: false,
    });
    return firstImageUrl(result);
  },
};

const idmVton: Provider = {
  name: 'idm-vton',
  supports: new Set<Category>(['upper_body', 'lower_body', 'dresses']),
  async run({ humanImageUrl, garmentImageUrl, category }) {
    const result = await fal.subscribe('fal-ai/idm-vton', {
      input: {
        human_image_url: humanImageUrl,
        garment_image_url: garmentImageUrl,
        category,
        // Quality knobs: 30+ steps is where IDM-VTON stops smearing print
        // detail; the auto crop/mask keeps the model from repainting the face.
        num_inference_steps: 34,
        guidance_scale: 2.2,
        auto_mask: true,
        auto_crop: true,
      },
      logs: false,
    });
    return firstImageUrl(result);
  },
};

const PROVIDERS: Record<ProviderName, Provider> = { kolors, 'idm-vton': idmVton };

/* ────────────────────────────── plumbing ────────────────────────────── */

class HttpError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

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

const ID = /^[A-Za-z0-9_-]{1,64}$/;
const CATEGORIES = new Set<Category>(['upper_body', 'lower_body', 'dresses']);

interface Payload {
  userId: string;
  garmentId: string;
  humanImageUrl: string;
  garmentImageUrl: string;
  category: Category;
}

/** Only https, only public hosts: this process holds fal, R2 and service-role
 *  credentials, so it must never be usable as an internal-network fetcher. */
function assertPublicHttps(raw: string, field: string): string {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new HttpError(400, `${field} is not a URL`);
  }
  if (url.protocol !== 'https:') throw new HttpError(400, `${field} must be https`);
  if (/^(localhost|127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|\[::1\])/i.test(url.hostname)) {
    throw new HttpError(400, `${field} host not allowed`);
  }
  return url.toString();
}

function parsePayload(body: unknown): Payload {
  if (typeof body !== 'object' || body === null) throw new HttpError(400, 'JSON body required');
  const b = body as Record<string, unknown>;
  const { userId, garmentId, humanImageUrl, garmentImageUrl, category } = b;
  if (typeof userId !== 'string' || !ID.test(userId)) throw new HttpError(400, 'invalid userId');
  if (typeof garmentId !== 'string' || !ID.test(garmentId)) throw new HttpError(400, 'invalid garmentId');
  if (typeof category !== 'string' || !CATEGORIES.has(category as Category)) {
    throw new HttpError(400, `category must be one of ${[...CATEGORIES].join(', ')}`);
  }
  if (typeof humanImageUrl !== 'string' || typeof garmentImageUrl !== 'string') {
    throw new HttpError(400, 'humanImageUrl and garmentImageUrl are required');
  }
  return {
    userId,
    garmentId,
    humanImageUrl: assertPublicHttps(humanImageUrl, 'humanImageUrl'),
    garmentImageUrl: assertPublicHttps(garmentImageUrl, 'garmentImageUrl'),
    category: category as Category,
  };
}

/** Stream the provider's result with a ceiling — a runaway response must not
 *  be able to fill the container's memory. */
async function download(url: string): Promise<{ buffer: Buffer; contentType: string }> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), config.downloadTimeoutMs);
  try {
    const res = await fetch(url, { signal: ctrl.signal });
    if (!res.ok) throw new HttpError(502, `result download ${res.status}`);
    if (!res.body) throw new HttpError(502, 'empty result body');
    const chunks: Uint8Array[] = [];
    let total = 0;
    for await (const chunk of res.body as unknown as AsyncIterable<Uint8Array>) {
      total += chunk.byteLength;
      if (total > config.maxImageBytes) {
        ctrl.abort();
        throw new HttpError(413, 'result exceeds size limit');
      }
      chunks.push(chunk);
    }
    return {
      buffer: Buffer.concat(chunks, total),
      contentType: res.headers.get('content-type') ?? 'image/jpeg',
    };
  } catch (err) {
    if (err instanceof HttpError) throw err;
    if ((err as Error).name === 'AbortError') throw new HttpError(504, 'result download timed out');
    throw new HttpError(502, `result download failed: ${(err as Error).message}`);
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Persist the render and return a permanent public URL.
 *
 * This is the ONLY place that knows about a storage vendor — swapping R2 in
 * later is this function, not the pipeline.
 */
async function store(key: string, body: Buffer, contentType: string): Promise<string> {
  if (config.storage === 'r2') {
    if (!s3 || !config.r2) throw new HttpError(500, 'R2 selected but not configured');
    await s3.send(
      new PutObjectCommand({
        Bucket: config.r2.bucket,
        Key: key,
        Body: body,
        ContentType: contentType,
        CacheControl: 'public, max-age=31536000, immutable',
      }),
    );
    return `${config.r2.publicBase.replace(/\/$/, '')}/${key}`;
  }

  const { error } = await supabase.storage
    .from(config.supabaseBucket)
    .upload(key, body, {
      contentType,
      cacheControl: '31536000',
      // Content-addressed keys never collide; upsert only matters when the
      // exact same render is produced twice, and then overwriting is right.
      upsert: true,
    });
  if (error) throw new HttpError(502, `storage upload failed: ${error.message}`);
  const { data } = supabase.storage.from(config.supabaseBucket).getPublicUrl(key);
  return data.publicUrl;
}

/* ─────────────────────────────── endpoint ─────────────────────────────── */

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '64kb' }));

app.get('/health', (_req, res) => {
  res.json({ ok: true, provider: config.provider, storage: config.storage, queued: gate.pending });
});

app.post('/api/generate-vton', async (req: Request, res: Response, next: NextFunction) => {
  const started = Date.now();
  let release: (() => void) | null = null;
  try {
    const payload = parsePayload(req.body);

    const requested = (req.query.provider as ProviderName | undefined) ?? config.provider;
    const provider = PROVIDERS[requested];
    if (!provider) throw new HttpError(400, `unknown provider "${requested}"`);
    if (!provider.supports.has(payload.category)) {
      // Failing loudly beats a silent bad render: Kolors given footwear
      // returns shorts, and the user would have blamed us, not the model.
      throw new HttpError(422, `${provider.name} does not support ${payload.category}`);
    }

    release = await gate.acquire();

    // Hard ceiling on the generation itself; fal's queue can stall.
    let resultUrl: string;
    try {
      resultUrl = await withTimeout(
        provider.run(payload),
        config.generateTimeoutMs,
        `${provider.name} generation`,
      );
    } catch (err) {
      if (err instanceof HttpError) throw err;
      throw new HttpError(502, `${provider.name}: ${(err as Error).message}`);
    }

    // fal's URLs expire. Re-host before anything is written to the database,
    // or the row would point at a link that dies within the day.
    const { buffer, contentType } = await download(resultUrl);
    const ext = contentType.includes('png') ? 'png' : contentType.includes('webp') ? 'webp' : 'jpg';
    const digest = createHash('sha256').update(buffer).digest('hex').slice(0, 12);
    const key = `vton/${payload.userId}/${Date.now()}-${digest}.${ext}`;

    const url = await store(key, buffer, contentType);

    const { data, error } = await supabase
      .from(config.supabase.table)
      .insert({
        user_id: payload.userId,
        garment_id: payload.garmentId,
        image_url: url,
        provider: provider.name,
        category: payload.category,
        duration_ms: Date.now() - started,
      })
      .select('id')
      .single();

    if (error) {
      // The image is safely stored and addressable — say so, so the caller can
      // retry the row instead of paying for the generation twice.
      throw new HttpError(500, `image stored at ${url} but DB insert failed: ${error.message}`);
    }

    res.json({
      ok: true,
      url,
      provider: provider.name,
      generationId: data?.id ?? null,
      ms: Date.now() - started,
    });
  } catch (err) {
    next(err);
  } finally {
    release?.();
  }
});

app.use((err: unknown, _req: Request, res: Response, _next: NextFunction) => {
  const status = err instanceof HttpError ? err.status : 500;
  const message = err instanceof Error ? err.message : 'unknown error';
  if (status >= 500) console.error('[generate-vton]', message);
  res.status(status).json({ ok: false, error: message });
});

app.listen(config.port, () => {
  console.log(
    `[generate-vton] :${config.port} · provider=${config.provider} · storage=${config.storage}` +
      ` · max ${config.maxConcurrent} concurrent`,
  );
});

export default app;
