# Snapstyle Backend

Node.js orchestration layer. Billing is **RevenueCat-only** (native in-app IAP) — no
Stripe, no web checkout (SDD §8.1). This service owns the server-side entitlement cache
and free-analysis quota that gate Gemini calls.

## Endpoints
| Method | Path | Purpose |
|---|---|---|
| GET  | `/health` | liveness |
| GET  | `/entitlement?appUserId=` | `{ pro, source, currentPeriodEnd, freeRemaining }` |
| POST | `/webhooks/revenuecat` | RevenueCat webhook → refresh entitlement cache |

## Install & run
```bash
cd backend
npm install
cp .env.example .env   # fill in RevenueCat keys
npm run dev
```

## Billing note
RevenueCat purchases happen **inside the Flutter app** via StoreKit / Play Billing.
They can't be exercised with curl — testing needs the built app plus App Store Connect /
Play Console sandbox accounts. Until then, `/entitlement` returns the free-quota state
and `pro:false`. The webhook + REST verification (`src/revenuecat.js`) are wired and ready
for when the app + RevenueCat project exist.

## Notes
- Entitlement store is **in-memory** (interim, SDD §2.3) — resets on restart. → Supabase later.
- `appUserId` is client-supplied for now → replace with verified Supabase JWT (same id as RevenueCat app_user_id).
- Free quota (10) burns only on a **successful** analysis, server-enforced (SDD §8.2).
