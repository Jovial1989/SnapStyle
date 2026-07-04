// fal.ai queue submission for Virtual Try-On. We use the ASYNC queue + webhook
// pattern (SDD §5.6) — image-gen takes far longer than any serverless timeout,
// so we never await the result inline. fal calls us back when it's done.
const QUEUE_BASE = 'https://queue.fal.run';

// A virtual try-on model on fal (swap the person into a target garment/look).
function tryOnModel() {
  return process.env.FAL_TRYON_MODEL || 'fal-ai/idm-vton';
}

/**
 * Submit an async try-on job. Returns fal's request_id for webhook correlation.
 * @param {object} input   model input (person image url, garment/prompt, ...)
 * @param {string} webhookUrl  our /webhooks/generation endpoint
 */
export async function submitTryOn(input, webhookUrl) {
  const key = process.env.FAL_KEY;
  if (!key) throw new Error('FAL_KEY missing');

  const res = await fetch(
    `${QUEUE_BASE}/${tryOnModel()}?fal_webhook=${encodeURIComponent(webhookUrl)}`,
    {
      method: 'POST',
      headers: { Authorization: `Key ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(input),
    },
  );
  if (!res.ok) throw new Error(`fal submit ${res.status}: ${(await res.text()).slice(0, 300)}`);

  const json = await res.json();
  return json.request_id; // correlate with generations.external_id
}
