import express from 'express';
import { entitlement } from './routes/entitlement.js';
import { revenueCatWebhook } from './routes/revenuecat.js';
import { analyze } from './routes/analyze.js';
// Serverless-style handlers (deploy as Vercel functions; mounted here for local dev).
import onboardingProfile from '../api/onboarding-profile.js';
import onboardingLocal from '../api/onboarding-local.js';
import generateLook from '../api/generate-look.js';
import generationWebhook from '../api/generation-webhook.js';

const app = express();
// Larger limit: interim transport inlines a base64 image in the JSON body (SDD §2.3).
app.use(express.json({ limit: '15mb' }));

app.get('/health', (_req, res) => res.json({ ok: true }));

// Subscription state is owned by RevenueCat; this webhook keeps our server cache fresh.
app.post('/webhooks/revenuecat', revenueCatWebhook);
app.post('/webhooks/generation', generationWebhook); // fal try-on completion

app.use('/entitlement', entitlement);
app.use('/analyze', analyze);                        // Flow 1 critique (base64, interim)
app.post('/api/onboarding-profile-local', onboardingLocal); // LOCAL: base64, no auth
app.post('/api/onboarding-profile', onboardingProfile);     // CLOUD: auth + Supabase
app.post('/api/generate-look', generateLook);               // Flow 2 (cloud only)

const port = process.env.PORT || 4242;
app.listen(port, () => {
  console.log(`Snapstyle backend listening on :${port}`);
});
