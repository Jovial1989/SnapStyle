-- 0011 — Try-on render cache.
-- Deterministic SHA-256 key over the FULL generation input (person payload +
-- instruction + reference images + model). A hit returns the stored image and
-- bypasses Gemini entirely (sub-second vs 10-30s). Serves generate-fix (VTON
-- swaps) and item-image (editor rail thumbnails, regenerated every screen
-- entry before this). Service-role only — clients never touch it directly.

create table if not exists public.tryon_cache (
  key         text primary key,               -- sha256 hex of the input fingerprint
  user_id     uuid references auth.users(id) on delete cascade,
  kind        text not null default 'fix' check (kind in ('fix','item')),
  image_path  text not null,                  -- object in the 'generations' bucket (_cache/ prefix)
  mime_type   text not null default 'image/webp',
  hits        int  not null default 0,
  created_at  timestamptz not null default now(),
  last_hit_at timestamptz not null default now()
);

create index if not exists tryon_cache_user_idx on public.tryon_cache (user_id);
create index if not exists tryon_cache_age_idx  on public.tryon_cache (last_hit_at);

-- No policies on purpose: RLS on + zero policies = service-role access only.
alter table public.tryon_cache enable row level security;
