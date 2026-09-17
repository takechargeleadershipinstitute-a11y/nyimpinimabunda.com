-- Book orders through Yoco payment links (Sept 2026)
--
-- Both books now use one details form and public.book_preorders, then send the
-- buyer to a Yoco payment link. A link cannot tell the site who paid, so each
-- row carries a short order_ref (TC-XXXXXX / CN-XXXXXX) that the buyer sees.
-- TCLI matches Yoco payments to rows and sets status to 'paid' in the dashboard.

-- Allow Take Charge as well as CEO Nights.
alter table public.book_preorders drop constraint if exists book_preorders_book_check;
alter table public.book_preorders
  add constraint book_preorders_book_check check (book in ('ceo-nights', 'take-charge'));

alter table public.book_preorders
  add column if not exists order_ref text
    check (order_ref ~ '^(TC|CN)-[A-Z0-9]{6}$'),
  add column if not exists delivery text
    check (delivery is null or delivery in ('johannesburg', 'kzn', 'collection')),
  add column if not exists delivery_address text
    check (delivery_address is null or length(btrim(delivery_address)) between 10 and 500),
  add column if not exists sign_for text
    check (sign_for is null or length(sign_for) <= 120);

create unique index if not exists book_preorders_order_ref_idx
  on public.book_preorders (order_ref) where order_ref is not null;

grant insert (order_ref, delivery, delivery_address, sign_for)
  on public.book_preorders to anon;
