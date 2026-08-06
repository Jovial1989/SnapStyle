-- Strict gender guard for the branded catalogue: a dress must NEVER surface
-- in a men's tab. Tagged offline (scripts/tag-inventory.mjs); real feeds set
-- it at ingest. Filtering happens at the QUERY level via match_gender in the
-- search RPCs (male|female → that gender + unisex; null → no filter).
alter table public.affiliate_items
  add column if not exists gender text not null default 'unisex'
  check (gender in ('male', 'female', 'unisex'));

-- Recreate search RPCs with the gender filter. DROP first: replacing with an
-- extra defaulted arg would create an OVERLOAD, and PostgREST rpc calls that
-- omit the new arg would then match both → ambiguity errors.
drop function if exists public.match_affiliate_items(vector, int, text, float);
drop function if exists public.recommend_items(uuid, text, text, text, text, boolean, int, float);
drop function if exists public.recommend_items_by_embedding(vector, text, text, text, text, boolean, int, float);

create or replace function public.match_affiliate_items(
  query_embedding vector(768),
  match_count int default 1,
  match_category text default null,
  min_similarity float default 0.35,
  match_gender text default null
) returns table (
  id uuid, brand_name text, name text, category text,
  price numeric, currency text, buy_url text, image_url text, similarity float
)
language sql stable security definer
set search_path = public
as $$
  select a.id, a.brand_name, a.name, a.category, a.price, a.currency,
         a.buy_url, a.image_url,
         1 - (a.embedding <=> query_embedding) as similarity
  from public.affiliate_items a
  where a.active
    and a.embedding is not null
    and (match_category is null or a.category = match_category)
    and (match_gender is null or a.gender in (match_gender, 'unisex'))
    and 1 - (a.embedding <=> query_embedding) >= min_similarity
  order by a.embedding <=> query_embedding
  limit greatest(match_count, 1)
$$;

create or replace function public.recommend_items(
  anchor_id uuid,
  match_category text default null,
  match_occasion text default null,
  match_style text default null,
  match_brand_tier text default null,
  require_stock boolean default true,
  match_count int default 6,
  min_similarity float default 0.30,
  match_gender text default null
) returns table (
  id uuid, brand_name text, name text, category text,
  price numeric, currency text, buy_url text, image_url text, similarity float
)
language sql stable security definer
set search_path = public
as $$
  with anchor as (
    select embedding from public.affiliate_items
    where id = anchor_id and embedding is not null
  )
  select a.id, a.brand_name, a.name, a.category, a.price, a.currency,
         a.buy_url, a.image_url,
         1 - (a.embedding <=> anchor.embedding) as similarity
  from public.affiliate_items a, anchor
  where a.active
    and a.id <> anchor_id
    and a.embedding is not null
    and (not require_stock or a.in_stock)
    and (match_category is null or a.category = match_category)
    and (match_occasion is null or a.occasion_tags @> array[match_occasion])
    and (match_style is null or a.style_tags @> array[match_style])
    and (match_brand_tier is null or a.brand_tier = match_brand_tier)
    and (match_gender is null or a.gender in (match_gender, 'unisex'))
    and 1 - (a.embedding <=> anchor.embedding) >= min_similarity
  order by a.embedding <=> anchor.embedding
  limit greatest(match_count, 1)
$$;

create or replace function public.recommend_items_by_embedding(
  query_embedding vector(768),
  match_category text default null,
  match_occasion text default null,
  match_style text default null,
  match_brand_tier text default null,
  require_stock boolean default true,
  match_count int default 6,
  min_similarity float default 0.30,
  match_gender text default null
) returns table (
  id uuid, brand_name text, name text, category text,
  price numeric, currency text, buy_url text, image_url text, similarity float
)
language sql stable security definer
set search_path = public
as $$
  select a.id, a.brand_name, a.name, a.category, a.price, a.currency,
         a.buy_url, a.image_url,
         1 - (a.embedding <=> query_embedding) as similarity
  from public.affiliate_items a
  where a.active
    and a.embedding is not null
    and (not require_stock or a.in_stock)
    and (match_category is null or a.category = match_category)
    and (match_occasion is null or a.occasion_tags @> array[match_occasion])
    and (match_style is null or a.style_tags @> array[match_style])
    and (match_brand_tier is null or a.brand_tier = match_brand_tier)
    and (match_gender is null or a.gender in (match_gender, 'unisex'))
    and 1 - (a.embedding <=> query_embedding) >= min_similarity
  order by a.embedding <=> query_embedding
  limit greatest(match_count, 1)
$$;

grant execute on function public.match_affiliate_items(vector, int, text, float, text)
  to authenticated, service_role;
grant execute on function public.recommend_items(uuid, text, text, text, text, boolean, int, float, text)
  to authenticated, service_role;
grant execute on function public.recommend_items_by_embedding(vector, text, text, text, text, boolean, int, float, text)
  to authenticated, service_role;
