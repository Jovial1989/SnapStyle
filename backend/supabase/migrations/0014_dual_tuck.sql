-- 0014 — Dual tuck generation: fix-render produces BOTH tuck states of a top
-- swap in one job (Promise.all). The row carries the second image so the
-- client caches both on ONE 'completed' event and the Tucked/Untucked toggle
-- becomes a purely local, zero-latency source swap.
alter table public.fix_renders
  add column if not exists image_path_tucked text,
  add column if not exists applied_tucked boolean;
