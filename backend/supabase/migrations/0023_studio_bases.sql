-- Studio base library, and face swap as a step of the render queue.
--
-- THE PIVOT THIS SUPPORTS: stop generating bodies, start reusing ideal ones.
-- Dressing an arbitrary user photo means the mask stage fights the input — a
-- hand across the hip, a three-quarter turn, a garment already occluding the
-- zone. Dressing a studio photograph we own removes that whole class: frontal,
-- evenly lit, arms clear of the torso, nothing over the garment areas. The user
-- becomes themselves through a FACE transfer onto that base, not through a body
-- generated from scratch — which is also how e-commerce try-on has always done
-- it, and it avoids inventing a body with the wrong proportions.
--
-- Selection is by nearest SKIN TONE and build, and that is not a nicety. The
-- swap matches luminance fully but chroma only partly, deliberately: matching
-- all the way would recolour a person's face to the model's tone. So the library
-- has to span tones and the selector has to pick close, or the compromise shows
-- at the neck. `skin_lab` is what makes "close" measurable.

create table if not exists public.studio_bases (
  id           uuid primary key default gen_random_uuid(),
  image_path   text not null unique,          -- path in the `bases` bucket
  gender       text not null check (gender in ('male', 'female', 'unisex')),
  -- Coarse on purpose. A build taxonomy finer than this cannot be chosen
  -- reliably from a selfie plus a height, so it would be precision we do not
  -- have and would only misroute people.
  build        text not null default 'regular'
                 check (build in ('slim', 'regular', 'athletic', 'plus')),
  -- Mean face skin colour in CIE Lab, as `faceswap.advise_base()` reports it.
  -- Lab because distance in it tracks perceived difference; RGB does not.
  skin_l       real not null,
  skin_a       real not null,
  skin_b       real not null,
  -- Face size in the stored photograph, in pixels between the eye corners.
  -- MEASURED constraint, not bookkeeping: FaceMesh finds nothing in a 768x1152
  -- full-body frame (face ~68px), and a face that small has little detail to
  -- carry an identity. A base whose interocular is under ~90px will look like a
  -- smudge after the swap however good the code is.
  interocular  smallint not null,
  -- Provenance is a hard requirement, not metadata. Every base must be one we
  -- have the right to use commercially — licensed stock, a commissioned shoot,
  -- or a permissive-licence source. Never scraped.
  license      text not null,
  credit       text,
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);

create index if not exists studio_bases_pick_idx
  on public.studio_bases (gender, build) where active;

alter table public.studio_bases enable row level security;

-- Authenticated read: the client shows the chosen base while a render runs, and
-- these are our own photographs, not user data. Writes are service-role only.
drop policy if exists studio_bases_read on public.studio_bases;
create policy studio_bases_read on public.studio_bases
  for select to authenticated using (active);

insert into storage.buckets (id, name, public)
  values ('bases', 'bases', false)
  on conflict (id) do nothing;

drop policy if exists bases_read on storage.objects;
create policy bases_read on storage.objects
  for select to authenticated using (bucket_id = 'bases');

-- FACE SWAP AS A STEP OF THE EXISTING QUEUE, not a second queue.
--
-- The swap runs in Python on the GPU box (MediaPipe + OpenCV), so it cannot live
-- in an Edge Function. It could have had its own table; it should not. The
-- transfer and the dressing are one trip for the same user: enqueuing them
-- separately would mean two claims, two model loads' worth of latency and a
-- half-done state to reason about when the second fails. With `face_url` set the
-- worker swaps first and then dresses whatever `steps` asks for — and with
-- `steps` empty it swaps only, which is how a base gets prepared and cached once
-- per user.
alter table public.vton_jobs
  add column if not exists face_url text;

alter table public.vton_jobs
  add column if not exists base_id uuid references public.studio_bases (id);

comment on column public.vton_jobs.face_url is
  'Selfie to transfer onto person_url before dressing. NULL = dress as-is.';
comment on column public.vton_jobs.base_id is
  'Which studio base person_url came from, so a bad base can be traced.';
