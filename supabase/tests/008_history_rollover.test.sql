-- 2.9 Historical visibility of published past events/projects
-- 2.10 Project rollover across semesters (schema/RLS-level: there is no rollover
--      RPC, so a rollover is an UPDATE of semester/year on the SAME project row)
-- plus the semester model used by the role-request cap.
-- Run: supabase test db   (needs `supabase start` + `npm run db:reset` for seed fixtures)

begin;

-- ---------------------------------------------------------------------------
-- Test harness (identical in every file; everything is rolled back at the end).
--
-- pgTAP itself always runs as the connecting superuser. To assert what a given
-- caller can do, tests call tests.n / tests.err / tests.js, which temporarily
-- switch to the target Postgres role (anon / authenticated / service_role) and
-- set the JWT claims that auth.uid() reads, run ONE statement, then restore.
--   tests.n   -> rows returned/affected, or -1 if the statement raised
--   tests.err -> 'ok' or 'SQLSTATE: message'
--   tests.js  -> jsonb array of result rows (or {"error": ...})
-- Fixture members from seed.sql have no auth.users row, but current_app_user_id()
-- only matches users.auth_user_id = auth.uid(), so setting the JWT `sub` claim to
-- a fixture auth_user_id is sufficient to act as that member.
-- ---------------------------------------------------------------------------
create extension if not exists pgtap with schema extensions;

create schema tests;
grant usage on schema tests to anon, authenticated, service_role;

create function tests.ctx(p_auth uuid, p_role text) returns void
language plpgsql as $fn$
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_auth::text, ''), true);
  perform set_config('request.jwt.claim.role', p_role, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_auth, 'role', p_role)::text, true);
  execute format('set local role %I', p_role);
end $fn$;

create function tests.n(p_auth uuid, p_role text, p_sql text) returns int
language plpgsql as $fn$
declare v int;
begin
  perform tests.ctx(p_auth, p_role);
  begin
    execute p_sql;
    get diagnostics v = row_count;
  exception when others then
    v := -1;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);
  return v;
end $fn$;

create function tests.err(p_auth uuid, p_role text, p_sql text) returns text
language plpgsql as $fn$
declare v text := 'ok';
begin
  perform tests.ctx(p_auth, p_role);
  begin
    execute p_sql;
  exception when others then
    v := sqlstate || ': ' || sqlerrm;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);
  return v;
end $fn$;

create function tests.js(p_auth uuid, p_role text, p_sql text) returns jsonb
language plpgsql as $fn$
declare v jsonb;
begin
  perform tests.ctx(p_auth, p_role);
  begin
    execute format('select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from (%s) t', p_sql) into v;
  exception when others then
    v := jsonb_build_object('error', sqlstate || ': ' || sqlerrm);
  end;
  execute 'reset role';
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claims', '', true);
  return v;
end $fn$;

-- Deterministic ids for users created inside a test.
create function tests.uid(p_name text) returns uuid language sql immutable as
  $fn$ select md5('pgtap-user:' || p_name)::uuid $fn$;
create function tests.aid(p_name text) returns uuid language sql immutable as
  $fn$ select md5('pgtap-auth:' || p_name)::uuid $fn$;

-- seed.sql fixture members (1 president, 2 events_lead, 3 project manager,
-- 4 member, 5 pending, 6 deactivated, 7 former VP): app-user id / auth uid.
create function tests.fu(n int) returns uuid language sql immutable as
  $fn$ select ('00000000-0000-4000-8000-0000000a000' || n)::uuid $fn$;
create function tests.fa(n int) returns uuid language sql immutable as
  $fn$ select ('00000000-0000-4000-8000-0000000f000' || n)::uuid $fn$;

create function tests.mk_user(
  p_name text, p_role text default null, p_team text default null,
  p_pending boolean default false, p_deactivated boolean default false,
  p_rejected boolean default false
) returns uuid language plpgsql as $fn$
declare v uuid := tests.uid(p_name);
begin
  insert into public.users
    (id, auth_user_id, email, is_pending, is_deactivated, is_rejected, email_verified, approved_at)
  values (v, tests.aid(p_name), p_name || '@pgtap.test', p_pending, p_deactivated, p_rejected,
    true, case when p_pending then null else now() end);
  insert into public.profiles (user_id, first_name, last_name) values (v, p_name, 'Tester');
  if p_role is not null then
    insert into public.role_assignments (user_id, role_id, team_id)
    select v, r.id, t.id from public.roles r left join public.teams t on t.key = p_team
    where r.key = p_role;
  end if;
  return v;
