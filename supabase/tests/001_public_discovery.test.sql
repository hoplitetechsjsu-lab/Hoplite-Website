-- 2.2 Public-content RLS (migration 008 intentional public discovery).
--   * anon can read PUBLISHED events/projects and the curated charts
--   * anon cannot read unpublished content or any private table
--   * chart views never project student_id / email
--   * pending users get the same public view as anon, but nothing member-only
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

select plan(39);

-- Setup (as superuser) -------------------------------------------------------
do $$ begin
  perform tests.mk_user('pend', p_pending => true, p_role => 'website_lead');
  perform tests.mk_user('plain');
  -- A pending + a deactivated person on the PUBLISHED project's team must not appear.
  perform tests.mk_user('pend_pm', p_pending => true);
  perform tests.mk_user('deact_pm', p_deactivated => true);
end $$;
insert into public.project_assignments (project_id, user_id, role_id)
select '00000000-0000-4000-8000-00000000b001', tests.uid(n), r.id
from unnest(array['pend_pm','deact_pm']) n, public.roles r where r.key = 'project_member';
-- Give the fixture president a private student ID so leaks are detectable.
update public.users set student_id = '900000001' where id = tests.fu(1);

-- Sanity ----------------------------------------------------------------------
select is((select count(*)::int from public.users where email like '%@fixture.test'), 7,
  'seed.sql fixtures are loaded (run `npm run db:reset` first)');
select is((select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity), 0,
  'every public table has row level security enabled');

-- Anonymous: events -----------------------------------------------------------
select is(tests.n(null, 'anon', $$select 1 from public.events where id = '00000000-0000-4000-8000-00000000e001'$$), 1,
  'anon can read the published upcoming event');
select is(tests.n(null, 'anon', $$select 1 from public.events where id = '00000000-0000-4000-8000-00000000e003'$$), 1,
  'anon can read the published past event');
select is(tests.n(null, 'anon', $$select 1 from public.events where id = '00000000-0000-4000-8000-00000000e002'$$), 0,
  'anon cannot read the unpublished event');
select is(tests.n(null, 'anon', $$select 1 from public.events where title like 'Fixture:%'$$), 2,
  'anon sees exactly the two published fixture events');

-- Anonymous: projects ---------------------------------------------------------
select is(tests.n(null, 'anon', $$select 1 from public.projects where id = '00000000-0000-4000-8000-00000000b001'$$), 1,
  'anon can read the published active project');
select is(tests.n(null, 'anon', $$select 1 from public.projects where id = '00000000-0000-4000-8000-00000000b003'$$), 1,
  'anon can read the published completed project');
select is(tests.n(null, 'anon', $$select 1 from public.projects where id = '00000000-0000-4000-8000-00000000b002'$$), 0,
  'anon cannot read the unpublished project');

-- Anonymous: curated charts ---------------------------------------------------
select is(tests.n(null, 'anon', $$select 1 from public.leadership_chart_current where role_key = 'president' and last_name = 'President'$$), 1,
  'anon can read the current leadership chart (president)');
select is(tests.n(null, 'anon', $$select 1 from public.leadership_chart_current where role_key = 'events_lead'$$), 1,
  'anon sees the current events lead');
select is(tests.n(null, 'anon', $$select 1 from public.leadership_chart_current where last_name = 'Deactivated'$$), 0,
  'deactivated leaders are hidden from the current chart');
select is(tests.n(null, 'anon', $$select 1 from public.leadership_chart_current where last_name = 'FormerVP'$$), 0,
  'ended assignments are hidden from the current chart');
select is(tests.n(null, 'anon', $$select 1 from public.leadership_chart_current where user_id = tests.uid('pend')$$), 0,
  'pending users holding a role are hidden from the current chart');
select is(tests.n(null, 'anon', $$select 1 from public.leadership_chart_history where last_name = 'FormerVP' and role_key = 'vp' and is_active = false and ended_at is not null$$), 1,
  'anon can read the ended VP assignment in leadership history');
select is(tests.n(null, 'anon', $$select 1 from public.project_chart_current where project_id = '00000000-0000-4000-8000-00000000b001'$$), 2,
  'published project team (PM + member) is public; pending/deactivated members are excluded');
select is(tests.n(null, 'anon', $$select 1 from public.project_chart_current where project_id = '00000000-0000-4000-8000-00000000b002'$$), 0,
  'unpublished project team is NOT in the public chart');

-- Chart column privacy --------------------------------------------------------
select columns_are('public', 'leadership_chart_current', array[
  'assignment_id','user_id','first_name','last_name','photo_path','linkedin_url',
  'role_key','role_name','team_key','team_name','assigned_at'],
  'leadership_chart_current exposes only curated columns');
select columns_are('public', 'leadership_chart_history', array[
  'assignment_id','user_id','first_name','last_name','photo_path','linkedin_url',
  'role_key','role_name','team_key','team_name','assigned_at','ended_at','is_active'],
  'leadership_chart_history exposes only curated columns');
