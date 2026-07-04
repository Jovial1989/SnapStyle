// Server-authoritative entitlement + free-quota store.
//
// INTERIM: in-memory only (non-persistent, resets on restart, single-instance).
// Deliberate prototype shortcut while Supabase is deferred (SDD §2.3, §8).
// Replace with a Supabase `entitlements` table before anything real ships —
// entitlement MUST survive restarts and MUST NOT be trusted from the client.
//
// Source of truth for `pro` is RevenueCat (SDD §8.1). This store is a server-side
// cache kept fresh by RevenueCat webhooks + REST verification. Free-quota is ours.

const FREE_ANALYSIS_QUOTA = 10; // SDD §8.2

/** appUserId -> { pro, currentPeriodEnd, freeUsed } */
const store = new Map();

function ensure(appUserId) {
  if (!store.has(appUserId)) {
    store.set(appUserId, { pro: false, currentPeriodEnd: null, freeUsed: 0 });
  }
  return store.get(appUserId);
}

export function getEntitlement(appUserId) {
  const e = ensure(appUserId);
  return {
    pro: e.pro,
    source: e.pro ? 'revenuecat' : null,
    currentPeriodEnd: e.currentPeriodEnd,
    freeRemaining: Math.max(0, FREE_ANALYSIS_QUOTA - e.freeUsed),
  };
}

/** True if the user may run an analysis right now (pro OR free quota left). */
export function canAnalyze(appUserId) {
  const e = ensure(appUserId);
  return e.pro || e.freeUsed < FREE_ANALYSIS_QUOTA;
}

/** Burn one free analysis — call ONLY after a successful analysis, and only if not pro. */
export function consumeFreeAnalysis(appUserId) {
  const e = ensure(appUserId);
  if (!e.pro) e.freeUsed += 1;
}

/** Set entitlement from verified RevenueCat state. */
export function setPro(appUserId, { pro, currentPeriodEnd }) {
  const e = ensure(appUserId);
  e.pro = pro;
  e.currentPeriodEnd = pro ? currentPeriodEnd : null;
}

export { FREE_ANALYSIS_QUOTA };
