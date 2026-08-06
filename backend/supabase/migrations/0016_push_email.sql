-- 0016: push tokens + transactional email plumbing.
-- device_tokens: FCM registration tokens, many devices per user, own-row RLS
-- (the app upserts directly; no EF hop needed).
create table if not exists public.device_tokens (
  token      text primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  platform   text not null default 'ios',
  updated_at timestamptz not null default now()
);
create index if not exists device_tokens_user_idx on public.device_tokens (user_id);
alter table public.device_tokens enable row level security;
drop policy if exists "own tokens" on public.device_tokens;
create policy "own tokens" on public.device_tokens
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- Private config the DB triggers read (no grants to anon/authenticated —
-- only the table owner / security-definer functions can see it).
create schema if not exists private;
create table if not exists private.app_config (
  key   text primary key,
  value text not null
);

-- Welcome-to-Pro email: when entitlements.pro flips false→true (purchase OR
-- FOUNDER26 promo), POST to the send-email EF via pg_net. Fire-and-forget —
-- a dead mailer must never block the entitlement update.
create extension if not exists pg_net;

create or replace function public.notify_pro_welcome()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  em  text;
  sec text;
begin
  if new.pro = true and coalesce(old.pro, false) = false then
    select email into em from auth.users where id = new.user_id;
    select value into sec from private.app_config where key = 'email_webhook_secret';
    if em is not null and sec is not null then
      perform net.http_post(
        url     := 'https://tnirnwapfgckfypvtooj.supabase.co/functions/v1/send-email',
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-email-secret', sec),
        body    := jsonb_build_object(
          'to', em,
          'template', 'welcome_pro',
          'data', jsonb_build_object('plan', coalesce(new.plan, 'promo'), 'source', coalesce(new.source, ''))
        )
      );
    end if;
  end if;
  return new;
end $$;

drop trigger if exists entitlements_pro_welcome on public.entitlements;
create trigger entitlements_pro_welcome
  after update on public.entitlements
  for each row execute function public.notify_pro_welcome();
