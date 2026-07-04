import { Router } from 'express';
import { analyzeFit } from '../gemini.js';
import { canAnalyze, consumeFreeAnalysis, getEntitlement } from '../entitlement.js';

export const analyze = Router();

// POST /analyze
// body: { appUserId, image: { data: <base64>, mimeType }, profile? }
// Gate → Gemini → validate → burn quota on success only (SDD §2.4 Pillar 2, §8.2).
analyze.post('/', async (req, res) => {
  const { appUserId, image, profile } = req.body || {};

  if (!appUserId) return res.status(400).json({ error: 'appUserId required' });
  if (!image?.data || !image?.mimeType) {
    return res.status(400).json({ error: 'image { data, mimeType } required' });
  }

  // Gate BEFORE spending a Gemini call. 402 → client shows paywall.
  if (!canAnalyze(appUserId)) {
    return res.status(402).json({
      error: 'quota_exhausted',
      entitlement: getEntitlement(appUserId),
    });
  }

  try {
    const result = await analyzeFit(image, profile);

    // Burn one free analysis ONLY after a successful result (no-op if pro).
    consumeFreeAnalysis(appUserId);

    res.json({
      ...result,
      entitlement: getEntitlement(appUserId),
    });
  } catch (err) {
    console.error('[analyze] failed:', err.message);
    // Quota intentionally NOT consumed — the user shouldn't pay for our failure.
    res.status(502).json({ error: 'analysis_failed' });
  }
});
