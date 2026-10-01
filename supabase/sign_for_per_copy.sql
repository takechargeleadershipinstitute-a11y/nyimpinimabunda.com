-- Personalisation per copy (1 Oct 2026): one "for ..." per book in an order,
-- so the stored text can be much longer than a single name.
alter table public.book_preorders drop constraint if exists book_preorders_sign_for_check;
alter table public.book_preorders add constraint book_preorders_sign_for_check
  check (sign_for is null or length(sign_for) <= 4000);
alter table public.book_orders drop constraint if exists book_orders_sign_for_check;
alter table public.book_orders add constraint book_orders_sign_for_check
  check (sign_for is null or length(sign_for) <= 4000);
