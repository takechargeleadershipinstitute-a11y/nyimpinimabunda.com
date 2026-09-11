-- Gig guide editors: who may manage public.gig_guide from /manage/gig-guide/
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
  ('takechargeleadershipinstitute@gmail.com', 'TCLI admin account'),
  ('ghoberts@gmail.com', 'Gerald Louw, developer. Remove at handover when no longer needed')
on conflict (email) do nothing;
