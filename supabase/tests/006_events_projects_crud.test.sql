-- 2.7 Events / Projects create-update-delete by role (RLS, table-driven).
--   events:   president, vp, website_*, events_* may write; everyone else may not
--   projects: president, vp, website_*, technical_sourcing_* may write; a project
--             manager may edit only the projects they manage
-- Actors are exercised through tests.n (role switch + JWT claims).
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

select plan(22);

-- Setup -----------------------------------------------------------------------
create function tests.rid_pm() returns uuid language sql stable as
  $fn$ select id from public.roles where key = 'project_member' $fn$;
-- Migration 009 forbids two active holders of a high-level unique role. This setup
-- deliberately creates extra holders (one per role / pending / deactivated), so the
-- guard trigger is disabled for setup only and re-enabled right after.
alter table public.role_assignments disable trigger trg_single_active_high_level_role;
do $$ begin
  perform tests.mk_user('a_pending', p_role => 'website_lead', p_pending => true);
  perform tests.mk_user('a_deact', p_role => 'president', p_deactivated => true);
  perform tests.mk_user('a_wl', p_role => 'website_lead');
  perform tests.mk_user('a_tsl', p_role => 'technical_sourcing_lead');
  perform tests.mk_user('a_ec', p_role => 'events_coordinator');
  perform tests.mk_user('a_newbie');
end $$;
alter table public.role_assignments enable trigger trg_single_active_high_level_role;

-- label, auth uid, pg role, may write events, may write (all) projects
create temp table actors as
select * from (values
  ('anon',       null::uuid,          'anon',          false, false),
  ('pending',    tests.aid('a_pending'), 'authenticated', false, false),
  ('deactivated', tests.aid('a_deact'),  'authenticated', false, false),
  ('member',     tests.fa(4),         'authenticated', false, false),
  ('pm',         tests.fa(3),         'authenticated', false, false),
  ('events_lead', tests.fa(2),        'authenticated', true,  false),
  ('events_coord', tests.aid('a_ec'), 'authenticated', true,  false),
  ('president',  tests.fa(1),         'authenticated', true,  true),
  ('website_lead', tests.aid('a_wl'), 'authenticated', true,  true),
  ('tech_lead',  tests.aid('a_tsl'),  'authenticated', false, true)
) v(label, auth, pgrole, ev, pr);

-- One private row per actor to update / delete.
insert into public.events (id, title, starts_at, ends_at, semester, year, is_published)
select tests.uid('ev:' || label), 'crud ' || label, now(), now() + interval '1 hour', 'fall', 2026, false from actors;
insert into public.projects (id, name, semester, year, is_published)
select tests.uid('pr:' || label), 'crud ' || label, 'fall', 2026, false from actors;

-- Events: insert / update / delete / read-unpublished -------------------------------
select results_eq($$
  select label, expected, actual from (
    select label, case when ev then 1 else -1 end as expected,
      tests.n(auth, pgrole, format($q$insert into public.events (title, starts_at, ends_at, semester, year)
        values ('new by %s', now(), now() + interval '1 hour', 'fall', 2026)$q$, label)) as actual
    from actors) x where actual is distinct from expected$$,
  $$select null::text, null::int, null::int where false$$,
  'events INSERT allowed only for event editors / site editors');
select results_eq($$
  select label, expected, actual from (
    select label, case when ev then 1 else 0 end as expected,
      tests.n(auth, pgrole, format($q$update public.events set description = 'edited' where id = %L$q$, tests.uid('ev:' || label))) as actual
    from actors) x where actual is distinct from expected$$,
  $$select null::text, null::int, null::int where false$$,
  'events UPDATE allowed only for event editors / site editors');
select results_eq($$
  select label, expected, actual from (
    select label, case when ev then 1 else 0 end as expected,
      tests.n(auth, pgrole, format($q$delete from public.events where id = %L$q$, tests.uid('ev:' || label))) as actual
    from actors) x where actual is distinct from expected$$,
  $$select null::text, null::int, null::int where false$$,
  'events DELETE allowed only for event editors / site editors');
select results_eq($$
  select label, expected, actual from (
    select label, case when ev then 1 else 0 end as expected,
      tests.n(auth, pgrole, $q$select 1 from public.events where id = '00000000-0000-4000-8000-00000000e002'$q$) as actual
    from actors) x where actual is distinct from expected$$,
  $$select null::text, null::int, null::int where false$$,
  'unpublished events are readable only by event editors / site editors');
select is(tests.n(tests.fa(4), 'authenticated', $$update public.events set title = 'hacked' where id = '00000000-0000-4000-8000-00000000e001'$$), 0,
  'a member cannot edit a published event');

