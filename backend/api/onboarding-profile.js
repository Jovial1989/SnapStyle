// POST /api/onboarding-profile  { photoPath, heightCm }
// Vercel-serverless-compatible handler (also mounted by the local Express server).
// Auth via Supabase JWT → Gemini body profiling → upsert style_profiles.
import { admin, getUser, signedUrl, hasSupabase } from '../src/supabase.js';
import { analyzeBodyProfile } from '../src/visionProfile.js';

const BUCKET = 'body-photos';

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'method_not_allowed' });
  if (!hasSupabase()) {
    return res.status(501).json({ error: 'cloud_only', hint: 'use /api/onboarding-profile-local' });
  }

  const user = await getUser(req);
  if (!user) return res.status(401).json({ error: 'unauthorized' });

  const { photoPath, heightCm } = req.body || {};
  if (!photoPath) return res.status(400).json({ error: 'photoPath required' });
  const h = Number(heightCm);
  if (!h || h < 100 || h > 250) return res.status(400).json({ error: 'valid heightCm required' });

  // Enforce the user can only reference their own storage folder (<uid>/...).
  if (!photoPath.startsWith(`${user.id}/`)) {
    return res.status(403).json({ error: 'photoPath must be in your own folder' });
  }

  // Mark processing so the client can show the analyzing state immediately.
  await admin.from('style_profiles').upsert({
    user_id: user.id,
    height_cm: h,
    source_photo_path: photoPath,
    status: 'processing',
    updated_at: new Date().toISOString(),
  });

  try {
    const url = await signedUrl(BUCKET, photoPath);
    const { profile, model, promptVersion } = await analyzeBodyProfile(url, h);

    if (profile.analyzable === false) {
      await admin.from('style_profiles').update({ status: 'failed' }).eq('user_id', user.id);
      return res.status(422).json({ error: 'unanalyzable_photo', note: profile.note });
    }

    const row = {
      user_id: user.id,
      height_cm: h,
      source_photo_path: photoPath,
      body_type: profile.body_type ?? null,
      proportions: profile.proportions ?? {},
      estimated_measurements: profile.estimated_measurements ?? {},
      confidence: profile.confidence ?? null,
      model,
      prompt_version: promptVersion,
      status: 'ready',
      updated_at: new Date().toISOString(),
    };
    await admin.from('style_profiles').upsert(row);

    return res.status(200).json({ profile: row, stylingNotes: profile.styling_notes ?? [] });
  } catch (err) {
    console.error('[onboarding-profile]', err.message);
    await admin.from('style_profiles').update({ status: 'failed' }).eq('user_id', user.id);
    return res.status(502).json({ error: 'profiling_failed' });
  }
}
