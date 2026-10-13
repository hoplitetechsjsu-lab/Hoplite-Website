-- 2.6 Role permission matrix + role requests.
--   * table-driven: one user per seeded role, every can_* capability checked
--   * approval_rules matrix (who may approve which target role/team)
--   * role request limits: <= 2 pending, <= 5 per semester (withdrawn excluded,
--     rejected included), request lifecycle (approve / reject / withdraw)
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

select plan(50);

-- Harness extras --------------------------------------------------------------
-- Evaluate a zero-arg public.can_*() capability as the named user.
create function tests.cap(p_name text, p_fn text) returns boolean language plpgsql as $fn$
declare v boolean;
begin
  perform set_config('request.jwt.claim.sub', tests.aid(p_name)::text, true);
  execute format('select public.%I()', p_fn) into v;
  perform set_config('request.jwt.claim.sub', '', true);
  return v;
end $fn$;

create function tests.can_appr(p_name text, p_role text, p_team text) returns boolean
language plpgsql as $fn$
declare v boolean;
begin
  perform set_config('request.jwt.claim.sub', tests.aid(p_name)::text, true);
  select public.can_approve_role_request(tests.rid(p_role), tests.tid(p_team)) into v;
  perform set_config('request.jwt.claim.sub', '', true);
  return v;
end $fn$;

-- Setup: one active user per role + edge-case users --------------------------------
-- Migration 009 forbids two active holders of a high-level unique role. This setup
-- deliberately creates extra holders (one per role / pending / deactivated), so the
-- guard trigger is disabled for setup only and re-enabled right after.
alter table public.role_assignments disable trigger trg_single_active_high_level_role;
do $$ declare r record; begin
  for r in select key from public.roles loop
    perform tests.mk_user('r_' || r.key, p_role => r.key);
  end loop;
  perform tests.mk_user('r_plain');
  perform tests.mk_user('r_pending_president', p_role => 'president', p_pending => true);
  perform tests.mk_user('r_deact_vp', p_role => 'vp', p_deactivated => true);
end $$;
alter table public.role_assignments enable trigger trg_single_active_high_level_role;
create temp table matrix_labels as
  select name as label from (
    select 'r_' || key as name from public.roles
    union all select 'r_plain' union all select 'r_pending_president' union all select 'r_deact_vp') x;

-- Role matrix (table-driven) -----------------------------------------------------
select is((select count(*)::int from public.roles), 15, 'seed defines the 15 expected roles');
select results_eq(
  $$select label from matrix_labels where tests.cap(label, 'can_edit_roles') order by 1$$,
  $$select 'r_' || k from unnest(array['president','vp','website_coordinator']) k order by 1$$,
  'can_edit_roles: president, vp, website_coordinator only');
select results_eq(
  $$select label from matrix_labels where tests.cap(label, 'can_edit_site') order by 1$$,
  $$select 'r_' || k from unnest(array['president','vp','website_coordinator','website_lead']) k order by 1$$,
  'can_edit_site: president, vp, website_coordinator, website_lead only');
select results_eq(
  $$select label from matrix_labels where tests.cap(label, 'can_manage_user_media') order by 1$$,
  $$select 'r_' || k from unnest(array['president','vp','website_coordinator','website_lead']) k order by 1$$,
  'can_manage_user_media: site editors only');
select results_eq(
  $$select label from matrix_labels where tests.cap(label, 'can_read_audit_logs') order by 1$$,
  $$select 'r_' || k from unnest(array['president','vp','website_coordinator','website_lead']) k order by 1$$,
  'can_read_audit_logs: site editors only');
select results_eq(
  $$select label from matrix_labels where tests.cap(label, 'can_edit_all_events') order by 1$$,
  $$select 'r_' || k from unnest(array['president','vp','website_coordinator','website_lead',
      'events_coordinator','events_lead']) k order by 1$$,
  'can_edit_all_events: site editors + events coordinator/lead');
select results_eq(
  $$select label from matrix_labels where tests.cap(label, 'can_edit_all_projects') order by 1$$,
  $$select 'r_' || k from unnest(array['president','vp','website_coordinator','website_lead',
      'technical_sourcing_coordinator','technical_sourcing_lead']) k order by 1$$,
  'can_edit_all_projects: site editors + technical sourcing coordinator/lead');
select results_eq(
  $$select label from matrix_labels where tests.cap(label, 'can_approve_membership') order by 1$$,
  $$select 'r_membership_admin'::text$$,
  'can_approve_membership: membership_admin only');
select is(tests.n(null, 'anon', $$select 1 where public.can_edit_site() or public.can_edit_all_events() or public.can_edit_all_projects() or public.can_edit_roles()$$), 0,
  'anon holds no capabilities');
select is(tests.n(tests.fa(4), 'authenticated', $$select 1 where public.can_edit_site() or public.can_edit_all_events() or public.can_edit_all_projects() or public.can_read_audit_logs()$$), 0,
  'ordinary member holds no capabilities');

