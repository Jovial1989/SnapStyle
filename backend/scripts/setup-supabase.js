// One-shot setup for the dedicated Snapstyle Supabase project.
// Run once after filling backend/.env:
//   node --env-file=.env scripts/setup-supabase.js
// Does: run the migration (public schema, tables, RLS, trigger) → create the two
// private storage buckets → add the folder-scoped storage policy → verify.
// Safe on a fresh project; re-running errors on "already exists" (harmless).
import { readFileSync } from 'node:fs';
import pg from 'pg';
import { createClient } from '@supabase/supabase-js';
import WebSocket from 'ws';

globalThis.WebSocket ??= WebSocket; // supabase-js realtime needs it on Node < 22

const { SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_DB_URL } = process.env;
if (!SUPABASE_DB_URL || !SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  console.error('Missing SUPABASE_DB_URL / SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY in .env');
  process.exit(1);
}

const STORAGE_POLICY = `
create policy "own folder" on storage.objects for all
  using ( bucket_id in ('body-photos','generations')
          and (storage.foldername(name))[1] = auth.uid()::text )
  with check ( bucket_id in ('body-photos','generations')
          and (storage.foldername(name))[1] = auth.uid()::text );`;

async function runSql(client, label, sql) {
  try {
    await client.query(sql);
    console.log(`✓ ${label}`);
  } catch (e) {
    console.log(`• ${label}: ${e.message}`); // e.g. already exists
  }
}

(async () => {
  // 1. migration + storage policy
  const client = new pg.Client({
    connectionString: SUPABASE_DB_URL,
    ssl: { rejectUnauthorized: false },
  });
  await client.connect();
  const migration = readFileSync(
    new URL('../supabase/migrations/0001_init.sql', import.meta.url),
    'utf8',
  );
  await runSql(client, 'migration (schema/tables/RLS/trigger)', migration);
  await runSql(client, 'storage folder policy', STORAGE_POLICY);
  await client.end();

  // 2. private buckets
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });
  for (const b of ['body-photos', 'generations']) {
    const { error } = await admin.storage.createBucket(b, { public: false });
    console.log(error ? `• bucket ${b}: ${error.message}` : `✓ bucket ${b} created (private)`);
  }

  // 3. verify tables are reachable
  const { error: verr } = await admin.from('entitlements').select('user_id').limit(1);
  console.log(verr ? `• verify: ${verr.message}` : '✓ tables reachable via API');
  console.log('done.');
})();