-- Projects: insert / update / delete / read-unpublished -------------------------------
select results_eq($$
  select label, expected, actual from (
    select label, case when pr then 1 else -1 end as expected,
      tests.n(auth, pgrole, format($q$insert into public.projects (name, semester, year)
        values ('new by %s', 'fall', 2026)$q$, label)) as actual
    from actors) x where actual is distinct from expected$$,
  $$select null::text, null::int, null::int where false$$,
  'projects INSERT allowed only for project editors / site editors');
select results_eq($$
  select label, expected, actual from (
    select label, case when pr then 1 else 0 end as expected,
      tests.n(auth, pgrole, format($q$update public.projects set description = 'edited' where id = %L$q$, tests.uid('pr:' || label))) as actual
    from actors) x where actual is distinct from expected$$,
  $$select null::text, null::int, null::int where false$$,
  'projects UPDATE (on an unrelated project) allowed only for project editors / site editors');
select results_eq($$
  select label, expected, actual from (
    select label, case when pr then 1 else 0 end as expected,
      tests.n(auth, pgrole, format($q$delete from public.projects where id = %L$q$, tests.uid('pr:' || label))) as actual
    from actors) x where actual is distinct from expected$$,
  $$select null::text, null::int, null::int where false$$,
  'projects DELETE (on an unrelated project) allowed only for project editors / site editors');
select results_eq($$
  select label, expected, actual from (
    select label, case when pr then 1 else 0 end as expected,
      tests.n(auth, pgrole, $q$select 1 from public.projects where id = '00000000-0000-4000-8000-00000000b002'$q$) as actual
    from actors where label <> 'pm') x where actual is distinct from expected$$,
  $$select null::text, null::int, null::int where false$$,
  'unpublished projects are readable only by project editors / site editors');

-- Project manager scope ---------------------------------------------------------
select is(tests.n(tests.fa(3), 'authenticated', $$update public.projects set description = 'pm edit' where id = '00000000-0000-4000-8000-00000000b001'$$), 1,
  'project manager can edit the published project they manage');
select is(tests.n(tests.fa(3), 'authenticated', $$update public.projects set description = 'pm edit' where id = '00000000-0000-4000-8000-00000000b003'$$), 0,
  'project manager cannot edit a project they do not manage');
select is(tests.n(tests.fa(4), 'authenticated', $$update public.projects set description = 'member edit' where id = '00000000-0000-4000-8000-00000000b001'$$), 0,
  'project_member (non-manager) cannot edit the project');
select is(tests.n(tests.fa(3), 'authenticated', $$select 1 from public.projects where id = '00000000-0000-4000-8000-00000000b002'$$), 1,
  'project manager can read their own unpublished project');
select is(tests.n(tests.fa(3), 'authenticated', $$update public.projects set description = 'pm draft edit' where id = '00000000-0000-4000-8000-00000000b002'$$), 1,
  'project manager can edit their own unpublished project');

-- Project team management ----------------------------------------------------------
select is(tests.n(tests.fa(3), 'authenticated', format($$insert into public.project_assignments (project_id, user_id, role_id)
  values ('00000000-0000-4000-8000-00000000b001', %L, %L)$$, tests.uid('a_newbie'), tests.rid_pm())), 1,
  'project manager can add a project_member to their project');
select is(tests.n(tests.fa(3), 'authenticated', format($$insert into public.project_assignments (project_id, user_id, role_id)
  values ('00000000-0000-4000-8000-00000000b003', %L, %L)$$, tests.uid('a_newbie'), tests.rid_pm())), -1,
  'project manager cannot add members to a project they do not manage');
select is(tests.n(tests.fa(4), 'authenticated', format($$insert into public.project_assignments (project_id, user_id, role_id)
  values ('00000000-0000-4000-8000-00000000b001', %L, %L)$$, tests.uid('a_newbie'), tests.rid_pm())), -1,
  'a plain project_member cannot add members');
select is(tests.n(tests.fa(4), 'authenticated', 'select 1 from public.project_assignments'), 2,
  'a member sees only their own project assignments');
select matches(tests.err(null, 'postgres', format($$insert into public.project_assignments (project_id, user_id, role_id)
  values ('00000000-0000-4000-8000-00000000b001', %L, %L)$$, tests.fu(4), tests.rid_pm())),
  '^23505', 'the same user cannot hold the same active project role twice');

-- Schema constraints ---------------------------------------------------------------
select matches(tests.err(null, 'postgres', $$insert into public.events (title, starts_at, ends_at, semester, year)
  values ('bad', now(), now() - interval '1 hour', 'fall', 2026)$$), '^23514',
  'an event cannot end before it starts');
select matches(tests.err(null, 'postgres', $$insert into public.events (title, starts_at, ends_at, semester, year)
  values ('bad', now(), now(), 'fall', 2020)$$), '^23514', 'events enforce year >= 2024');
select matches(tests.err(null, 'postgres', $$insert into public.projects (name, semester, year)
  values ('bad', 'fall', 2020)$$), '^23514', 'projects enforce year >= 2024');

select * from finish();
rollback;