-- Project-scoped capability ------------------------------------------------------
select is(tests.n(tests.fa(3), 'authenticated', $$select 1 where public.can_edit_project('00000000-0000-4000-8000-00000000b001')$$), 1,
  'project manager can edit their own project');
select is(tests.n(tests.fa(3), 'authenticated', $$select 1 where public.can_edit_project('00000000-0000-4000-8000-00000000b003')$$), 0,
  'project manager cannot edit a project they do not manage');
select is(tests.n(tests.fa(4), 'authenticated', $$select 1 where public.can_edit_project('00000000-0000-4000-8000-00000000b001')$$), 0,
  'project_member (non-manager) cannot edit the project');
select is(tests.n(tests.aid('r_technical_sourcing_lead'), 'authenticated', $$select 1 where public.can_edit_project('00000000-0000-4000-8000-00000000b003')$$), 1,
  'technical sourcing lead can edit any project');

-- Approval rules matrix (who can approve which role/team) ------------------------
select results_eq($$
  select a, r, t, expected, tests.can_appr(a, r, t) as actual
  from (values
    ('r_president','president',null,true), ('r_president','vp',null,true),
    ('r_president','events_lead','events',true), ('r_president','project_member',null,true),
    ('r_vp','vp',null,true), ('r_vp','president',null,false), ('r_vp','website_lead',null,true),
    ('r_vp','events_lead','events',true),
    ('r_website_coordinator','president',null,true), ('r_website_coordinator','events_lead','events',true),
    ('r_website_lead','events_lead','events',false), ('r_website_lead','website_lead',null,false),
    ('r_events_coordinator','events_lead','events',true),
    ('r_events_coordinator','events_lead','outreach',false),
    ('r_events_coordinator','events_lead',null,false),
    ('r_events_coordinator','outreach_lead','outreach',false),
    ('r_events_coordinator','vp',null,false), ('r_events_coordinator','project_member',null,false),
    ('r_outreach_coordinator','outreach_lead','outreach',true),
    ('r_outreach_coordinator','events_lead','events',false),
    ('r_finance_coordinator','finance_lead','finance',true),
    ('r_finance_coordinator','finance_lead','events',false),
    ('r_technical_sourcing_coordinator','technical_sourcing_lead','technical_sourcing',true),
    ('r_technical_sourcing_coordinator','project_manager',null,true),
    ('r_technical_sourcing_coordinator','events_lead','events',false),
    ('r_technical_sourcing_lead','project_manager',null,true),
    ('r_technical_sourcing_lead','project_member',null,true),
    ('r_technical_sourcing_lead','technical_sourcing_lead','technical_sourcing',false),
    ('r_events_lead','events_lead','events',false), ('r_events_lead','project_member',null,false),
    ('r_membership_admin','president',null,false), ('r_membership_admin','project_member',null,false),
    ('r_plain','project_member',null,false), ('r_plain','events_lead','events',false),
    ('r_pending_president','president',null,false), ('r_pending_president','project_member',null,false),
    ('r_deact_vp','events_lead','events',false)
  ) v(a, r, t, expected)
  where tests.can_appr(a, r, t) is distinct from expected$$,
  $$select null::text, null::text, null::text, null::boolean, null::boolean where false$$,
  'approval_rules matrix matches the approval hierarchy (diagnostics list any mismatch)');

-- Role request limits -------------------------------------------------------------
do $$ begin
  perform tests.mk_user('req1');   perform tests.mk_user('req2');
  perform tests.mk_user('req3');   perform tests.mk_user('req4');
  perform tests.mk_user('req5');   perform tests.mk_user('req6');
  perform tests.mk_user('other');  perform tests.mk_user('req_pending', p_pending => true);
end $$;


select matches(tests.err(null, 'anon', format('select public.submit_role_request(%L, null, %L)', tests.rid('website_lead'), 'x')),
  'Not authenticated', 'anon cannot submit a role request');
select matches(tests.submit('req_pending'), 'Not authenticated', 'pending user cannot submit a role request');
select matches(tests.err(tests.aid('req1'), 'authenticated',
  format($$insert into public.role_requests (requester_id, target_role_id) values (%L, %L)$$, tests.uid('req1'), tests.rid('vp'))),
  '^42501', 'role requests cannot be inserted directly (RPC only)');

-- <= 2 pending
select is(tests.submit('req1'), 'ok', 'first pending request accepted');
select is(tests.submit('req1', 'events_lead', 'events'), 'ok', 'second pending request accepted');
select matches(tests.submit('req1', 'outreach_lead', 'outreach'), 'Maximum pending role requests reached',
  'third pending request is refused');
select is(tests.decide('withdraw_role_request', 'req1', 'req1'), 'ok', 'requester can withdraw a pending request');
select is((select count(*)::int from public.role_requests
           where requester_id = tests.uid('req1') and status = 'withdrawn' and withdrawn_at is not null), 1,
  'withdrawn request is marked withdrawn with a timestamp');
