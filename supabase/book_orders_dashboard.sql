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
  row public.book_preorders;
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
  returning * into row;
  if row.id is null then
    raise exception 'order not found' using errcode = 'P0002';
  end if;
  return row;
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
