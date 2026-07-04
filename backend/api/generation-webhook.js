// POST /webhooks/generation?gen=<id>  — fal calls this when a try-on finishes.
// Downloads the result, stores it in the private `generations` bucket, and flips
// the generations row to succeeded/failed. The client is watching via Realtime.
import { admin } from '../src/supabase.js';

const OUT_BUCKET = 'generations';

export default async function handler(req, res) {
  const genId = req.query?.gen;
  if (!genId) return res.status(400).json({ error: 'gen id required' });

  const payload = req.body || {};
  // fal webhook shape: { status: 'OK'|'ERROR', payload: {...}, ... }
  const ok = payload.status === 'OK' || payload.status === 'COMPLETED';

  const { data: gen } = await admin
    .from('generations')
    .select('id, user_id')
    .eq('id', genId)
    .single();
  if (!gen) return res.status(404).json({ error: 'generation not found' });

  if (!ok) {
    await admin.from('generations')
      .update({ status: 'failed', error: 'provider_error', updated_at: new Date().toISOString() })
      .eq('id', genId);
    return res.json({ received: true });
  }

  try {
    const resultUrl = payload?.payload?.image?.url || payload?.payload?.images?.[0]?.url;
    if (!resultUrl) throw new Error('no image url in webhook');

    const img = await fetch(resultUrl);
    const bytes = Buffer.from(await img.arrayBuffer());
    const path = `${gen.user_id}/${genId}.png`;

    const { error: upErr } = await admin.storage
      .from(OUT_BUCKET)
      .upload(path, bytes, { contentType: 'image/png', upsert: true });
    if (upErr) throw new Error(upErr.message);

    await admin.from('generations')
      .update({ status: 'succeeded', output: { image_path: path }, updated_at: new Date().toISOString() })
      .eq('id', genId);

    return res.json({ received: true });
  } catch (err) {
    console.error('[generation-webhook]', err.message);
    await admin.from('generations')
      .update({ status: 'failed', error: err.message, updated_at: new Date().toISOString() })
      .eq('id', genId);
    return res.status(500).json({ error: 'webhook_failed' });
  }
}
