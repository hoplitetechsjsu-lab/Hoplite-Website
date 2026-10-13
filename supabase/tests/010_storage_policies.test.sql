-- 2.12 Storage policies (migration 006).
--   * project-images, site-assets: public buckets, anon-readable objects
--   * profile-photos, export-files: private, never readable through RLS
--   * no client (anon/authenticated, editors included) can insert/update/delete;
--     only service_role (Edge Functions) can write
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

-- Setup (superuser bypasses RLS) ------------------------------------------------
insert into storage.objects (bucket_id, name) values
  ('project-images', 'pgtap/project.png'), ('site-assets', 'pgtap/site.png'),
  ('profile-photos', 'pgtap/profile.png'), ('export-files', 'pgtap/export.csv');

select results_eq(
  $$select id, public from storage.buckets where id in ('project-images','site-assets','profile-photos','export-files') order by id$$,
  $$values ('export-files', false), ('profile-photos', false), ('project-images', true), ('site-assets', true)$$,
  'bucket visibility: images/assets public, profile photos/exports private');
select is((select count(*)::int from pg_policies where schemaname = 'storage' and tablename = 'objects'
           and policyname in ('storage read public buckets','storage no client insert','storage no client update','storage no client delete')), 4,
  'migration 006 policies are present on storage.objects');

-- Reads -----------------------------------------------------------------------------
select is(tests.n(null, 'anon', $$select 1 from storage.objects where bucket_id = 'project-images'$$), 1, 'anon can read project-images');
select is(tests.n(null, 'anon', $$select 1 from storage.objects where bucket_id = 'site-assets'$$), 1, 'anon can read site-assets');
select is(tests.n(null, 'anon', $$select 1 from storage.objects where bucket_id = 'profile-photos'$$), 0, 'anon cannot read profile-photos');
select is(tests.n(null, 'anon', $$select 1 from storage.objects where bucket_id = 'export-files'$$), 0, 'anon cannot read export-files');
select is(tests.n(tests.fa(4), 'authenticated', $$select 1 from storage.objects where bucket_id in ('profile-photos','export-files')$$), 0,
  'a member cannot read private buckets directly (signed URLs only)');
select is(tests.n(tests.fa(1), 'authenticated', $$select 1 from storage.objects where bucket_id in ('profile-photos','export-files')$$), 0,
  'not even the president can read private buckets directly');
select is(tests.n(tests.fa(4), 'authenticated', $$select 1 from storage.objects where bucket_id in ('project-images','site-assets')$$), 2,
  'members can read the public buckets');

-- Writes ------------------------------------------------------------------------------
select matches(tests.err(null, 'anon', $$insert into storage.objects (bucket_id, name) values ('project-images', 'anon.png')$$),
  '^42501', 'anon cannot upload to a public bucket');
select matches(tests.err(null, 'anon', $$insert into storage.objects (bucket_id, name) values ('profile-photos', 'anon.png')$$),
  '^42501', 'anon cannot upload to a private bucket');
select matches(tests.err(tests.fa(4), 'authenticated', $$insert into storage.objects (bucket_id, name) values ('profile-photos', 'member.png')$$),
  '^42501', 'a member cannot upload directly (uploads go through Edge Functions)');
select matches(tests.err(tests.fa(1), 'authenticated', $$insert into storage.objects (bucket_id, name) values ('site-assets', 'pres.png')$$),
  '^42501', 'the president cannot upload directly either');
select is(tests.n(tests.fa(4), 'authenticated', $$update storage.objects set name = 'renamed.png' where bucket_id = 'project-images'$$), 0,
  'a member cannot rename/update objects');
select is(tests.n(tests.fa(1), 'authenticated', $$update storage.objects set name = 'renamed.png' where bucket_id = 'project-images'$$), 0,
  'the president cannot rename/update objects');
select is(greatest(tests.n(tests.fa(1), 'authenticated', $$delete from storage.objects where bucket_id = 'project-images'$$), 0), 0,
  'the president cannot delete objects directly (denied or filtered; Storage also blocks raw deletes)');
select is(greatest(tests.n(null, 'anon', $$delete from storage.objects where bucket_id = 'site-assets'$$), 0), 0, 'anon cannot delete objects');
select is(greatest(tests.n(tests.fa(1), 'authenticated', $$delete from storage.objects where bucket_id in ('profile-photos','export-files')$$), 0), 0,
  'private objects cannot be deleted by clients');

-- service_role (Edge Functions; deletes go through the Storage API, which blocks raw SQL deletes) ----------------------------------------------------------
select is(tests.err(null, 'service_role', $$insert into storage.objects (bucket_id, name) values ('profile-photos', 'svc.png')$$), 'ok',
  'service_role can upload to a private bucket');
select is(tests.n(null, 'service_role', $$update storage.objects set name = 'svc2.png' where name = 'svc.png'$$), 1,
  'service_role can update objects');

-- Bucket limits (migration 009, F8) / deferred -------------------------------------------------------------------
select ok((select bool_and(file_size_limit is not null and allowed_mime_types is not null) from storage.buckets
           where id in ('project-images','profile-photos','site-assets')),
  'image/asset buckets restrict file size and MIME types');
select skip('DEFERRED: signed-URL issuance and per-user profile-photo ownership checks are Edge Function / Storage API behaviour (POST_MVP.md).', 1);

select * from finish();
rollback;
