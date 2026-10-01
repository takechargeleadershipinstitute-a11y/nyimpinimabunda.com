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
