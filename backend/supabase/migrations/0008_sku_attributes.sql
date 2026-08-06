-- Structured SKU attributes for attribute-parity rendering: the diffusion
-- prompt injects these EXPLICITLY ("long-sleeve beige linen shirt") so the
-- model can't hallucinate clothing geometry (sleeve length, fabric, color).
-- Filled offline by the async Gemini tagger (scripts/tag-inventory.mjs);
-- real affiliate feeds will populate them directly at ingest.
alter table public.affiliate_items
  add column if not exists attributes jsonb not null default '{}';

comment on column public.affiliate_items.attributes is
  'Structured render-binding attributes: {sleeve_length: long|short|sleeveless|na, fabric: text, color: text}';
