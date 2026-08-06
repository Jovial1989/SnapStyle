-- 0015: promo codes — bonus free tokens on entitlements + one-shot redemptions.
-- BETA3X triples the free tier (adds +2×FREE_QUOTA bonus tokens, once per user);
-- FOUNDER26 flips `pro` (the existing unlimited bypass). Codes live in the
-- redeem-promo-code Edge Function; this is only the state they mutate.
alter table public.entitlements
  add column if not exists bonus_tokens int not null default 0;

create table if not exists public.promo_redemptions (
  user_id    uuid not null references auth.users(id) on delete cascade,
  code       text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, code)   -- once per user per code, atomically
);
alter table public.promo_redemptions enable row level security;
drop policy if exists "own redemptions read" on public.promo_redemptions;
create policy "own redemptions read" on public.promo_redemptions
  for select using (auth.uid() = user_id);
