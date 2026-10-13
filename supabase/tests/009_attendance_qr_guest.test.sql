-- 2.11 Attendance / QR / guest locks.
--   * QR token hashes: event editors only
--   * attendances: no client INSERT/DELETE (check-in is server-side), members read own
--   * guest identities/attendances: never client-readable (identities) / editors only
--   * guest -> member merge via merge_guest_attendance_into_user()
-- Token validation, expiry and HTTP behaviour live in the check-in Edge Functions
-- (skipped below, tracked in POST_MVP.md).
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

select plan(38);

-- Setup -----------------------------------------------------------------------
create function tests.mk_event(p_name text) returns uuid language plpgsql as $fn$
declare v uuid := tests.uid('event:' || p_name);
begin
  insert into public.events (id, title, starts_at, ends_at, semester, year, is_published)
  values (v, p_name, now(), now() + interval '1 hour', 'fall', 2026, true);
  return v;
end $fn$;

do $$ begin
  perform tests.mk_event('ea'); perform tests.mk_event('eb'); perform tests.mk_event('ec');
  perform tests.mk_user('g1'); perform tests.mk_user('g2'); perform tests.mk_user('g3');
  perform tests.mk_user('g_none');
end $$;
insert into public.event_qr_tokens (event_id, token_hash, expires_at)
values ('00000000-0000-4000-8000-00000000e001', 'hash-pgtap-1', now() + interval '1 hour');
insert into public.attendances (event_id, user_id, source)
values (tests.uid('event:ea'), tests.fu(4), 'qr_user'), (tests.uid('event:eb'), tests.fu(3), 'qr_user');
insert into public.guest_identities (id, normalized_email, normalized_email_hash) values
  (tests.uid('guest:g1'), 'g1@pgtap.test', public.hash_email('g1@pgtap.test')),
  (tests.uid('guest:g2'), 'g2@pgtap.test', public.hash_email('g2@pgtap.test')),
  (tests.uid('guest:stranger'), 'stranger@pgtap.test', public.hash_email('stranger@pgtap.test'));
insert into public.guest_attendances (event_id, guest_identity_id) values
  (tests.uid('event:ea'), tests.uid('guest:g1')), (tests.uid('event:eb'), tests.uid('guest:g1')),
  (tests.uid('event:ea'), tests.uid('guest:g2')), (tests.uid('event:eb'), tests.uid('guest:g2')),
  (tests.uid('event:ea'), tests.uid('guest:stranger'));
-- g2 already attended event A as a member -> overlap must not duplicate.
insert into public.attendances (event_id, user_id, source) values (tests.uid('event:ea'), tests.uid('g2'), 'qr_user');

-- QR tokens ---------------------------------------------------------------------
select hasnt_column('public', 'event_qr_tokens', 'token', 'only a token HASH is stored (no plaintext token column)');
select col_not_null('public', 'event_qr_tokens', 'expires_at', 'every QR token has an expiry');
select results_eq($$
  select label, expected, actual from (
    select label, ev as expected,
      tests.n(auth, pgrole, 'select 1 from public.event_qr_tokens') = 1 as actual
    from (values
      ('anon', null::uuid, 'anon', false), ('pending', tests.aid('a_pending'), 'authenticated', false),
      ('member', tests.fa(4), 'authenticated', false), ('pm', tests.fa(3), 'authenticated', false),
      ('events_lead', tests.fa(2), 'authenticated', true), ('president', tests.fa(1), 'authenticated', true)
    ) v(label, auth, pgrole, ev)) x where actual is distinct from expected$$,
  $$select null::text, null::boolean, null::boolean where false$$,
  'QR token rows are readable only by event editors / site editors');
select matches(tests.err(tests.fa(4), 'authenticated',
  $$insert into public.event_qr_tokens (event_id, token_hash, expires_at) values ('00000000-0000-4000-8000-00000000e001', 'h-member', now() + interval '1 hour')$$),
  '^42501', 'a member cannot mint a QR token');
select matches(tests.err(null, 'anon',
  $$insert into public.event_qr_tokens (event_id, token_hash, expires_at) values ('00000000-0000-4000-8000-00000000e001', 'h-anon', now() + interval '1 hour')$$),
  '^42501', 'anon cannot mint a QR token');
select is(tests.err(tests.fa(2), 'authenticated',
  $$insert into public.event_qr_tokens (event_id, token_hash, expires_at) values ('00000000-0000-4000-8000-00000000e001', 'h-lead', now() + interval '1 hour')$$),
  'ok', 'an events lead can mint a QR token');
select is(tests.n(tests.fa(4), 'authenticated', $$update public.event_qr_tokens set is_active = true$$), 0,
  'a member cannot touch QR tokens');
select matches(tests.err(null, 'postgres',
  $$insert into public.event_qr_tokens (event_id, token_hash, expires_at) values ('00000000-0000-4000-8000-00000000e001', 'hash-pgtap-1', now())$$),
  '^23505', 'token hashes are unique');
select is((select count(*)::int from public.event_qr_tokens where event_id = '00000000-0000-4000-8000-00000000e001'), 2,
  'precondition: two tokens exist for the event');

-- Attendances ---------------------------------------------------------------------
select matches(tests.err(tests.fa(4), 'authenticated',
  format($$insert into public.attendances (event_id, user_id) values (%L, %L)$$, tests.uid('event:ec'), tests.fu(4))),
  '^42501', 'a member cannot check themselves in by direct INSERT (server-side only)');
