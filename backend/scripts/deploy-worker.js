// Deploy the bundled Worker directly via the Cloudflare API (bypasses wrangler:
// no /memberships call, no Node-22 requirement). Needs a token with
// "Workers Scripts: Edit". Run:
//   npx esbuild worker.js --bundle --format=esm --outfile=dist/worker.mjs
//   node --env-file=.env scripts/deploy-worker.js
import { readFileSync } from 'node:fs';

const ACC = process.env.CLOUDFLARE_ACCOUNT_ID;
const TOK = process.env.CLOUDFLARE_API_TOKEN;
const GK = process.env.GEMINI_API_KEY;
const NAME = 'snapstyle-api';
const API = 'https://api.cloudflare.com/client/v4';

(async () => {
  const script = readFileSync(new URL('../dist/worker.mjs', import.meta.url));
  const metadata = {
    main_module: 'worker.mjs',
    compatibility_date: '2026-07-01',
    bindings: [
      { type: 'secret_text', name: 'GEMINI_API_KEY', text: GK },
      { type: 'plain_text', name: 'GEMINI_MODEL', text: 'gemini-2.5-flash' },
    ],
  };
  const fd = new FormData();
  fd.append('metadata', new Blob([JSON.stringify(metadata)], { type: 'application/json' }));
  fd.append('worker.mjs', new Blob([script], { type: 'application/javascript+module' }), 'worker.mjs');

  const put = await fetch(`${API}/accounts/${ACC}/workers/scripts/${NAME}`, {
    method: 'PUT', headers: { Authorization: `Bearer ${TOK}` }, body: fd,
  });
  const pj = await put.json().catch(() => ({}));
  console.log('deploy:', put.status, pj.success ? 'OK' : JSON.stringify(pj.errors));
  if (!pj.success) process.exit(1);

  await fetch(`${API}/accounts/${ACC}/workers/scripts/${NAME}/subdomain`, {
    method: 'POST', headers: { Authorization: `Bearer ${TOK}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ enabled: true }),
  });

  const s = await fetch(`${API}/accounts/${ACC}/workers/subdomain`, { headers: { Authorization: `Bearer ${TOK}` } });
  const sj = await s.json().catch(() => ({}));
  const sub = sj?.result?.subdomain;
  console.log(sub ? `✓ URL: https://${NAME}.${sub}.workers.dev` : '• deployed; get workers.dev subdomain from dashboard');
})();
