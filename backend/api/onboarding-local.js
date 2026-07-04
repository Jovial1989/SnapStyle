// POST /api/onboarding-profile-local  { heightCm, image:{ data(base64), mimeType } }
// LOCAL DEV path: no auth, no Supabase, no storage — mirrors the base64 critique
// flow. Runs the same Gemini body-profiling and returns the same response shape
// the client expects, but does NOT persist. Swap to /api/onboarding-profile
// (auth + Supabase) for production.
import { analyzeBodyProfileInline } from '../src/visionProfile.js';

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'method_not_allowed' });

  const { heightCm, image } = req.body || {};
  const h = Number(heightCm);
  if (!h || h < 100 || h > 250) return res.status(400).json({ error: 'valid heightCm required' });
  if (!image?.data || !image?.mimeType) {
    return res.status(400).json({ error: 'image { data, mimeType } required' });
  }

  try {
    const { profile, model, promptVersion } = await analyzeBodyProfileInline(image, h);
    if (profile.analyzable === false) {
      return res.status(422).json({ error: 'unanalyzable_photo', note: profile.note });
    }
    // Shape identical to the cloud route so the Flutter model parses unchanged.
    return res.status(200).json({
      profile: {
        height_cm: h,
        body_type: profile.body_type ?? null,
        proportions: profile.proportions ?? {},
        estimated_measurements: profile.estimated_measurements ?? {},
        confidence: profile.confidence ?? null,
        model,
        prompt_version: promptVersion,
      },
      stylingNotes: profile.styling_notes ?? [],
    });
  } catch (err) {
    console.error('[onboarding-local]', err.message);
    return res.status(502).json({ error: 'profiling_failed' });
  }
}
