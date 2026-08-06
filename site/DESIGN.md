# Snapstyle marketing site — DESIGN.md

Astro static site (near-zero JS), deployed to Cloudflare Pages. Mirrors the app's
"Editorial Luxury" language in the **brand register** (more expressive type/motion
than the app, same vocabulary).

## Languages (i18n)
- Client-side switcher mirroring the original single-page site. 9 locales in menu
  order: **en, uk, es, fr, it, zh, th, ko, vi**.
- Translatable text carries a `data-i18n="key"` attribute; `public/i18n.js` holds the
  full dictionary (`SNAP_I18N`), swaps `innerHTML` per locale, persists the choice to
  `localStorage` (`snap_lang`), detects `navigator.language`, and sets `<html lang>`.
  Values may contain trusted markup (`<br>`, `<span class="serif">`).
- Served HTML is English (canonical/SEO); other locales apply on load. Switcher lives
  in the Header (desktop right + mobile sheet). Fallback font stack in `tokens.css`
  covers CJK/Thai/Korean glyphs (Geist has no CJK).
- Source of truth = the `en` block in `public/i18n.js`. To retranslate, feed that
  key→value map to a translator and keep keys/markup identical.

## Stack
- **Astro 4** (static output) → `site/dist` → Cloudflare Pages.
- Zero UI framework. JS only for: scroll-reveal (IntersectionObserver, ~0.6 kB)
  and the partners form (mailto builder). Both degrade gracefully + honour
  `prefers-reduced-motion`.
- Fonts self-hosted (`public/fonts/Geist-Variable.woff2`), preloaded, `swap`.
  No runtime external requests.

## Tokens (`src/styles/tokens.css`)
- **Colour** (tinted, never pure): `--ink #0A0A0A`, `--ink-soft #33332F`,
  `--bg #F8F8F6`, `--surface #FFFFFF`, `--surface-2 #EFEFEC`,
  `--muted #6B6B67` (darkened to pass WCAG 4.5:1), `--line #E4E4E0`.
  Accent = `--sig #2E5BFF` (Electric Blue), wash `--sig-wash #ECF0FF` (~10%).
  `--good #1E9E6A`.
- **Type**: Geist (`--w-black 800`, `--w-med 500`, `--w-reg 400`). Fluid scale via
  `clamp()`: `--t-display` (hero), `--t-h1`, `--t-h2`, `--t-lead`, `--t-body`,
  `--t-small`, `--t-label`. Serif accent = Instrument Serif (falls back to Georgia
  italic) for one "voice" moment on About. Max 4 sizes / 2 weights per view.
- **Spacing**: 8pt scale `--s-1…--s-8` (8→128).
- **Radius**: `--radius 14px`, `--radius-lg 28px`. **Shadow**: `--shadow-soft` only.
- `--wrap 1120px`, `--ease` cubic-bezier.

## Components (`src/components`, `src/layouts`)
- **Layout.astro** — html shell: SEO (title/desc/canonical), OpenGraph + Twitter,
  JSON-LD slot, font preload, skip-link, `<Header>`, `<main>`, `<Footer>`, the
  reveal script. Props: `title, description, path, ogImage, schema`.
- **Header.astro** — sticky blur bar; lens-mark + `snapstyle` wordmark; primary
  nav with active state (border-bottom `--sig`); `Get the app` pill; `<details>`
  hamburger < 760px.
- **Footer.astro** — brand + tagline, site nav mirror, contact
  (`petrov.cpay@gmail.com`, LinkedIn), legal (placeholder → `[NEED: legal]`), ©.
- **Screen.astro** — the ONE phone frame (9/19.5). `src` for a real export or
  `placeholder` to reserve exact space (no reflow when reals drop in). `eager`
  marks the LCP hero image (preloaded, `fetchpriority=high`).
- **Reveal** — not a component; add `class="reveal"` and the Layout's observer
  animates transform+opacity in. **Never on above-the-fold content** (it starts at
  opacity 0 → invisible if JS is slow; a11y + no-flash rule).

## Motion
- Scroll-reveal on below-fold sections (transform + opacity only).
- `prefers-reduced-motion` → everything visible, no transitions.
- One delight moment max per page. No bounce/elastic. (Editor demo loop is a
  `[NEED: export]` placeholder for now.)

## Information architecture
- Nav: **Product (/)** · **How it works (/how-it-works)** · **About (/about)** ·
  **Partners (/partners)** · `Get the app`.
- **Home** — hero → problem → 3-act loop (Snap / Honest read / Restyle) →
  sectioned-editor feature → shopping-mode feature → trustworthy (4 points) →
  social-proof placeholder → closing CTA. Schema: `SoftwareApplication`.
- **How it works** — what it evaluates (fit/proportion/footwear/layering/colour) →
  brand-agnostic + inspiration-only stance → **#privacy** (`[NEED: photo policy]`).
- **About** — founder story (verbatim, first-person), principles, `[NEED: photo]`,
  LinkedIn. Schema: `Person`. "Previously/companies" line intentionally omitted;
  layout leaves room to add it without reflow.
- **Partners** — lean "get in touch": value (qualified intent) + moat (partnerships
  never override the honest verdict) + contact form (client-side validate → mailto)
  + direct email/LinkedIn.
- **404** — in-brand.
- `sitemap.xml` + `robots.txt` in `public/`.

## Quality
- **a11y**: audited with @accesslint/core (WCAG AA) — 0 violations across all 4
  pages at moderate+. Keyboard focus ring (`--sig`), skip-link, semantic
  landmarks, headings in order, alt text on real images, `[NEED: export]` labels
  on placeholders.
- **Perf**: static HTML, inlined critical CSS (Astro `inlineStylesheets: auto`),
  hero image preloaded + `fetchpriority=high`, below-fold images `loading=lazy`,
  fixed aspect-ratios (CLS ~0), self-hosted font preloaded.
- **SEO**: per-page title/description/canonical, OG + Twitter cards, JSON-LD
  (SoftwareApplication / Person), sitemap, clean URLs, no orphan pages.

## Open items (`[NEED:]`)
- Fresh app screenshots (home / fit-review / occasion results / **sectioned
  editor** / **shopping verdict**) — placeholders reserve exact space now.
- Real 1200×630 OG image (currently a stand-in).
- Photo/data-handling policy (How it works #privacy) + Privacy/Terms pages.
- Real store links (buttons show "Coming soon").
- Testimonials / usage metrics (social-proof strip is an honest placeholder).

## Build & deploy
```bash
cd site
npm install
npm run build          # → site/dist
# Cloudflare Pages:
npx wrangler pages deploy dist --project-name=snapstyle
```
