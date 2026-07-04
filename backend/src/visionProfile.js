// AI Body Profiling (Onboarding). Gemini vision reads a full-body photo + the
// user's stated height and returns PROPORTIONS (reliable) and MEASUREMENT
// ESTIMATES AS RANGES (unreliable — never a single "measured" number).
// See SDD §5.5.

const API_BASE = 'https://generativelanguage.googleapis.com/v1beta/models';
export const PROFILE_PROMPT_VERSION = 'bodyprofile-v1';

function profileModel() {
  // Deep vision reasoning → default to the pro tier for onboarding.
  return process.env.GEMINI_MODEL_PROFILE || 'gemini-2.5-pro';
}

function systemPrompt(heightCm) {
  return `You are a body-proportion analyst for a fashion styling app. You are NOT a medical or tailoring tool.
Given ONE full-body photo and the user's stated height of ${heightCm} cm, infer styling-relevant body data.

USE THE HEIGHT AS A SCALE ANCHOR: estimate everything relative to ${heightCm} cm.

WHAT IS RELIABLE vs NOT — respect this honestly:
- PROPORTIONS & BODY TYPE (shoulder-to-hip balance, torso-to-leg ratio, silhouette shape) are
  readable from a 2D photo → report them with normal confidence.
- ABSOLUTE MEASUREMENTS (chest/waist/hip/inseam in cm) CANNOT be measured from a photo. Report them
  ONLY as a plausible RANGE {min,max} plus a confidence 0..1. NEVER output a single exact cm value as if measured.

If the image is not a clear, single-person, full-body shot (cropped, blurry, multiple people, not a person),
set analyzable=false and explain in "note" exactly what photo is needed. Do not fabricate a profile.

Return ONLY JSON matching the provided schema.`;
}

export const PROFILE_SCHEMA = {
  type: 'OBJECT',
  properties: {
    analyzable: { type: 'BOOLEAN' },
    note: { type: 'STRING' },
    body_type: {
      type: 'STRING',
      enum: ['rectangle', 'triangle', 'inverted_triangle', 'hourglass', 'oval', 'athletic'],
    },
    proportions: {
      type: 'OBJECT',
      properties: {
        shoulder_to_hip: { type: 'STRING', enum: ['narrower', 'balanced', 'wider'] },
        torso_to_leg: { type: 'STRING', enum: ['short_torso', 'balanced', 'long_torso'] },
        description: { type: 'STRING' },
      },
      required: ['description'],
    },
    estimated_measurements: {
      type: 'OBJECT',
      properties: {
        chest_cm: { type: 'OBJECT', properties: { min: { type: 'NUMBER' }, max: { type: 'NUMBER' } } },
        waist_cm: { type: 'OBJECT', properties: { min: { type: 'NUMBER' }, max: { type: 'NUMBER' } } },
        hip_cm: { type: 'OBJECT', properties: { min: { type: 'NUMBER' }, max: { type: 'NUMBER' } } },
        inseam_cm: { type: 'OBJECT', properties: { min: { type: 'NUMBER' }, max: { type: 'NUMBER' } } },
      },
    },
    confidence: { type: 'NUMBER' }, // overall, 0..1
    styling_notes: { type: 'ARRAY', items: { type: 'STRING' } }, // brand-agnostic cuts that flatter
  },
  required: ['analyzable', 'proportions'],
};

/**
 * Core: analyze from inline base64 (local mode — no storage/fetch).
 * @param {{data: string, mimeType: string}} image
 * @param {number} heightCm
 */
export async function analyzeBodyProfileInline(image, heightCm) {
  const apiKey = process.env.GEMINI_API_KEY;
  if (!apiKey) throw new Error('GEMINI_API_KEY missing');

  const body = {
    systemInstruction: { parts: [{ text: systemPrompt(heightCm) }] },
    contents: [
      {
        role: 'user',
        parts: [
          { text: `Analyze this full-body photo. Stated height: ${heightCm} cm.` },
          { inlineData: { mimeType: image.mimeType, data: image.data } },
        ],
      },
    ],
    generationConfig: {
      responseMimeType: 'application/json',
      responseSchema: PROFILE_SCHEMA,
      temperature: 0.3, // low — this is analysis, not creativity
    },
  };

  const res = await fetch(`${API_BASE}/${profileModel()}:generateContent?key=${apiKey}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`Gemini ${res.status}: ${(await res.text()).slice(0, 400)}`);

  const json = await res.json();
  const text = json?.candidates?.[0]?.content?.parts?.[0]?.text;
  if (!text) throw new Error('Gemini returned no content');

  return {
    profile: JSON.parse(text),
    model: profileModel(),
    promptVersion: PROFILE_PROMPT_VERSION,
  };
}

/**
 * Cloud wrapper: fetch a (signed) URL then run the core.
 * @param {string} imageUrl
 * @param {number} heightCm
 */
export async function analyzeBodyProfile(imageUrl, heightCm) {
  const imgRes = await fetch(imageUrl);
  if (!imgRes.ok) throw new Error(`image fetch ${imgRes.status}`);
  const mimeType = imgRes.headers.get('content-type') || 'image/jpeg';
  const data = Buffer.from(await imgRes.arrayBuffer()).toString('base64');
  return analyzeBodyProfileInline({ data, mimeType }, heightCm);
}