select columns_are('public', 'project_chart_current', array[
  'assignment_id','project_id','project_name','user_id','first_name','last_name',
  'photo_path','linkedin_url','role_key','role_name','assigned_at'],
  'project_chart_current exposes only curated columns');
select is((select count(*)::int from information_schema.columns
           where table_schema = 'public'
             and table_name in ('leadership_chart_current','leadership_chart_history','project_chart_current')
             and column_name ~* '(student|email)'), 0,
  'no chart view has a student_id/email-like column');
select doesnt_match(
  tests.js(null, 'anon', 'select * from public.leadership_chart_current')::text
  || tests.js(null, 'anon', 'select * from public.leadership_chart_history')::text
  || tests.js(null, 'anon', 'select * from public.project_chart_current')::text,
  '(900000001|fixture\.test|pgtap\.test)',
  'chart rows never contain a student ID or email value');
select is((select count(*)::int from pg_class
           where relname in ('leadership_chart_current','leadership_chart_history','project_chart_current')
             and relnamespace = 'public'::regnamespace
             and 'security_barrier=true' = any(reloptions)), 3,
  'all chart views are security_barrier');
select is((select count(*)::int
           from unnest(array['public.leadership_chart_current','public.leadership_chart_history','public.project_chart_current']) v,
                unnest(array['INSERT','UPDATE','DELETE','TRUNCATE']) p
           where has_table_privilege('anon', v, p) or has_table_privilege('authenticated', v, p)), 0,
  'chart views are read-only for anon and authenticated');

-- Anonymous: private data stays private ---------------------------------------
select results_eq(
  $$select t, n from (
      select t, tests.n(null, 'anon', 'select 1 from public.' || t) as n
      from unnest(array['users','profiles','student_id_collisions','roles','teams',
        'role_assignments','approval_rules','role_requests','event_qr_tokens','guest_identities',
        'guest_attendances','attendances','membership_status','project_assignments',
        'export_jobs','audit_logs','user_deactivations']) t) x
    where n <> 0$$,
  $$select null::text, null::int where false$$,
  'anon reads zero rows from every private table');
select matches(tests.err(null, 'anon', $$insert into public.events (title, starts_at, ends_at, semester, year, is_published) values ('x', now(), now(), 'fall', 2026, true)$$),
  '^42501', 'anon cannot insert events');
select matches(tests.err(null, 'anon', $$insert into public.projects (name, semester, year, is_published) values ('x', 'fall', 2026, true)$$),
  '^42501', 'anon cannot insert projects');
select is(tests.n(null, 'anon', $$update public.events set title = 'hacked' where is_published$$), 0,
  'anon cannot update published events');
select is(tests.n(null, 'anon', $$delete from public.projects where is_published$$), 0,
  'anon cannot delete published projects');
select is(greatest(tests.n(null, 'anon', 'select * from public.get_admin_member_queue()'), 0), 0,
  'anon gets no rows from get_admin_member_queue (error or empty)');
select ok(not has_function_privilege('anon', 'public.get_admin_member_queue()', 'execute'),
  'anon has no EXECUTE privilege on get_admin_member_queue');

-- Pending member: public yes, member-only no ----------------------------------
select is(tests.n(tests.aid('pend'), 'authenticated', 'select 1 where public.current_app_user_id() is null'), 1,
  'pending user has no acting app-user id');
select is(tests.n(tests.aid('pend'), 'authenticated', $$select 1 from public.events where id = '00000000-0000-4000-8000-00000000e001'$$), 1,
  'pending user can read published events (public content)');
select is(tests.n(tests.aid('pend'), 'authenticated', $$select 1 from public.events where id = '00000000-0000-4000-8000-00000000e002'$$), 0,
  'pending user cannot read unpublished events');
select cmp_ok(tests.n(tests.aid('pend'), 'authenticated', 'select 1 from public.leadership_chart_current'), '>', 0,
  'pending user can read the public leadership chart');
select results_eq(
  $$select t, n from (
      select t, tests.n(tests.aid('pend'), 'authenticated', 'select 1 from public.' || t) as n
      from unnest(array['profiles','student_id_collisions','role_assignments','role_requests',
        'event_qr_tokens','guest_identities','guest_attendances','attendances','membership_status',
        'project_assignments','export_jobs','audit_logs','user_deactivations']) t) x
    where n <> 0$$,
  $$select null::text, null::int where false$$,
  'pending user reads zero rows from member-only tables');
select is(tests.n(tests.aid('pend'), 'authenticated', 'select 1 from public.users'), 1,
  'pending user can only see their own users row (no member list)');

-- Ordinary approved member -----------------------------------------------------
select is(tests.n(tests.fa(4), 'authenticated', $$select 1 from public.events where id in ('00000000-0000-4000-8000-00000000e001','00000000-0000-4000-8000-00000000e002')$$), 1,
  'ordinary member sees the published event but not the unpublished one');
select is(tests.n(tests.fa(4), 'authenticated', $$select 1 from public.projects where id = '00000000-0000-4000-8000-00000000b002'$$), 0,
  'ordinary member cannot read the unpublished project');

select * from finish();
rollback;
