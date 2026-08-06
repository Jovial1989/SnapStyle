-- 0004_affiliate_items.sql — affiliate marketplace pivot (user-confirmed 2026-07-09).
-- Global catalogue of shoppable branded items sourced from affiliate FEEDS
-- (Rakuten/CJ/Awin — never scraped retailer sites). image_url = the network's
-- clean flat-lay product shot (hosted by the network/merchant CDN, hotlinked).
create table if not exists public.affiliate_items (
  id         uuid primary key default gen_random_uuid(),
  brand_name text not null,
  name       text not null,
  category   text not null check (category in ('top','bottom','shoes','outerwear','accessory')),
  price      numeric(10,2),
  currency   text not null default 'USD',
  buy_url    text not null,
  image_url  text not null,
  source     text, -- feed network id (rakuten | cj | awin | manual)
  external_id text, -- the network's product id (dedup key for re-ingestion)
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index if not exists affiliate_items_ext_idx on public.affiliate_items (source, external_id);
create index if not exists affiliate_items_cat_idx on public.affiliate_items (category) where active;
alter table public.affiliate_items enable row level security;
do $$ begin
  if not exists (select 1 from pg_policies where tablename='affiliate_items' and policyname='affiliate read authed') then
    create policy "affiliate read authed" on public.affiliate_items for select to authenticated using (active);
  end if;
end $$;
