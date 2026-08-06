-- 0002_feeds.sql — Personalized loader feeds ("Style DNA lookbook").
-- Adds the three tables + storage bucket the feed feature needs. Everything
-- else it relies on (trend_insights, match_trend_insights, style_profiles.style_dna,
-- wardrobe_items, the `vector` extension) already exists in the live DB — this
-- migration reconciles the repo with it and is fully idempotent (safe to re-run).

-- ── reference_looks ─────────────────────────────────────────────────────────
-- The 2–10 outfit photos a user uploads at onboarding. Private, own-folder.
create table if not exists public.reference_looks (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  image_path text not null,
  created_at timestamptz not null default now()
);
create index if not exists reference_looks_user_idx on public.reference_looks (user_id, created_at desc);
alter table public.reference_looks enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename='reference_looks' and policyname='own reference read') then
    create policy "own reference read" on public.reference_looks for select using (auth.uid() = user_id);
  end if;
end $$;

-- ── feed_looks ──────────────────────────────────────────────────────────────
-- The user's silently pre-generated personal lookbook (Review loader feed).
-- source: how each look was produced. Written service-role; read by owner.
create table if not exists public.feed_looks (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  image_path    text not null,
  source        text not null default 'aspirational'
                  check (source in ('remix','aspirational','trend')),
  aesthetic_tag text,
  caption       text,
  created_at    timestamptz not null default now()
);
create index if not exists feed_looks_user_idx on public.feed_looks (user_id, created_at desc);
alter table public.feed_looks enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename='feed_looks' and policyname='own feed read') then
    create policy "own feed read" on public.feed_looks for select using (auth.uid() = user_id);
  end if;
end $$;

-- ── muse_looks ──────────────────────────────────────────────────────────────
-- Shared, non-personal archetype library (Generate loader feed). No user_id —
-- the same rows serve everyone. No real names/likenesses (unnamed archetypes).
create table if not exists public.muse_looks (
  id         uuid primary key default gen_random_uuid(),
  archetype  text not null,
  category   text not null,
  image_path text not null,
  caption    text,
  season     text,
  created_at timestamptz not null default now()
);
create index if not exists muse_looks_cat_idx on public.muse_looks (category, archetype);
alter table public.muse_looks enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename='muse_looks' and policyname='muse read authed') then
    create policy "muse read authed" on public.muse_looks for select to authenticated using (true);
  end if;
end $$;

-- ── muses storage bucket ────────────────────────────────────────────────────
-- Public read (non-sensitive shared archetype images → plain cacheable URLs);
-- writes are service-role only (edge functions), so no write policy is granted.
insert into storage.buckets (id, name, public)
values ('muses', 'muses', true)
on conflict (id) do nothing;
