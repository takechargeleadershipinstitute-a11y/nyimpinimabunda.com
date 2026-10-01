-- FULL REBUILD of the nyimpini.com database on a NEW Supabase project (1 Oct 2026).
-- Paste the whole file into SQL Editor and Run once. Built from the scripts in this
-- folder, in the order they were originally applied, then: required-field rules,
-- the editors list for the new account, and the public gig guide events copied
-- from the old project. Safe to re-run.


-- ════════════════ schema.sql ════════════════
-- Waitlist storage for nyimpinimabunda.com
--
-- Run once in the Supabase SQL editor (Dashboard -> SQL Editor -> New query).
--
-- Design note: the page posts here directly from the browser using the
-- publishable (anon) key. That is only safe because of the policy at the
-- bottom: anon may INSERT and may do nothing else. Without it, the anon key
-- would let anyone read the entire mailing list.

create table if not exists public.waitlist (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),

  first_name  text not null check (length(btrim(first_name)) between 1 and 80),
  last_name   text not null check (length(btrim(last_name))  between 1 and 80),
  -- Stored lower-cased by the page. Unique so a double submission is a 409
  -- rather than a duplicate row; the page treats 409 as success.
  email       text not null unique
                check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and length(email) <= 254),

  interests   text[] not null default '{}',
  source      text,

  -- Set by the Edge Function so a failed hand-off to beehiiv is visible and
  -- retryable, instead of silently losing a subscriber.
  synced_at   timestamptz,
  sync_error  text
);

create index if not exists waitlist_created_at_idx on public.waitlist (created_at desc);
create index if not exists waitlist_unsynced_idx   on public.waitlist (created_at)
  where synced_at is null;

alter table public.waitlist enable row level security;

-- Insert only. No select, update or delete policy exists for anon, and with RLS
-- on, anything without a policy is denied. Staff read the list in the dashboard,
-- which uses the service role and bypasses RLS.
drop policy if exists "anon can join the waitlist" on public.waitlist;
create policy "anon can join the waitlist"
  on public.waitlist
  for insert
  to anon
  with check (true);

-- Belt and braces: revoke everything, then grant back only the insert.
revoke all on public.waitlist from anon;
grant insert on public.waitlist to anon;


-- ════════════════ waitlist_profile.sql ════════════════
-- Waitlist: title, job title, industry (Sept 2026)
--
-- RUN THIS BEFORE deploying the waitlist page that sends these fields.
-- PostgREST rejects an insert naming a column that does not exist, so the
-- page must never go live ahead of the columns.
--
-- All three are nullable on purpose: the CEO Nights dialog, the U-GRIP page
-- and any cached copy of the old waitlist page do not send them, and must
-- keep working. The waitlist form itself enforces what is required.

alter table public.waitlist
  add column if not exists title     text check (title in ('Mr','Ms','Mrs','Dr','Prof','Adv','Prefer not to say')),
  add column if not exists job_title text check (length(btrim(job_title)) between 1 and 120),
  add column if not exists industry  text check (length(btrim(industry))  between 1 and 80);

-- anon already holds table-level INSERT, which covers new columns.


-- ════════════════ book_preorders.sql ════════════════
-- CEO Nights book pre-orders for nyimpinimabunda.com
--
-- Run once in the Supabase SQL editor of the TCLI project (cbbhgoahhykpckbtlzkr).
--
-- Kept separate from public.waitlist on purpose: a pre-order needs a contact
-- number and a quantity, and the same person may order more than once, which
-- the waitlist's unique email would turn into a silent 409.
--
-- Same safety model as the waitlist: the page posts with the publishable key,
-- which may INSERT the visitor-supplied columns and do nothing else. TCLI reads
-- and updates orders in the dashboard, which uses the service role.

