-- Local development fixtures (loaded by `supabase db reset` AFTER the roles seed).
--
-- config.toml [db.seed] sql_paths runs, in order:
--   1. ./seed_roles_and_teams.sql  roles, teams, approval_rules (also safe for hosted)
--   2. ./seed.sql                  this file — LOCAL FIXTURES ONLY, never run on hosted
--
-- Deterministic: fixed UUIDs everywhere; event dates are relative to reset time so
-- "upcoming" stays upcoming. Idempotent (on conflict do nothing).
--
-- Users: public.users.auth_user_id is NOT NULL UNIQUE but has no FK to auth.users,
-- so fixture members are inserted directly with fixed auth_user_id values. They
-- CANNOT log in (no auth.users row). Login-based tests (member/admin/pending
-- sessions) need a test helper that creates auth users via the Auth API and then
-- calls the Edge Functions / bootstrap — see POST_MVP.md.
--
-- Emails use the reserved .test TLD. No real student IDs.
begin;

do $$
begin
  if not exists (select 1 from public.roles where key = 'president') then
    raise exception 'Roles are missing — seed_roles_and_teams.sql must run before seed.sql';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Events: published upcoming, unpublished, published past
-- ---------------------------------------------------------------------------
insert into public.events
  (id, title, description, location, starts_at, ends_at, semester, year, is_published, is_past)
select v.id, v.title, v.description, v.location, v.starts_at, v.starts_at + interval '2 hours',
  (case when extract(month from v.starts_at) between 1 and 7 then 'spring' else 'fall' end)::public.semester_term,
  extract(year from v.starts_at)::int, v.is_published, v.is_past
from (values
  ('00000000-0000-4000-8000-00000000e001'::uuid, 'Fixture: Published Upcoming Event',
    'Public upcoming event for anonymous discovery tests.', 'Engineering 101',
    date_trunc('day', now()) + interval '14 days 18 hours', true, false),
  ('00000000-0000-4000-8000-00000000e002'::uuid, 'Fixture: Unpublished Event',
    'Draft event — must not be visible to anon or ordinary members.', 'Engineering 102',
    date_trunc('day', now()) + interval '21 days 18 hours', false, false),
  ('00000000-0000-4000-8000-00000000e003'::uuid, 'Fixture: Published Past Event',
    'Public historical event.', 'Engineering 103',
    date_trunc('day', now()) - interval '30 days' + interval '18 hours', true, true)
) as v(id, title, description, location, starts_at, is_published, is_past)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Projects: published active, unpublished, published completed
-- ---------------------------------------------------------------------------
insert into public.projects
  (id, name, description, status, semester, year, is_published, is_past)
select v.id, v.name, v.description, v.status::public.project_status,
  (case when extract(month from now()) between 1 and 7 then 'spring' else 'fall' end)::public.semester_term,
  extract(year from now())::int, v.is_published, v.is_past
from (values
  ('00000000-0000-4000-8000-00000000b001'::uuid, 'Fixture: Published Active Project',
    'Public active project.', 'active', true, false),
  ('00000000-0000-4000-8000-00000000b002'::uuid, 'Fixture: Unpublished Project',
    'Draft project — team must not appear in public charts.', 'active', false, false),
  ('00000000-0000-4000-8000-00000000b003'::uuid, 'Fixture: Published Completed Project',
    'Public completed project.', 'completed', true, true)
) as v(id, name, description, status, is_published, is_past)
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Fixture members (no auth.users rows — see header)
-- ---------------------------------------------------------------------------
insert into public.users
  (id, auth_user_id, student_id, email, is_pending, email_verified, is_deactivated, approved_at)
