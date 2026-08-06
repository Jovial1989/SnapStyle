// Geo-test: does Gemini accept requests from the Supabase DB region (Mumbai)?
// Uses pg_net to make the HTTP call FROM the database (egress = ap-south-1),
// with only the DB connection we already have. node --env-file=.env scripts/geo-test.js
import pg from 'pg';

const client = new pg.Client({ connectionString: process.env.SUPABASE_DB_URL, ssl: { rejectUnauthorized: false } });
const url = `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=${process.env.GEMINI_API_KEY}`;
const body = { contents: [{ parts: [{ text: 'Reply with exactly: OK' }] }] };

(async () => {
  await client.connect();
  await client.query('create extension if not exists pg_net with schema extensions;').catch((e) => console.log('ext:', e.message));
  const r = await client.query(
    `select net.http_post(url := $1, body := $2::jsonb, headers := '{"Content-Type":"application/json"}'::jsonb) as id`,
    [url, JSON.stringify(body)],
  );
  const id = r.rows[0].id;
  console.log('request id:', id, '— waiting for async response…');
  await new Promise((res) => setTimeout(res, 5000));
  const resp = await client.query(
    `select status_code, left(content, 250) as content, error_msg from net._http_response where id = $1`,
    [id],
  );
  console.log('response:', JSON.stringify(resp.rows[0] ?? '(none yet)'));
  await client.end();
  process.exit(0);
})();
