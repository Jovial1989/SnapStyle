-- 0010 — Async fan-out look generation.
-- One row per look render: the dispatcher inserts them as 'pending', one
-- render-look worker per row flips it to completed/failed, and the Flutter
-- client watches the rows over Supabase Realtime to update each card
-- independently. Parent set state stays on public.generations.

create table if not exists public.look_renders (
  id            uuid primary key default gen_random_uuid(),
  generation_id uuid not null references public.generations(id) on delete cascade,
  user_id       uuid not null references auth.users(id) on delete cascade,
  look_index    int  not null default 0,
  type          text not null default 'tryon',
  status        text not null default 'pending'
                check (status in ('pending','completed','failed')),
  image_path    text,
  error         text,
  meta          jsonb not null default '{}'::jsonb, -- frozen at dispatch: prompt, tier, title, affiliate[]
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists look_renders_gen_idx  on public.look_renders (generation_id);
create index if not exists look_renders_user_idx on public.look_renders (user_id);

alter table public.look_renders enable row level security;

-- Owners read their own rows (Realtime subscriptions respect this policy);
-- all writes go through the service role (dispatcher + workers) — no
-- insert/update/delete policies on purpose.
drop policy if exists "look_renders_own_select" on public.look_renders;
create policy "look_renders_own_select" on public.look_renders
  for select using (auth.uid() = user_id);

-- Realtime: stream row changes to subscribed clients.
do $$ begin
  alter publication supabase_realtime add table public.look_renders;
exception when duplicate_object then null; end $$;
