// Live verification against the real Snapstyle Supabase project:
//   node --env-file=.env scripts/verify-cloud.js
// 1) create a test auth user → confirms the signup trigger auto-provisions
//    profiles + entitlements. 2) upload a photo to the private body-photos bucket.
import { readFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';
import WebSocket from 'ws';
globalThis.WebSocket ??= WebSocket;

const { SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY } = process.env;
const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const EMAIL = 'test+snapstyle@example.com';

(async () => {
  // 1. test user (create or find)
  let userId;
  const { data: created, error: ce } = await admin.auth.admin.createUser({
    email: EMAIL, password: 'TestPass123!', email_confirm: true,
  });
  if (created?.user) {
    userId = created.user.id;
    console.log('✓ created test user', userId);
  } else {
    const { data: list } = await admin.auth.admin.listUsers();
    userId = list.users.find((u) => u.email === EMAIL)?.id;
    console.log(`• test user exists (${ce?.message}) → ${userId}`);
  }

  // 2. trigger auto-provision check
  const { data: prof } = await admin.from('profiles').select('id').eq('id', userId);
  const { data: ent } = await admin.from('entitlements').select('user_id,free_used,pro').eq('user_id', userId);
  console.log(`✓ trigger: profiles row=${prof?.length === 1}, entitlements=`, ent?.[0]);

  // 3. storage upload into <uid>/ folder
  const photo = readFileSync(`${process.env.HOME}/Downloads/istockphoto-1082488184-612x612.jpg`);
  const path = `${userId}/verify.jpg`;
  const { error: ue } = await admin.storage.from('body-photos').upload(path, photo, {
    contentType: 'image/jpeg', upsert: true,
  });
  console.log(ue ? `• upload: ${ue.message}` : `✓ uploaded body-photos/${path} (${photo.length} bytes)`);

  process.exit(0);
})();
