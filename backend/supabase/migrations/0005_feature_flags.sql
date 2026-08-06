-- Remote feature flags (client-readable). First flag: use_sam2_engine — gates
-- the experimental MediaPipe+SAM2 mask engine in the app (see Flutter
-- FeatureFlagService). Writes are service-role/dashboard only.
create table if not exists public.feature_flags (
  key text primary key,
  enabled boolean not null default false,
  updated_at timestamptz not null default now()
);

alter table public.feature_flags enable row level security;

drop policy if exists "feature_flags_read_authed" on public.feature_flags;
create policy "feature_flags_read_authed" on public.feature_flags
  for select to authenticated using (true);

insert into public.feature_flags (key, enabled)
  values ('use_sam2_engine', false)
  on conflict (key) do nothing;
