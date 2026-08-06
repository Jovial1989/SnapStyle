-- Training-pair capture: a proprietary paired VTON dataset accumulated as a
-- byproduct of every successful render (person + garment refs + result +
-- instruction). Future use: distill a cheap fast local model from Gemini
-- outputs. Service-role write only; NO public/user read (raw user photos).

-- Private bucket for the captured person + reference images.
insert into storage.buckets (id, name, public)
values ('training-pairs', 'training-pairs', false)
on conflict (id) do nothing;

create table if not exists public.training_pairs (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  render_id     text,
  source        text not null check (source in ('fix', 'look')),
  person_path   text,              -- training-pairs bucket
  ref_paths     text[] default '{}',  -- training-pairs bucket
  result_bucket text,              -- e.g. 'generations'
  result_path   text,
  instruction   text,
  meta          jsonb default '{}'::jsonb,
  created_at    timestamptz not null default now()
);

create index if not exists training_pairs_created_idx on public.training_pairs (created_at);

-- RLS on, but NO policies for anon/authenticated → only the service role
-- (which bypasses RLS) can read/write. Client apps can never touch this.
alter table public.training_pairs enable row level security;
