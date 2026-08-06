-- 0013 — Fal.ai usage ledger (mirror of gemini_usage for the second vendor).
-- Every falTryOn call logs one row (fire-and-forget from the EF): count,
-- latency, and an ESTIMATED cost (per-mode config — the invoice truth lives
-- on fal.ai/dashboard/usage; this ledger is for our own unit economics).

create table if not exists public.fal_usage (
  id          bigint generated always as identity primary key,
  endpoint    text not null,                 -- e.g. 'fashn/tryon/v1.6'
  mode        text not null,                 -- performance | balanced | quality
  category    text,                          -- tops | bottoms
  ok          boolean not null default true, -- false = failed call (fell back to Gemini)
  duration_ms int,
  cost_usd    numeric(8, 4) not null default 0, -- 0 on failures (not billed)
  created_at  timestamptz not null default now()
);

create index if not exists fal_usage_created_idx on public.fal_usage (created_at);

-- Service-role only (RLS on, zero policies) — same posture as gemini_usage.
alter table public.fal_usage enable row level security;

-- Day-by-day rollup for quick reports.
create or replace view public.fal_usage_daily
with (security_invoker = on) as
select
  date_trunc('day', created_at)::date as day,
  count(*) filter (where ok)          as calls_ok,
  count(*) filter (where not ok)      as calls_failed,
  round(avg(duration_ms) filter (where ok)) as avg_ms,
  round(sum(cost_usd), 4)             as est_cost_usd
from public.fal_usage
group by 1
order by 1 desc;
