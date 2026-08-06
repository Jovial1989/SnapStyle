-- Fast Recommendation Engine: hybrid vector + hard-rule search, NO LLM in the
-- hot path. The LLM's only role is ASYNC inventory tagging (see
-- scripts/tag-inventory.mjs) — it pre-computes the tags these hard WHERE
-- clauses filter on. Real-time requests are pure SQL + pgvector math.

-- Pre-computed tag columns (filled offline by the Gemini tagger).
alter table public.affiliate_items
  add column if not exists in_stock boolean not null default true,
  add column if not exists brand_tier text,                          -- premium | mid | value
  add column if not exists style_tags text[] not null default '{}',  -- e.g. {minimalist,casual}
  add column if not exists occasion_tags text[] not null default '{}'; -- e.g. {date,office,beach}

-- GIN indexes make the array-containment filters index-supported.
create index if not exists affiliate_items_style_tags_idx
  on public.affiliate_items using gin (style_tags);
create index if not exists affiliate_items_occasion_tags_idx
  on public.affiliate_items using gin (occasion_tags);

-- ── Hybrid search, anchor by SKU id (embedding looked up in-query: one
-- round-trip total). Cosine distance (<=>) + strict metadata WHERE. ─────────
create or replace function public.recommend_items(
  anchor_id uuid,
  match_category text default null,
  match_occasion text default null,
  match_style text default null,
  match_brand_tier text default null,
  require_stock boolean default true,
  match_count int default 6,
  min_similarity float default 0.30
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
    and 1 - (a.embedding <=> anchor.embedding) >= min_similarity
  order by a.embedding <=> anchor.embedding
  limit greatest(match_count, 1)
$$;

-- ── Same search, anchor by raw pre-computed embedding (e.g. the wardrobe
-- item the user is holding, embedded at ingest time). ───────────────────────
create or replace function public.recommend_items_by_embedding(
  query_embedding vector(768),
  match_category text default null,
  match_occasion text default null,
  match_style text default null,
  match_brand_tier text default null,
  require_stock boolean default true,
  match_count int default 6,
  min_similarity float default 0.30
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
    and 1 - (a.embedding <=> query_embedding) >= min_similarity
  order by a.embedding <=> query_embedding
  limit greatest(match_count, 1)
$$;

grant execute on function public.recommend_items(uuid, text, text, text, text, boolean, int, float)
  to authenticated, service_role;
grant execute on function public.recommend_items_by_embedding(vector, text, text, text, text, boolean, int, float)
  to authenticated, service_role;
