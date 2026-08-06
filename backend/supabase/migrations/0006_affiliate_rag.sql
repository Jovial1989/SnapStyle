-- Semantic matching (RAG) layer for the branded inventory.
--
-- NOTE: the brief's `branded_inventory` table already exists here as
-- `affiliate_items` (0004): brand_name, product/buy_url, image_url, price,
-- currency, category, source+external_id, active. Creating a second table
-- would fork the catalog — instead this migration adds the missing RAG
-- pieces: a pgvector embedding per SKU + a cosine-similarity match RPC.
-- Embeddings are gemini-embedding-001 @ 768 dims (the project standard —
-- same space as trend_insights).

create extension if not exists vector;

alter table public.affiliate_items
  add column if not exists embedding vector(768);

-- ivfflat wants ~sqrt(rows) lists; 10 is right for a catalog of tens–hundreds.
-- Retune (and re-create) when real feeds push this past ~10k SKUs.
create index if not exists affiliate_items_embedding_idx
  on public.affiliate_items using ivfflat (embedding vector_cosine_ops)
  with (lists = 10);

-- Top-N real SKUs for an AI garment description. SECURITY DEFINER so the
-- authed client role can match without a broad table grant; the function
-- exposes only active rows and only shop-safe columns.
create or replace function public.match_affiliate_items(
  query_embedding vector(768),
  match_count int default 1,
  match_category text default null,
  min_similarity float default 0.35
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
    and 1 - (a.embedding <=> query_embedding) >= min_similarity
  order by a.embedding <=> query_embedding
  limit greatest(match_count, 1)
$$;

grant execute on function public.match_affiliate_items(vector, int, text, float)
  to authenticated, service_role;
