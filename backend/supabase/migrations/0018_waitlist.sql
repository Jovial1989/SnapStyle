-- 0018: launch waitlist — the landing's only real conversion until the app
-- ships. Anon INSERT only (the publishable key on the static site can add a
-- row and nothing else); no select/update/delete for clients.
create table if not exists public.waitlist (
  id         uuid primary key default gen_random_uuid(),
  email      text not null,
  locale     text,
  source     text default 'landing',
  created_at timestamptz not null default now()
);
create unique index if not exists waitlist_email_uniq on public.waitlist (lower(email));
alter table public.waitlist enable row level security;
drop policy if exists "anon can join" on public.waitlist;
create policy "anon can join" on public.waitlist
  for insert to anon, authenticated with check (true);
