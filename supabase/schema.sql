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
