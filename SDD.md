# Snapstyle — Software Design Document (SDD)

> **Single source of truth.** Every architectural decision, data model, AI flow, and feature spec lives here. Code is downstream of this document. If it's not in the SDD, it's not final.

- **Product:** AI-powered styling & shopping assistant
- **Platform:** Mobile-first (the app IS the product). Web is a static download-driver only.
- **Status:** `v0.0.2 — Supabase deferred; Node+Gemini interim stack`
- **Last updated:** 2026-07-03

> ⚠️ **SECRETS POLICY:** No API keys, tokens, or credentials in this document, in source, or in git. Secrets live only in `.env` (git-ignored) and are referenced by name (e.g. `GEMINI_API_KEY`). Any key ever pasted in plaintext is considered compromised and must be rotated.

---

## 0. Document Conventions

- `[DECISION]` — a finalized, locked technical decision.
- `[OPEN]` — an unresolved question requiring product/eng input.
- `[ASSUMPTION]` — a working assumption to be validated.
- Schemas are authoritative: Supabase SQL, Dart models, and API contracts here override anything in code.

---

## 1. Product Overview & Scope

### 1.1 What Snapstyle Does
A **personal AI stylist by subscription.** Analyzes user photos to reason about **clothing fit, body proportions, and outfit coordination** — with specific competencies in:
- Pant cuts (rise, break, taper) vs. body proportion
- Footwear matching to outfit + occasion
- Layering logic (proportion, weight, silhouette)

Delivers **honest, specific, brand-agnostic styling advice** — like asking a stylist or a friend "how do I look, what's off, what should I change?" Advice describes *what* to change (cut, color, silhouette, garment category), **not where to buy it.** No shopping, no brands, no product links.

**Monetization:** subscription (recurring). No commerce, no affiliate, no ads.

### 1.2 Scope Boundaries
| Surface | Role | Effort |
|---|---|---|
| Flutter app | Core product — capture, analysis, styling advice, subscription | 95% |
| Node.js + Supabase | AI orchestration, data, auth, storage | (part of the 95%) |
| Web | Static landing page → app-store conversion only | 5%, no over-engineering |

### 1.3 Non-Goals (v1)
- `[DECISION]` **No shopping / commerce / affiliate / product catalog.** Advice is brand-agnostic. Cut from scope.
- `[DECISION]` **No ads.** Revenue is subscription only.
- `[OPEN]` Social feed / sharing?

---

## 2. System Architecture

### 2.1 High-Level Topology
```
┌──────────────┐        ┌────────────────────┐        ┌──────────────┐
│  Flutter App │        │  Node.js Orchestr. │        │  Gemini API  │
│  (iOS/Android)│──────▶│  (stateless API)   │──────▶ │ (multimodal) │
└──────┬───────┘        └─────────┬──────────┘        └──────────────┘
       │                          │
       │  direct SDK (auth,       │  service-role
       │  storage upload,         │  reads/writes
       │  realtime subscribe)     │
       ▼                          ▼
        ┌──────────────────────────────────┐
        │  Supabase (Postgres/Auth/Storage/ │
        │           Realtime)               │
        └──────────────────────────────────┘
```

### 2.2 Core Architectural Decisions
- `[DECISION]` **Gemini is server-side only.** No Google AI key ever ships in the Flutter binary — even in the interim, no-Supabase stack. All multimodal calls proxy through Node.js. `GEMINI_API_KEY` lives in Node `.env` only.
- `[DECISION — target]` **Image upload is client → Supabase Storage direct**, using a short-lived signed upload path. Flutter sends only the storage *path* to Node.js, never raw bytes over the API.
- `[DECISION — target]` **AI analysis is asynchronous** via Supabase Realtime once Supabase lands.
- `[OPEN]` Job queue mechanism — Postgres-backed queue (pg-boss / Supabase table) vs. external (Redis/Cloud Tasks)?

### 2.3 Interim Stack → Supabase ACTIVATING
`[DECISION]` As of the MVP build, **Supabase is being activated** (Auth + Postgres + Storage + Realtime). The interim table below is the migration map; the "target" column is now the live target. Schema in `backend/supabase/migrations/0001_init.sql`.
- Client `appUserId` → Supabase auth `uid`. In-memory entitlement store → `entitlements` table.
- New heavy flows (onboarding profiling, try-on) use **Storage-path transport** (upload to private bucket → send path). The base64 critique flow (`/analyze`) stays interim for now; migrating it to Storage-path is a follow-up.
- Serverless target: **Vercel functions** (`backend/api/*.js`), mounted in the local Express server for dev. `[DECISION]` Because image-gen exceeds serverless timeouts, **try-on is async (provider webhook + Realtime)**, never a synchronous function.

