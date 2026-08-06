import { defineConfig } from 'astro/config';

// Static build → Cloudflare Pages (output: site/dist). Sitemap is a static file
// in public/ (the sitemap integration crashed on this version).
export default defineConfig({
  site: 'https://snapstyle.pages.dev',
  build: { inlineStylesheets: 'auto' },
});
