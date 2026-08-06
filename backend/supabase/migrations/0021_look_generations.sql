-- VTON output ledger. The service writes here after the image is safely
-- re-hosted on R2, so every row points at a permanent URL — provider URLs
-- expire within a day and must never reach this table.
create table if not exists public.look_generations (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  garment_id   text not null,
  image_url    text not null,
  provider     text not null,               -- 'kolors' | 'idm-vton' | …
  category     text not null check (category in ('upper_body', 'lower_body', 'dresses')),
  duration_ms  integer,
  created_at   timestamptz not null default now()
);

-- The gallery reads "my newest looks"; this index is that query.
create index if not exists look_generations_user_created_idx
  on public.look_generations (user_id, created_at desc);

-- Cost/quality reporting per engine — the reason `provider` is stored at all.
create index if not exists look_generations_provider_idx
  on public.look_generations (provider, created_at desc);

alter table public.look_generations enable row level security;

-- Owner-read only. Writes come from the service role, which bypasses RLS —
-- clients must never be able to forge a generation row.
drop policy if exists look_generations_owner_read on public.look_generations;
create policy look_generations_owner_read
  on public.look_generations for select
  using (auth.uid() = user_id);
