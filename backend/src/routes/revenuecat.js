import { verifyEntitlement } from '../revenuecat.js';
import { setPro } from '../entitlement.js';

// RevenueCat webhook. Authenticated by a shared secret in the Authorization header
// (configured in the RevenueCat dashboard → project → webhooks). RevenueCat sends
// plain JSON (no raw-body signature), so this route uses the normal json parser.
export async function revenueCatWebhook(req, res) {
  const expected = process.env.REVENUECAT_WEBHOOK_AUTH;
  if (expected && req.headers.authorization !== expected) {
    return res.status(401).json({ error: 'unauthorized' });
  }

  const appUserId = req.body?.event?.app_user_id;
  if (!appUserId) {
    return res.status(400).json({ error: 'missing app_user_id' });
  }

  try {
    // Don't trust the event payload for state — re-fetch authoritative entitlement.
    const { pro, currentPeriodEnd } = await verifyEntitlement(appUserId);
    setPro(appUserId, { pro, currentPeriodEnd });
    res.json({ received: true, pro });
  } catch (err) {
    console.error('[revenuecat] webhook error:', err.message);
    // 5xx so RevenueCat retries the delivery.
    res.status(500).json({ error: 'webhook_handler_failed' });
  }
}
