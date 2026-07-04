// POST /api/generate-look  { photoPath, event }
// Flow 2 Virtual Try-On. Gated (image-gen is expensive), ASYNC via fal webhook.
// Returns a generationId immediately; the client subscribes to the row via
// Supabase Realtime and shows the result when status flips to 'succeeded'.
import { admin, getUser, signedUrl, hasSupabase } from '../src/supabase.js';
import { submitTryOn } from '../src/fal.js';

const FREE_QUOTA = 10; // SDD §8.2
const BUCKET = 'body-photos';

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'method_not_allowed' });
  if (!hasSupabase() || !process.env.FAL_KEY) {
    return res.status(501).json({ error: 'try_on_unavailable_local' });
  }

  const user = await getUser(req);
  if (!user) return res.status(401).json({ error: 'unauthorized' });

  const { photoPath, event } = req.body || {};
  if (!photoPath || !photoPath.startsWith(`${user.id}/`)) {
    return res.status(400).json({ error: 'valid photoPath (own folder) required' });
  }

  // Gate BEFORE incurring any fal cost.
  const { data: ent } = await admin
    .from('entitlements')
    .select('pro, free_used')
    .eq('user_id', user.id)
    .single();
  const pro = ent?.pro === true;
  if (!pro && (ent?.free_used ?? 0) >= FREE_QUOTA) {
    return res.status(402).json({ error: 'quota_exhausted' });
  }

  // Create the generation row up front (status queued) so the client can watch it.
  const { data: gen, error: insErr } = await admin
    .from('generations')
    .insert({
      user_id: user.id,
      type: 'tryon',
      status: 'queued',
      provider: 'fal',
      input: { photoPath, event: event ?? null },
    })
    .select('id')
    .single();
  if (insErr) {
    console.error('[generate-look] insert', insErr.message);
    return res.status(500).json({ error: 'db_error' });
  }

  try {
    const personUrl = await signedUrl(BUCKET, photoPath, 900);
    const webhookUrl = `${process.env.PUBLIC_BASE_URL}/webhooks/generation?gen=${gen.id}`;
    const requestId = await submitTryOn(
      { human_image_url: personUrl, prompt: event ?? 'a stylish, well-fitted outfit' },
      webhookUrl,
    );

    await admin
      .from('generations')
      .update({ status: 'processing', external_id: requestId, updated_at: new Date().toISOString() })
      .eq('id', gen.id);

    // Reserve the credit on submit — fal bills us regardless of outcome.
    if (!pro) {
      await admin
        .from('entitlements')
        .update({ free_used: (ent?.free_used ?? 0) + 1, updated_at: new Date().toISOString() })
        .eq('user_id', user.id);
    }

    return res.status(202).json({ generationId: gen.id, status: 'processing' });
  } catch (err) {
    console.error('[generate-look]', err.message);
    await admin.from('generations').update({ status: 'failed', error: err.message }).eq('id', gen.id);
    return res.status(502).json({ error: 'generation_failed' });
  }
}
