-- 0017: set-level feedback — fires when the user walks away from a generated
-- set without keeping a look. Low ratings route into the preference-upload
-- flow (reference_looks → style_dna), closing the taste loop.
create table if not exists public.look_feedback (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  generation_id uuid,
  rating        int not null check (rating between 1 and 5),
  created_at    timestamptz not null default now()
);
create index if not exists look_feedback_user_idx on public.look_feedback (user_id, created_at desc);
alter table public.look_feedback enable row level security;
drop policy if exists "own feedback" on public.look_feedback;
create policy "own feedback" on public.look_feedback
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
