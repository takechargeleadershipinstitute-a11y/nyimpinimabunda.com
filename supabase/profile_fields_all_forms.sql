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
