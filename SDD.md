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

### 5.6a Structural constraints — fixing the "floating head" / proportion mismatch
`[REQUIREMENT 2026-07-07]` Generated full-body renders MUST match the user's true build — no pasted-on head over generic-model shoulders. The backend enforces structural constraints **before inpainting**:
1. **Keypoint extraction** from the user's source photo — at minimum **neck** (base + width) and **shoulder** (L/R acromion) keypoints (MediaPipe Pose or equivalent), computed server-side at upload/onboarding and cached with the body profile.
2. **Conditioning** — the keypoints are passed into the diffusion step as hard structure:
   - **ControlNet (OpenPose)** for the skeleton (shoulder line/angle, neck position), optionally **ControlNet (Depth)** for volume; and/or
   - an **IP-Adapter** step carrying the user's head+neck crop as an identity/structure reference.
   This forces the generated **collar and shoulders to match the user's real neck width and shoulder angle** — the garment is fitted to the skeleton instead of the head being fitted to a generic garment.
3. **Providers** — applies to any diffusion path (fal.ai `flux`/Kontext pipelines expose ControlNet/IP-Adapter). The current **Gemini image** path (§15 `generate-look`) cannot take ControlNet inputs; interim mitigation = prompt-level constraints ("keep face, hair, body, pose identical") + the §P0-3 validity gate. When quality demands exceed prompt-level control, route try-on through the fal path with the constraints above.

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

## 11. Web Landing Page — built (v2: multi-step walkthrough + i18n)

`[V2 2026-07-04]` **Revolut-style product walkthrough + 7-language i18n.** Still one self-contained static file (`web/index.html`, zero build/deps).
- **Structure**: hero (device = real `app-result.jpg`) → 3 alternating feature blocks (Revolut pattern: eyebrow + big headline + lead + phone screenshot; block 2 adds a blue-check list) using **real in-app screenshots** `web/app-{home,result,look}.jpg` (captured from the iOS build) → editorial 3-step "how it works" → isolated closing tagline → footer.
- **i18n**: pure-JS, self-contained. `data-i18n` keys + `I18N` dict; `apply(lang)` swaps `textContent`, sets `<html lang>` + `document.title`, persists `localStorage`. Language `<select>` in header + footer; default = `navigator.language` → fallback `en`. `.accent-last` elements get their final char wrapped in the blue `.dot` (keeps the signature blue `?`/`.` across scripts). **Markets/langs: English, Українська, Español, Français, 中文, ไทย, Tiếng Việt.** `[VERIFIED]` en + zh render correctly incl. blue accent; feature blocks + alternation OK in preview.
- `[DEPLOYED 2026-07-04]` **v2 is LIVE at https://snapstyle.pages.dev** (verified: 35 i18n strings, feature blocks, `app-{home,result,look}.jpg` all 200, lang selector, Українська). Deployed with a dedicated **`snapstyle_pages`** Pages-Write token via `npx wrangler@3 pages deploy web --project-name=snapstyle --commit-dirty=true`. `[SECURITY]` that token was pasted in chat → ROTATE before prod (with the other chat-pasted secrets).

## 11.0 Web Landing Page — v1 (superseded)