select matches(tests.err(tests.fa(2), 'authenticated',
  format($$insert into public.attendances (event_id, user_id) values (%L, %L)$$, tests.uid('event:ec'), tests.fu(4))),
  '^42501', 'even an events lead cannot INSERT attendance rows from the client');
select is(tests.n(tests.fa(4), 'authenticated', 'delete from public.attendances'), 0,
  'a member cannot delete attendance records');
select is(tests.n(tests.fa(2), 'authenticated', 'delete from public.attendances'), 0,
  'event editors cannot delete attendance records either');
select is(tests.n(tests.fa(4), 'authenticated', 'select 1 from public.attendances'), 1,
  'a member reads only their own attendance');
select cmp_ok(tests.n(tests.fa(2), 'authenticated', 'select 1 from public.attendances'), '>=', 3,
  'event editors can read all attendance');
select is(tests.n(null, 'anon', 'select 1 from public.attendances'), 0, 'anon cannot read attendance');

-- Guest data ------------------------------------------------------------------------
select results_eq($$
  select label, n from (
    select label, tests.n(auth, pgrole, 'select 1 from public.guest_identities') as n
    from (values ('anon', null::uuid, 'anon'), ('member', tests.fa(4), 'authenticated'),
      ('events_lead', tests.fa(2), 'authenticated'), ('president', tests.fa(1), 'authenticated')) v(label, auth, pgrole)
  ) x where n <> 0$$,
  $$select null::text, null::int where false$$,
  'guest_identities (emails) are invisible to every client role, editors included');
select matches(tests.err(tests.fa(2), 'authenticated', $$insert into public.guest_identities (normalized_email, normalized_email_hash) values ('x@pgtap.test', 'x')$$),
  '^42501', 'clients cannot create guest identities');
select is(tests.n(tests.fa(4), 'authenticated', 'select 1 from public.guest_attendances'), 0, 'members cannot read guest attendance');
select is(tests.n(null, 'anon', 'select 1 from public.guest_attendances'), 0, 'anon cannot read guest attendance');
select cmp_ok(tests.n(tests.fa(2), 'authenticated', 'select 1 from public.guest_attendances'), '>=', 5,
  'event editors can read guest attendance');
select matches(tests.err(tests.fa(2), 'authenticated',
  format($$insert into public.guest_attendances (event_id, guest_identity_id) values (%L, %L)$$, tests.uid('event:ec'), tests.uid('guest:g1'))),
  '^42501', 'clients cannot write guest attendance');
select matches(tests.err(null, 'postgres',
  format($$insert into public.guest_attendances (event_id, guest_identity_id) values (%L, %L)$$, tests.uid('event:ea'), tests.uid('guest:g1'))),
  '^23505', 'a guest can check in to an event only once');
select matches(tests.err(null, 'postgres',
  $$insert into public.guest_identities (normalized_email, normalized_email_hash) values ('G1@PGTAP.TEST', 'other-hash')$$),
  '^23505', 'guest emails are unique case-insensitively');
select is(public.hash_email('  G1@PGTAP.test '), public.hash_email('g1@pgtap.test'), 'hash_email normalizes case and whitespace');
select is(length(public.hash_email('g1@pgtap.test')), 64, 'hash_email is a sha-256 hex digest');

-- Guest -> member merge ---------------------------------------------------------------
select is(public.merge_guest_attendance_into_user(tests.uid('g1')), 2,
  'merge folds both guest check-ins into the matching account');
select is((select count(*)::int from public.attendances
           where user_id = tests.uid('g1') and source = 'guest_merge' and counts_for_membership and created_by is null), 2,
  'merged attendances are flagged guest_merge and count toward membership');
select is((select count(*)::int from public.guest_attendances
           where guest_identity_id = tests.uid('guest:g1') and merged and merged_into_user_id = tests.uid('g1') and merged_at is not null), 2,
  'guest rows are marked merged into the user');
select is((select is_active from public.membership_status where user_id = tests.uid('g1')), true,
  'merged attendance activates membership (2 qualifying check-ins)');
select is(public.merge_guest_attendance_into_user(tests.uid('g1')), 0, 'merge is idempotent');
select is(public.merge_guest_attendance_into_user(tests.uid('g2')), 1,
  'merge skips an event the member already attended (no duplicate row)');
select is(public.merge_guest_attendance_into_user(tests.uid('g_none')), 0,
  'merge with no guest identity is a no-op');
select is((select count(*)::int from public.attendances where user_id in (tests.uid('g_none'), tests.uid('g3'))), 0,
  'other accounts never receive someone else''s guest attendance');

-- Privilege hardening (migration 009, F7) / deferred -----------------------------------------------------------------
select ok(not has_function_privilege('anon', 'public.merge_guest_attendance_into_user(uuid)', 'execute'),
  'anon cannot execute merge_guest_attendance_into_user');
select ok(not has_function_privilege('authenticated', 'public.recalculate_membership(uuid)', 'execute'),
  'authenticated cannot execute recalculate_membership');
select skip('DEFERRED (Edge Functions, see POST_MVP.md): check-in-user/check-in-guest reject unknown or inactive tokens (404), expired tokens (410), unauthenticated/pending callers (401/403); guest check-in merges only into verified, non-pending, non-rejected accounts.', 2);

select * from finish();
rollback;
