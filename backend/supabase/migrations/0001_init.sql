-- Snapstyle — dedicated Supabase project (its own auth/storage/db). Standard
-- `public` schema. Run once in the fresh Snapstyle project (SQL Editor or via
-- the setup script). Nothing shared with Motixi.

create extension if not exists "pgcrypto";

-- ── profiles (1:1 with auth.users) ────────────────────────────────────────
create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ── style_profiles (AI body profiling) ────────────────────────────────────
create table public.style_profiles (
  user_id                uuid primary key references auth.users(id) on delete cascade,
  height_cm              numeric(5,1) not null check (height_cm between 100 and 250),
  source_photo_path      text,
  body_type              text,
  proportions            jsonb not null default '{}',
  estimated_measurements jsonb not null default '{}',
  confidence             numeric(3,2) check (confidence between 0 and 1),
  model                  text,
  prompt_version         text,
  status                 text not null default 'processing'
                           check (status in ('processing','ready','failed')),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);

-- ── generations (Flow 1 critique + Flow 2 try-on/look-gen) ────────────────
create table public.generations (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  type         text not null check (type in ('critique','tryon')),
  status       text not null default 'queued'
                 check (status in ('queued','processing','succeeded','failed')),
  input        jsonb not null default '{}',
  output       jsonb,
  provider     text,
  external_id  text,
  error        text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index generations_user_idx on public.generations (user_id, created_at desc);
create index generations_external_idx on public.generations (external_id);

-- ── entitlements (server-owned; 10 free reviews) ──────────────────────────
create table public.entitlements (
  user_id            uuid primary key references auth.users(id) on delete cascade,
  pro                boolean not null default false,
  plan               text check (plan in ('monthly','yearly')),
  source             text,
  current_period_end timestamptz,
  free_used          int not null default 0,   -- free_reviews_left = 10 - free_used
  updated_at         timestamptz not null default now()
);

-- ── auto-provision profile + entitlement on signup ────────────────────────
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id) values (new.id) on conflict do nothing;
  insert into public.entitlements (user_id) values (new.id) on conflict do nothing;
  return new;
end; $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ── RLS (owner read; AI + billing rows written only by service role) ──────
alter table public.profiles       enable row level security;
alter table public.style_profiles enable row level security;
alter table public.generations    enable row level security;
alter table public.entitlements   enable row level security;

create policy "own profile rw"  on public.profiles       for all    using (auth.uid() = id)      with check (auth.uid() = id);
create policy "own style read"  on public.style_profiles for select using (auth.uid() = user_id);
create policy "own gen read"    on public.generations    for select using (auth.uid() = user_id);
create policy "own ent read"    on public.entitlements   for select using (auth.uid() = user_id);

-- ── storage (private buckets — create via dashboard/API) ──────────────────
-- Buckets (private): body-photos, generations
--   create policy "own folder" on storage.objects for all
--   using   ( bucket_id in ('body-photos','generations')
--             and (storage.foldername(name))[1] = auth.uid()::text )
--   with check ( bucket_id in ('body-photos','generations')
--             and (storage.foldername(name))[1] = auth.uid()::text );