create table if not exists public.book_preorders (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),

  book        text not null default 'ceo-nights' check (book in ('ceo-nights')),

  first_name  text not null check (length(btrim(first_name)) between 1 and 80),
  last_name   text not null check (length(btrim(last_name))  between 1 and 80),
  email       text not null
                check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' and length(email) <= 254),
  -- Stored as typed. 9 to 15 digits covers a local 0XX number and a full
  -- international +CC number.
  phone       text not null
                check (phone ~ '^\+?[0-9 ()-]+$'
                       and length(regexp_replace(phone, '\D', '', 'g')) between 9 and 15),
  copies      smallint not null default 1 check (copies between 1 and 50),
  signed      boolean not null default false,
  source      text check (source is null or length(source) <= 60),

  -- The consent tick is kept with the order, plus which version of /terms/
  -- (its "Last updated" date) the visitor accepted.
  accepted_terms boolean,
  terms_version  text check (terms_version is null or length(terms_version) <= 40),

  -- Moved along by TCLI in the dashboard. The page cannot write this column.
  status      text not null default 'new'
                check (status in ('new', 'contacted', 'paid', 'fulfilled', 'cancelled'))
);

-- For a table created before the consent columns existed (the live table was,
-- on 11 Sept 2026). No-ops on a fresh install.
alter table public.book_preorders
  add column if not exists accepted_terms boolean,
  add column if not exists terms_version  text
    check (terms_version is null or length(terms_version) <= 40);

create index if not exists book_preorders_created_at_idx
  on public.book_preorders (created_at desc);

alter table public.book_preorders enable row level security;

-- Insert only. With RLS on and no select, update or delete policy, the
-- publishable key can never read the order list back.
drop policy if exists "anon can place a pre-order" on public.book_preorders;
create policy "anon can place a pre-order"
  on public.book_preorders
  for insert
  to anon
  with check (status = 'new' and accepted_terms is true and terms_version is not null);

-- Belt and braces: revoke everything, then grant INSERT on the visitor-supplied
-- columns only, so nobody can post a row that arrives already marked 'paid'.
revoke all on public.book_preorders from anon, authenticated;
grant insert (book, first_name, last_name, email, phone, copies, signed,
              accepted_terms, terms_version, source)
  on public.book_preorders to anon;


-- ════════════════ book_orders.sql ════════════════
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


-- ════════════════ gig_guide.sql ════════════════
-- Gig guide for nyimpinimabunda.com (/gig-guide/)
--
-- Run once in the Supabase SQL editor of the TCLI project (cbbhgoahhykpckbtlzkr).
--
-- TCLI keeps this table up to date in the Table Editor; the page reads it with
-- the publishable key, so nobody has to edit website code to add an event.
--
-- One table holds both halves of the gig guide:
--   public columns   event, host, dates, city, country, link   -> readable by the site
--   planning columns venue, theme, attendance, audience, dress  -> TCLI only
-- Column-level grants keep the planning columns out of the public API entirely.

create table if not exists public.gig_guide (
  id                   uuid primary key default gen_random_uuid(),
  created_at           timestamptz not null default now(),

  -- Public
  event_name           text not null check (length(btrim(event_name)) between 1 and 120),
  organisation         text check (organisation is null or length(organisation) <= 120),
  starts_on            date not null,
  ends_on              date check (ends_on is null or ends_on >= starts_on),
  -- Optional, South African time (SAST, UTC+2). Used for calendar links.
  start_time           time,
  end_time             time,
  city                 text check (city is null or length(city) <= 80),
  country              text check (country is null or length(country) <= 80),
  link                 text check (link is null or link ~* '^https://'),
  -- Short type label shown as a tag: Conference, Keynote, CEO Nights, Masterclass...
  category             text check (category is null or length(category) <= 40),
  -- Tick for a corporate booking whose client should not be named. The site shows
  -- "Private corporate session" and the city only.
  private              boolean not null default false,
  -- Untick to hide an event from the site entirely without deleting it.
  published            boolean not null default true,

  -- TCLI only: never readable through the website's key
  venue                text,
  theme                text,
  expected_attendance  text,
  audience             text,
  dress_code           text,
  notes                text
);

-- For a table created before these columns existed (the live one was). No-op otherwise.
alter table public.gig_guide
  add column if not exists category text check (category is null or length(category) <= 40),
  add column if not exists private  boolean not null default false,
  add column if not exists start_time time,
  add column if not exists end_time   time;

create index if not exists gig_guide_starts_on_idx on public.gig_guide (starts_on);

alter table public.gig_guide enable row level security;

