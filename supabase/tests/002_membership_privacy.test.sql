-- 2.3 Membership privacy.
--   * anon / pending users cannot read the member list
--   * ordinary members cannot read the approval queue or other members' rows
--   * student_id never leaves via the queue, chart views, or any function result
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

select plan(29);

-- Setup -----------------------------------------------------------------------
do $$ begin
  perform tests.mk_user('madmin', p_role => 'membership_admin');
  perform tests.mk_user('rej', p_rejected => true);
end $$;
update public.users set student_id = '900000001' where id = tests.fu(1);
update public.users set student_id = '900000004' where id = tests.fu(4);
update public.users set student_id = '900000005' where id = tests.fu(5);
-- An open student-ID collision (resolved manually by a membership admin).
insert into public.student_id_collisions (student_id, new_user_id, existing_user_id)
values ('900000005', tests.fu(5), tests.fu(4));

-- Anonymous --------------------------------------------------------------------
select is(tests.n(null, 'anon', 'select student_id from public.users'), 0,
  'anon cannot read users.student_id');
select is(tests.n(null, 'anon', 'select 1 from public.student_id_collisions'), 0,
  'anon cannot read student-ID collisions');

-- Pending --------------------------------------------------------------------
select is(tests.n(tests.fa(5), 'authenticated', 'select 1 from public.users'), 1,
  'pending user sees only their own users row (no member list)');
select is(tests.n(tests.fa(5), 'authenticated', 'select 1 from public.users where is_pending'), 1,
  'pending user can read their own pending status');
select is(tests.n(tests.fa(5), 'authenticated', 'select 1 from public.profiles'), 0,
  'pending user cannot read any profiles');
select is(tests.n(tests.fa(5), 'authenticated', 'select 1 from public.get_admin_member_queue()'), 0,
  'pending user gets an empty approval queue');

-- Rejected / deactivated -------------------------------------------------------
select is(tests.n(tests.aid('rej'), 'authenticated', 'select 1 where public.current_app_user_id() is null'), 1,
  'rejected user has no acting app-user id');
select is(tests.n(tests.fa(6), 'authenticated', 'select 1 where public.current_app_user_id() is null'), 1,
  'deactivated user has no acting app-user id');
select is(tests.n(tests.aid('rej'), 'authenticated', 'select 1 from public.get_admin_member_queue()'), 0,
  'rejected user gets an empty approval queue');

-- Ordinary approved member -----------------------------------------------------
select is(tests.n(tests.fa(4), 'authenticated', 'select 1 from public.users'), 1,
  'member can only read their own users row');
select is(tests.n(tests.fa(4), 'authenticated', 'select 1 from public.users where id = tests.fu(1)'), 0,
  'member cannot read another member (president) row');
select is(tests.n(tests.fa(4), 'authenticated', 'select 1 from public.users where id = tests.fu(5)'), 0,
  'member cannot read a pending applicant row');
select is(tests.n(tests.fa(4), 'authenticated', 'select 1 from public.profiles'), 1,
  'member can only read their own profile');
select is(tests.n(tests.fa(4), 'authenticated', 'select 1 from public.get_admin_member_queue()'), 0,
  'member cannot read the approval queue');
select is(tests.n(tests.fa(4), 'authenticated', 'select 1 from public.student_id_collisions'), 0,
  'member cannot read student-ID collisions');
select matches(tests.err(tests.fa(4), 'authenticated',
  $$insert into public.users (auth_user_id, email) values (gen_random_uuid(), 'sneaky@pgtap.test')$$),
  '^42501', 'member cannot insert users rows directly (registration is server-side)');

-- Approval authority is least-privilege: president is NOT a membership admin ----
select is(tests.n(tests.fa(1), 'authenticated', 'select 1 from public.get_admin_member_queue()'), 0,
  'president (not membership_admin) gets an empty approval queue');

-- Membership admin -------------------------------------------------------------
select is(tests.n(tests.aid('madmin'), 'authenticated', 'select 1 from public.get_admin_member_queue()'),
  (select count(*)::int from public.users where is_pending or is_rejected),
  'membership_admin queue = every pending + rejected member');
select is(tests.n(tests.aid('madmin'), 'authenticated', 'select 1 from public.get_admin_member_queue() where user_id = tests.fu(5)'), 1,
  'queue contains the pending applicant');
select is(tests.n(tests.aid('madmin'), 'authenticated', 'select 1 from public.get_admin_member_queue() where user_id = tests.fu(4)'), 0,
  'queue excludes approved members');
select doesnt_match(pg_get_function_result('public.get_admin_member_queue()'::regprocedure), 'student',
  'queue result type has no student_id column');
select doesnt_match(
  tests.js(tests.aid('madmin'), 'authenticated', 'select * from public.get_admin_member_queue()')::text,
  '(student|9000000)', 'queue rows never carry a student ID');
select is(tests.n(tests.aid('madmin'), 'authenticated', 'select 1 from public.users'), 1,
  'membership_admin cannot browse the member list directly (users RLS is self/site-editor only)');
select is(tests.n(tests.aid('madmin'), 'authenticated', 'select student_id from public.users where id = tests.fu(5)'), 0,
  'membership_admin cannot read an applicant student_id directly');
select is(tests.n(tests.aid('madmin'), 'authenticated', 'select 1 from public.student_id_collisions'), 1,
  'membership_admin can read student-ID collisions (to resolve them)');

-- student_id never escapes through views / functions ---------------------------
select doesnt_match(
  tests.js(tests.fa(4), 'authenticated', 'select * from public.leadership_chart_current')::text
  || tests.js(tests.fa(4), 'authenticated', 'select * from public.leadership_chart_history')::text
  || tests.js(tests.fa(4), 'authenticated', 'select * from public.project_chart_current')::text,
  '(9000000|pgtap\.test|fixture\.test)',
  'chart views seen by a member contain no student IDs or emails');
select is((select count(*)::int from information_schema.columns c
           join information_schema.views v on v.table_schema = c.table_schema and v.table_name = c.table_name
           where c.table_schema = 'public' and c.column_name in ('student_id', 'email')), 0,
  'no public view exposes student_id or email');
select is((select count(*)::int from pg_proc
           where pronamespace = 'public'::regnamespace
             and pg_get_function_result(oid) ~* 'student_id'), 0,
  'no public function returns a student_id column');
select is((select count(*)::int from pg_proc p
           where p.pronamespace = 'public'::regnamespace
             and p.prosecdef and p.prorettype = 'public.users'::regtype), 0,
  'no security-definer function returns whole users rows');

select * from finish();
rollback;
