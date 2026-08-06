-- Per-call Gemini usage ledger (unit economics). Written service-role only
-- (RLS on, no policies). kind: image | text. images = returned image count.
create table if not exists public.gemini_usage (
  id            uuid primary key default gen_random_uuid(),
  kind          text not null,
  model         text not null,
  images        int not null default 0,
  prompt_tokens int not null default 0,
  output_tokens int not null default 0,
  total_tokens  int not null default 0,
  created_at    timestamptz not null default now()
);
create index if not exists gemini_usage_time_idx on public.gemini_usage (created_at desc);
alter table public.gemini_usage enable row level security;
