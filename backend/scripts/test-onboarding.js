// Full cloud onboarding proof:
//   node --env-file=.env scripts/test-onboarding.js
// Signs in the test user → gets a JWT → invokes the real /api/onboarding-profile
// handler (Gemini vision on the uploaded photo) → reads back style_profiles.
import { createClient } from '@supabase/supabase-js';
import WebSocket from 'ws';
globalThis.WebSocket ??= WebSocket;

const { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, SUPABASE_SERVICE_ROLE_KEY } = process.env;

(async () => {
  // 1. sign in as the test user → JWT
  const anon = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false } });
  const { data: si, error: se } = await anon.auth.signInWithPassword({
    email: 'test+snapstyle@example.com', password: 'TestPass123!',
  });
  if (se) throw se;
  const jwt = si.session.access_token;
  const uid = si.user.id;
  console.log('✓ signed in', uid);

  // 2. invoke the real handler with a mock req/res
  const { default: handler } = await import('../api/onboarding-profile.js');
  const req = {
    method: 'POST',
    headers: { authorization: `Bearer ${jwt}` },
    body: { photoPath: `${uid}/verify.jpg`, heightCm: 180 },
  };
  const res = {
    statusCode: 200,
    status(c) { this.statusCode = c; return this; },
    json(o) { console.log(`→ HTTP ${this.statusCode}:`, JSON.stringify(o).slice(0, 700)); return this; },
  };
  console.log('… calling onboarding-profile (Gemini 2.5 Pro)…');
  await handler(req, res);

  // 3. read back what got written
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const { data } = await admin.from('style_profiles').select('*').eq('user_id', uid).single();
  console.log('✓ style_profiles row:', JSON.stringify({
    status: data?.status, body_type: data?.body_type, height_cm: data?.height_cm,
    confidence: data?.confidence, model: data?.model,
  }));
  process.exit(0);
})();
