-- 2.14 Exports.
--   Only the export_jobs table, enum and RLS exist today. There is no export
--   RPC / Edge Function, so generation, per-type authorization, file contents
--   and expiry are DEFERRED (skip below, tracked in POST_MVP.md). Schema/RLS is
--   verified now so the deferred work starts from a locked-down table.
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

select plan(20);

-- Setup -----------------------------------------------------------------------
insert into public.export_jobs (id, requested_by, export_type, filters, file_path) values
  (tests.uid('job:member'), tests.fu(4), 'active_members', '{}', 'export-files/member.csv'),
  (tests.uid('job:president'), tests.fu(1), 'all_members', '{"semester":"fall"}', 'export-files/president.csv');

-- Schema ----------------------------------------------------------------------
select has_table('public', 'export_jobs', 'export_jobs exists');
select is((select relrowsecurity from pg_class where oid = 'public.export_jobs'::regclass), true, 'RLS is enabled on export_jobs');
select enum_has_labels('public', 'export_type', array[
  'weekly_digest','event_attendance','all_members','active_members',
  'all_officers','all_profiles','project_roster','project_applicants'], 'export_type enum lists the 8 export kinds');
select is((select public from storage.buckets where id = 'export-files'), false, 'the export-files bucket is private');
select col_not_null('public', 'export_jobs', 'requested_by', 'every export job records who requested it');

-- RLS ----------------------------------------------------------------------------
select is(tests.n(tests.fa(4), 'authenticated', 'select 1 from public.export_jobs'), 1, 'a member sees only their own export jobs');
select is(tests.n(tests.fa(4), 'authenticated', format('select 1 from public.export_jobs where id = %L', tests.uid('job:president'))), 0,
  'a member cannot see another user''s export job');
select is(tests.n(tests.fa(2), 'authenticated', 'select 1 from public.export_jobs'), 0, 'a user with no jobs sees none');
select is(tests.n(tests.fa(1), 'authenticated', 'select 1 from public.export_jobs'), 2, 'site editors see all export jobs');
select is(tests.n(null, 'anon', 'select 1 from public.export_jobs'), 0, 'anon sees no export jobs');
select matches(tests.err(tests.fa(1), 'authenticated',
  format($$insert into public.export_jobs (requested_by, export_type) values (%L, 'all_members')$$, tests.fu(1))),
  '^42501', 'even the president cannot create export jobs from the client');
select matches(tests.err(tests.fa(4), 'authenticated',
  format($$insert into public.export_jobs (requested_by, export_type) values (%L, 'all_members')$$, tests.fu(4))),
  '^42501', 'a member cannot create export jobs from the client');
select matches(tests.err(null, 'anon',
  format($$insert into public.export_jobs (requested_by, export_type) values (%L, 'all_members')$$, tests.fu(4))),
  '^42501', 'anon cannot create export jobs');
select is(tests.n(tests.fa(4), 'authenticated', $$update public.export_jobs set file_path = 'export-files/stolen.csv'$$), 0,
  'a member cannot rewrite export job file paths');
select is(tests.n(tests.fa(1), 'authenticated', 'delete from public.export_jobs'), 0, 'clients cannot delete export jobs');

-- Deferred ---------------------------------------------------------------------------------
select ok(not exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname ~* 'export'),
  'NOTE: no export RPC exists yet; when one is added, replace the skips below with real tests');
select skip('DEFERRED (POST_MVP.md 2.14): per-export-type authorization matrix (who may run all_members / all_profiles / project_applicants ...).', 1);
select skip('DEFERRED (POST_MVP.md 2.14): generated CSV never contains student_id unless explicitly authorized; emails limited to the permitted types.', 1);
select skip('DEFERRED (POST_MVP.md 2.14): export file lifecycle - signed URL expiry (expires_at), generated_at, cleanup of export-files objects.', 1);
select skip('DEFERRED (POST_MVP.md 2.14): generating an export writes a generate_export audit_logs row with the requester.', 1);

select * from finish();
rollback;
