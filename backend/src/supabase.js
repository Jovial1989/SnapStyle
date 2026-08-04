import { createClient } from '@supabase/supabase-js';
import WebSocket from 'ws';

// supabase-js's realtime client needs a global WebSocket; Node < 22 has none.
globalThis.WebSocket ??= WebSocket;

/** True when Supabase env is configured. Local dev can run without it. */
export function hasSupabase() {
  return Boolean(process.env.SUPABASE_URL && process.env.SUPABASE_SERVICE_ROLE_KEY);
}

// Service-role client — bypasses RLS. Used ONLY server-side for AI writes.
// LAZY: constructed on first use so importing this file never crashes the local
// server when Supabase env is absent. Access throws only if actually used unconfigured.
let _admin = null;
export const admin = new Proxy(
  {},
  {
    get(_t, prop) {
      if (!_admin) {
        if (!hasSupabase()) throw new Error('Supabase not configured (local mode)');
        _admin = createClient(
          process.env.SUPABASE_URL,
          process.env.SUPABASE_SERVICE_ROLE_KEY,
          // Dedicated Snapstyle project — standard public schema (SDD §2.3.2).
          { auth: { persistSession: false } },
        );
      }
      return _admin[prop];
    },
  },
);

/**
 * Resolve the authenticated user from a request's Bearer token.
 * The Flutter client sends its Supabase access token; we verify it here so a
 * client can never act as another user (interim `appUserId` trust is gone).
 * @returns {Promise<{id: string} | null>}
 */
export async function getUser(req) {
  const auth = req.headers?.authorization || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : null;
  if (!token) return null;
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data?.user) return null;
  return { id: data.user.id };
}

/** Signed URL for a private storage object (so Gemini/fal can fetch it). */
export async function signedUrl(bucket, path, expiresIn = 300) {
  const { data, error } = await admin.storage
    .from(bucket)
    .createSignedUrl(path, expiresIn);
  if (error) throw new Error(`signedUrl failed: ${error.message}`);
  return data.signedUrl;
}