select is(tests.submit('req1', 'outreach_lead', 'outreach'), 'ok',
  'withdrawing frees a pending slot');
select matches(tests.decide('withdraw_role_request', 'other', 'req1'),
  'Not authorized', 'only the requester can withdraw a request');

-- <= 5 per semester (approved/rejected/pending count; withdrawn does not)
insert into public.role_requests (requester_id, target_role_id, status)
select tests.uid('req2'), tests.rid('website_lead'), s
from unnest(array['approved','approved','rejected','rejected']::public.role_request_status[]) s;
select is(tests.submit('req2'), 'ok', '5th request of the semester (4 decided + 1 pending) is accepted');
select matches(tests.submit('req2'), 'Maximum semester role requests reached', '6th request of the semester is refused');
select is(tests.decide('withdraw_role_request', 'req2', 'req2'), 'ok', 'withdraw the pending request');
select is(tests.submit('req2'), 'ok', 'a withdrawn request does not count toward the semester cap');

insert into public.role_requests (requester_id, target_role_id, status, created_at)
select tests.uid('req3'), tests.rid('website_lead'), 'rejected', now() - interval '400 days'
from generate_series(1, 5);
select is(tests.submit('req3'), 'ok', 'requests from a previous semester do not count');

insert into public.role_requests (requester_id, target_role_id, status, withdrawn_at)
select tests.uid('req4'), tests.rid('website_lead'), 'withdrawn', now() from generate_series(1, 5);
select is(tests.submit('req4'), 'ok', 'five withdrawn requests do not block a new request');
select is((select count(*)::int from public.audit_logs
           where action_type = 'create' and entity_type = 'role_request'
             and actor_user_id = tests.uid('req4')), 1, 'submitting a request writes an audit row for the requester');

-- Visibility ---------------------------------------------------------------------
select is(tests.submit('req5', 'events_lead', 'events'), 'ok', 'req5 requests events_lead for the events team');
select is(tests.n(tests.aid('req5'), 'authenticated', 'select 1 from public.role_requests'), 1,
  'requester sees only their own requests');
select is(tests.n(tests.aid('other'), 'authenticated', 'select 1 from public.role_requests'), 0,
  'unrelated member sees no role requests');
select is(tests.n(tests.aid('r_events_coordinator'), 'authenticated',
  format('select 1 from public.role_requests where requester_id = %L', tests.uid('req5'))), 1,
  'the in-scope approver (events coordinator) can see the request');
select is(tests.n(tests.aid('r_outreach_coordinator'), 'authenticated',
  format('select 1 from public.role_requests where requester_id = %L', tests.uid('req5'))), 0,
  'an out-of-scope approver (outreach coordinator) cannot see the request');
select is(tests.n(tests.aid('r_president'), 'authenticated', 'select 1 from public.role_requests') >= 1, true,
  'site editors can see role requests');

-- Approve / reject lifecycle ---------------------------------------------------------
select matches(tests.decide('approve_role_request', 'other', 'req5'), 'Not authorized to approve',
  'a non-approver cannot approve a role request');
select matches(tests.decide('approve_role_request', null, 'req5'), 'Not authenticated',
  'anon cannot approve a role request');
select matches(tests.decide('approve_role_request', 'r_outreach_coordinator', 'req5'), 'Not authorized to approve',
  'an out-of-scope coordinator cannot approve (events_lead is events-scoped)');
select matches(tests.decide('reject_role_request', 'other', 'req5'), 'Not authorized to reject',
  'a non-approver cannot reject a role request');
select is(tests.decide('approve_role_request', 'r_events_coordinator', 'req5'), 'ok',
  'events coordinator approves an events_lead request');
select is((select count(*)::int from public.role_assignments ra
           where ra.user_id = tests.uid('req5') and ra.role_id = tests.rid('events_lead')
             and ra.team_id = tests.tid('events') and ra.is_active
             and ra.assigned_by = tests.uid('r_events_coordinator')), 1,
  'approval creates an active role assignment attributed to the approver');
select is((select status::text || ':' || (decided_by = tests.uid('r_events_coordinator'))::text
           from public.role_requests where requester_id = tests.uid('req5') and target_team_id = tests.tid('events')),
  'approved:true', 'request is marked approved with the decider recorded');
select matches(tests.decide('approve_role_request', 'r_events_coordinator', 'req5'), 'not found or not pending',
  'an already-approved request cannot be approved again');

select is(tests.submit('req6', 'events_lead', 'events'), 'ok', 'req6 requests events_lead');
select is(tests.decide('reject_role_request', 'r_events_coordinator', 'req6'), 'ok', 'events coordinator rejects the request');
select is((select count(*)::int from public.role_assignments where user_id = tests.uid('req6')), 0,
  'rejection grants no role');
select is((select count(*)::int from public.audit_logs
           where entity_type = 'role_request' and action_type in ('approve','reject','withdraw')), 4,
  'approve, reject and 2 withdrawals were each audit-logged');

select * from finish();
rollback;
