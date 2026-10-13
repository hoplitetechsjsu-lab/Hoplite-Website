-- 2.13 Audit append-only (+ user_deactivations, the other history table).
--   * only site editors can read audit_logs; nobody can write through the client
--   * log_audit() is the only writer; rows survive actor deletion
--   * Privileged paths (service_role, TRUNCATE, public log_audit) are hardened by
--     migration 009 (F9/F10): RLS alone cannot make a table append-only for roles that bypass it.
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

select plan(28);

-- Setup -----------------------------------------------------------------------
do $$ begin
  perform tests.mk_user('au_actor');
  perform tests.mk_user('au_wl', p_role => 'website_lead');
  perform tests.mk_user('au_madmin', p_role => 'membership_admin');
end $$;
insert into public.audit_logs (id, actor_user_id, action_type, entity_type, entity_id, before_state, after_state) values
  (tests.uid('audit:1'), tests.fu(1), 'create', 'event', tests.uid('audit:e1'), null, '{"title":"a"}'),
  (tests.uid('audit:2'), tests.fu(4), 'check_in', 'event', tests.uid('audit:e1'), null, '{"user":"x"}'),
  (tests.uid('audit:3'), tests.uid('au_actor'), 'update', 'event', tests.uid('audit:e1'), '{"title":"a"}', '{"title":"b"}');
insert into public.user_deactivations (id, user_id, reason, deactivated_by)
values (tests.uid('deact:1'), tests.fu(4), 'pgtap', tests.fu(1));

-- Read access -------------------------------------------------------------------
select results_eq($$
  select label, expected, actual from (
    select label, readable as expected, tests.n(auth, pgrole, 'select 1 from public.audit_logs') >= 3 as actual
    from (values
      ('anon', null::uuid, 'anon', false), ('pending', tests.aid('au_pending_none'), 'authenticated', false),
      ('member', tests.fa(4), 'authenticated', false), ('events_lead', tests.fa(2), 'authenticated', false),
      ('membership_admin', tests.aid('au_madmin'), 'authenticated', false),
      ('president', tests.fa(1), 'authenticated', true), ('website_lead', tests.aid('au_wl'), 'authenticated', true)
    ) v(label, auth, pgrole, readable)) x where actual is distinct from expected$$,
  $$select null::text, null::boolean, null::boolean where false$$,
  'audit_logs are readable only by site editors (president/vp/website_*)');
select is((select relrowsecurity from pg_class where oid = 'public.audit_logs'::regclass), true, 'RLS is enabled on audit_logs');

-- Client writes denied --------------------------------------------------------------
select matches(tests.err(tests.fa(1), 'authenticated',
  $$insert into public.audit_logs (action_type, entity_type) values ('create', 'forged')$$),
  '^42501', 'the president cannot INSERT audit rows from the client');
select matches(tests.err(tests.fa(4), 'authenticated',
  $$insert into public.audit_logs (action_type, entity_type) values ('create', 'forged')$$),
  '^42501', 'a member cannot INSERT audit rows from the client');
select matches(tests.err(null, 'anon',
  $$insert into public.audit_logs (action_type, entity_type) values ('create', 'forged')$$),
  '^42501', 'anon cannot INSERT audit rows');
select is(greatest(tests.n(tests.fa(1), 'authenticated', $$update public.audit_logs set after_state = '{"tampered":true}'$$), 0), 0,
  'the president cannot UPDATE audit rows');
select is(greatest(tests.n(tests.aid('au_wl'), 'authenticated', $$update public.audit_logs set action_type = 'delete'$$), 0), 0,
  'a website lead cannot UPDATE audit rows');
select is(greatest(tests.n(tests.fa(1), 'authenticated', 'delete from public.audit_logs'), 0), 0, 'the president cannot DELETE audit rows');
select is(greatest(tests.n(tests.aid('au_wl'), 'authenticated', 'delete from public.audit_logs'), 0), 0, 'a website lead cannot DELETE audit rows');
select is(greatest(tests.n(null, 'anon', 'delete from public.audit_logs'), 0), 0, 'anon cannot DELETE audit rows');
select is((select after_state::text from public.audit_logs where id = tests.uid('audit:3')), '{"title": "b"}',
  'audit row content is intact after the tamper attempts');

