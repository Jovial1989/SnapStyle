-- Render queue for the self-hosted VTON engine.
--
-- The GPU worker is NOT reachable from the internet — it holds no open port at
-- all. Instead it connects OUT to Supabase, claims rows here, and writes results
-- back. Edge Functions never call the GPU; they enqueue and wait. Consequences
-- worth stating: there is no public endpoint to attack or to leak, the worker
-- survives its own IP changing (RunPod remaps ports on every restart), and a
-- dead worker degrades into "jobs stay queued" rather than into 5xx storms.

create table if not exists public.vton_jobs (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users (id) on delete cascade,
  status       text not null default 'queued'
                 check (status in ('queued', 'running', 'done', 'failed')),
  -- Inputs are URLs, not bytes: the worker pulls them itself. Keeping megabytes
  -- of base64 out of Postgres keeps the queue table small and the claim fast.
  person_url   text not null,
  -- Ordered dressing steps. Each: {url, kind, hint}. Applied one after another,
  -- each render feeding the next — that is how a full outfit gets built, and
  -- why the order matters (top, then bottom, then shoes).
  steps        jsonb not null,
  result_path  text,               -- Storage path in `generations` once done
  error        text,
  attempts     smallint not null default 0,
  -- Cheap FIFO ordering + a lease so a worker that dies mid-render does not
  -- strand the job forever.
  claimed_at   timestamptz,
  created_at   timestamptz not null default now(),
  finished_at  timestamptz
);

-- The claim query's only index: "oldest queued job". Partial, so it stays tiny
-- however many finished rows accumulate.
create index if not exists vton_jobs_queued_idx
  on public.vton_jobs (created_at)
  where status = 'queued';

create index if not exists vton_jobs_user_idx
  on public.vton_jobs (user_id, created_at desc);

alter table public.vton_jobs enable row level security;

-- Owners may read their own jobs (the client can poll a render it triggered).
-- Nobody but the service role writes: a client that could insert here would be
-- able to spend GPU time directly, bypassing every quota check in the EFs.
drop policy if exists vton_jobs_own_select on public.vton_jobs;
create policy vton_jobs_own_select on public.vton_jobs
  for select using (auth.uid() = user_id);

-- Atomic claim. Without SKIP LOCKED two workers racing the same row both render
-- it and one result is thrown away — paid twice, delivered once. FOR UPDATE
-- alone would serialise them into a queue instead of letting the second worker
-- take the next job.
create or replace function public.claim_vton_job()
returns public.vton_jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  job public.vton_jobs;
begin
  update public.vton_jobs j
     set status = 'running', claimed_at = now(), attempts = j.attempts + 1
   where j.id = (
     select c.id from public.vton_jobs c
      where c.status = 'queued'
         -- Re-offer a job whose worker vanished: 'running' for over 3 minutes
         -- with attempts left. A render is ~2s, so 3 minutes means dead.
         or (c.status = 'running' and c.claimed_at < now() - interval '3 minutes'
             and c.attempts < 3)
      order by c.created_at
      limit 1
      for update skip locked
   )
  returning j.* into job;
  return job;
end;
$$;

revoke all on function public.claim_vton_job() from public, anon, authenticated;
grant execute on function public.claim_vton_job() to service_role;