values
  ('00000000-0000-4000-8000-0000000a0001', '00000000-0000-4000-8000-0000000f0001', null, 'president@fixture.test',     false, true, false, now()),
  ('00000000-0000-4000-8000-0000000a0002', '00000000-0000-4000-8000-0000000f0002', null, 'events-lead@fixture.test',   false, true, false, now()),
  ('00000000-0000-4000-8000-0000000a0003', '00000000-0000-4000-8000-0000000f0003', null, 'pm@fixture.test',            false, true, false, now()),
  ('00000000-0000-4000-8000-0000000a0004', '00000000-0000-4000-8000-0000000f0004', null, 'member@fixture.test',        false, true, false, now()),
  ('00000000-0000-4000-8000-0000000a0005', '00000000-0000-4000-8000-0000000f0005', null, 'pending@fixture.test',       true,  true, false, null),
  ('00000000-0000-4000-8000-0000000a0006', '00000000-0000-4000-8000-0000000f0006', null, 'deactivated@fixture.test',   false, true, true,  now()),
  ('00000000-0000-4000-8000-0000000a0007', '00000000-0000-4000-8000-0000000f0007', null, 'former-vp@fixture.test',     false, true, false, now())
on conflict (id) do nothing;

insert into public.profiles (user_id, first_name, last_name, linkedin_url) values
  ('00000000-0000-4000-8000-0000000a0001', 'Pat',    'President',   'https://www.linkedin.com/in/fixture-president'),
  ('00000000-0000-4000-8000-0000000a0002', 'Evelyn', 'Events',      null),
  ('00000000-0000-4000-8000-0000000a0003', 'Parker', 'Manager',     null),
  ('00000000-0000-4000-8000-0000000a0004', 'Morgan', 'Member',      null),
  ('00000000-0000-4000-8000-0000000a0005', 'Penny',  'Pending',     null),
  ('00000000-0000-4000-8000-0000000a0006', 'Dana',   'Deactivated', null),
  ('00000000-0000-4000-8000-0000000a0007', 'Vic',    'FormerVP',    null)
on conflict (user_id) do nothing;

-- ---------------------------------------------------------------------------
-- Leadership: current (President, Events Lead), deactivated (hidden from
-- current), and an ended VP assignment (history only).
-- ---------------------------------------------------------------------------
insert into public.role_assignments (id, user_id, role_id, team_id, is_active, assigned_at, ended_at)
select v.id, v.user_id, r.id, t.id, v.is_active, now() - interval '90 days', v.ended_at
from (values
  ('00000000-0000-4000-8000-0000000c0001'::uuid, '00000000-0000-4000-8000-0000000a0001'::uuid, 'president',     'executive', true,  null::timestamptz),
  ('00000000-0000-4000-8000-0000000c0002'::uuid, '00000000-0000-4000-8000-0000000a0002'::uuid, 'events_lead',   'events',    true,  null),
  ('00000000-0000-4000-8000-0000000c0003'::uuid, '00000000-0000-4000-8000-0000000a0006'::uuid, 'outreach_lead', 'outreach',  true,  null),
  ('00000000-0000-4000-8000-0000000c0004'::uuid, '00000000-0000-4000-8000-0000000a0007'::uuid, 'vp',            'executive', false, now() - interval '30 days')
) as v(id, user_id, role_key, team_key, is_active, ended_at)
join public.roles r on r.key = v.role_key
join public.teams t on t.key = v.team_key
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- Project teams: published project (visible in chart) + unpublished (hidden)
-- ---------------------------------------------------------------------------
insert into public.project_assignments (id, project_id, user_id, role_id, is_active)
select v.id, v.project_id, v.user_id, r.id, true
from (values
  ('00000000-0000-4000-8000-0000000d0001'::uuid, '00000000-0000-4000-8000-00000000b001'::uuid, '00000000-0000-4000-8000-0000000a0003'::uuid, 'project_manager'),
  ('00000000-0000-4000-8000-0000000d0002'::uuid, '00000000-0000-4000-8000-00000000b001'::uuid, '00000000-0000-4000-8000-0000000a0004'::uuid, 'project_member'),
  ('00000000-0000-4000-8000-0000000d0003'::uuid, '00000000-0000-4000-8000-00000000b002'::uuid, '00000000-0000-4000-8000-0000000a0003'::uuid, 'project_manager'),
  ('00000000-0000-4000-8000-0000000d0004'::uuid, '00000000-0000-4000-8000-00000000b002'::uuid, '00000000-0000-4000-8000-0000000a0004'::uuid, 'project_member')
) as v(id, project_id, user_id, role_key)
join public.roles r on r.key = v.role_key
on conflict (id) do nothing;

commit;
