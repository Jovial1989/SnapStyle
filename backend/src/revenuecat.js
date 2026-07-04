// RevenueCat REST verification.
// On every webhook we re-fetch the authoritative subscriber state instead of
// inferring entitlement from the event type — a CANCELLATION does not mean the
// user lost access immediately (they keep it until period end); only an expired
// entitlement does. Asking RevenueCat directly avoids that whole class of bugs.

const RC_API = 'https://api.revenuecat.com/v1';

/**
 * Fetch current entitlement state for a RevenueCat app_user_id.
 * @returns {Promise<{ pro: boolean, currentPeriodEnd: string|null }>}
 */
export async function verifyEntitlement(appUserId) {
  const apiKey = process.env.REVENUECAT_API_KEY;
  const entId = process.env.REVENUECAT_ENTITLEMENT_ID || 'pro';
  if (!apiKey) throw new Error('REVENUECAT_API_KEY missing — set it in backend/.env');

  const res = await fetch(`${RC_API}/subscribers/${encodeURIComponent(appUserId)}`, {
    headers: { Authorization: `Bearer ${apiKey}` },
  });
  if (!res.ok) {
    throw new Error(`RevenueCat REST ${res.status} for ${appUserId}`);
  }

  const body = await res.json();
  const ent = body?.subscriber?.entitlements?.[entId];
  if (!ent) return { pro: false, currentPeriodEnd: null };

  // `expires_date` null => lifetime/non-expiring. Otherwise active if in the future.
  const expires = ent.expires_date ? Date.parse(ent.expires_date) : null;
  const pro = expires === null || expires > nowMs();
  return { pro, currentPeriodEnd: ent.expires_date ?? null };
}

// Isolated so tests can stub time; Date.now() is fine at runtime.
function nowMs() {
  return Date.now();
}