end $fn$;

-- Role / team lookups and role-request helpers.
create function tests.rid(p_key text) returns uuid language sql stable as
  $fn$ select id from public.roles where key = p_key $fn$;
create function tests.tid(p_key text) returns uuid language sql stable as
  $fn$ select id from public.teams where key = p_key $fn$;

-- 'fix:N' addresses seed.sql fixture member N; any other name is a tests.mk_user name.
create function tests.auth_of(p_name text) returns uuid language sql immutable as
  $fn$ select case when p_name like 'fix:%' then tests.fa(substr(p_name, 5)::int) else tests.aid(p_name) end $fn$;

create function tests.submit(p_name text, p_role text default 'website_lead', p_team text default null) returns text
language sql as $fn$
  select tests.err(tests.auth_of(p_name), 'authenticated',
    format('select public.submit_role_request(%L, %L, %L)', tests.rid(p_role), tests.tid(p_team), 'pgTAP request'))
$fn$;

-- Resolve the request id as superuser (RLS would hide it from the caller), then
-- call the RPC as the caller.
create function tests.decide(p_fn text, p_actor text, p_requester text, p_status text default 'pending')
returns text language plpgsql as $fn$
declare v_id uuid;
begin
  select id into v_id from public.role_requests
  where requester_id = (select id from public.users where auth_user_id = tests.auth_of(p_requester)) and status::text = p_status
  order by created_at desc, id limit 1;
  return tests.err(case when p_actor is null then null else tests.auth_of(p_actor) end,
    case when p_actor is null then 'anon' else 'authenticated' end,
    format('select public.%I(%L)', p_fn, v_id));
end $fn$;

select plan(30);

-- Setup -----------------------------------------------------------------------
insert into public.events (id, title, starts_at, ends_at, semester, year, is_published, is_past) values
  (tests.uid('ev:old_pub'),   'old published',   '2024-02-10 18:00+00', '2024-02-10 20:00+00', 'spring', 2024, true,  true),
  (tests.uid('ev:old_draft'), 'old unpublished', '2024-03-10 18:00+00', '2024-03-10 20:00+00', 'spring', 2024, false, true);
insert into public.attendances (event_id, user_id, checked_in_at, source)
values ('00000000-0000-4000-8000-00000000e003', tests.fu(4), now() - interval '30 days', 'qr_user');

-- 2.9 Historical events ---------------------------------------------------------
select is(tests.n(null, 'anon', $$select 1 from public.events where id = '00000000-0000-4000-8000-00000000e003' and is_past$$), 1,
  'anon can read the published past event (is_past = true)');
select is(tests.n(null, 'anon', format('select 1 from public.events where id = %L', tests.uid('ev:old_pub'))), 1,
  'anon can read a published event from a past year (no recency cutoff)');
select is(tests.n(null, 'anon', format('select 1 from public.events where id = %L', tests.uid('ev:old_draft'))), 0,
  'anon cannot read an UNPUBLISHED past event');
select is(tests.n(tests.fa(4), 'authenticated', format('select 1 from public.events where id = %L', tests.uid('ev:old_draft'))), 0,
  'a member cannot read an UNPUBLISHED past event');
select is(tests.n(tests.fa(2), 'authenticated', format('select 1 from public.events where id = %L', tests.uid('ev:old_draft'))), 1,
  'event editors can still read an unpublished past event');
select cmp_ok(tests.n(null, 'anon', 'select 1 from public.events where is_past and is_published'), '>=', 2,
  'anon can list the published historical events');
select is(tests.n(tests.fa(2), 'authenticated', $$update public.events set is_past = true where id = '00000000-0000-4000-8000-00000000e001'$$), 1,
  'event editor can archive (mark past) a published event');
select is(tests.n(null, 'anon', $$select 1 from public.events where id = '00000000-0000-4000-8000-00000000e001' and is_past$$), 1,
  'archiving a published event keeps it publicly visible');
select is(tests.n(tests.fa(2), 'authenticated', $$update public.events set is_published = false where id = '00000000-0000-4000-8000-00000000e001'$$), 1,
  'event editor can unpublish an archived event');
