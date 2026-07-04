// Gemini multimodal client. Direct REST (no SDK) to keep deps minimal.
// Server-side only — GEMINI_API_KEY never leaves Node (SDD §2.2).
import {
  SYSTEM_PROMPT,
  ANALYSIS_SCHEMA,
  buildUserContext,
  PROMPT_VERSION,
} from './stylistPrompt.js';

const API_BASE = 'https://generativelanguage.googleapis.com/v1beta/models';

function model() {
  return process.env.GEMINI_MODEL || 'gemini-2.5-flash';
}

/**
 * Run the fit/proportion analysis on one image.
 * @param {{ data: string, mimeType: string }} image  base64 (no data: prefix) + mime
 * @param {object} [profile]  optional user profile context
 * @returns {Promise<{ analysis: object, model: string, promptVersion: string }>}
 */
export async function analyzeFit(image, profile) {
  const apiKey = process.env.GEMINI_API_KEY;
  if (!apiKey) throw new Error('GEMINI_API_KEY missing — set it in backend/.env');

  const body = {
    systemInstruction: { parts: [{ text: SYSTEM_PROMPT }] },
    contents: [
      {
        role: 'user',
        parts: [
          { text: buildUserContext(profile) },
          { inlineData: { mimeType: image.mimeType, data: image.data } },
        ],
      },
    ],
    generationConfig: {
      responseMimeType: 'application/json',
      responseSchema: ANALYSIS_SCHEMA,
      temperature: 0.6,
    },
  };

  const res = await fetch(
    `${API_BASE}/${model()}:generateContent?key=${apiKey}`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    },
  );

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Gemini ${res.status}: ${text.slice(0, 500)}`);
  }

  const json = await res.json();

  const blocked = json?.promptFeedback?.blockReason;
  if (blocked) throw new Error(`Gemini blocked prompt: ${blocked}`);

  const part = json?.candidates?.[0]?.content?.parts?.[0]?.text;
  if (!part) throw new Error('Gemini returned no content');

  let analysis;
  try {
    analysis = JSON.parse(part);
  } catch {
    throw new Error('Gemini returned non-JSON despite schema');
  }

  return { analysis, model: model(), promptVersion: PROMPT_VERSION };
}
