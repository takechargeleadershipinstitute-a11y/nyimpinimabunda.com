-- Take Charge book orders, paid through Yoco Checkout
--
-- Run once in the Supabase SQL editor of the TCLI project (cbbhgoahhykpckbtlzkr).
--
-- Unlike book_preorders, the website cannot write here at all. Orders are
-- created by the book-checkout Edge Function (which sets the price on the
-- server) and marked paid by the yoco-webhook Edge Function (which only acts on
-- a correctly signed message from Yoco). Both use the service role.
--
-- TCLI reads orders in Table Editor -> book_orders and moves paid orders on to
-- 'fulfilled' once the book is sent.

create table if not exists public.book_orders (
  id                uuid primary key default gen_random_uuid(),
  created_at        timestamptz not null default now(),

  book              text not null default 'take-charge' check (book in ('take-charge')),

  first_name        text not null check (length(btrim(first_name)) between 1 and 80),
  last_name         text not null check (length(btrim(last_name))  between 1 and 80),
  email             text not null
                      check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and length(email) <= 254),
  phone             text not null
                      check (phone ~ '^\+?[0-9 ()-]+$'
                             and length(regexp_replace(phone, '\D', '', 'g')) between 9 and 15),
  -- Same options as TCLI's Paystack product page: Johannesburg R90,
  -- KwaZulu-Natal R120, collection free. One fee per order.
  delivery          text not null check (delivery in ('johannesburg', 'kzn', 'collection')),
  delivery_fee_cents integer not null check (delivery_fee_cents >= 0),
  delivery_address  text check (delivery_address is null or length(btrim(delivery_address)) between 10 and 500),
  copies            smallint not null check (copies between 1 and 50),
  signed            boolean not null default false,
  sign_for          text check (sign_for is null or length(sign_for) <= 120),

  accepted_terms    boolean not null check (accepted_terms),
  terms_version     text not null check (length(terms_version) <= 40),
  source            text check (source is null or length(source) <= 60),

  -- Set by the function, never by the visitor. Cents, as Yoco expects.
  unit_price_cents  integer not null check (unit_price_cents > 0),
  amount_cents      integer not null check (amount_cents >= 200),
  -- 'test' while the sk_test_ key is in use; test orders never move money.
  mode              text not null check (mode in ('test', 'live')),

  status            text not null default 'pending'
                      check (status in ('pending', 'paid', 'fulfilled', 'cancelled', 'refunded')),
  checkout_id       text unique,
  payment_id        text,
  paid_at           timestamptz,
  last_error        text
);

-- The live table was first created without delivery options (11 Sept 2026,
-- while still empty). No-ops on a fresh install.
alter table public.book_orders
  add column if not exists delivery text check (delivery in ('johannesburg', 'kzn', 'collection')),
  add column if not exists delivery_fee_cents integer check (delivery_fee_cents >= 0);
alter table public.book_orders alter column delivery set not null;
alter table public.book_orders alter column delivery_fee_cents set not null;
alter table public.book_orders alter column delivery_address drop not null;

alter table public.book_orders drop constraint if exists book_orders_address_needed;
alter table public.book_orders add constraint book_orders_address_needed
  check (delivery = 'collection' or delivery_address is not null);

create index if not exists book_orders_created_at_idx on public.book_orders (created_at desc);

alter table public.book_orders enable row level security;
-- No policies and no grants: the publishable key can neither read nor write.
revoke all on public.book_orders from anon, authenticated;


-- Yoco webhook registrations, one per key mode. The signing secret Yoco returns
-- is shown only once, so yoco-webhook stores it here during setup. Service role only.
create table if not exists public.yoco_webhooks (
  mode        text primary key check (mode in ('test', 'live')),
  webhook_id  text not null,
  url         text not null,
  secret      text not null,
  created_at  timestamptz not null default now()
);

alter table public.yoco_webhooks enable row level security;
revoke all on public.yoco_webhooks from anon, authenticated;
