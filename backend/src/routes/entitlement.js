import { Router } from 'express';
import { getEntitlement } from '../entitlement.js';

export const entitlement = Router();

// INTERIM AUTH: appUserId comes from the client. Once Supabase Auth lands, derive
// it from the verified JWT and use the same id as the RevenueCat app_user_id.
function requireUserId(req, res) {
  const id = req.query?.appUserId || req.body?.appUserId;
  if (!id) {
    res.status(400).json({ error: 'appUserId required' });
    return null;
  }
  return String(id);
}

// Current entitlement + free-analysis balance. Client renders paywall from this.
// (The RevenueCat SDK also exposes `pro` client-side, but free-quota is server-owned.)
entitlement.get('/', (req, res) => {
  const appUserId = requireUserId(req, res);
  if (!appUserId) return;
  res.json(getEntitlement(appUserId));
});