-- Read-only, published rows only. No insert, update or delete policy exists for
-- the public key: TCLI edits the table in the dashboard (service role).
drop policy if exists "anyone can read published gig guide events" on public.gig_guide;
create policy "anyone can read published gig guide events"
  on public.gig_guide
  for select
  to anon
  using (published);

-- Belt and braces: revoke everything, then grant SELECT on the public columns only.
-- `published` is included because the policy above reads it.
revoke all on public.gig_guide from anon, authenticated;
grant select (id, event_name, organisation, starts_on, ends_on, start_time, end_time,
              city, country, link, category, private, published)
  on public.gig_guide to anon;


-- ════════════════ gig_guide_editors.sql ════════════════
-- Gig guide editors: who may manage public.gig_guide from /admin/
--
-- Run once in the Supabase SQL editor of the TCLI project (cbbhgoahhykpckbtlzkr),
-- after supabase/gig_guide.sql.
--
-- How access works:
--   * Anyone can request a sign-in email on the manage page, but signing in
--     grants nothing by itself.
--   * Only emails listed in public.gig_guide_editors can read unpublished rows or
--     add, change and delete gig guide events. Every policy below checks it.
--   * The list itself is invisible to the website: no anon or authenticated
--     access. Add or remove people in the Table Editor.

create table if not exists public.gig_guide_editors (
  email     text primary key
              check (email = lower(btrim(email)) and email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  added_at  timestamptz not null default now(),
  note      text
);
alter table public.gig_guide_editors enable row level security;
revoke all on public.gig_guide_editors from anon, authenticated;

-- security definer so policies can consult the list without granting anyone
-- read access to it. search_path pinned to '' so nothing can be shadowed.
create or replace function public.is_gig_guide_editor()
returns boolean
language sql
stable
security definer
set search_path = ''
as $fn$
  select exists (
    select 1 from public.gig_guide_editors e
    where e.email = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$fn$;
revoke all on function public.is_gig_guide_editor() from public, anon;
grant execute on function public.is_gig_guide_editor() to authenticated;

-- "Last edited" on each event, maintained by the database.
alter table public.gig_guide add column if not exists updated_at timestamptz not null default now();

create or replace function public.gig_guide_touch()
returns trigger
language plpgsql
set search_path = ''
as $fn$
begin
  new.updated_at := now();
  return new;
end;
$fn$;
drop trigger if exists gig_guide_touch on public.gig_guide;
create trigger gig_guide_touch before update on public.gig_guide
  for each row execute function public.gig_guide_touch();

-- Editors: full read and write on gig_guide. The public (anon) policy in
-- gig_guide.sql is untouched: visitors still see published public columns only.
drop policy if exists "editors can read every gig guide row" on public.gig_guide;
create policy "editors can read every gig guide row" on public.gig_guide
  for select to authenticated using (public.is_gig_guide_editor());
drop policy if exists "editors can add gig guide rows" on public.gig_guide;
create policy "editors can add gig guide rows" on public.gig_guide
  for insert to authenticated with check (public.is_gig_guide_editor());
drop policy if exists "editors can change gig guide rows" on public.gig_guide;
create policy "editors can change gig guide rows" on public.gig_guide
  for update to authenticated using (public.is_gig_guide_editor()) with check (public.is_gig_guide_editor());
drop policy if exists "editors can delete gig guide rows" on public.gig_guide;
create policy "editors can delete gig guide rows" on public.gig_guide
  for delete to authenticated using (public.is_gig_guide_editor());

grant select, insert, update, delete on public.gig_guide to authenticated;

insert into public.gig_guide_editors (email, note) values
  ('zimasa@takechargeli.co.za', 'TCLI, keeps the gig guide up to date'),
  ('takecharge.tcli@outlook.com', 'TCLI admin account'),
  ('ghoberts@gmail.com', 'Gerald Louw, developer. Remove at handover when no longer needed')
on conflict (email) do nothing;


-- ════════════════ book_orders_via_links.sql ════════════════
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


-- ════════════════ profile_fields_all_forms.sql ════════════════
-- Title, job title and industry on every form (Sept 2026)
--
-- Run in TWO parts, in order.
--
-- PART 1: run now. Adds the columns. Safe at any time: nothing sends them yet
-- except the waitlist page, and the columns accept blanks until Part 2.

alter table public.waitlist drop constraint if exists waitlist_title_check;
alter table public.waitlist
  add constraint waitlist_title_check check (title in ('Mr','Ms','Mrs','Dr','Prof','Adv'));

alter table public.book_preorders
  add column if not exists title     text check (title in ('Mr','Ms','Mrs','Dr','Prof','Adv')),
  add column if not exists job_title text check (length(btrim(job_title)) between 1 and 120),
  add column if not exists industry  text check (length(btrim(industry))  between 1 and 80);

alter table public.book_orders
  add column if not exists title     text check (title in ('Mr','Ms','Mrs','Dr','Prof','Adv')),
  add column if not exists job_title text check (length(btrim(job_title)) between 1 and 120),
  add column if not exists industry  text check (length(btrim(industry))  between 1 and 80);


-- PART 2: run ONLY after the new pages are live on BOTH nyimpini.com and
-- pages.dev, and book-checkout is redeployed. From then on the database itself
-- refuses any new signup or order missing these fields, so the rule cannot be
-- bypassed by skipping the website. NOT VALID leaves existing rows untouched.
--
-- alter table public.waitlist       add constraint waitlist_profile_required
--   check (title is not null and job_title is not null and industry is not null) not valid;
-- alter table public.book_preorders add constraint book_preorders_profile_required
--   check (title is not null and job_title is not null and industry is not null) not valid;
-- alter table public.book_orders    add constraint book_orders_profile_required
--   check (title is not null and job_title is not null and industry is not null) not valid;

-- Part 1b: the pre-order table uses column-level grants, so the new columns need one.
grant insert (title, job_title, industry) on public.book_preorders to anon;


-- ════════════════ book_orders_dashboard.sql ════════════════
-- (re-run safety: a later section changes this function's return type)
drop function if exists public.set_book_order_status(uuid, text);
-- Book orders on the manager dashboard (Sept 2026)
--
-- Run once in the Supabase SQL editor, after book_orders_via_links.sql.
--
-- 1. Who changed an order's status, and when.
-- 2. list_book_orders(): the full order list, for signed-in dashboard editors
--    only. Unlike site_stats() this DOES return names and contact details,
--    because TCLI needs them to match payments and send books.
-- 3. set_book_order_status(): the only way the dashboard changes an order.
-- 4. site_stats(): adds per-book order counts for the "At a glance" tiles.

alter table public.book_preorders
  add column if not exists status_changed_at timestamptz,
  add column if not exists status_changed_by text;

create or replace function public.list_book_orders()
returns setof public.book_preorders
language plpgsql
stable
security definer
set search_path = ''
as $fn$
begin
  if not public.is_gig_guide_editor() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return query
    select * from public.book_preorders
    order by created_at desc
    limit 1000;
end;
$fn$;
revoke all on function public.list_book_orders() from public, anon;
grant execute on function public.list_book_orders() to authenticated;

create or replace function public.set_book_order_status(p_id uuid, p_status text)
returns public.book_preorders
language plpgsql
volatile
security definer
set search_path = ''
as $fn$
declare
  rec public.book_preorders;
begin
  if not public.is_gig_guide_editor() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_status not in ('new', 'contacted', 'paid', 'fulfilled', 'cancelled') then
    raise exception 'bad status' using errcode = '22023';
  end if;
  update public.book_preorders
     set status = p_status,
         status_changed_at = now(),
         status_changed_by = lower(auth.jwt() ->> 'email')
   where id = p_id
  returning * into rec;
  if rec.id is null then
    raise exception 'order not found' using errcode = 'P0002';
  end if;
  return rec;
end;
$fn$;
revoke all on function public.set_book_order_status(uuid, text) from public, anon;
grant execute on function public.set_book_order_status(uuid, text) to authenticated;

create or replace function public.site_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  tz        constant text := 'Africa/Johannesburg';
  today     date := (now() at time zone 'Africa/Johannesburg')::date;
  this_week date := date_trunc('week', now() at time zone 'Africa/Johannesburg')::date;
  result    jsonb;
begin
  if not public.is_gig_guide_editor() then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  with w as (
    select (created_at at time zone tz)::date as day, created_at, interests
    from public.waitlist
    where email not ilike '%@example.com'
  ), p as (
    select (created_at at time zone tz)::date as day, created_at, copies, signed, book, status
    from public.book_preorders
    where email not ilike '%@example.com'
      and coalesce(source, '') <> 'smoke-test'
      and status <> 'cancelled'
  ), o as (
    select (coalesce(paid_at, created_at) at time zone tz)::date as day,
           copies, amount_cents, status, mode
    from public.book_orders
  ), paid as (
    select * from o where mode = 'live' and status in ('paid', 'fulfilled')
  ), g as (
    select coalesce(ends_on, starts_on) as last_day, published
    from public.gig_guide
  ), weeks as (
    -- generate_series has no (date, date, integer) form; step timestamps by 7 days.
    select d::date as week
    from generate_series((this_week - 77)::timestamp, this_week::timestamp, interval '7 days') as d
  )
  select jsonb_build_object(
    'generated_at', now(),
    'totals', jsonb_build_object(
      'mailing_list',        (select count(*) from w),
      'mailing_list_7d',     (select count(*) from w where created_at >= now() - interval '7 days'),
      'interest_tcli',       (select count(*) from w where 'tcli' = any(interests)),
      'interest_ceo_nights', (select count(*) from w where 'ceo-nights' = any(interests)),
      'interest_book',       (select count(*) from w where 'book' = any(interests)),
      'interest_ugrip',      (select count(*) from w where 'ugrip' = any(interests)),
      'preorders',           (select count(*) from p where book = 'ceo-nights'),
      'preorders_7d',        (select count(*) from p where book = 'ceo-nights' and created_at >= now() - interval '7 days'),
      'preorder_copies',     (select coalesce(sum(copies), 0) from p where book = 'ceo-nights'),
      'preorder_signed',     (select count(*) from p where book = 'ceo-nights' and signed),
      -- Orders placed through the details form + Yoco link, per book.
      'cn_new',              (select count(*) from p where book = 'ceo-nights'  and status in ('new', 'contacted')),
      'cn_paid',             (select count(*) from p where book = 'ceo-nights'  and status in ('paid', 'fulfilled')),
      'cn_to_send',          (select count(*) from p where book = 'ceo-nights'  and status = 'paid'),
      'tc_orders',           (select count(*) from p where book = 'take-charge'),
      'tc_orders_7d',        (select count(*) from p where book = 'take-charge' and created_at >= now() - interval '7 days'),
      'tc_new',              (select count(*) from p where book = 'take-charge' and status in ('new', 'contacted')),
      'tc_paid',             (select count(*) from p where book = 'take-charge' and status in ('paid', 'fulfilled')),
      'tc_to_send',          (select count(*) from p where book = 'take-charge' and status = 'paid'),
      'orders_paid',         (select count(*) from paid),
      'orders_paid_copies',  (select coalesce(sum(copies), 0) from paid),
      'orders_paid_cents',   (select coalesce(sum(amount_cents), 0) from paid),
      'orders_to_send',      (select count(*) from paid where status = 'paid'),
      'orders_test',         (select count(*) from o where mode = 'test'),
      'events_upcoming',     (select count(*) from g where published and last_day >= today),
      'events_hidden',       (select count(*) from g where not published and last_day >= today)
    ),
    -- Last 12 weeks, Monday to Sunday, South African time, oldest first.
    'weekly', (
      select jsonb_agg(jsonb_build_object(
        'week',         k.week,
        'mailing_list', (select count(*) from w where w.day >= k.week and w.day < k.week + 7),
        'preorders',    (select count(*) from p where p.day >= k.week and p.day < k.week + 7),
        'orders',       (select count(*) from paid where paid.day >= k.week and paid.day < k.week + 7)
      ) order by k.week)
      from weeks k
    )
  ) into result;

  return result;
end;
$fn$;

revoke all on function public.site_stats() from public, anon;
grant execute on function public.site_stats() to authenticated;

-- Admin sign-in for the new TCLI mailbox (Sept 2026). The old Gmail is gone.
insert into public.gig_guide_editors (email, note) values
  ('takecharge.tcli@outlook.com', 'TCLI admin account')
on conflict (email) do nothing;
delete from public.gig_guide_editors where email = 'takechargeleadershipinstitute@gmail.com';


-- ════════════════ book_checkout_both_books.sql ════════════════
-- Yoco checkout for BOTH books (1 Oct 2026)
--
-- Run once in the Supabase SQL editor. Safe to re-run.
--
-- public.book_orders holds orders paid through the Yoco checkout (written only
-- by the book-checkout and yoco-webhook functions). public.book_preorders holds
-- the older orders that were paid by link or not at all. The admin shows both.

-- 1. book_orders: CEO Nights, a buyer-facing reference, optional delivery,
--    and who changed the status.
alter table public.book_orders drop constraint if exists book_orders_book_check;
alter table public.book_orders
  add constraint book_orders_book_check check (book in ('take-charge', 'ceo-nights'));

alter table public.book_orders
  add column if not exists order_ref text check (order_ref ~ '^(TC|CN)-[A-Z0-9]{6}$'),
  add column if not exists status_changed_at timestamptz,
  add column if not exists status_changed_by text;
create unique index if not exists book_orders_order_ref_idx
  on public.book_orders (order_ref) where order_ref is not null;

-- CEO Nights is a pre-sale: delivery is arranged on release, so it may be empty.
alter table public.book_orders alter column delivery drop not null;
alter table public.book_orders drop constraint if exists book_orders_address_needed;
alter table public.book_orders add constraint book_orders_address_needed
  check (delivery is null or delivery = 'collection' or delivery_address is not null);

-- 2. One list for the admin: both tables, newest first. "src" says where the
--    order lives: 'yoco' = paid through the checkout, 'link' = older manual order.
create or replace function public.list_all_book_orders()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  result jsonb;
begin
  if not public.is_gig_guide_editor() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb) into result
  from (
    select 'link'::text as src, id, created_at, book, order_ref, title, first_name, last_name,
           email, phone, job_title, industry, copies::int as copies, delivery, delivery_address,
           signed, sign_for, status, status_changed_at, status_changed_by,
           null::int as amount_cents, null::text as mode, null::timestamptz as paid_at
    from public.book_preorders
    union all
    select 'yoco'::text, id, created_at, book, order_ref, title, first_name, last_name,
           email, phone, job_title, industry, copies::int, delivery, delivery_address,
           signed, sign_for, status, status_changed_at, status_changed_by,
           amount_cents, mode, paid_at
    from public.book_orders
  ) x;
  return result;
end;
$fn$;
revoke all on function public.list_all_book_orders() from public, anon;
grant execute on function public.list_all_book_orders() to authenticated;

-- 3. One status change for the admin, whichever table the order is in.
drop function if exists public.set_book_order_status(uuid, text);
create function public.set_book_order_status(p_id uuid, p_status text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $fn$
declare
  who text := lower(auth.jwt() ->> 'email');
  result jsonb;
begin
  if not public.is_gig_guide_editor() then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  if exists (select 1 from public.book_orders where id = p_id) then
    if p_status not in ('pending', 'paid', 'fulfilled', 'cancelled', 'refunded') then
      raise exception 'bad status' using errcode = '22023';
    end if;
    update public.book_orders
       set status = p_status, status_changed_at = now(), status_changed_by = who
     where id = p_id
    returning jsonb_build_object('status', status, 'status_changed_at', status_changed_at,
                                 'status_changed_by', status_changed_by) into result;
    return result;
  end if;

  if p_status not in ('new', 'contacted', 'paid', 'fulfilled', 'cancelled') then
    raise exception 'bad status' using errcode = '22023';
  end if;
  update public.book_preorders
     set status = p_status, status_changed_at = now(), status_changed_by = who
   where id = p_id
  returning jsonb_build_object('status', status, 'status_changed_at', status_changed_at,
                               'status_changed_by', status_changed_by) into result;
  if result is null then
    raise exception 'order not found' using errcode = 'P0002';
  end if;
  return result;
end;
$fn$;
revoke all on function public.set_book_order_status(uuid, text) from public, anon;
grant execute on function public.set_book_order_status(uuid, text) to authenticated;

-- 4. Dashboard counts: per book, across both tables. Test-key orders and
--    @example.com rows are left out; unfinished checkouts count as awaiting payment.
create or replace function public.site_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $fn$
declare
  tz        constant text := 'Africa/Johannesburg';
  today     date := (now() at time zone 'Africa/Johannesburg')::date;
  this_week date := date_trunc('week', now() at time zone 'Africa/Johannesburg')::date;
  result    jsonb;
begin
  if not public.is_gig_guide_editor() then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  with w as (
    select (created_at at time zone tz)::date as day, created_at, interests
    from public.waitlist
    where email not ilike '%@example.com'
  ), o as (
    select (coalesce(paid_at, created_at) at time zone tz)::date as day,
           copies, amount_cents, status, mode
    from public.book_orders
  ), paid as (
    select * from o where mode = 'live' and status in ('paid', 'fulfilled')
  ), u as (
    -- every real order, both tables, with one status vocabulary
    select (created_at at time zone tz)::date as day, created_at, copies::int as copies, signed, book, status
    from public.book_preorders
    where email not ilike '%@example.com'
      and coalesce(source, '') <> 'smoke-test'
      and status <> 'cancelled'
    union all
    select (created_at at time zone tz)::date, created_at, copies::int, signed, book,
           case status when 'pending' then 'new' else status end
    from public.book_orders
    where mode = 'live' and status not in ('cancelled', 'refunded')
      and email not ilike '%@example.com'
  ), g as (
    select coalesce(ends_on, starts_on) as last_day, published
    from public.gig_guide
  ), weeks as (
    select d::date as week
    from generate_series((this_week - 77)::timestamp, this_week::timestamp, interval '7 days') as d
  )
  select jsonb_build_object(
    'generated_at', now(),
    'totals', jsonb_build_object(
      'mailing_list',        (select count(*) from w),
      'mailing_list_7d',     (select count(*) from w where created_at >= now() - interval '7 days'),
      'interest_tcli',       (select count(*) from w where 'tcli' = any(interests)),
      'interest_ceo_nights', (select count(*) from w where 'ceo-nights' = any(interests)),
      'interest_book',       (select count(*) from w where 'book' = any(interests)),
      'interest_ugrip',      (select count(*) from w where 'ugrip' = any(interests)),
      'preorders',           (select count(*) from u where book = 'ceo-nights'),
      'preorders_7d',        (select count(*) from u where book = 'ceo-nights' and created_at >= now() - interval '7 days'),
      'preorder_copies',     (select coalesce(sum(copies), 0) from u where book = 'ceo-nights'),
      'preorder_signed',     (select count(*) from u where book = 'ceo-nights' and signed),
      'cn_new',              (select count(*) from u where book = 'ceo-nights'  and status in ('new', 'contacted')),
      'cn_paid',             (select count(*) from u where book = 'ceo-nights'  and status in ('paid', 'fulfilled')),
      'cn_to_send',          (select count(*) from u where book = 'ceo-nights'  and status = 'paid'),
      'tc_orders',           (select count(*) from u where book = 'take-charge'),
      'tc_orders_7d',        (select count(*) from u where book = 'take-charge' and created_at >= now() - interval '7 days'),
      'tc_new',              (select count(*) from u where book = 'take-charge' and status in ('new', 'contacted')),
      'tc_paid',             (select count(*) from u where book = 'take-charge' and status in ('paid', 'fulfilled')),
      'tc_to_send',          (select count(*) from u where book = 'take-charge' and status = 'paid'),
      'orders_paid',         (select count(*) from paid),
      'orders_paid_copies',  (select coalesce(sum(copies), 0) from paid),
      'orders_paid_cents',   (select coalesce(sum(amount_cents), 0) from paid),
      'orders_to_send',      (select count(*) from paid where status = 'paid'),
      'orders_test',         (select count(*) from o where mode = 'test'),
      'events_upcoming',     (select count(*) from g where published and last_day >= today),
      'events_hidden',       (select count(*) from g where not published and last_day >= today)
    ),
    'weekly', (
      select jsonb_agg(jsonb_build_object(
        'week',         k.week,
        'mailing_list', (select count(*) from w where w.day >= k.week and w.day < k.week + 7),
        'preorders',    (select count(*) from u where u.status in ('new', 'contacted') and u.day >= k.week and u.day < k.week + 7),
        'orders',       (select count(*) from u where u.status in ('paid', 'fulfilled') and u.day >= k.week and u.day < k.week + 7)
      ) order by k.week)
      from weeks k
    )
  ) into result;

  return result;
end;
$fn$;
revoke all on function public.site_stats() from public, anon;
grant execute on function public.site_stats() to authenticated;


-- ════════════════ final: required fields, editors, events ════════════════
alter table public.waitlist drop constraint if exists waitlist_profile_required;
alter table public.waitlist add constraint waitlist_profile_required
  check (title is not null and job_title is not null and industry is not null) not valid;
alter table public.book_preorders drop constraint if exists book_preorders_profile_required;
alter table public.book_preorders add constraint book_preorders_profile_required
  check (title is not null and job_title is not null and industry is not null) not valid;
alter table public.book_orders drop constraint if exists book_orders_profile_required;
alter table public.book_orders add constraint book_orders_profile_required
  check (title is not null and job_title is not null and industry is not null) not valid;

delete from public.gig_guide_editors
  where email in ('takechargeleadershipinstitute@gmail.com', 'takecharge.tcli@outlook.com');
insert into public.gig_guide_editors (email, note) values
  ('takechargeleadership@gmail.com', 'TCLI admin account'),
  ('zimasa@takechargeli.co.za', 'TCLI, keeps the gig guide up to date'),
  ('ghoberts@gmail.com', 'Gerald Louw, developer. Remove at handover when no longer needed')
on conflict (email) do nothing;

insert into public.gig_guide (event_name, organisation, starts_on, ends_on, start_time, end_time, city, country, link, category, private, published)
select event_name, organisation, starts_on::date, ends_on::date, start_time::time, end_time::time, city, country, link, category, private::boolean, published::boolean from (values
  ('CEO Nights with Nyimpini', 'TCLI', '2026-08-20', null, null, null, 'Johannesburg', 'South Africa', null, 'CEO Nights', false, true),
  ('Women''s Day Event', 'TCLI', '2026-08-25', null, null, null, 'Johannesburg', 'South Africa', null, 'Gathering', false, true),
  ('SAUMA Conference', 'SAUMA', '2026-09-04', null, null, null, 'Johannesburg', 'South Africa', null, 'Conference', false, true),
  ('GEC Africa 2026', 'GEC', '2026-09-16', '2026-09-17', null, null, 'Cape Town', 'South Africa', null, 'Conference', false, true),
  ('Joburg CEO Nights with Ben Magara', 'CEO Nights and UCT GSB', '2026-09-17', null, '18:00:00', '21:00:00', 'Johannesburg', 'South Africa', 'https://www.gsb.uct.ac.za/event/791/joburg-ceo-nights-with-ben-magara-ceo-exxaro', 'CEO Nights', false, true),
  ('UGRIP', 'TCLI', '2026-10-10', null, null, null, 'Bloemfontein', 'South Africa', null, 'Programme', false, true),
  ('CEO Nights Book EmpowaWorx House Launch', 'EmpowaWorx House', '2026-10-23', null, '17:00:00', '20:00:00', 'Johannesburg', 'South Africa', null, 'Gathering', false, true),
  ('CEO Nights with Nyimpini', 'UCT', '2026-10-28', null, null, null, 'Johannesburg', 'South Africa', null, 'CEO Nights', false, true),
  ('GIBS MBA Launch', 'Serenity Hotel', '2026-11-14', null, null, null, 'Johannesburg', 'South Africa', null, 'Gathering', false, true),
  ('CEO Nights with Nyimpini', 'UCT', '2026-11-19', null, null, null, 'Johannesburg', 'South Africa', null, null, false, true),
  ('CEO Nights with Nyimpini', 'TCLI', '2026-11-19', null, null, null, 'Johannesburg', 'South Africa', null, 'CEO Nights', false, true),
  ('Durban Book Launch', 'UCT', '2026-11-26', null, null, null, 'Johannesburg', 'South Africa', null, 'CEO Nights', false, true)
) as v(event_name, organisation, starts_on, ends_on, start_time, end_time, city, country, link, category, private, published)
where not exists (select 1 from public.gig_guide);
