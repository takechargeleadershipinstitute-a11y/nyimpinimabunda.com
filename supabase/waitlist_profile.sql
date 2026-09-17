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
