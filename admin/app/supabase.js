// Server-only admin client. SERVICE ROLE KEY — never import this from a
// client component ("use client" files must not touch it).
import "server-only";
import { createClient } from "@supabase/supabase-js";

export const admin = () =>
  createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

export const FREE_QUOTA = 10; // mirror of backend _shared/supabase.ts
