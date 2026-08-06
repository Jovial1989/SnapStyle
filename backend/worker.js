// Cloudflare Worker (Hono) — Snapstyle API on Cloudflare (SDD §15).
// Slice 1: /health + /analyze (Gemini critique). Secrets come from the Worker
// env (wrangler secret), not process.env. Native fetch — no Node polyfills.
// Remaining routes (entitlement, onboarding, generate-look, webhooks) + Supabase
// gating are ported next.
import { Hono } from 'hono';
import { SYSTEM_PROMPT, ANALYSIS_SCHEMA, buildUserContext, PROMPT_VERSION } from './src/stylistPrompt.js';

const GEMINI = 'https://generativelanguage.googleapis.com/v1beta/models';

const app = new Hono();

app.get('/health', (c) => c.json({ ok: true, runtime: 'cloudflare-workers' }));

// POST /analyze { appUserId, image:{ data(base64), mimeType }, profile? }
app.post('/analyze', async (c) => {
  const { image, profile } = await c.req.json().catch(() => ({}));
  if (!image?.data || !image?.mimeType) {
    return c.json({ error: 'image { data, mimeType } required' }, 400);
  }
  const key = c.env.GEMINI_API_KEY;
  const model = c.env.GEMINI_MODEL || 'gemini-2.5-flash';

  const body = {
    systemInstruction: { parts: [{ text: SYSTEM_PROMPT }] },
    contents: [{
      role: 'user',
      parts: [
        { text: buildUserContext(profile) },
        { inlineData: { mimeType: image.mimeType, data: image.data } },
      ],
    }],
    generationConfig: {
      responseMimeType: 'application/json',
      responseSchema: ANALYSIS_SCHEMA,
      temperature: 0.6,
    },
  };

  const res = await fetch(`${GEMINI}/${model}:generateContent?key=${key}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!res.ok) return c.json({ error: 'analysis_failed' }, 502);

  const json = await res.json();
  const text = json?.candidates?.[0]?.content?.parts?.[0]?.text;
  if (!text) return c.json({ error: 'analysis_failed' }, 502);

  return c.json({ analysis: JSON.parse(text), model, promptVersion: PROMPT_VERSION });
});

export default app;
