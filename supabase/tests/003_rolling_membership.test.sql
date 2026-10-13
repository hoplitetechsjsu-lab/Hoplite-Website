-- 2.4 Rolling 30-day membership: active iff >= 2 qualifying attendances with
-- checked_in_at >= now() - 30 days (inclusive boundary). Uses
-- public.recalculate_membership(uuid) + the after-insert trigger on attendances.
-- now() is fixed for the whole transaction, so boundaries are exact.
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

select plan(31);

-- Setup -----------------------------------------------------------------------
create function tests.mk_event(p_name text) returns uuid language plpgsql as $fn$
declare v uuid := tests.uid('event:' || p_name);
begin
  insert into public.events (id, title, starts_at, ends_at, semester, year, is_published)
  values (v, p_name, now(), now() + interval '1 hour', 'fall', 2026, true);
  return v;
end $fn$;

-- p_ages: one entry per attendance, as an interval before now(); p_counts parallels it.
create function tests.mk_member(p_name text, p_ages interval[] default '{}', p_counts boolean[] default null)
returns uuid language plpgsql as $fn$
declare v uuid := tests.mk_user(p_name); i int;
begin
  for i in 1 .. coalesce(array_length(p_ages, 1), 0) loop
    insert into public.attendances (event_id, user_id, checked_in_at, counts_for_membership, source)
    values (tests.mk_event(p_name || '-e' || i), v, now() - p_ages[i],
            coalesce(p_counts[i], true), 'qr_user');
  end loop;
  return v;
end $fn$;

do $$ begin
  perform tests.mk_member('m_zero');
  perform tests.mk_member('m_one',      array['0 days']::interval[]);
  perform tests.mk_member('m_two',      array['0 days','1 day']::interval[]);
  perform tests.mk_member('m_three',    array['0 days','5 days','20 days']::interval[]);
  perform tests.mk_member('m_edge_in',  array['0 days','30 days']::interval[]);
  perform tests.mk_member('m_edge_out', array['0 days','30 days 1 second']::interval[]);
  perform tests.mk_member('m_29d',      array['0 days','29 days 23 hours 59 minutes']::interval[]);
  perform tests.mk_member('m_old',      array['31 days','45 days']::interval[]);
  perform tests.mk_member('m_nocount',  array['0 days','1 day']::interval[], array[false,false]);
  perform tests.mk_member('m_mixed',    array['0 days','1 day']::interval[], array[true,false]);
  perform tests.mk_member('m_decay',    array['0 days','1 day']::interval[]);
end $$;
do $$ begin
  perform public.recalculate_membership(tests.uid('m_zero'));
  perform public.recalculate_membership(tests.fu(4));  -- fixture member with no attendance
end $$;

create function tests.ms(p_name text, out is_active boolean, out cnt int) language sql as
  $fn$ select is_active, qualifying_attendance_count from public.membership_status where user_id = tests.uid(p_name) $fn$;

-- Counts ----------------------------------------------------------------------
select is((tests.ms('m_zero')).cnt, 0, '0 attendances -> count 0');
select is((tests.ms('m_zero')).is_active, false, '0 attendances -> inactive');
select is((select is_active from public.membership_status where user_id = tests.fu(4)), false,
  'fixture member with no attendance is inactive');
select is((tests.ms('m_one')).cnt, 1, '1 attendance -> count 1 (trigger recalculated)');
select is((tests.ms('m_one')).is_active, false, '1 attendance -> inactive');
select is((tests.ms('m_two')).cnt, 2, '2 attendances -> count 2');
select is((tests.ms('m_two')).is_active, true, '2 attendances -> active');
select is((tests.ms('m_three')).is_active, true, '3 attendances -> active');
select is((tests.ms('m_three')).cnt, 3, '3 attendances -> count 3');

-- Window boundary (inclusive at exactly 30 days) --------------------------------
select is((tests.ms('m_edge_in')).cnt, 2, 'attendance at exactly now()-30d still counts (inclusive boundary)');
select is((tests.ms('m_edge_in')).is_active, true, 'exactly-30-day attendance keeps membership active');
select is((tests.ms('m_edge_out')).cnt, 1, 'attendance 1 second older than 30d does not count');
select is((tests.ms('m_edge_out')).is_active, false, 'membership inactive when 2nd attendance is just outside window');
select is((tests.ms('m_29d')).is_active, true, 'attendance at 29d23h59m counts');
select is((tests.ms('m_old')).cnt, 0, 'attendances older than 30 days do not count');
select is((tests.ms('m_old')).is_active, false, 'only old attendances -> inactive');

-- counts_for_membership --------------------------------------------------------
select is((tests.ms('m_nocount')).cnt, 0, 'attendances flagged counts_for_membership=false are excluded');
select is((tests.ms('m_mixed')).cnt, 1, 'only qualifying attendances are counted');
select is((tests.ms('m_mixed')).is_active, false, '1 qualifying + 1 non-qualifying -> inactive');

-- Rolling decay & recompute ----------------------------------------------------
select is((tests.ms('m_decay')).is_active, true, 'member starts active with 2 recent attendances');
update public.attendances set checked_in_at = now() - interval '40 days'
where user_id = tests.uid('m_decay') and checked_in_at < now();
do $$ begin perform public.recalculate_membership(tests.uid('m_decay')); end $$;
select is((tests.ms('m_decay')).is_active, false, 'membership lapses when attendance rolls out of the 30-day window');
select is((tests.ms('m_decay')).cnt, 1, 'lapsed member keeps only the in-window attendance count');
-- Recalculation is an upsert, never a duplicate row.
do $$ begin
  perform public.recalculate_membership(tests.uid('m_two'));
  perform public.recalculate_membership(tests.uid('m_two'));
end $$;
select is((select count(*)::int from public.membership_status where user_id = tests.uid('m_two')), 1,
  'repeated recalculation keeps a single membership_status row');
select is((select window_end - window_start from public.membership_status where user_id = tests.uid('m_two')),
  interval '30 days', 'stored window is exactly 30 days wide');
select is((select calculated_at from public.membership_status where user_id = tests.uid('m_two')), now(),
  'calculated_at is stamped on recalculation');
select is((tests.ms('m_one')).cnt, 1, 'recalculating one user does not alter another');

-- Integrity / access -----------------------------------------------------------
select has_trigger('public', 'attendances', 'trg_attendances_recalc_membership',
  'attendance inserts trigger a membership recalculation');
select matches(tests.err(null, 'postgres',
  format($$insert into public.attendances (event_id, user_id) values (%L, %L)$$,
    tests.uid('event:m_two-e1'), tests.uid('m_two'))),
  '^23505', 'a member cannot be checked in twice to the same event');
select is(tests.n(tests.aid('m_two'), 'authenticated', 'select 1 from public.membership_status'), 1,
  'member can read only their own membership_status');
select matches(tests.err(tests.aid('m_two'), 'authenticated',
  format($$insert into public.membership_status (user_id, is_active) values (%L, true)$$, tests.uid('m_zero'))),
  '^42501', 'members cannot write membership_status directly');
select is(tests.n(tests.aid('m_zero'), 'authenticated',
  format($$update public.membership_status set is_active = true where user_id = %L$$, tests.uid('m_zero'))), 0,
  'members cannot flip their own membership_status to active');

select * from finish();
rollback;