- `web/index.html` — **single self-contained static file** (hand-crafted CSS, zero build/deps), B&W editorial to match the app. Single goal: download conversion. No app logic.
- `[DECISION]` **Host: Cloudflare Pages** (free tier; not Vercel). Deploy: `npx wrangler pages deploy web --project-name=snapstyle` (see `web/DEPLOY.md`). Verified premium on desktop + mobile (375px) via preview.
- Chose hand-crafted CSS over a Tailwind build to keep it a zero-dependency static file (trivial CF Pages deploy).
- `[HIGH-FIDELITY PASS 2026-07-04]` upgraded to Vercel/Linear polish level (visual-verified, NOT yet redeployed):
  - **Logo → lens mark + tight wordmark** `[lens] snapstyle.` — LensMark icon (crop-marks + electric-blue AI pupil) restored **before** the text (owner override of the critique's "drop the icon"); wordmark one word, lowercase, `font-weight:800`, `-.045em`, blue period. Wordmark wrapped in its own `<span>` so the flex `gap` (icon spacing) doesn't push the period off the text.
  - **Device screen → REAL in-app screenshot** `web/app-result.jpg` (the actual Flutter `ResultScreen`: photo + score 6/10 + 5 hotspot pins + verdict rail), replacing the blank placeholder. Captured via a marketing harness in the app: `--dart-define=DEMO=result` → `main()` renders `DemoResultScreen` (loads bundled `assets/demo/fit.jpg` + captured real `fit.json` → `AnalysisResult.fromResponse` → `ResultScreen`). Harness is gated by the define; the demo assets ship in the bundle (~105KB) — strip before store release if desired.
  - **Device mock → sleek white hardware**: white body, hairline `1px rgba(10,10,10,.07)` border, layered soft shadow (`0 44px 88px -20px …`), inner bezel highlight, dynamic-island pill. Replaces the old chunky `#111` slab.
  - **Pins → electric-blue (#2E5BFF) + pulsing "AI activity" ring** (`ping` keyframe, staggered delays). Was flat black.
  - **Steps 01/02/03 → editorial**: no fills, transparent cards split by hairline vertical dividers (horizontal on mobile); blue tracked numbers, typography-led. No gray boxes.
  - **Tagline** "Dress like someone told you the truth." → isolated, `padding:160px` (py-40), oversized `clamp(36px,6.5vw,72px)`.
  - `[NOTE]` the preview MCP server cached a stale snapshot; verified against a direct `python -m http.server` on the `web/` dir (pin `rgb(46,91,255)`, card bg transparent, close pad 160px, no h-overflow).

### 11.1 Design System — "Extreme Editorial Minimalism"
- **Type:** massive ultra-condensed heavy/black headings (`font-black tracking-[-0.04em]`, clamp sizing); body in SF Pro / system (`font-sans`). `[DECISION]` Inter allowed for BODY only — never headings+body both (AI-slop rule).
- **Whitespace:** extreme (`py-24 md:py-40`, generous `gap`); content breathes.
- **Color:** bg `#F8F8F8`, ink `#0A0A0A`. **Electric Blue `#2E5BFF` is the ONLY accent** — reserved for interactive AI elements (pins) + primary CTA.
- **Texture / Invisible UI:** ~1.5% CSS noise overlay; no heavy borders/solid boxes — soft layered shadows + glassmorphism (`backdrop-blur`) for floating elements.
- **Tailwind presets** (`tailwind.config` → theme.extend): `colors:{bg:'#F8F8F8',ink:'#0A0A0A',signature:'#2E5BFF'}`, `boxShadow:{ soft:'0 4px 12px rgb(0 0 0/.06),0 12px 32px rgb(0 0 0/.08)', float:'0 20px 60px rgb(0 0 0/.12)' }`.
  - Noise: `<div class="pointer-events-none fixed inset-0 z-50 opacity-[0.015] bg-[url('/noise.svg')] bg-repeat"/>`
  - Glass card: `bg-white/70 backdrop-blur-xl border border-white/40 shadow-float rounded-2xl`

### 11.2 Component Architecture (Next.js App Router, `output:'export'` → same CF Pages)
```
app/layout.tsx     fonts (condensed display + SF/Inter body), <NoiseOverlay/>, metadata/OG
app/page.tsx       composes sections
components/ Hero · InteractiveDemo('use client') · ValueProps · EditorialGrid · FinalCTA · Footer
  ui/ StoreButton · PhoneMock · Pin · GlassCard · Wordmark(SVG mark)
```

### 11.3 Interactive Demo — web "Show, Don't Tell"
- `InteractiveDemo` client: `useState active pin`. Outfit photo fills block; `Pin[]` absolute-positioned by `%`, glowing `bg-signature` dot + `animate-ping` ring; `onClick`→setActive.
- Active → `GlassTooltip` "blooms" near pin (`origin-top scale-95 opacity-0 → scale-100 opacity-100`, `transition-all duration-300 ease-out`; reduced-motion skips). Glass = `backdrop-blur-xl bg-white/70 shadow-float`.
- Content: severity tag + short title + horizontal **look-suggestion carousel** (`flex overflow-x-auto snap-x gap-3`, cards = generated look image + caption). `[DECISION]` NO price/brand/Shop/buy — inspiration only (§1.3).
- Outside/Esc closes; another pin re-targets.
- `[DECISION]` Pragmatic: this demo can be added to the **current static landing in ~40 lines vanilla JS** (no build) — preferred unless the marketing site grows multi-page.

### 11.4 Flow
Hero ("Stop guessing. Start styling." + sub + floating iPhone mock of the Result screen + store buttons) → Interactive Demo → 3 Value Props (Instant Fit Check / Wardrobe Synergy / Style Panic) → Editorial Before/After masonry ("Honest, not flattering") → Final CTA ("Ready to elevate your look?") → minimalist Footer. Sole goal: store-download conversion.

---

## 12. Non-Functional Requirements

- Latency targets for analysis round-trip, cost ceiling per analysis, offline behavior, observability/logging.

---

## 15. Deploy & Hosting (backlog)

`[DECISION]` Target hosting = **Cloudflare + Supabase, no Vercel, no separate Node host.**
- **Landing → Cloudflare Pages — LIVE** at **https://snapstyle.pages.dev** (project `snapstyle`, account petrov.cpay@gmail.com). Redeploy: `wrangler pages deploy web --project-name=snapstyle`. Optional Git-connect to `Jovial1989/SnapStyle` for auto-deploy on push (output dir `web`).
- **Backend/API → Cloudflare Workers** — Hono worker (`backend/worker.js`) **deployed & live** at `https://snapstyle-api.snapstyle-jovial.workers.dev` (`/health` 200 ✓). Deployed via direct CF API (`scripts/deploy-worker.js`), not wrangler (wrangler broke: latest needs Node 22; account-scoped `cfat_` tokens fail wrangler's `/memberships`). Secrets as `secret_text` bindings in the deploy metadata.
  - `[BLOCKER]` **Gemini API geo-blocks the Cloudflare Worker egress**: `400 "User location is not supported"`. Key works from the Mac + Supabase test, but NOT from the CF edge PoP. So **AI (Gemini) calls cannot run on CF Workers** as-is.
  - `[DECISION]` **Move the AI-calling backend to Supabase Edge Functions** (project region = Mumbai/ap-south-1, where Gemini IS supported). Non-AI routes (health) may stay on Workers, but simpler to keep the whole API on Edge Functions. Alternatives: Vertex AI (region-pinned, needs GCP SA) or a small US/EU host.
  - `pg` stays a local setup-only tool (no TCP on Workers).
- **AI backend → Supabase Edge Functions — FULL BACKEND PORTED, DEPLOYED & VERIFIED ✓.** Region Mumbai/ap-south-1 (Gemini-supported). Base: `https://tnirnwapfgckfypvtooj.supabase.co/functions/v1`. Deno, shared modules under `backend/supabase/functions/_shared/` (`http.ts`, `supabase.ts` = admin+getUser+quota, `gemini.ts` = prompts/schemas mirroring `stylistPrompt.js`+`visionProfile.js`).
  - `analyze` — Flow 1 critique. **verify_jwt ON.** `{ image:{data(b64),mimeType}, profile? }` → `{ analysis, model, promptVersion, generationId, entitlement }`. Auth via user JWT → gate on `entitlements` → **fetches the user's `style_profiles` (height/body_type/proportions/measurement ranges) and merges it with the client `profile` preferences into the Gemini context** so the audit factors in the body profile → Gemini → burn 1 free credit on success only. **Persists to history** (best-effort): uploads the photo to `generations/<uid>/<id>.jpg` + inserts a `generations` row `{type:'critique', output:{image_path, analysis, model, promptVersion}}`.
  - `onboarding-profile` — body profiling. **verify_jwt ON.** `{ photoPath, heightCm }` → upserts `style_profiles`. Enforces `photoPath` starts with `<uid>/`.
  - `generate-look` — Flow 2 look-gen (**try-on: restyle the user's OWN photo for an occasion, identity-preserving**). **verify_jwt ON.** `{ photoPath, event(occasion) }` → **200** `{ generationId, imagePath, occasion }`. **SYNCHRONOUS** (~15–20s), no queue/webhook. Uses **Gemini 2.5 Flash Image** (`GEMINI_IMAGE_MODEL`, default `gemini-2.5-flash-image`) via the existing `GEMINI_API_KEY`; prompt = brand-agnostic per-occasion wardrobe map + `style_profiles.body_type`; result PNG uploaded to `generations` bucket; burns 1 credit on success only. `[DECISION 2026-07-04]` **provider = Gemini image, NOT fal** — owner unfamiliar with fal + already on Gemini; no new account/key/billing, stays Supabase+Gemini. fal (`fal-ai/flux-pro/kontext`) dropped. `[DECISION]` look-gen = on-user try-on (over neutral-figure). `[VERIFIED E2E]` anon user → upload body photo → generate-look = 200 (~19s), real identity-preserving date-night look in `generations` bucket, `free_used`=1.
  - `generation-webhook?gen=<id>` — fal callback. **--no-verify-jwt** (fal has no JWT). Stores result in `generations` bucket, flips row succeeded/failed.
  - `[RESOLVED]` **Gemini geo works from Edge Functions** — CF-Worker geo-block bypassed. **CF Workers dropped for AI**; CF keeps Pages (landing) only. Vertex AI not needed.
  - `[VERIFIED end-to-end]` created test user → signed in → `analyze` with JWT = **200** (score 7, 4 hotspots, ~24s); no-token = **401**; DB `free_used` = 1 (server-authoritative burn). JWT alone passes the gateway (apikey optional; our `getUser` is the real gate).
  - Deploy: standalone Supabase CLI `~/.local/bin/supabase` (v2.109.0 — brew bypassed, needed Xcode CLT). `supabase functions deploy <fn> --project-ref <ref> --use-api [--no-verify-jwt]` with `SUPABASE_ACCESS_TOKEN` env. Secrets set: `GEMINI_API_KEY`, `GEMINI_MODEL`.
- **Flutter cloud client wired** — `app/lib/services/snapstyle_api.dart` now targets `${SUPABASE_URL}/functions/v1/*` (raw http + user JWT), exposes `analyze` / `onboardingProfile` / `generateLook` / `uploadPhoto` / `watchGeneration`. `flutter analyze` clean. **NOT yet used by the UI** — `home_screen`/`onboarding` still call the local `ApiClient` (base64, appUserId) for emulator play. Flipping the UI onto the cloud client is blocked on real Supabase Auth (need a session/JWT).
- **iOS build — BUILT, INSTALLED & RUNNING on iPhone simulator ✓ (2026-07-04).** Xcode 26.4.1. Cloud path verified live: home screen renders, "10 free reviews left" = entitlement read for the anonymous user.
  - Build (simulator, debug): `flutter build ios --simulator --debug --dart-define=SUPABASE_URL=… --dart-define=SUPABASE_ANON_KEY=sb_publishable_…` (LANG=en_US.UTF-8 for CocoaPods). Artifact: `build/ios/iphonesimulator/Runner.app`.
  - Install/run: `xcrun simctl install <dev> Runner.app && xcrun simctl launch <dev> com.fitgestion.fitgestion`. Sim used: "iPhone 16 Payn".
  - `[NOTE]` first cold launch after install is slow (~30–45s: debug JIT compiles the kernel; iOS shows a launch spinner). Warm relaunches are instant. A `--profile`/`--release` build (AOT) starts fast.
  - `[TODO pre-release]` bundle id + display name still `com.fitgestion.fitgestion` → rename to Snapstyle.
  - `[VERIFIED]` anonymous session E2E: `POST /auth/v1/signup {}` → `is_anonymous=true` → trigger provisioned `entitlements` (free_used=0) → `analyze` with anon JWT = 200 (score 6, freeRemaining=9). Dummy login fully wires the cloud.
- **Supabase** already live for auth/db/storage (§2.3.2).
- Backlog order: (1) **wire Flutter → real Supabase Auth** (email + Google) — unblocks the cloud client; then repoint `home_screen`/`onboarding` from `ApiClient` → `SnapstyleApi`; (2) set `FAL_KEY` secret + wire fal look-gen; (3) RevenueCat entitlement sync (pro flag) via webhook EF; (4) Digital Wardrobe (Journey B).
- `[SECURITY / TODO before prod]` all EFs authed EXCEPT `generation-webhook` (add fal HMAC signature check). Rotate all chat-pasted secrets before release.

## 14. Onboarding, Routing & Two Journeys (design — Phase next, needs Supabase Auth)

### 14.1 State & Routing
- `[DECISION]` **Riverpod + GoRouter**. A `sessionProvider` exposes `{ authed, hasHeight }` (from Supabase Auth + `style_profiles.height_cm`). GoRouter `redirect` gates:
  - not authed → `/onboarding/auth`; authed but no height → `/onboarding/body`; else → `/`.
- `[DECISION]` **Hard gate fallback**: if any core action fires without a height, show a **non-dismissible** bottom sheet (`isDismissible:false, enableDrag:false`) demanding height before proceeding.

### 14.2 Onboarding Flow — IMPLEMENTED (build → estimate → confirm)
1. **Value prop + Auth** — swipeable intro → dummy anon session (§14.2b).
2. **Body profile** — offered **right after sign-up, skippable** (`AuthScreen._finish` → `OnboardingScreen(skippable:true)` if `!hasBodyProfile`, then Home). Builder flow: **height (required)** → full-body photo (camera/gallery) → **AI estimate** (`onboarding-profile` EF, sets `style_profiles` ready) → **user confirms/corrects** (editable body_type dropdown + read-only measurement ranges + styling notes → `Confirm & continue` → `confirmBodyProfile`). Height also mirrored to the local `profileProvider`.
3. **Hard gate** — `ensureBodyProfile(context, ref)` (`body_profile_gate.dart`) runs **before Fit Check AND look-gen** (`home_screen._startReview` / `_runWardrobe`, ahead of `ensureTokens`). No profile → routes into the mandatory builder (`skippable:false`); returns true once built. No-op in local dev build. `hasBodyProfile()` = `style_profiles.status=='ready' && height_cm!=null`.

### 14.3 Main Screen — "Contextual Editorial Dashboard" — IMPLEMENTED (v2 2026-07-05)
`[REDESIGN]` Overrides the old two-card/stepper layout. **No avatars, memojis, raw photos, or 1-2-3 stepper** on the main screen (all killed). `home_screen.dart` = `Stack`:
1. **Frosted Canvas** (`FrostedCanvas`, `Positioned.fill`) `[v2c]`: a **faint hand-drawn fitting-room sketch** (`assets/bg/mirror_selfies.jpg` — three mirror-selfie figures, editorial pencil style) at `Opacity 0.16`, `BoxFit.cover` top-aligned, over the near-white base, with **top scrim (bg@0.55) + bottom scrim (bg@0.94)** so the greeting and cards stay legible. `RepaintBoundary`. (Superseded the generated line-art + the scan-blur mesh; `recentScanUrl()` kept but unused.)
2. **Dynamic header** (`_Greeting`): time-of-day greeting in **massive heavy tight type** (52px, w800, -2 tracking) + a styling nudge ("Good morning. / Let's set today's look."). `[TODO]` weather/location plugs in here (needs a weather API key + geolocation permission).
3. **Core action split** — two floating cards, `32px` radius, padding `22`, shadow `blur 30 / offset (0,14)`:
   - **Card A (primary)** solid `ink` — "Review my outfit" + blue sparkle → `_startReview` (body-profile + token gates → camera/gallery → Journey A).
   - **Card B (secondary)** real **glass** (`BackdropFilter` blur 18 over the canvas + `white@0.55` + `white@0.75` border) — "What should I wear?" → `_openStylist` → Stylist Portal (§14.3a).
   - **`_WardrobeLink`** (slim glass row, radius 22) below the two cards — "My wardrobe · Manage" → `WardrobeItemsScreen` (also in Profile).
- Small `Logo` top-left; `_BalanceChip` (reviews left / Pro) above the cards. The body-profile card is gone (the gate enforces it). Journey B look-gen unchanged (§14.3a, multi-look try-on).

### 14.3a Stylist Portal — unified "What should I wear?" entry — IMPLEMENTED (New looks) / SPEC (My clothes)
Replaces the old fixed occasion-chip sheet. Glass bottom sheet (`widgets/stylist_portal.dart`, `openStylistPortal()` → `PortalResult {text, closet}`), copy deliberately plain for non-fashion users.
- **Widget structure**: `BackdropFilter(blur 24)` + translucent `bg@82%` + top hairline; grab handle → heading **"Where are you headed?"** → **borderless custom field** (underline only, blue cursor, hint "Type it — e.g. dinner date, beach day", submit=go) → **horizontal quick chips** `[Office, Date, Drinks, Casual, Active, Hot day]` (tap fills the field; the field is the single source of truth, so free text + chips unify) → **source toggle** `_SourceToggle` (minimalist segmented control: a `bg` pill slides via `AnimatedAlign` under the active label with a soft shadow) → helper line that swaps with the mode → full-width **"Style me"** CTA (disabled until text present).
- **Copy (simplified)**: toggle = **"New looks"** ("We style you from scratch") vs **"My clothes"** ("We use only clothes you've added"). No jargon ("Inspire Me"/"portal"/"closet" dropped from UI). `[DECISION]` **affiliate/upsell framing REJECTED** — pure stylist, inspiration only (product lock).
- **Photo to style**: the portal has a photo control — **take a selfie / choose from gallery** (`_photo` XFile in `PortalResult`); if left empty, falls back to the profile photo. `_runWardrobe(text, {photo})` uploads the fresh selfie (else `_ensureBodyPhoto`).
- **New looks (LIVE)**: `res.text` → `_runWardrobe(text, photo)` → `generate-look` EF. Prompt strategy for **free-typed events**: known chip → specific brand-agnostic guidance from the OCCASIONS map; otherwise the text is injected as *context* — "a complete outfit suited to this context: \"<text>\" — infer the right formality, vibe, season and weather from it" — so Gemini parses weather/vibe itself (no separate parser). `[VERIFIED]` "Rooftop craft beer bar, warm summer evening" → linen SS shirt + tee + olive chinos + suede loafers, ×4.
- **My clothes — Digital Wardrobe IMPLEMENTED**: `source='closet'` → `generate-look` queries `wardrobe_items`, serializes labels, and constrains the prompt to assemble the look **only from owned items** on the user's photo. Portal "My clothes" → `_runWardrobe(closet:true)`: if the wardrobe is empty → routes to `WardrobeItemsScreen` ("add clothes first"); else generates. `[VERIFIED E2E]` closet look = 200, 4 variants.

### 14.6 Digital Wardrobe — IMPLEMENTED
- **Data**: `wardrobe_items` table (id, user_id, image_path, label, category) + owner RLS; private `wardrobe` storage bucket + own-folder policy.
- **Add item**: `wardrobe-add` EF `{image}` → uploads to `wardrobe/<uid>/` + **Gemini auto-labels** it (`classifyItem` → label + category enum) → inserts row → returns item. Authed, no credit burn. `[VERIFIED]` 200 ~7.7s.
- **UI**: `WardrobeItemsScreen` — grid of items (image + label), "Add item" FAB (camera/gallery → add w/ progress), long-press → delete. Reached from **Profile → "My Wardrobe"** and from the empty-closet route.
- **Client**: `SnapstyleApi.addWardrobeItem / wardrobeItems / wardrobeImageUrl / deleteWardrobeItem`; `generateLook(..., source)`.

### 9.9 Design system v3 — "Editorial Luxury" enforcement (D-1..D-6, 2026-07-05)
Home is the reference register; these rules propagate it to every screen.
- **Surfaces (D-2)** — exactly two treatments: (a) **pure white + one soft diffused shadow** `0,10 / blur 30 / black 5%` (`AppShadows.soft`, `AppSurfaces.card`) — default; (b) **stark black** — primary/high-emphasis only ("Review my outfit", THE FIX chips, entitlement banner). Flat gray blocks and default Material elevations are banned. **No blur on regular cards** — glass is reserved for elements overlaying photos (pins, try-on chips). Applied: home cards + wardrobe link, profile (account/body/wardrobe cards), rec cards. Stylist Portal sheet is now solid (blur removed).
- **Geometry (D-3, chosen system)** — ONE radius scale app-wide: `AppRadius.hero 28` (sheets, hero action cards), `card 20`, `control 12` (buttons, chips, inputs, thumbnails). **Pills (999) banned**; circles only for pins/icon dots. Portal chips + source toggle moved from pill → 12.
- **Pins (D-1)** — numbers and red/blue severity coding REMOVED from pins. Default pin: **frosted-glass dot** (27px, BackdropFilter blur 10, white@0.38, white@0.9 inner ring + ink@0.28 outer hairline for ≥3:1 contrast on light garments) — the functional-glass exception. Active: **solid Electric Blue dot + thin pulsing ring** (opacity+scale via one controller; no shadow glow; static under reduced motion). 44px touch target. **Pin ↔ card link = tap-sync**: GlobalKey per hotspot; pin tap scrolls the sheet to its card (`Scrollable.ensureVisible`) + highlights both; card tap highlights its pin. Severity moved onto the card as a small typed label (`FIX THIS`/`TWEAK`/`WORKS`, letterSpacing 1.6) — not color-only.
- **Loaders (D-4)** — `widgets/status_cycler.dart`: single-line typographic loader; phrases **fade-through** (outgoing fully gone before incoming — fixes the two-strings-overlapping bug); honors `disableAnimations` with a hard swap. Used by ProcessingScreen (static sub-line removed) and look-gen ("Reading your proportions… / Styling <occasion> directions… / Rendering looks on you… / Finalizing the set…" + `UP TO A MINUTE` tracked caps).
- **Type & buttons (D-5)** — buttons min-height 58, padding v18, w700, radius 12 (no system-dialog look); all-caps sub-headers get letterSpacing ≥1.2; max 4 sizes / 2 weights per screen.
- **ThemeData (D-6)** — filled/outlined button themes, chipTheme (white, hairline, radius 12), inputDecorationTheme (white fill + hairline, radius 12) rewritten; `AppRadius`/`AppShadows`/`AppSurfaces` tokens added.

### 14.4a P0-3 bug fixes (2026-07-05)
- Analyzing overlap → StatusCycler fade-through (root cause: AnimatedSwitcher default cross-fade shows both strings mid-transition).
- **Render validity gate**: `validateLookImages()` (one flash call, batch) in `generate-look` — drops non-person renders before saving; fail-open; a failed render can no longer become a My Looks card.
- My Looks: **segmented** STYLED LOOKS / FIT REVIEWS with cross-empty states; card meta = label + **relative date** (differentiates near-duplicates); score pill always present on reviews (`N/10` or explicit `no score`).
- "NOW" thumbnail label: dark chip, no clipping.
- Guest+Pro contradiction resolved in copy: "Guest account — your looks, wardrobe and plan live only on this device. Create an account to keep them." (state is legit: entitlements are device-bound for anon users).

### 14.9 P2 — iteration economics & retention — IMPLEMENTED (partial)
- **Occasion results**: primary action is now **"Edit this look"** (opens the sectioned editor on the selected look → per-slot iteration); "Try another set" (full ~1-min regen) demoted to a secondary text link. **Keep-more-than-one**: the generated set stays in My Looks by default (no forced trim); "Remove set" is a subtle discard. `generationBytes` fetches the selected look for the editor.
- **Recent occasions**: `ProfileStore.recentOccasions()` / `addRecentOccasion()` (last 4, deduped) → quick "RECENT" chips at the top of the Stylist Portal.
- **Haptics**: medium impact on look-set ready + shopping verdict reveal; selection clicks on slot/alt swaps in the editor.
- `[DEFERRED]` weather-aware suggestion line — needs a weather API key + geolocation permission.

### 14.6b Fit Check goes straight to the editor (no verdict screen) `[2026-07-05]`
`[DECISION]` The standalone pins/verdict result screen is **removed**. After `analyze`, the flow lands directly in the sectioned editor (§14.7), seeded from the read: each flagged hotspot pre-seeds its slot's first alternative, and the hotspot's problem becomes that alternative's **"Why it's better"** one-liner. The `/10` score is kept as a subtle chip in the editor app bar. My Looks critique reopen → editor too. `result_screen.dart` deleted (pins/tap-sync/rec-cards retired with it).
- **"Why it's better"**: on any alternative, a button expands the sheet (`AnimatedSize`) to reveal one sentence. Source: analysis `detail` for seeded fixes; `outfit-slots` now returns `ideas:[{garment, why}]` (why = one sharp-friend sentence, no clichés) for styling ideas; a generic line for wardrobe items.

### 14.6c Onboarding media — real editorial imagery (Gemini-generated) `[2026-07-05]`
`[DECISION]` The two onboarding slides (`auth_screen.dart` `_ScanMock`/`_PinsMock`) previously drew a grey blob CustomPaint figure (`_paintFigure`) — cheap and off-brand. Replaced with **Gemini-generated B&W editorial fashion photos** as the base layer, with the existing scan-line/detection-frame and pin animations composited on top (real photo + signature-blue overlay reads premium). `_paintFigure` deleted; painters no longer fill background.
- Assets: `assets/onboarding/scan.jpg` (woman, tailored look — slide 1 "Honest, not flattering") + `assets/onboarding/fix.jpg` (man, oversized blazer — slide 2 "See the fix"). ~1.5 MB each, 1024², `BoxFit.cover`.
- Generation: `gemini-2.5-flash-image` via REST (`responseModalities:["IMAGE"]`), prompt = full-length monochrome studio editorial, generous negative space, no text/logos. Repeatable via `scratchpad/gen_onboarding.py` (reads `GEMINI_API_KEY` from `backend/.env`).
- **Home backdrop** `[2026-07-05]`: the hand-drawn `mirror_selfies.jpg` was replaced (deleted) by a Gemini high-key B&W editorial figure `assets/bg/home.jpg` — subject held to the right, near-white negative space top-left. `FrostedCanvas` renders it at `opacity 0.70`, `alignment: centerRight`, with a **left→right white wash** (0.82→0.06 over 0–80%) keeping the headline column pristine + a vertical scrim (0.25 top → 0 → 0.55 bottom) seating the status bar and cards. Composition was pre-verified with a PIL mock (`scratchpad/preview_home.py`) before building. Generated with `scratchpad/gen_home_bg.py` (3 candidates: figure/drape/atelier — figure chosen).

### 14.10 Subjects — style yourself or a guest `[2026-07-05]` — IMPLEMENTED
`[DECISION]` The account is yours, but you can shoot **someone else** and style them. Before any photo upload in **Review** and **What should I wear**, we ask *"Who is this look for?"* → *It's me* / *Someone else*.
- **Guest = ephemeral** (chosen over a saved roster): nothing persists between sessions. A guest supplies a **required height**; measurements (bust/waist/hip) are **optional** and can be **AI-estimated from the photo** (button) then corrected. Model: `lib/models/subject.dart` (`Subject.me()` / `Subject.guest{height, bust, waist, hip, bodyType, proportionDesc, name}`, immutable, `withName()` copy). UI: `lib/widgets/subject_sheet.dart` (`askSubject` → who + guest-details sheet; `promptSubjectName`).
- **Estimate reuses onboarding** with a new `ephemeral:true` flag on `onboarding-profile` → returns the estimate WITHOUT upserting `style_profiles` (never clobbers the owner's profile). Guest height 100–250 enforced.
- **Accurate read for the guest**: `Subject.toOverride()` → server `subject` body_profile override. `analyze` + `generate-look` use the override instead of the owner's stored profile when a guest is present. Owner path unchanged (override null → stored profile).
- **Name at save, not before** (per spec): saving a guest look prompts for a name; history then reads **"Victoria's look"** / **"Victoria's review"**. Wiring: `saveEditedLook(subjectName:)`, `keepLook(subjectName:)`, and `nameGeneration(id, name)` (tags an existing row's `input.subject`). The editor also back-tags the **auto-saved critique** via `AnalysisResult.generationId` so the reopened review shows the name. The Wear set auto-saves, so the name is asked as soon as a guest's set is ready. My Looks cards render the name (`wardrobe_screen`).
- **Scope**: Shopping (checking a garment you might buy) intentionally excluded — it's about the item, not whose body. Guest reopen→editor saves as owner (minor; original row keeps the name).

### 14.11 Polish batch `[2026-07-05]` — IMPLEMENTED
Eight fixes from a device test:
- **Home backdrop**: swapped the editorial figure for a user-supplied hand-drawn fitting-room **triptych** (`assets/bg/home.jpg`), rendered `opacity 0.14`, `topCenter`, top+bottom vertical scrim (0.50 → 0.02 → 0.92). Left-wash removed.
- **Loader** (`processing_screen.dart`): retired the viewfinder scan for a **rotating cobalt gradient ring** (`SweepGradient` arc + leading dot) around a line-art **selfie figure** (`assets/onboarding/selfie.jpg`, Gemini). Status cycler below.
- **My Looks viewer** (`wardrobe_screen.dart`): opening a look now **preloads bytes behind a loader** (no black flash) → `_LookViewer` with **Save to Photos** (`gal`) + **Share** (`share_plus`, temp-file). New deps: `share_plus`, `gal`; Info.plist gains `NSPhotoLibraryAddUsageDescription`.
- **Editor render economy** (§14.7) `[revised 2026-07-05]`: pre-rendering every alternative of every slot (+re-warming on every commit) generated far too many Gemini renders. Reverted to **lazy**: reveal gated on the focused slot's **first 3**; the thumbnail strip shows a **placeholder** for un-warmed alternatives and only renders one when it's **selected** (plus a 1-ahead pre-warm) — a thumbnail on screen never triggers a render. `_warm()` now warms at most 3; the "all looks ready" blue badge was removed (nothing renders the full set). Per-review renders dropped from ~35+ to ~4 + what the user actually opens.
- **Wardrobe items worn on the user** (§14.11 / `wardrobe-add`): adding a garment now renders it **on the user's default body photo** (`generateLookImage(person, prompt, [garment])`) and stores that as the item image — a flat lay is "far from the truth". Falls back to the flat photo if no body photo exists. Add button reads "Trying it on…".
- **Consistent background**: on editor entry the avatar is normalized onto one **plain light-grey studio background** (framed full-length) via a `generateFix` pass; every slot swap keeps that same background; `generate-look` prompt pins the same light-grey studio bg — so real-world photo backgrounds never mix with studio renders.
- **Plain camera**: `guided_camera_screen` dropped the silhouette overlay/frame for a plain camera + one readable bottom instruction ("Stand full-length, centered in the frame").
- **Unified suggestion text**: one tappable caption expands full garment text + the "why" together (replaced the separate truncated label + "Why it's better" button).
- **Profile photo fix** `[revised 2026-07-05]`: `style_profiles` is **SELECT-only under RLS** (all writes go through service-role EFs), so the client upsert could never work. Added a `set-body-photo` EF (admin) — client uploads to its own body-photos folder then calls it to update `source_photo_path`. 422 `no_profile` if none exists yet.
- **Nav label**: bottom tab "Style" → **"Style me"**.
- **Default zoom + pinch**: the avatar sits in an `InteractiveViewer` seeded to a **1.5× centered zoom** (people frame themselves far away) with pinch to 5×.
- **Expandable suggestion text**: tap the title to expand the full garment description (`AnimatedSize`, `maxLines` toggle) instead of a hard ellipsis.
- **6–7 ideas per slot**: `detectOutfitSlots` prompt now asks 6–7 distinct alternatives; editor takes up to 7 ideas / 8 alts.
- **Default profile photo** (§14.11 / `profile_screen.dart`): the post-signup selfie (`style_profiles.source_photo_path`) surfaces as a **"Your photo"** card with **Change photo** (camera/gallery → `setBodyPhoto`); reused across flows (Wear already pulls it). Multi-photo roster deferred.

### 14.15 One-tap "Style my look" (auto-compose) `[2026-07-06]`
A right-side floating composer in the editor (`_StyleBestButton`, cobalt pill). One tap → keep what works, and for every slot the review **flagged** (`_flagged`, seeded from non-'good' hotspots) swap in the stylist's **recommended** alternative — composed in a SINGLE `generate-fix` render (not per-slot). Absent a review, it applies each slot's recommended pick. Result becomes the new base (`_rev++`, caches cleared, focused slot re-warmed); manual per-slot tweaks continue from there. Empty target set → "Your look already works." Inspiration only, no commerce.

### 14.14 Style Engine + Monthly Trend Parser (RAG) `[2026-07-05]`
**Style DNA initialization order.** (1) *Preferred* — Visual onboarding (§14.12): 1–3 images → Gemini Vision → aesthetic rules. (2) *Locale context* — device `locale` (no permission) frames baseline cultural proportions (European tailoring vs. Asian streetwear, etc.). (3) *Fallback* — on skip, Locale context **augmented by the Monthly Trend Parser** (RAG), default anchor "Elevated Minimalism".

**Monthly Trend Parser — RAG store.** `pgvector` enabled; table `trend_insights(source, region, season, aesthetic_tag, summary, keywords[], embedding vector(768), captured_at)` + RPC `match_trend_insights(query_embedding, match_region, match_count)` (cosine). RLS: authed read; service-role write. Embeddings via Gemini `text-embedding-004` (768-d).

**Ingestion (`trend-parser` EF, monthly cron).** For each curated snippet → `summarizeTrend` distils a **brand-agnostic styling RULE** (no brands/stores/prices/links) → `embedText` → upsert. Cron-gated by `x-cron-secret`. **ToS/legal `[DECISION]`:** we do NOT scrape SSENSE / Vogue Runway / Lyst / Highsnobiety / Mr Porter — their ToS forbid it and content is paywalled/copyrighted. Ingestion is **licensed only** (official APIs/partnerships, permitted RSS/press feeds, or human-curated season notes) fed as `items[].rawText`; only the distilled rule + embedding are stored, never raw editorial text.

**Retrieval (generation time).** For a **fallback-DNA** user, build a query from `aesthetic_tag + region + season`, `embedText` it, `match_trend_insights(embedding, region, k=3)`, and inject the top rules into the styling prompt (`generate-look`/`analyze`). Owners with image-derived DNA use their own DNA; trends only augment the fallback.

**Generation prompt — visual context over assumed weather `[DECISION]`.** The styling prompt instructs Gemini to base fabric weight/layering on **what is visible in the photo** (setting, light, current layering) + the user's stated occasion, and to **NOT assume a climate/season/weather the image doesn't show**. Implemented in `generate-look.buildPrompt`. No silent geo/weather ever drives styling — see §14.12 privacy.

**Stack note.** "Node.js scheduled task" == the Supabase Edge Function `trend-parser` (Deno) triggered by a monthly schedule (pg_cron/`net.http_post`, or an external scheduler). No separate Node service.

### 14.13 Editor / profile / camera polish `[2026-07-05]`
- **Ideas per slot: 4** (was 6–7) — fewer Gemini renders. `detectOutfitSlots` + editor `.take(4)`.
- **Avatar fill, no crop, no black**: `_avatar` = `BoxFit.contain` on a **studio-grey backing** (`_studioBg`) matching the render bg → person head-to-toe, margins blend (no black bars, nothing cropped). `InteractiveViewer` **minScale 1** (zoom-IN only — killed the zoom-out-to-black glitch); default zoom seed removed; avatar padding removed (full-bleed). Collapse the sheet (chevron) for a near-full-screen view.
- **Faster input**: review gallery pick downscaled to 1152px q75 (Telegram-style). Note: Gemini generation time dominates render latency, so this is a modest win vs. the 4-ideas/lazy cuts.
- **Camera (body) guidance**: `GuidedCaptureConfig.body` instruction now — "Full body, face visible — no cap, no sunglasses. Wear fitted clothes (a tee with shorts or leggings) so your shape reads." (drives a clean avatar-quality selfie).
- **Profile photo**: a loader overlays the photo tile while updating; tapping the photo opens it **full-screen** (`_viewPhoto`).

### 14.12 Vibe Check — visual "Style DNA" onboarding `[2026-07-05]` — IMPLEMENTED
`[DECISION]` A frictionless visual onboarding step that decodes the user's taste from reference images, with a smart fallback when skipped. Runs on the first-run path (`auth_screen._finish`) right after the body-profile step, before Home.

**Data.** New `style_profiles.style_dna jsonb not null default '{}'`. Shape: `{ fit_preference: slim|regular|relaxed|oversized, color_palette: string[3-5], aesthetic_tag: string, keywords: string[3-6], summary: string, source: 'images'|'fallback', version, context? }`. `style_dna` is folded into the `analyze` prompt context (via the `style_profiles` select) so the read reflects taste, not just body.

**Flow 1 — image extraction.** `VibeCheckScreen` (`vibe_check_screen.dart`, Editorial-Luxury dark register): headline "Show us what you like.", a 3-tile 3:4 upload grid (tap to add from gallery, × to remove), a privacy line, a white "Decode my style (N)" CTA, and a prominent **Skip** (app-bar + "I'll do this later"). On continue the client uploads 1–3 images to its own `body-photos` folder and calls `vibe-check` with `{imagePaths, locale}`. The EF signs each, sends them to Gemini Vision (`extractStyleDna`, one call, JSON schema) to extract recurring styling rules (NOT per-photo description), and saves `style_dna` (service-role; `style_profiles` is SELECT-only for clients). `locale` = `PlatformDispatcher.instance.locale.toLanguageTag()`.

**Flow 2 — smart fallback (skip).** `vibe-check` with `{skip:true, locale}` (no images) seeds a safe anchor without any AI call: **default aesthetic `"Elevated Minimalism"`**, `fit_preference:'regular'`, neutral `color_palette`, plus a `context` block = `{ locale, region (parsed from locale or an `x-country` header), city?, weather?, season (server-computed) }`. `source:'fallback'`.

**Privacy `[DECISION]`.** A truly "silent" precise-geo fetch is impossible on iOS without a permission prompt and violates our PII rules (§ fintech non-negotiables). So the fallback uses **locale (device settings — no permission)** + a **coarse region** parsed from it (or an `x-country` edge header) + server-side **season**. `city`/`weather` are honoured ONLY if the client explicitly passes them (opt-in); a real weather layer is a documented follow-up, not a background location grab.

**Stack note.** The "Node.js backend logic" in the brief is implemented as the Supabase **Edge Function** `vibe-check` (Deno) — the app's cloud backend; there is no separate Node service in prod. Never blocks onboarding: any error → the screen pops and proceeds (fallback can seed later).

### 14.7 Sectioned avatar editor (P0-1) — IMPLEMENTED — FLAGSHIP
`look_editor_screen.dart`. Replaces the old single "alternatives" carousel. Avatar on top; bottom = **slot rail** (top/bottom/outerwear/shoes/belt/accessories/bag — only slots detected on the photo) → selected slot shows a strip `[NOW] + alternatives`, ‹ › cycle, tap swaps **on the avatar in place**.
- **Slots + alts**: `outfit-slots` EF (one flash call) → present slots + current item + 2 brand-agnostic ideas each. **Mixed feed with badges** (chosen over a toggle in shape): wardrobe items of the slot's category (badge `WARDROBE`, max 2) + `IDEA` suggestions.
- **Economics**: a swap = one **scoped** `generate-fix` ("replace ONLY the <slot>… keep everything else the same") — never a full-look regen. Cached by `rev:slot:alt`; committing a variant becomes the new base so edits compound. Progressive reveal (skeleton per thumb; focused slot warmed first).
- **Lock**: long-press a slot chip → lock (excluded from swaps). **Fixed-height caption** (title never jumps). Entry: fit-review "Edit this look" CTA (seeds the fixed slot + its alternative), occasion results, My Looks. Save → `saveEditedLook` (owner-insert). No commerce; "inspiration only" caption fixed.
- Retired: the inline `_TryOn`/`_CarouselPanel` on the result screen (superseded by this editor); per-issue "Try alternatives" buttons removed.

### 14.8 Shopping mode (P0-2) — IMPLEMENTED — advice only, ZERO commerce
`shopping_screen.dart`, home entry "Shopping? Check an item". Camera-first, one-handed. Flow: photo → **verdict streams first** (`shopping-check` EF, ~8–11s) → **avatar render streams after** (`shopping-render` EF, free). Verdict card: giant `BUY.`/`SKIP.`/`TRY ANOTHER SIZE OR COLOR.` + one blunt sentence → FOR YOUR BUILD (body-profile note) → WORKS WITH YOUR WARDROBE (top-3 real pairings) or WOULD PAIR WITH (3 generic + "add wardrobe" nudge when empty) → ON YOU render → Check another / Save look.
- `[HARD INVARIANT]` **no commerce anywhere**: prompt forbids brands, stores, prices, links, buying; verdict is styling advice. "Inspiration only, not a product" on the render. Burns 1 credit on the check; render is free. Saves to My Looks only on explicit Save.

### 14.4 My Looks (was "Wardrobe") — curated collection — IMPLEMENTED
Renamed **"Wardrobe" → "My Looks"** (tab + title). It's a *curated* collection, not an auto-log:
- **Keep vs discard (no purchase — pure stylist).** After a look-gen (`LookGenScreen._Gallery`): **"Keep it"** trims the set to the selected variant (`keepLook` — deletes the other images + `output.image_paths=[chosen]`); **"Not for me"** deletes the whole set (`deleteLook`); "Try another set" regenerates. (User asked for a "did you keep it / delete?" step — implemented as keep/discard, NOT buying; product is commerce-free.)
- **Delete from My Looks**: long-press a card → confirm → `deleteLook` (removes images + row) → reload.
- Backend: added owner **UPDATE + DELETE RLS** on `generations` (via Management API). `SnapstyleApi.keepLook` / `deleteLook`; `generateLook()` now returns `({id, paths})`. `[VERIFIED]` user JWT UPDATE=204, DELETE=204, row gone.

### 14.3c Result screen v3 — zones + numbered recommendations + fix previews — IMPLEMENTED
Replaces the old floating-dots/tooltip design (`result_screen.dart`, rewrite).
- **Zones, not dots**: each hotspot renders as a numbered chip inside a soft colored halo (the "zone"). Issues/tips are numbered 1..N; **"good" areas show a green ✓** (keep). Severity colors: issue=`flag` red, tip=`signature` blue, good=`good` green (new token). Selected zone scales up + glows (`AnimatedContainer`).
- **Bottom popup panel** (rounded-top sheet w/ handle, ~45% height, internal scroll): verdict summary + "N to tweak · M working" stat → **numbered recommendation cards** (number badge + title + detail + dark "THE FIX" chip) → green-check "WHAT WORKS" list. Tapping a card ↔ selecting its zone are two-way linked.
- **Live try-on carousel per zone — INLINE (same screen)**: tapping a flagged zone (or a rec's "Try alternatives on me") turns the bottom sheet into a carousel **without leaving the screen** — the avatar stays on top and **swaps in realtime** to the selected variant. Index 0 = "now" (their photo, instant); each variant = the hotspot's `visual_suggestions[]` (2–3) rendered on their photo via `generate-fix`, generated in parallel and **streaming into the carousel** (thumbnail spinners → ready); ‹ › + thumbnails switch the top avatar instantly. A pill "‹zone title› ×" + back exits try-on. Backend `generate-fix` EF `{image, instruction}` → edited image inline; **authed, NO credit burned** (part of a paid review). `[VERIFIED via DEMO auto-try-on]` inline carousel renders: avatar on top + "now" + 2 generated alternatives at the bottom, live swap. `SnapstyleApi.generateFix`. `[DECISION 2026-07-04]` inline avatar try-on (person on top, carousel below, realtime) per user request + STORE reference. (`ResultScreen.debugAutoTryOn` = QA-only auto-open, default false.)
- `[VERIFIED via DEMO harness]` new screen renders: red #1 (issue) + blue #2/3/4 (tips) + green ✓ (works) zones, numbered cards, THE FIX chips. (DEMO harness now wrapped in `ProviderScope` since the screen uses Riverpod for fix previews.)

### 14.4b History grid — IMPLEMENTED
- `wardrobe_screen.dart`: reads succeeded `generations` (`SnapstyleApi.history()` — id/type/output/input, newest first, owner RLS). 2-col editorial grid: image thumb (signed URL, `own folder` storage RLS) + label ("Fit review" + score pill `N/10`, or "<occasion> look") + bottom scrim. Tap critique → download bytes + `AnalysisResult.fromResponse(output)` → reopen `ResultScreen`; tap look → full-screen `InteractiveViewer`. Pull-to-refresh + appbar refresh (IndexedStack keeps it alive → manual reload). Cloud-only; empty/placeholder states. `[VERIFIED E2E]` analyze → critique row persisted (image_path+analysis, signable) → history returns it.
- `profile_screen.dart`: **entitlement banner** + **fixed Body-profile card** (`_BodyProfileCard` from `bodyProfileProvider`: height, body type, measurement ranges — locked once confirmed) with a **"Re-measure parameters"** button (re-runs the builder), + **Style preferences** form (fit/shoe/styles/colors → `ProfileStore`). Height/build removed from the form — the body profile owns them.

### 14.5 Body profile — single source of truth + AI wiring
- `bodyProfileProvider` (cloud `style_profiles` row) + `hasBodyProfileProvider`. Invalidated on confirm/re-measure so all screens refresh.
- Home: the **"Build your body profile" card hides once `hasBodyProfileProvider` is true** (no longer shown after completion).
- Profile: params are **fixed/read-only** once confirmed; change only via **Re-measure**.
- `[AI USES IT]` body profile feeds all three AI flows: **audit** (`analyze` EF merges it into the critique context), **look-gen** (`generate-look` prompt uses `body_type` + proportion description), and it's the confirmed source for future recommendations.

### 14.2b Onboarding & Auth — IMPLEMENTED (dummy anonymous session)
- `AuthScreen` (`screens/auth_screen.dart`): swipeable value-prop intro (PageView) → auth page with Email/Password + "Continue with Google". These fields are **cosmetic stubs**; tapping Continue calls `auth.ensureSession()`.
- `[DECISION 2026-07-04]` **DUMMY LOGIN = Supabase ANONYMOUS session.** `services/auth.dart` `ensureSession()` calls `signInAnonymously()` → a REAL JWT with no credentials, so the cloud backend (Edge Functions + RLS + server quota) works end to end. The signup trigger provisions `profiles`+`entitlements`. Called in `main()` after `Supabase.initialize` (returning users) AND in `AuthScreen._finish()` (idempotent). Anonymous sign-ins enabled on the project via Management API (`external_anonymous_users_enabled=true`).
- **Cloud vs local switch**: `cloudEnabledProvider` = `auth.cloudReady()` (true when built with `SUPABASE_URL`+`SUPABASE_ANON_KEY`). `home_screen` analyze + `onboarding_screen` profiling + `entitlementProvider` route to `SnapstyleApi` (cloud) when true, else the local `ApiClient` (Node dev server). Onboarding cloud path = `uploadPhoto` → `onboarding-profile` EF.
- Routing: `main.dart` shows `AuthScreen` when `!signedIn`, else `HomeShell`.
- **Real email auth — IMPLEMENTED (anon-first + upgrade)** `[2026-07-05]`. Model: keep the frictionless anonymous guest; offer "Create account" to upgrade. `services/auth.dart`: `isGuest()`, `currentEmail()`, `createAccount(email,pass)` = `updateUser(email,password)` on the anon user (**same uid → all data preserved**), `signIn(email,pass)` = `signInWithPassword`, `signOut()`. `AccountScreen` (create/sign-in toggle). **Profile → account card**: guest → Create account / Sign in; signed in → email + Sign out (→ back to `AuthScreen`, fresh anon). Providers (`bodyProfileProvider`, `entitlementProvider`) invalidated on auth change. Email **autoconfirm ON** in Supabase (no SMTP needed for now; `[TODO]` enable real confirmation + SMTP before prod). `[VERIFIED E2E]` anon→email upgrade keeps uid + data; sign-in works.
- `[target]` **Google/Apple OAuth** — deferred (needs a Google Cloud OAuth client + iOS URL scheme). Button will activate once creds provided. GoRouter hard height-gate (§14.1) optional later.

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
| 2026-07-04 | **Supabase LIVE + verified end-to-end** (project ref tnirnwapfgckfypvtooj, Pro) | Migration/RLS/trigger/buckets provisioned; cloud onboarding proven: JWT→Gemini 2.5 Pro→style_profiles (body_type, ranges, confidence 0.85). ⚠️ sb_secret + DB pw pasted in chat → ROTATE |
| 2026-07-04 | Fixed: supabase-js needs global WebSocket on Node 20 (`ws` polyfill) | Backend crashed otherwise |
| 2026-07-04 | Backlog: deploy to Cloudflare — Pages (landing, ready) + Workers (backend, Express→Hono port) | Consolidate on Cloudflare+Supabase, drop Vercel/Node host |
| 2026-07-04 | **Landing LIVE on Cloudflare Pages** → https://snapstyle.pages.dev | wrangler deploy verified serving the landing |
| 2026-07-04 | Landing design system spec'd: "Extreme Editorial Minimalism" (§11.1–11.4) | Type/whitespace/1 accent/glass/noise; Next.js arch documented; interactive demo = look-suggestions (NO shop, 6th commerce reject); Inter body-only |
| 2026-07-04 | Worker deployed via direct CF API (wrangler bypassed: Node-22 + cfat token /memberships) | `snapstyle-api.snapstyle-jovial.workers.dev` /health live |
| 2026-07-04 | **Gemini geo-blocks CF Worker egress** ("User location not supported") → move AI backend to Supabase Edge Functions (Mumbai, Gemini-supported) | Key fine from Mac/Supabase; CF edge blocked |
| 2026-07-04 | **Verified via pg_net: Gemini returns 200 from Supabase Mumbai region** | Zero new creds (DB conn only). Confirms Supabase region is Gemini-friendly → Edge Functions are the AI host |
| 2026-07-04 | Supabase CLI installed as standalone binary (brew failed → needs Xcode CLT) | `~/.local/bin/supabase` v2.109.0; Node/brew/Xcode-independent |
| 2026-07-04 | **`analyze` Edge Function deployed + geo-VERIFIED (HTTP 200, real critique)** | AI backend = Supabase Edge Functions confirmed. CF Workers dropped for AI (Pages/landing only). Vertex AI not needed |
| 2026-07-04 | **Full AI backend ported to Edge Functions** (analyze/onboarding-profile/generate-look verify_jwt; generation-webhook no-jwt) + shared `_shared/*` | Server-authoritative auth (JWT) + quota (`entitlements` table), not in-memory |
| 2026-07-04 | **E2E authed test PASS**: JWT analyze=200 (score7/4 hotspots), no-token=401, DB free_used burned on success | Production-shaped gate proven; `entitlement.js` in-memory store retired for cloud |
| 2026-07-04 | Flutter `SnapstyleApi` repointed to `/functions/v1/*` (analyze/onboarding/generate-look), `flutter analyze` clean | Cloud client ready; UI flip blocked on real Supabase Auth |
| 2026-07-04 | Web landing built (`web/index.html`), host on Cloudflare Pages (not Vercel) | Zero-dep static, B&W editorial; free CF tier; verified desktop+mobile |
| 2026-07-03 | Pin bottom sheet gets look-suggestion carousel (gen prompts, NOT shop) | Visual solution; image via fal later; no commerce |
| 2026-07-03 | Paywall: Monthly $12.99 / Yearly $89.99; `ensureTokens` interceptor at 0 | Trial=10; gate camera + occasion chips |
| 2026-07-03 | Main split: Fit Check CTA + "What should I wear?" wardrobe card | Two intents, no clutter |
| 2026-07-03 | Onboarding intro + auth stub (email/pass + Google stub), local signedIn flag | Real Supabase Auth deferred |
