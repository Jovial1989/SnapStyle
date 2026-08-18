-- The library's category vocabulary was written before the editor had slots.
--
-- affiliate_items.category was constrained to top/bottom/shoes/outerwear/
-- accessory, but the editor asks its pool for the SLOT it is filling — and the
-- slots split accessories into watch, glasses, jewelry, belt and bag, and add
-- dress. So every dress and every accessory idea missed the library by
-- vocabulary alone and fell through to a per-thumbnail hosted render: ~4 cents
-- and several seconds each, for garments whose flat-lays were already sitting
-- in the catalogue bucket unused (15 dresses, 20 accessories).
--
-- 'accessory' stays valid so nothing already stored has to move.
alter table public.affiliate_items
  drop constraint if exists affiliate_items_category_check;
alter table public.affiliate_items
  add constraint affiliate_items_category_check
  check (category in ('top','bottom','shoes','outerwear','accessory',
                      'dress','watch','glasses','jewelry','belt','bag'));
