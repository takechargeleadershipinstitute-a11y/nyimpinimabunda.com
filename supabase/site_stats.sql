-- Website sign-up figures for the manager dashboard (/manage/gig-guide/)
--
-- Run once in the Supabase SQL editor of the TCLI project (cbbhgoahhykpckbtlzkr),
-- after gig_guide_editors.sql and book_orders.sql.
--
-- Returns COUNTS ONLY: no names, emails or phone numbers ever leave the database
-- through this function. It runs with the owner's rights so it can count rows in
-- tables the signed-in user cannot read, and refuses anyone who is not on the
-- gig guide editors list.
--
-- Test entries are not counted: waitlist and pre-order rows with an
-- @example.com address, pre-orders with source 'smoke-test', cancelled
-- pre-orders, and book orders placed with Yoco test keys (reported separately).

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
    select (created_at at time zone tz)::date as day, created_at, copies, signed
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
      'preorders',           (select count(*) from p),
      'preorders_7d',        (select count(*) from p where created_at >= now() - interval '7 days'),
      'preorder_copies',     (select coalesce(sum(copies), 0) from p),
      'preorder_signed',     (select count(*) from p where signed),
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