### 2.3.2 Supabase Hosting — dedicated Snapstyle project
`[DECISION]` **Separate, dedicated Supabase project** for Snapstyle (in the user's Pro org — no pausing). NOT inside Motixi. Full isolation of auth/storage/db from day one → no later migration. Standard `public` schema.
- Reverted the earlier "schema inside Motixi" plan (user has a paid org, so a clean separate project is simpler and safer).
- Migration `backend/supabase/migrations/0001_init.sql` (public schema, `on_auth_user_created` trigger auto-provisions profiles + entitlements). Buckets: private `body-photos`, `generations`.
- Clients use default schema (no override). `public` is API-exposed by default → no dashboard toggle.
- Hosting of server logic (target): **Supabase Edge Functions** (drop Vercel). Local Node runs against this project for dev/testing first.

### 2.3.1 Local Dev Mode (current default)
`[DECISION]` Supabase/fal/auth are **not required to run locally** — only `GEMINI_API_KEY`. The backend degrades gracefully:
- Supabase client is **lazy** (`hasSupabase()` guard) → server boots with no Supabase env. Verified.
- **Onboarding has two routes:** `/api/onboarding-profile-local` (base64, no auth, no persistence — LOCAL) and `/api/onboarding-profile` (Supabase + JWT — CLOUD, returns 501 locally).
- Try-on `/api/generate-look` → 501 locally (needs fal + Supabase + public webhook URL).
- Flutter: onboarding + critique use the base64 ApiClient path; `SnapstyleApi` (Supabase) is retained for the cloud path but unused locally. Supabase init in `main` is skipped when dart-defines are empty.

| Layer | Target (later) | Interim (now) |
|---|---|---|
| Database | Supabase Postgres | On-device **Isar** (or SQLite) |
| Auth | Supabase Auth | None / anonymous local profile |
| Photo storage | Supabase Storage (private bucket) | Local device file cache |
| Realtime | Supabase Realtime | Direct synchronous Node response |
| Gemini key | Node `.env` | Node `.env` (unchanged) |

- `[DECISION]` Even without Supabase, the **thin Node.js proxy stays** — it is the security boundary that holds the Gemini key. Flutter never talks to Gemini directly.
- `[DECISION]` Interim analysis is a **synchronous request/response** through Node (small payloads, single image). Async+Realtime is deferred with Supabase.
- `[ASSUMPTION]` Interim image transport: Flutter sends base64/multipart image → Node → Gemini inline. Revisit when photo sizes/volume grow.

---

## 2.4 Core Features Breakdown (The 4 Pillars)

> Flows below document the **target** stack (Flutter → Node.js/Supabase → Gemini). Interim variances (no Supabase) are noted inline per §2.3.

### Pillar 1 — Onboarding & Digital Wardrobe (Profile)
**Goal:** capture the personalization context and build a structured, machine-readable wardrobe.

- **Body proportions & sizing:** typed columns (height, weight optional, shoulder/waist/hip/inseam, shoe size, fit preference). Sensitive → RLS-scoped, never sent to shopping/affiliate layers.
- **Style preferences:** freeform-but-bounded `jsonb` (preferred styles, colors, occasions, disliked cuts, budget band).
- **Digital Wardrobe:** each added garment → photo to Storage + **auto-cataloguing Gemini pass (Flash tier)** that extracts structured attributes. This structured metadata is what makes Pillar 3 possible without re-sending images.

Flow:
```
Flutter (add item + photo)
  → Storage upload (signed path)        [interim: local file cache]
  → Node.js: Gemini Flash "catalog this garment" → strict JSON attrs
  → persist wardrobe_items row (attrs + photo path)
  → Flutter renders catalogued item
```

### Pillar 2 — AI Fit & Proportion Analyzer (Core Engine)
**Goal:** turn one body/outfit photo into structured, actionable styling advice.

Flow:
```
Flutter camera → on-device downscale (≤~1568px long edge, JPEG/WebP)
  → Storage upload (signed path)        [interim: multipart to Node]
  → Node.js: assemble prompt (system stylist rubric + user profile context + image)
  → Gemini (Pro tier) analyzes: overall fit, pant cut vs proportion, footwear match, layering
  → Gemini returns STRICT JSON (validated server-side)
  → persist analysis row
  → Flutter: async result via Realtime  [interim: synchronous HTTP response]
```
**Bottlenecks & mitigations:**
- *Gemini latency (multi-second):* async + Realtime (target); skeleton UI; model tiering (Flash vs Pro).
- *Image payload:* on-device resize/compress; only Storage path travels to Node in target stack.
- *Cost:* one deep analysis per request; cache wardrobe cataloguing.

### Pillar 3 — Outfit Coordination & Layering Logic
**Goal:** suggest combinations from existing wardrobe + candidate new items.

- `[DECISION]` **Reason over catalogued text attributes, not images.** Gemini receives the structured attribute list of relevant wardrobe items + the target item and returns compatibility scoring + layering rationale. Images only when a genuine visual match is required.
- Output: ranked outfit combinations with a short "why it works" per suggestion.

### Pillar 4 — Brand-Agnostic Styling Suggestions
**Goal:** turn analysis into honest, actionable advice on *what* to change — never *where to buy*.

- `[DECISION]` **Suggestions are brand-agnostic and describe change, not purchase.** Output is a structured `styling_suggestion` (e.g. `{ target: "pants", change: "wider straight-leg cut", reason: "balances shoulder-to-hip ratio" }` or `{ target: "top", change: "swap to warm neutral", reason: "cool tone drains complexion" }`). No SKUs, no prices, no brands, no links.
- The LLM already produces this inside the Pillar 2 analysis JSON — no separate commerce layer, no catalog.
- Value lives entirely in **advice quality** → the stylist persona/rubric (§5.3) is the core IP.

Flow:
```
analysis / coordination output → styling_suggestion[] (structured, brand-agnostic)
  → Flutter renders as prioritized "what's off / what to change" cards
  → optional: save suggestion, re-analyze after user changes something
```

---

## 3. Flutter Architecture (Core App)

### 3.1 State Management
- `[DECISION]` **Riverpod** (`flutter_riverpod ^2.5`). Providers: `profileStoreProvider` (overridden in `main`), `apiClientProvider`, `appUserIdProvider`, `profileProvider` (Notifier), `entitlementProvider` (FutureProvider).

### 3.2 Navigation
- `[DECISION — interim]` Plain `Navigator.push` (3 screens: Home → Result, Home → Profile). Revisit go_router when the graph grows.

### 3.3 Camera & Image Capture
- `[DECISION]` **`image_picker`** (not the `camera` package) — handles permissions + capture, and **downscales on-device** via `maxWidth/maxHeight: 1568, imageQuality: 85` (SDD §2.4 Pillar 2). No full-res sensor upload.
- iOS: `NSCameraUsageDescription` + `NSPhotoLibraryUsageDescription` set. Android: `INTERNET` + `usesCleartextTraffic` (dev-only, for local Node).
- Image → `base64Encode` → `POST /analyze` (interim transport §2.3).

### 3.6 App Structure (implemented)
```
app/lib/
  main.dart              ProviderScope + SharedPreferences init
  theme.dart             cobalt tokens (AppColors) + Material3 theme
  models/{profile,analysis}.dart
  services/{api_client,profile_store}.dart
  providers.dart
  screens/{home,result,profile}_screen.dart
```
- `appUserId`: generated + persisted locally (ProfileStore); doubles as RevenueCat `app_user_id` until Supabase Auth.
- API base: `--dart-define=API_BASE=`, default `http://10.0.2.2:4242` (Android emu); iOS sim uses `localhost`.
- Supabase: `--dart-define=SUPABASE_URL/SUPABASE_ANON_KEY`; empty → init skipped (critique flow still runs).
- Onboarding/try-on stack: `camera/` (guided capture), `services/snapstyle_api.dart` (Storage upload + JWT calls + Realtime), `screens/onboarding_screen.dart`, `models/body_profile.dart`, `widgets/shimmer.dart`.

### 3.7 Guided Camera (Smart Capture) — implemented
`app/lib/camera/{guided_camera_screen,silhouette_overlay}.dart`. Uses the `camera` plugin (not image_picker — needs a live overlay).
- `SilhouetteOverlay` = `CustomPainter`: dimmed scrim with a punched-out body/face cutout (`BlendMode.clear`) + cobalt dashed guide. No image assets.
- `GuidedCaptureConfig` presets: `body` (onboarding, back lens), `mirrorSelfie` (front lens). Rotating hint chips ("Stand in a well-lit area", etc.). Pops the captured `XFile`.
- Permissions: iOS `NSCameraUsageDescription`; Android `CAMERA`.

### 3.8 Loading / Shimmer — implemented
`app/lib/widgets/shimmer.dart` — hand-rolled `Shimmer` (AnimationController + `ShaderMask` sweep) + `ShimmerBox`, no extra dependency. Onboarding shows a shimmer skeleton during "AI is analyzing your proportions…".

### 3.4 Async & Realtime
- Pattern for subscribing to analysis-result rows and mapping to UI state.

### 3.5 Performance Budget
- 60fps canvas/styling screen; jank-free image manipulation; memory ceiling for image buffers.

---

## 4. Node.js API Orchestration

### 4.1 Responsibilities
- Auth verification (Supabase JWT), request validation, Gemini prompt assembly, response schema validation, persistence, error/retry policy.

### 4.2 Endpoint Catalog
| Method | Path | Purpose | Auth (interim) |
|---|---|---|---|
| GET | `/health` | Liveness | none |
| GET | `/entitlement?appUserId=` | `{ pro, source, currentPeriodEnd, freeRemaining }` — client renders paywall from this | client appUserId → later JWT |
| POST | `/webhooks/revenuecat` | RevenueCat webhook (Authorization shared-secret) → re-verifies via REST, refreshes entitlement cache | RC shared secret |

Repo layout: `backend/` (Node), `app/` (Flutter, later), `web/` (landing, later).

### 4.3 Interim Store Note
`[DECISION — interim]` Entitlement + free-quota live in a server-side in-memory store (`backend/src/entitlement.js`). Non-persistent, single-instance. Migrate to a Supabase `entitlements` table when Supabase lands. Client `userId` is trusted for now → replace with verified Supabase JWT.

### 4.3 Async Job Lifecycle
- `queued → processing → succeeded | failed`, with retry + idempotency keys.

---

## 5. Gemini API Integration (Prompting & Analysis)

### 5.1 Model & Modality Strategy
- `[DECISION]` Model configurable via `GEMINI_MODEL`. Default `gemini-2.5-flash` (fast/cheap for iteration); `gemini-2.5-pro` = deep-analysis tier when prompt is calibrated.
- `[DECISION]` Direct REST (`v1beta/models/{model}:generateContent`), no SDK — minimal deps, key stays in Node.
- Image sent as `inlineData` (base64) in the user turn (interim transport, §2.3).

### 5.2 Structured Output Contract
- `[DECISION]` Gemini must return **strict JSON** validated against a schema server-side before persistence. Free-text advice lives inside typed fields.

### 5.3 Prompt Architecture — Stylist Persona (CORE IP)
- Since there is no commerce, **advice quality is the entire product.** The system prompt is the most valuable asset in the repo.
- System prompt = stylist persona + proportion-reasoning rubric + tone calibration + user profile context + image(s). Versioned.
- `[DECISION]` **Tone dial: "a friend who tells you the truth."** Honest and specific — never flattering, never harsh. Every critique pairs with a concrete, brand-agnostic change ("what's off" + "what to do instead").
- `[DECISION]` Advice must be **actionable and specific** (cut/color/silhouette/category), never vague ("looks great!") and never a purchase instruction.

### 5.4 Analysis Flows

**Fit & Proportion Analysis (Pillar 2) — implemented.** `backend/src/{gemini,stylistPrompt}.js` + `routes/analyze.js`.
```
POST /analyze { appUserId, image:{ data(base64), mimeType }, profile? }
  → gate: canAnalyze(appUserId)?  no → 402 { entitlement }   (client shows paywall)
  → Gemini generateContent (system persona + profile ctx + inlineData image)
       responseMimeType=application/json, responseSchema=ANALYSIS_SCHEMA
  → parse + (schema-enforced) validate
  → consumeFreeAnalysis()  [success only; no-op if pro]
  → 200 { analysis, model, promptVersion, entitlement }
  on error → 502, quota NOT burned
```

`ANALYSIS_SCHEMA` **v2 (hotspots, `stylist-v2-hotspots`)** — visual-first (SDD §9.4):
```jsonc
{
  "analyzable": true,
  "note": "…",                       // when analyzable=false, what photo is needed
  "overall": { "summary": "…", "score": 6 },   // score 1–10
  "hotspots": [                        // 3–6 pins placed ON the photo
    {
      "x_percent": 48, "y_percent": 82,        // 0–100 relative to image (top-left origin)
      "area": "ankle",                          // shoulders|chest|waist|hips|knee|ankle|shoes|overall
      "severity": "issue",                      // issue | tip | good
      "title": "Pants too long",                // ≤4 words
      "detail": "Full break pools fabric at the ankle.",
      "fix": "Hem to a slight break."           // brand-agnostic; never a product/brand/link
    }
  ]
}
```
- `[DECISION]` Feedback is **spatially anchored** — each issue carries `x_percent/y_percent` so Flutter renders a tappable pin on the photo. Replaces the old text-section schema.
- `[DECISION]` `analyzable=false` → model states what photo is needed, no hotspots, no fabrication.
- `fix` = brand-agnostic action only. No commerce (SDD §1.3).

### 5.5 AI Body Profiling (Onboarding) — implemented
`backend/src/visionProfile.js` + `backend/api/onboarding-profile.js`. Model default `gemini-2.5-pro` (`GEMINI_MODEL_PROFILE`), temp 0.3.
```
POST /api/onboarding-profile { photoPath, heightCm }  (Supabase JWT)
  → verify user; enforce photoPath in own <uid>/ folder
  → upsert style_profiles status=processing
  → signed URL → Gemini vision (height as scale anchor) → strict JSON
  → analyzable=false → 422; else upsert status=ready → 200 { profile, stylingNotes }
```
- `[DECISION]` **Measurements are estimates, not measurements.** Proportions/body-type reported normally; absolute cm returned ONLY as `{min,max}` + `confidence`. The prompt forbids single "measured" numbers; the UI labels them "approximate ranges." Accuracy + liability guardrail.
- `PROFILE_SCHEMA`: `analyzable`, `note`, `body_type` enum, `proportions{shoulder_to_hip,torso_to_leg,description}`, `estimated_measurements{chest/waist/hip/inseam_cm:{min,max}}`, `confidence`, `styling_notes[]`.

### 5.6 Virtual Try-On (Flow 2) — async pipeline, implemented
`backend/src/fal.js` + `backend/api/generate-look.js` + `backend/api/generation-webhook.js`.
```
POST /api/generate-look { photoPath, event }  (Supabase JWT)
  → gate entitlement (pro OR free_used<10) — else 402  [image-gen is costly]
  → insert generations row (type=tryon, status=queued)
  → fal queue submit w/ webhook (async) → external_id → status=processing
  → reserve credit on submit (fal bills regardless) → 202 { generationId }
[later] fal → POST /webhooks/generation?gen=<id>
  → download result → upload to `generations` bucket → row status=succeeded {image_path}
Flutter watches the row via Supabase Realtime (SnapstyleApi.watchGeneration).
```
- `[DECISION]` Never synchronous — exceeds serverless timeout (§2.3).

---

## 6. Data Models (Supabase / PostgreSQL)

### 6.1 Conventions
- `[DECISION]` RLS **on by default** for every user-owned table. `auth.uid()` scoping. Service-role used only from Node.js.
- UUID PKs, `created_at`/`updated_at` timestamptz, soft-delete where relevant.

### 6.2 Tables — `backend/supabase/migrations/0001_init.sql`
| Table | Purpose | RLS |
|---|---|---|
| `profiles` | 1:1 with `auth.users`; auto-created on signup (trigger) | owner read/update |
| `style_profiles` | AI body profiling: `height_cm`, `body_type`, `proportions` jsonb, `estimated_measurements` jsonb (ranges), `confidence`, `status` | owner **read**; writes = service role |
| `generations` | Flow 1 critique + Flow 2 try-on log: `type`, `status`, `input`, `output`, `provider`, `external_id` | owner **read**; writes = service role |
| `entitlements` | `pro`, `source`, `current_period_end`, `free_used` | owner **read only** (never client-writable) |

- `[DECISION]` AI-inferred + billing rows are **read-only to the client**; only the service-role backend writes them (un-forgeable). Signup trigger provisions `profiles` + `entitlements`.
- Storage: private buckets `body-photos`, `generations`; RLS restricts each user to their own `<uid>/…` folder.

---

## 7. User Profile & Personalization

The profile is the **context object injected into every analysis prompt** (`buildUserContext`, §5.4). Interim: client-owned, stored on-device, passed in the `/analyze` body as `profile?`. Target: a Supabase `profiles` row (RLS-scoped).

`[DECISION]` Profile shape (all fields optional — analysis works with none):
```jsonc
{
  "body": {
    "heightCm": 178,
    "build": "athletic",        // slim | average | athletic | curvy | plus
    "shoeSize": "43EU",
    "shoulderCm": 46, "waistCm": 82, "hipCm": 94, "inseamCm": 80  // optional
  },
  "fitPreference": "regular",   // slim | regular | relaxed | oversized
  "style": {
    "styles": ["minimal", "smart-casual"],
    "colors": ["navy", "warm neutrals"],
    "occasions": ["work", "weekend"],
    "dislikedCuts": ["skinny"]
  }
}
```
- `[DECISION]` **No `budget` field** — dropped with commerce. Sensitive body measurements never leave the analysis path (§10).

---

## 8. Monetization & Subscription

`[DECISION]` Product is **subscription-only**. No commerce, affiliate, or ads. The "shopping engine" pillar is removed.

### 8.1 Billing Stack — RevenueCat Only
`[DECISION]` **RevenueCat-only**, wrapping native StoreKit / Play Billing. **Stripe and all web billing are dropped** — web has no billing surface for us (landing page stays as a download driver only).
- Trade-off accepted: Apple/Google take **15–30%**; web was the only compliant way to avoid it. We forgo that margin for a single compliant path.
- Purchases happen **inside the Flutter app** (`purchases_flutter`). RevenueCat is the source of truth for `pro`.
- Server-side entitlement is a **cache** kept fresh by the RevenueCat **webhook**, which on each event re-fetches authoritative state via RevenueCat **REST** (`GET /subscribers/{app_user_id}`) — never inferred from event type (cancellation ≠ immediate loss; only expiry is).
- Node entitlement shape: `{ pro: bool, source: 'revenuecat', current_period_end, freeRemaining }`. Free-quota is server-owned; `pro` mirrors RevenueCat.
- `[DECISION]` No hand-rolled receipt validation/refunds/grace periods — RevenueCat owns it.
- Secrets: `REVENUECAT_API_KEY`, `REVENUECAT_WEBHOOK_AUTH`, `REVENUECAT_ENTITLEMENT_ID` (Node `.env`).
- **Testing caveat:** RevenueCat cannot be exercised via curl — requires the built Flutter app + App Store Connect / Play Console sandbox accounts. Billing flow is validated once the app exists.

### 8.2 Free-Tier / Conversion / Paywall
- `[DECISION]` **10 free reviews/generations** (lifetime, per account), server-counted, burned only on **success**. Applies to BOTH Fit Check (Journey A) and Wardrobe generation (Journey B).
- **Counter UI**: home shows "N free reviews left" (from `entitlementProvider.freeRemaining`).
- **Paywall interceptor** (`app/lib/paywall_gate.dart` → `ensureTokens`): wraps the camera CTA AND the occasion chips. When `freeRemaining==0 && !pro` → presents `PaywallScreen`, blocks the action.
- `[DECISION]` **Pricing tiers**: Monthly **$12.99/mo**, Yearly **$89.99/yr** (default-selected; ~$7.50/mo). `PaywallScreen` (`screens/paywall_screen.dart`). Purchase stubbed → RevenueCat (§8.1).
- Supabase `entitlements.plan` ∈ {monthly, yearly}; `free_reviews_left = 10 - free_used`.

### 8.3 Entitlement Enforcement
- Client shows paywall; **server (Node) enforces** the entitlement before spending a Gemini call. Never trust client-side gate alone.

---

## 9. Design System & Brand

### 9.1 Direction — Premium Editorial-Tech (monochrome + 1 signature)
- `[DECISION]` **Monochrome editorial-tech**, register like *Answear* / *aesthetic* / SHEIN. References: Answear (logo), aesthetic, ALTA.
- **Brand icon direction (strict):** fusion of a **mobile phone lens** + **fashion/selfie framing** with an AI edge. The mechanical aperture is **discarded**.
  - **Simplicity first** — strictly scalable; **no ticks, hairlines, or mechanical parts**. Must read clean at home-screen size. Only thick rounded strokes + solid shapes.
  - **Metaphor** — minimalist mobile-camera UI: **focus crop-marks (⌜ ⌝ ⌞ ⌟)** framing a clean lens (fashion/selfie framing nod).
  - **AI accent** — signature Electric Blue used STRICTLY as a **single glowing dot = the "AI Lens Pupil"** inside the lens, against the black/white brand.
  - Implemented: `LensMark` = 4 focus brackets + solid ink lens + one blue pupil (`widgets/wordmark.dart`, `_MarkPainter`).
- Wordmark: **`snapstyle`** split-weight (heavy `snap` + light `style`, tight tracking). `Logo` = mark + wordmark. _Baloo 2 + aperture experiments reverted per user._
- `[DECISION]` **Single signature accent = Electric Blue `#2E5BFF`**, used SPARINGLY (10% rule): logo period, AI/sparkle icons only — never on surfaces/text. Flip to Acid Lime `#C7F026` via one token.
- Dials: product register, VARIANCE 4 / MOTION 3 / DENSITY 5.

### 9.2 Color Tokens (`app/lib/theme.dart` → AppColors)
| Token | Value | Use |
|---|---|---|
| `bg` | `#F8F8F8` | subtle off-white base (not pure #fff) |
| `surface` | `#EFEFEE` | light-grey cards / inputs |
| `surfaceHi` | `#FFFFFF` | 1px top highlight on inset cards |
| `ink` | `#0A0A0A` | text + **primary buttons (matte black)** |
| `muted` | `#8C8C88` | secondary text |
| `line` | `#E4E4E1` | hairlines |
| `signature` | `#2E5BFF` | **electric blue — logo period + AI/sparkle icons only** |
| `flag` | `#9B2C2C` | functional priority (desaturated) |
- `accent` aliased to `ink`; no color on surfaces/text.

### 9.6 Surface & Texture
- `[DECISION]` **Noise overlay** (`widgets/noise_overlay.dart`): ~3% black points, stable seed, painted once, layered app-wide via `MaterialApp.builder` as `IgnorePointer`. Premium tactile grain.
- `[DECISION]` **Micro-neumorphic card** (`AppDecorations.neuCard`): light-grey top→bottom gradient, 1px white top highlight, graded side/bottom borders, soft outer lift + white inner-top hairline shadow (Flutter has no true inset shadow — refined approximation). Used on secondary cards (e.g. "Build your body profile").
- `[DECISION]` **Primary CTA** stays matte black; only the **sparkle icon** uses `signature` (draws the eye, keeps monochrome).
- Typography: `google_fonts` (Baloo 2 for the wordmark); massive tightly-tracked sans headers unchanged (`AppType.display`).

### 9.3 App Structure (redesign)
- `HomeShell` = bottom nav (Style / Wardrobe / Profile), each tab its own Scaffold.
- Capture: one primary CTA → bottom sheet (camera/gallery). Camera = custom `GuidedCameraScreen` (SafeArea, silhouette overlay, hint cluster, pill title) → branded `ConfirmPhotoScreen` (BoxFit.cover) → `ProcessingScreen` (scan animation + rotating status) → result.
- `WardrobeScreen` = history placeholder (Phase 3).

### 9.4 Result Screen — Editorial-AR / Clean Canvas — implemented
`app/lib/screens/result_screen.dart`. **Overrides the spotlight/big-callout version.** Layout = `Column[ Expanded(photo Z-stack), BottomRail ]`.
- **Clean canvas by default**: photo (`Image.memory` cover, `AspectRatio` box) + floating **pins only**. No overlays, no dimming, no big container.
- **Pins** (`_Pin`, LayoutBuilder pixel coords from `x/y_percent`): tap → sets active hotspot; active pin enlarges/ring-thickens. Tap empty photo → deselect.
- **Tooltip bubble** (`_Tooltip`): small custom bubble with a **caret pointer** toward the pin (above if pin is low, below if high; x-clamped). Core feedback ONLY — severity label + title. Editorial type.
- **Bottom Rail** (`_BottomRail`, persistent): nothing selected → overall verdict + "tap a pin"; pin selected → **updates** to that pin's `title` + a horizontal carousel = a black **"THE FIX"** text card (`_FixCard`) + look-suggestion image cards (`_LookCard`, shown once generated).
- `callout_type` = hotspot `severity` (issue → flag; tip/good → suggestion) — no separate field.
- **No price / cart / buy / shop** anywhere — look inspiration only (§1.3).
- Score badge (normalized 1–10) + back over the photo. Responsive: `Column`+`Expanded`+horizontal `ListView`, no `RenderFlex` overflow.
- Image bytes threaded capture → `ProcessingScreen` → `ResultScreen(imageBytes)`.
- `[DECISION]` No product/upsell in pins — `fix` is brand-agnostic advice only (§1.3).
- **Look-suggestion carousel**: pin sheet shows a horizontal carousel of generated look references ONLY once images exist (`imageUrl != null`). No perpetual "generating" placeholders — hidden until ready. `[target]` generation runs during the processing phase (fal); the result opens fully populated. Carousel items are inspiration, never shoppable.
- `[DECISION]` **Score is normalized client-side** to 1–10 (`_score`): a stray 0–100 value (e.g. 75) is divided down so the badge never shows "75/10".

### 9.7 Splash (branded)
- `screens/splash_screen.dart`: full lockup — `LensMark` + `snapstyle` wordmark + "YOUR AI STYLIST" — calm fade/rise, then routes to auth/home after ~1.5s. Native Android-12 splash shows the icon only; this Flutter splash adds the **name**.
- Onboarding media mocks calmed (single detection frame + slow scan; subtle pin breathing) — earlier version read cheap/janky.
- Note: the teal touch trails seen on-device are the emulator's "Pointer location / Show taps" dev overlay, not app UI.

### 9.5 Processing Screen (fixed)
Centered full-body silhouette, scan band **clipped to the silhouette** + sweeping line, rotating status text. Replaces the earlier off-center render.

---

## 10. Security & Compliance

- `[DECISION]` User photos are PII/biometric-adjacent → private Storage buckets, signed URLs, no public access, RLS-scoped.
- `[OPEN]` Retention policy for uploaded body photos + right-to-delete flow.
- `[OPEN]` Consent capture before first photo analysis.

---

## 11. Web Landing Page — built

- `web/index.html` — **single self-contained static file** (hand-crafted CSS, zero build/deps), B&W editorial to match the app: `snapstyle` logo (inline SVG LensMark), oversized tight-tracked hero "How does it really look?" with the electric-blue `?` accent, phone mock (score badge + pulsing pins + ISSUE callout), 3-step "how it works", closing CTA, App Store / Google Play buttons. Single goal: download conversion. No app logic.
- `[DECISION]` **Host: Cloudflare Pages** (free tier; not Vercel). Deploy: `npx wrangler pages deploy web --project-name=snapstyle` (see `web/DEPLOY.md`). Verified premium on desktop + mobile (375px) via preview.
- Chose hand-crafted CSS over a Tailwind build to keep it a zero-dependency static file (trivial CF Pages deploy).

---

## 12. Non-Functional Requirements

- Latency targets for analysis round-trip, cost ceiling per analysis, offline behavior, observability/logging.

---

## 14. Onboarding, Routing & Two Journeys (design — Phase next, needs Supabase Auth)

### 14.1 State & Routing
- `[DECISION]` **Riverpod + GoRouter**. A `sessionProvider` exposes `{ authed, hasHeight }` (from Supabase Auth + `style_profiles.height_cm`). GoRouter `redirect` gates:
  - not authed → `/onboarding/auth`; authed but no height → `/onboarding/body`; else → `/`.
- `[DECISION]` **Hard gate fallback**: if any core action fires without a height, show a **non-dismissible** bottom sheet (`isDismissible:false, enableDrag:false`) demanding height before proceeding.

### 14.2 Onboarding Flow
1. **Value prop + Auth** — swipeable intro → Supabase Auth (email + Apple/Google OAuth).
2. **Body profile (hard gate)** — **height required**; optional baseline full-body photo + preferred style. Height → `style_profiles`; feeds every Gemini prompt as system context.

### 14.3 Main Screen (Style tab) — two intents, no clutter — IMPLEMENTED
- **Primary — Fit Check**: solid black CTA "Review my outfit" (signature sparkle icon) → token gate → source sheet (camera/gallery) → Journey A. `home_screen.dart`.
- **Secondary — "What should I wear?"** card (`_WardrobeCard`) → bottom sheet with occasion chips (Office / Date / Pub / Active / Hot weather) → token gate → Journey B. `[stub]` generation blocked on Digital Wardrobe (§14.5); chip currently opens a "coming next" sheet.
- Then the "Build your body profile" card (onboarding entry).
- Both primary + occasion actions pass through `ensureTokens` (§8.2).

### 14.2b Onboarding & Auth — IMPLEMENTED (local stub)
- `AuthScreen` (`screens/auth_screen.dart`): swipeable value-prop intro (PageView) → auth page with Email/Password + **"Continue with Google" (stub)**. On continue → `ProfileStore.setSignedIn(true)` → `HomeShell`.
- Routing: `main.dart` shows `AuthScreen` when `!signedIn`, else `HomeShell`.
- `[target]` Replace stub with **Supabase Auth** (email/pass + Google OAuth) + GoRouter hard height-gate (§14.1) when Supabase is on.

### 14.4 Journey A — Fit Check (photo)
`photo + height + wardrobe metadata → Gemini` → evaluates the item's fit + whether it matches owned pieces → visual hotspots result (§9.4).

### 14.5 Journey B — Style Panic (occasion, no camera)
`tap occasion chip → Node queries the user's Digital Wardrobe (Supabase) → sends inventory + occasion → Gemini` → **complete outfit using ONLY owned items**. `[BLOCKED]` needs the Digital Wardrobe (catalogued items) — not built yet.
- `[OPEN]` Wardrobe ingestion (add items + Gemini Flash auto-catalog, §2.4 Pillar 1) is the prerequisite for Journey B.

## 13. Decision Log

| Date | Decision | Rationale |
|---|---|---|
| 2026-07-03 | Gemini server-side only | Key security + billing control |
| 2026-07-03 | Direct client→Storage image upload | Keep Node light, avoid double upload |
| 2026-07-03 | Async analysis via Realtime | Mobile network resilience |
| 2026-07-03 | Strict JSON from Gemini | Deterministic persistence |
| 2026-07-03 | RLS-on-by-default | Fintech-grade data isolation |
| 2026-07-03 | Cobalt accent (not lime) | Brand direction from reference |
| 2026-07-03 | Supabase deferred; interim = Isar + local cache + sync Node | Ship AI loop first; swap in Supabase as layers later |
| 2026-07-03 | Node proxy stays even without Supabase | It is the security boundary holding `GEMINI_API_KEY` |
| 2026-07-03 | Secrets only in `.env`, never in doc/code/git | Pasted key treated as compromised → rotate |
| 2026-07-03 | Auto-catalog wardrobe items with Gemini Flash on add | Structured attrs enable Pillar 3 without re-sending images |
| 2026-07-03 | Coordination reasons over text attrs, not images | Cheap, fast, deterministic; images only for true visual match |
| 2026-07-03 | LLM emits recommendation_intent, not real SKUs/prices | Kills price/discount hallucination; decouples analysis from commerce |
| 2026-07-03 | Model tiering: Flash (catalog) vs Pro (deep analysis) | Latency + cost control |
| 2026-07-03 | PIVOT: pure AI stylist, no commerce/affiliate/ads | Value = honest advice; simplifies backend, removes catalog + price hallucination |
| 2026-07-03 | Subscription via RevenueCat; server-enforced entitlement | Don't hand-roll IAP; gate Gemini spend server-side |
| 2026-07-03 | Stylist persona = core IP; tone = "friend who tells the truth" | With no commerce, advice quality is the whole product |
| 2026-07-03 | Free tier = 10 lifetime analyses, server-counted, burn on success only | Habit-building runway before paywall; no client-side trust |
| 2026-07-03 | ~~Hybrid billing (Stripe web + RevenueCat)~~ **REVERSED** | Web has no billing value for us |
| 2026-07-03 | **RevenueCat-only** billing; Stripe/web dropped | Single compliant in-app path; accept 15–30% store fee; no web billing surface |
| 2026-07-03 | Webhook re-verifies via RevenueCat REST, not event type | Cancellation ≠ immediate loss; only expiry revokes access |
| 2026-07-03 | Backend = Express only (`backend/`); Stripe code removed | Gemini-gate entitlement layer stays, now fed by RevenueCat |
| 2026-07-03 | Gemini via direct REST, no SDK; model via `GEMINI_MODEL` (flash default) | Minimal deps, key server-side, tier switchable |
| 2026-07-03 | Strict JSON via responseSchema (not prompt-only) | Model can't emit invalid structure; deterministic persistence |
| 2026-07-03 | `/analyze` gates before spend, burns quota only on success | Never charge users for our failures; no client trust |
| 2026-07-03 | Pillar 2 & Pillar 4 share one analysis JSON (`suggestions[]`) | No separate commerce call; advice is the product |
| 2026-07-03 | Stylist persona versioned (`stylist-v1`) as core IP file | Advice quality is the whole product; iterate deliberately |
| 2026-07-03 | Profile shape locked (§7), `budget` dropped | Client-owned context object; no commerce field |
| 2026-07-03 | Flutter stack: Riverpod + image_picker + http + shared_preferences | Lean; image_picker also does on-device downscale |
| 2026-07-03 | Profile in shared_preferences, Isar reserved for wardrobe | One small object needs no codegen/DB |
| 2026-07-03 | Flutter app scaffolded (`app/`), core loop built, analyze clean | Capture → /analyze → advice cards, cobalt accent |
| 2026-07-03 | Product renamed → **Snapstyle** (display, package, prompt) | Bundle id `com.fitgestion.*` + repo folder deferred (separate native step) |
| 2026-07-03 | **Supabase activated** (Auth/DB/Storage/Realtime); schema + RLS live | Interim in-memory store retired; client uid from auth |
| 2026-07-03 | Serverless target = Vercel functions (`api/`), Express mounts for dev | Handlers share `(req,res)` signature — write once |
| 2026-07-03 | Try-on is async (fal webhook + Realtime), never sync | Image-gen exceeds serverless timeout |
| 2026-07-03 | Body profiling: proportions confident, measurements as ranges+confidence | Vision LLM can't measure; accuracy + liability guardrail |
| 2026-07-03 | Gemini 1.5 → 2.5 (pro for profiling, flash for critique) | 1.5 legacy; 2.5 current |
| 2026-07-03 | Guided camera via `camera` plugin + CustomPainter silhouette | image_picker can't overlay; live guidance needed |
| 2026-07-03 | AI + billing rows read-only to client (service-role writes) | Un-forgeable inferred/subscription data |
| 2026-07-03 | **Local dev mode**: run on `GEMINI_API_KEY` alone; Supabase/fal deferred again | Lazy Supabase client; base64 onboarding-local route; cloud routes 501 locally |
| 2026-07-03 | **Redesign → black & white editorial**; cobalt dropped | aesthetic/SHEIN register; `theme.dart` reskin, wordmark logo |
| 2026-07-03 | Commerce stays cut; **add AI look-gen (image) as inspiration only** | No affiliate/brands/links ever; reuses fal image-gen |
| 2026-07-03 | Home: single CTA + source bottom sheet; bottom nav (Style/Wardrobe/Profile) | Fixes action hierarchy, header alignment, dangling CTA |
| 2026-07-03 | Custom Flutter camera+confirm replaces system camera UI | Seamless UX; BoxFit.cover; SafeArea; branded confirm |
| 2026-07-03 | Added ProcessingScreen (scan anim + rotating text) | Fills the 3–5s Gemini gap with intelligence cue |
| 2026-07-03 | Result screen → **visual-first hotspots** on the photo; schema v2 | Kills the text-wall; feedback spatially anchored |
| 2026-07-03 | Gemini returns `hotspots[]` with `x/y_percent` coords | Flutter renders tappable pins from relative coords |
| 2026-07-03 | Onboarding gating via Riverpod + GoRouter redirect; hard height gate | Height is mandatory for the proportion engine |
| 2026-07-03 | Two journeys: A Fit-Check (photo) / B Style-Panic (occasion→owned wardrobe) | B blocked on Digital Wardrobe ingestion |
| 2026-07-03 | Premium tokens: `snapstyle.` Baloo2 wordmark, electric-blue signature, noise, neu cards | Editorial-tech identity (Answear ref) |
| 2026-07-03 | Signature accent used SPARINGLY (logo period + sparkle only) | Keeps monochrome; 10% rule |
| 2026-07-03 | Onboarding photo step = camera OR gallery upload | Height valid → source bottom sheet |
| 2026-07-03 | Logo = LensMark (aperture + measurement bezel, blue center) + split-weight wordmark; Baloo2 reverted | User preferred prior wordmark + wanted a lens/measurement mark |
| 2026-07-03 | LensMark simplified to 4 cardinal ticks | "проще" — reads as lens, not gear |
| 2026-07-03 | Icon redesigned → focus crop-marks + solid lens + single blue AI pupil; aperture discarded | Strict scalable icon; phone-lens ⨯ selfie framing, no mechanical parts |
| 2026-07-03 | Launcher icon generated (flutter_launcher_icons) from the mark | Android adaptive + iOS |
| 2026-07-03 | Onboarding = "show don't tell": 60% animated media mock / 40% copy+CTA | Scan mock + pins mock, page dots |
| 2026-07-03 | Result → AR-Editorial: Z-stack, spotlight, frosted tethered callouts; bottom sheet removed | No sheet obscuring photo; dim-to-0.6 + bright pin |
| 2026-07-03 | Commerce re-requested (Add to Cart/Price) → REJECTED again; look cards only | Locked no-commerce; user reconfirmed "no sales/buy" |
| 2026-07-03 | Branded Flutter splash (mark + wordmark + name); onboarding mocks calmed | Native splash = icon only; add name; janky anim toned down |
| 2026-07-03 | Result → Editorial-AR / Clean Canvas: pins + tooltip bubble + persistent Bottom Rail | Killed big floating card; rail updates per selected pin |
| 2026-07-04 | Shoppable "THE FIX" (product_recommendations{price,url,brand,Shop}) re-requested → REJECTED (5th) | User reconfirmed pure-stylist; Bottom Rail stays look-only. No product schema. LLM can't return real url/price anyway |
| 2026-07-04 | ~~Supabase = schema inside Motixi~~ **REVERSED** → dedicated Snapstyle project | User has paid org; separate project = clean isolation, no later migration. Back to public schema + auth trigger + body-photos/generations buckets |
| 2026-07-04 | Web landing built (`web/index.html`), host on Cloudflare Pages (not Vercel) | Zero-dep static, B&W editorial; free CF tier; verified desktop+mobile |
| 2026-07-03 | Pin bottom sheet gets look-suggestion carousel (gen prompts, NOT shop) | Visual solution; image via fal later; no commerce |
| 2026-07-03 | Paywall: Monthly $12.99 / Yearly $89.99; `ensureTokens` interceptor at 0 | Trial=10; gate camera + occasion chips |
| 2026-07-03 | Main split: Fit Check CTA + "What should I wear?" wardrobe card | Two intents, no clutter |
| 2026-07-03 | Onboarding intro + auth stub (email/pass + Google stub), local signedIn flag | Real Supabase Auth deferred |
