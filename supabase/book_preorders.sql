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