select is(tests.n(null, 'anon', $$select 1 from public.events where id = '00000000-0000-4000-8000-00000000e001'$$), 0,
  'unpublishing hides the event from anon again');
select is(tests.n(tests.fa(4), 'authenticated', $$select 1 from public.attendances where event_id = '00000000-0000-4000-8000-00000000e003'$$), 1,
  'a member keeps their own attendance record for a past event');
select is(tests.n(tests.fa(3), 'authenticated', $$select 1 from public.attendances where event_id = '00000000-0000-4000-8000-00000000e003'$$), 0,
  'other members cannot see that attendance');

-- 2.9 Historical projects / leadership --------------------------------------------
select is(tests.n(null, 'anon', $$select 1 from public.projects where id = '00000000-0000-4000-8000-00000000b003' and status = 'completed' and is_past$$), 1,
  'anon can read the published completed (past) project');
select cmp_ok(tests.n(null, 'anon', 'select 1 from public.leadership_chart_history'), '>=',
  tests.n(null, 'anon', 'select 1 from public.leadership_chart_current'),
  'leadership history is a superset of the current chart');
select is(tests.n(null, 'anon', 'select 1 from public.leadership_chart_history where not is_active and ended_at is not null'), 1,
  'ended leadership assignments remain visible in history');

-- 2.10 Project rollover ---------------------------------------------------------------
select is((select count(*)::int from pg_index i where i.indrelid = 'public.projects'::regclass and i.indisunique), 1,
  'projects has only its primary key as a unique index (no name+semester uniqueness blocks a rollover)');
select ok(not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname ~* 'roll'),
  'NOTE: no rollover RPC exists; rollover = UPDATE semester/year on the same project row (revisit if one is added)');
select is(tests.n(tests.fa(3), 'authenticated',
  $$update public.projects set semester = 'spring', year = year + 1 where id = '00000000-0000-4000-8000-00000000b001'$$), 1,
  'a project manager can roll their project into a new semester/year');
select is((select count(*)::int from public.projects where id = '00000000-0000-4000-8000-00000000b001'
           and year = extract(year from now())::int + 1), 1, 'rolled-over project keeps the same id with the new semester/year');
select is((select count(*)::int from public.project_assignments
           where project_id = '00000000-0000-4000-8000-00000000b001' and is_active), 2,
  'the project team carries over a rollover unchanged');
select is(tests.n(null, 'anon', $$select 1 from public.project_chart_current where project_id = '00000000-0000-4000-8000-00000000b001'$$), 2,
  'the public project chart still shows the team after rollover');
select is(tests.n(tests.fa(3), 'authenticated',
  $$update public.projects set status = 'completed', is_past = true where id = '00000000-0000-4000-8000-00000000b001'$$), 1,
  'the project can be archived (completed + past)');
select is(tests.n(null, 'anon', $$select 1 from public.projects where id = '00000000-0000-4000-8000-00000000b001' and is_past$$), 1,
  'an archived published project stays publicly visible');

-- Ending a role keeps the row (history) and allows re-assignment later ---------------
update public.project_assignments set is_active = false, ended_at = now()
where id = '00000000-0000-4000-8000-0000000d0002';
select is((select count(*)::int from public.project_assignments where id = '00000000-0000-4000-8000-0000000d0002' and not is_active), 1,
  'ended project assignment is retained as history');
select is(tests.n(null, 'anon', $$select 1 from public.project_chart_current where project_id = '00000000-0000-4000-8000-00000000b001'$$), 1,
  'ended project members leave the public project chart');
select is(tests.err(null, 'postgres', $$insert into public.project_assignments (project_id, user_id, role_id)
  select '00000000-0000-4000-8000-00000000b001', tests.fu(4), id from public.roles where key = 'project_member'$$), 'ok',
  'the same member can be re-assigned in a later semester after their earlier assignment ended');

-- Semester model ------------------------------------------------------------------------
select is(public.semester_key_for('2026-01-15 12:00+00'), 'spring-2026', 'mid January is spring');
select is(public.semester_key_for('2026-07-31 12:00+00'), 'spring-2026', 'late July is still spring');
select is(public.semester_key_for('2026-08-15 12:00+00'), 'fall-2026', 'mid August is fall');
select is(public.current_semester_key(), public.semester_key_for(now()), 'current_semester_key() = semester_key_for(now())');

select * from finish();
rollback;
