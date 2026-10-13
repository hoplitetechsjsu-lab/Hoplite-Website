-- 2.5 Approval / rejection authority and one-time admin bootstrap.
--   * bootstrap_first_admin: owner-only, one-shot, no student_id required
--   * ordinary users cannot approve themselves or anyone else through RLS
--   * Approve/reject themselves run in Edge Functions (service role): those
--     behaviours are skipped below and tracked in POST_MVP.md.
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

select plan(32);

-- Setup -----------------------------------------------------------------------
-- No membership_admin may exist for the first-run bootstrap path.
update public.role_assignments set is_active = false, ended_at = now()
where is_active and role_id = (select id from public.roles where key = 'membership_admin');
insert into auth.users (id, email, email_confirmed_at, aud, role) values
  (tests.aid('boot1'), 'boot1@pgtap.test', now(), 'authenticated', 'authenticated'),
  (tests.aid('boot2'), 'boot2@pgtap.test', now(), 'authenticated', 'authenticated'),
  (tests.aid('unconf'), 'unconf@pgtap.test', null, 'authenticated', 'authenticated');

-- Bootstrap: who may call it ---------------------------------------------------
select ok(not has_function_privilege('anon', 'public.bootstrap_first_admin(uuid)', 'execute'),
  'anon has no EXECUTE on bootstrap_first_admin');
select ok(not has_function_privilege('authenticated', 'public.bootstrap_first_admin(uuid)', 'execute'),
  'authenticated has no EXECUTE on bootstrap_first_admin');
select matches(tests.err(null, 'anon', format('select public.bootstrap_first_admin(%L)', tests.aid('boot1'))),
  '^42501', 'anonymous caller cannot bootstrap');
select matches(tests.err(tests.fa(4), 'authenticated', format('select public.bootstrap_first_admin(%L)', tests.fa(4))),
  '^42501', 'ordinary member cannot bootstrap themselves into admin');
select matches(tests.err(tests.aid('boot1'), 'authenticated', format('select public.bootstrap_first_admin(%L)', tests.aid('boot1'))),
  '^42501', 'a verified auth user cannot bootstrap themselves either');
select matches(tests.err(tests.fa(4), 'authenticated',
  format($$insert into public.role_assignments (user_id, role_id) select %L, id from public.roles where key = 'membership_admin'$$, tests.fu(4))),
  '^42501', 'member cannot grant themselves membership_admin via role_assignments');

-- Bootstrap: owner-run behaviour -----------------------------------------------
select matches(tests.err(null, 'postgres', format('select public.bootstrap_first_admin(%L)', gen_random_uuid())),
  'not found or email not confirmed', 'bootstrap rejects an unknown auth user');
select matches(tests.err(null, 'postgres', format('select public.bootstrap_first_admin(%L)', tests.aid('unconf'))),
  'not found or email not confirmed', 'bootstrap rejects an unverified email');
select is(tests.err(null, 'postgres', format('select public.bootstrap_first_admin(%L)', tests.aid('boot1'))), 'ok',
  'owner can bootstrap a verified auth user');
select is((select (not is_pending and not is_rejected and email_verified and student_id is null)
           from public.users where auth_user_id = tests.aid('boot1')), true,
  'bootstrapped admin is approved and needs no student_id');
select is((select count(*)::int from public.role_assignments ra join public.roles r on r.id = ra.role_id
           join public.users u on u.id = ra.user_id
           where r.key = 'membership_admin' and ra.is_active and u.auth_user_id = tests.aid('boot1')), 1,
  'bootstrapped user holds exactly one active membership_admin role');
select is((select count(*)::int from public.audit_logs a join public.users u on u.id = a.actor_user_id
           where u.auth_user_id = tests.aid('boot1') and a.action_type = 'approve_member'
             and a.after_state ->> 'bootstrap' = 'true' and a.after_state::text !~* 'student'), 1,
  'bootstrap is audit-logged without any student ID');
select matches(tests.err(null, 'postgres', format('select public.bootstrap_first_admin(%L)', tests.aid('boot2'))),
  'membership_admin already exists', 'second bootstrap is refused once an admin exists');
select is(tests.n(tests.aid('boot1'), 'authenticated', 'select 1 where public.can_approve_membership()'), 1,
  'bootstrapped admin passes can_approve_membership()');

-- Approval authority: who is / is not a membership approver ---------------------
do $$ begin
  perform tests.mk_user('ordinary');
  perform tests.mk_user('applicant', p_pending => true);
  perform tests.mk_user('rejected', p_rejected => true);
end $$;
select is(tests.n(tests.aid('ordinary'), 'authenticated', 'select 1 where public.can_approve_membership()'), 0,
  'ordinary member cannot approve members');
select is(tests.n(tests.fa(1), 'authenticated', 'select 1 where public.can_approve_membership()'), 0,
  'president is not a membership approver (least privilege)');
select is(tests.n(tests.aid('applicant'), 'authenticated', 'select 1 where public.can_approve_membership()'), 0,
  'pending applicant cannot approve members');
select is(tests.n(null, 'anon', 'select 1 where public.can_approve_membership()'), 0,
  'anonymous caller cannot approve members');

-- Self-approval / tampering through RLS ------------------------------------------
select is(tests.n(tests.aid('applicant'), 'authenticated',
  format('update public.users set is_pending = false where id = %L', tests.uid('applicant'))), 0,
  'pending applicant cannot approve themselves');
select is((select is_pending from public.users where id = tests.uid('applicant')), true,
  'applicant is still pending after the self-approval attempt');
select is(tests.n(tests.aid('rejected'), 'authenticated',
  format('update public.users set is_rejected = false where id = %L', tests.uid('rejected'))), 0,
  'rejected user cannot clear their own rejection');
select is(tests.n(tests.aid('ordinary'), 'authenticated',
  format('update public.users set is_pending = false where id = %L', tests.uid('applicant'))), 0,
  'ordinary member cannot approve another applicant');
select is(tests.n(tests.aid('boot1'), 'authenticated',
  format('update public.users set is_pending = false where id = %L', tests.uid('applicant'))), 0,
  'membership_admin approves via the approve-member function, not direct table writes');
select is(tests.n(tests.aid('ordinary'), 'authenticated',
  format('delete from public.users where id = %L', tests.uid('applicant'))), 0,
  'ordinary member cannot delete another user');

-- Column protection (migration 009, F2/F3) ----------------------------------------
select matches(tests.err(tests.fa(1), 'authenticated',
  format('update public.users set is_pending = false where id = %L', tests.uid('applicant'))),
  'Membership state changes', 'president cannot approve an applicant through a direct UPDATE');
select is((select is_pending from public.users where id = tests.uid('applicant')), true,
  'applicant is still pending after the president''s direct UPDATE attempt');
select matches(tests.err(tests.fa(4), 'authenticated',
  format($$update public.users set student_id = '123456789', email = 'changed@pgtap.test' where id = %L$$, tests.fu(4))),
  'cannot be changed', 'member cannot rewrite their own student_id / email after registration');
select is((select (email::text <> 'changed@pgtap.test' and student_id is distinct from '123456789')
           from public.users where id = tests.fu(4)), true,
  'member''s student_id / email are unchanged after the rewrite attempt');

-- Edge Function behaviour (needs the deployed functions + Deno/HTTP) -------------
select skip('DEFERRED (Edge Functions, see POST_MVP.md): approve-member rejects self-approval (400), non-pending (409), open student-ID collision (409); reject-member requires membership_admin; approval merges guest attendance and writes an audit row.', 4);

select * from finish();
rollback;