-- log_audit is the writer ---------------------------------------------------------------
select is(tests.err(tests.fa(4), 'postgres', $$select public.log_audit('check_in', 'event', null, null, '{"via":"log_audit"}')$$), 'ok',
  'log_audit appends a row');
select is((select actor_user_id from public.audit_logs where after_state ->> 'via' = 'log_audit'), tests.fu(4),
  'log_audit attributes the row to the acting app user (auth.uid())');
select is((select count(*)::int from public.audit_logs where after_state ->> 'via' = 'log_audit' and created_at = now()), 1,
  'log_audit stamps created_at');
select is(tests.err(null, 'postgres', $$select public.log_audit('delete', 'event', null, null, null)$$), 'ok',
  'log_audit with no acting user records a NULL actor (system/service call)');

-- Audit history outlives its actor --------------------------------------------------------
delete from public.users where id = tests.uid('au_actor');
select is((select count(*)::int from public.audit_logs where id = tests.uid('audit:3') and actor_user_id is null), 1,
  'deleting the actor keeps the audit row (actor becomes NULL)');

-- user_deactivations: append-only to clients ----------------------------------------------
select is(tests.n(tests.fa(1), 'authenticated', 'select 1 from public.user_deactivations'), 1, 'site editors can read deactivation history');
select is(tests.n(tests.fa(4), 'authenticated', 'select 1 from public.user_deactivations'), 0, 'members cannot read deactivation history');
select matches(tests.err(tests.fa(1), 'authenticated',
  format($$insert into public.user_deactivations (user_id, reason) values (%L, 'x')$$, tests.fu(4))),
  '^42501', 'clients cannot insert deactivations (server-side only)');
select is(tests.n(tests.fa(1), 'authenticated', $$update public.user_deactivations set reason = 'tampered'$$), 0,
  'deactivation history cannot be updated by clients');
select is(tests.n(tests.fa(1), 'authenticated', 'delete from public.user_deactivations'), 0,
  'deactivation history cannot be deleted by clients');

-- Privileged-path hardening (migration 009) ---------------------------------------------------------------------
select ok(not has_function_privilege('anon', 'public.log_audit(public.audit_action,text,uuid,jsonb,jsonb)', 'execute')
      and not has_function_privilege('authenticated', 'public.log_audit(public.audit_action,text,uuid,jsonb,jsonb)', 'execute'),
  'anon/authenticated cannot execute log_audit');
select is(greatest(tests.n(null, 'service_role', $$update public.audit_logs set after_state = '{"tampered":true}'$$), 0), 0,
  'service_role cannot UPDATE audit rows');
select is(greatest(tests.n(null, 'service_role', 'delete from public.audit_logs'), 0), 0,
  'service_role cannot DELETE audit rows');
select ok(not (has_table_privilege('anon', 'public.audit_logs', 'TRUNCATE') or has_table_privilege('authenticated', 'public.audit_logs', 'TRUNCATE')
               or has_table_privilege('service_role', 'public.audit_logs', 'TRUNCATE')),
  'no API role holds TRUNCATE on audit_logs');
select is((select count(*)::int from pg_trigger where tgrelid = 'public.audit_logs'::regclass and not tgisinternal), 2,
  'immutability triggers guard audit_logs (UPDATE and DELETE)');
select matches(tests.err(null, 'postgres', $$update public.audit_logs set after_state = '{"tampered":true}'$$),
  'append-only', 'even the table owner cannot rewrite audit content (trigger)');
select matches(tests.err(null, 'postgres', 'delete from public.audit_logs'),
  'append-only', 'even the table owner cannot DELETE audit rows (trigger)');

select * from finish();
rollback;
