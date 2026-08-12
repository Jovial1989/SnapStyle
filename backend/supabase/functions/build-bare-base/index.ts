// POST /functions/v1/build-bare-base  { photoPath }  — service-bearer only.
// Internal trigger for the minimal base (tank + short shorts). Split from
// set-body-photo so the bare mannequin can be built or REBUILT for an existing
// photo without touching the user's profile — during rollout, after a prompt
// change, or when QA on the pod rejects a build and we want another attempt.
import { admin } from "../_shared/supabase.ts";
import { buildMinimalBase } from "../_shared/avatar.ts";
import { json, preflight } from "../_shared/http.ts";

Deno.serve(async (req) => {
  const pre = preflight(req);
  if (pre) return pre;
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  if (req.headers.get("Authorization") !== `Bearer ${service}`) {
    return json({ error: "forbidden" }, 403);
  }
  const { photoPath } = await req.json().catch(() => ({}));
  if (typeof photoPath !== "string" || !photoPath) {
    return json({ error: "photoPath required" }, 400);
  }
  // Synchronous on purpose: the caller is an operator who wants to QA the
  // result immediately, not a user waiting on onboarding.
  await buildMinimalBase(admin(), photoPath);
  return json({ ok: true, bare: `${photoPath}.bare.png` });
});
