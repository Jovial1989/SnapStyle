# Snapstyle landing — deploy to Cloudflare Pages

Static site (single `index.html`, zero build, zero dependencies). Hosts free on
Cloudflare Pages (free tier: unlimited requests/bandwidth, free SSL, custom domain).

## Option A — direct upload (fastest)
```bash
cd "web"
npx wrangler login                      # opens browser, authorize your Cloudflare account
npx wrangler pages deploy . --project-name=snapstyle
```
First run creates the `snapstyle` Pages project and returns a `*.pages.dev` URL.
Re-run the deploy command to publish updates.

Headless/CI instead of `login`:
```bash
export CLOUDFLARE_API_TOKEN=...         # token with "Cloudflare Pages: Edit"
export CLOUDFLARE_ACCOUNT_ID=...
npx wrangler pages deploy . --project-name=snapstyle
```

## Option B — Git-connected
Push this repo, then Cloudflare Dashboard → Workers & Pages → Create → Pages →
Connect to Git → select repo. Build command: (none). Build output directory: `web`.

## Custom domain
Pages project → Custom domains → add `snapstyle.app` (or your domain); Cloudflare
issues SSL automatically.

Note: I can't run the deploy — it needs your Cloudflare account. Steps above are
copy-paste ready.
