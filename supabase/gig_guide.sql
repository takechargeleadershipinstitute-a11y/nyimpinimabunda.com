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
