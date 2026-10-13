-- 2.8 Unique-role replacement + history.
--   President / VP / Coordinators are high-level unique roles: approving a new
--   holder auto-ends the previous holder's assignment (kept as history, never
--   deleted). Non-unique roles (leads) coexist.
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

select plan(27);

-- Setup -----------------------------------------------------------------------
do $$ begin
  perform tests.mk_user('v_old',  p_role => 'vp', p_team => 'executive');
  perform tests.mk_user('v_new');
  perform tests.mk_user('ec_old', p_role => 'events_coordinator', p_team => 'events');
  perform tests.mk_user('ec_new');
  perform tests.mk_user('wl_old', p_role => 'website_lead', p_team => 'website');
  perform tests.mk_user('wl_new');
  perform tests.mk_user('p_new');
end $$;

-- VP replacement (approved by the president) --------------------------------------
select is((select count(*)::int from public.role_assignments ra join public.roles r on r.id = ra.role_id
           where r.key = 'vp' and ra.is_active), 1, 'precondition: exactly one active VP');
select is(tests.submit('v_new', 'vp', 'executive'), 'ok', 'new VP candidate submits a request');
select is(tests.decide('approve_role_request', 'fix:1', 'v_new'),
  'ok', 'president approves the new VP');
select is((select count(*)::int from public.role_assignments ra join public.roles r on r.id = ra.role_id
           where r.key = 'vp' and ra.is_active), 1, 'still exactly one active VP after replacement');
select is((select count(*)::int from public.role_assignments ra join public.roles r on r.id = ra.role_id
           where r.key = 'vp' and ra.is_active and ra.user_id = tests.uid('v_new')), 1, 'the new VP is the active holder');
select is((select count(*)::int from public.role_assignments ra join public.roles r on r.id = ra.role_id
           where r.key = 'vp' and not ra.is_active and ra.ended_at is not null and ra.user_id = tests.uid('v_old')), 1,
  'the previous VP assignment is ended (is_active=false, ended_at set), not deleted');
select is((select count(*)::int from public.audit_logs
           where action_type = 'auto_replace_role' and actor_user_id = tests.fu(1)), 1,
  'automatic replacement is audit-logged with the approving actor');
select is(tests.n(null, 'anon', $$select 1 from public.leadership_chart_current where role_key = 'vp' and first_name = 'v_new'$$), 1,
  'public current chart shows the new VP');
select is(tests.n(null, 'anon', $$select 1 from public.leadership_chart_current where first_name = 'v_old'$$), 0,
  'public current chart no longer shows the replaced VP');
select is(tests.n(null, 'anon', $$select 1 from public.leadership_chart_history where role_key = 'vp' and first_name = 'v_old' and is_active = false and ended_at is not null$$), 1,
  'public leadership history keeps the replaced VP with an end date');
select is(tests.n(null, 'anon', $$select 1 from public.leadership_chart_history where role_key = 'vp' and first_name = 'v_new' and is_active$$), 1,
  'public leadership history lists the new VP as active');
select is(tests.n(tests.aid('v_old'), 'authenticated', 'select 1 where public.can_edit_site()'), 0,
  'the replaced VP immediately loses site-edit capability');
select is(tests.n(tests.aid('v_new'), 'authenticated', 'select 1 where public.can_edit_site()'), 1,
  'the new VP immediately gains site-edit capability');

-- Coordinator replacement approved by the (new) VP -----------------------------------
select is(tests.submit('ec_new', 'events_coordinator', 'events'), 'ok', 'events coordinator candidate submits a request');
select is(tests.decide('approve_role_request', 'v_new', 'ec_new'),
  'ok', 'new VP approves the events coordinator');
select is((select string_agg(u.email::text, ',' order by u.email) from public.role_assignments ra
           join public.roles r on r.id = ra.role_id join public.users u on u.id = ra.user_id
           where r.key = 'events_coordinator' and ra.is_active), 'ec_new@pgtap.test',
  'only the new events coordinator remains active');

-- Non-unique roles coexist ------------------------------------------------------------
select is(tests.submit('wl_new', 'website_lead', 'website'), 'ok', 'second website lead candidate submits a request');
select is(tests.decide('approve_role_request', 'fix:1', 'wl_new'),
  'ok', 'president approves the second website lead');
select is((select count(*)::int from public.role_assignments ra join public.roles r on r.id = ra.role_id
           where r.key = 'website_lead' and ra.is_active and ra.user_id in (tests.uid('wl_old'), tests.uid('wl_new'))), 2,
  'non-unique roles (leads) are not auto-replaced');

-- Authority limits on the highest role -------------------------------------------------
select is(tests.submit('p_new', 'president', 'executive'), 'ok', 'a member requests the president role');
select matches(tests.decide('approve_role_request', 'v_new', 'p_new'),
  'Not authorized', 'a VP cannot approve a president request');
select matches(tests.decide('approve_role_request', 'ec_new', 'p_new'),
  'Not authorized', 'a coordinator cannot approve a president request');

-- Schema guard + self-approval (migration 009, F5/F6) ---------------------------------------------------------------------------
select isnt(tests.err(null, 'postgres', format($$insert into public.role_assignments (user_id, role_id) values (%L, %L)$$, tests.uid('p_new'), tests.rid('vp'))),
  'ok', 'schema rejects a second active holder of a unique role');
select is(tests.submit('fix:1', 'vp', 'executive'), 'ok', 'president requests the VP role for themself');
select matches(tests.decide('approve_role_request', 'fix:1', 'fix:1'),
  'Not authorized|own', 'an approver cannot approve their own role request');
select matches(tests.decide('reject_role_request', 'fix:1', 'fix:1'),
  'own', 'an approver cannot reject their own role request');
select is((select status::text from public.role_requests
           where requester_id = tests.fu(1) and target_role_id = tests.rid('vp')), 'pending',
  'the self-decided request is still pending');

select * from finish();
rollback;
