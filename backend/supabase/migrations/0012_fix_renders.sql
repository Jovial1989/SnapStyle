-- 0012 — Realtime editor swaps ("fast first, right after").
-- One row per try-on swap: fix-dispatch inserts it and returns instantly; the
-- fix-render worker paints v1 (status=completed, phase=verifying), then QA
-- either finalizes (phase=done) or silently REPLACES the image with a refined
-- v2 (phase refining→done, image_path swapped). The Flutter editor watches the
-- row over Realtime — no more 45s held HTTP connections or invisible retries.

create table if not exists public.fix_renders (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  status      text not null default 'pending'
              check (status in ('pending','completed','failed')),
  phase       text not null default 'rendering'
              check (phase in ('rendering','verifying','refining','done')),
  image_path  text,        -- object in the 'generations' bucket (<uid>/_fix/…)
  applied     boolean,     -- QA verdict for the CURRENT image_path
  error       text,
  cache_key   text,        -- tryon_cache key, filled by the dispatcher
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists fix_renders_user_idx on public.fix_renders (user_id);
create index if not exists fix_renders_age_idx  on public.fix_renders (created_at);

alter table public.fix_renders enable row level security;

drop policy if exists "fix_renders_own_select" on public.fix_renders;
create policy "fix_renders_own_select" on public.fix_renders
  for select using (auth.uid() = user_id);
-- Writes: service role only (dispatcher + worker) — no other policies.

do $$ begin
  alter publication supabase_realtime add table public.fix_renders;
exception when duplicate_object then null; end $$;
