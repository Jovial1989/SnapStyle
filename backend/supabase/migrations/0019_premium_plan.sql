-- Premium tier (fit controls, accessory studio) becomes a real plan value.
-- 0001 allowed only ('monthly','yearly') — widen to the tier×period matrix
-- the paywall actually sells, plus bare 'premium' for founder/promo grants.
alter table public.entitlements drop constraint if exists entitlements_plan_check;
alter table public.entitlements add constraint entitlements_plan_check
  check (plan is null or plan in (
    'monthly', 'yearly',                      -- legacy values, kept valid
    'pro_monthly', 'pro_yearly',
    'premium', 'premium_monthly'
  ));
