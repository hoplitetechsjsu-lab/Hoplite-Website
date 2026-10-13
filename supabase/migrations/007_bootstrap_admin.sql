-- 007: one-time first-admin bootstrap (SECURE).
--
-- Defines a security-definer function that ONLY the database owner / trusted
-- setup process may call (execute is revoked from public, anon, and
-- authenticated). No ordinary user can bootstrap themselves into admin.
--
-- No email or student ID is stored in this file. The owner passes the verified
-- auth.users.id at runtime. A student ID is NOT required to grant admin access.
--
-- Usage (run ONCE, as the owner, from the Supabase SQL Editor, after the target
-- person has signed up and verified their email — and after seed_roles_and_teams):
--   select public.bootstrap_first_admin('<verified-auth-user-uuid>'::uuid);
-- Then drop the function so it can never be called again:
--   drop function public.bootstrap_first_admin(uuid);
begin;

create or replace function public.bootstrap_first_admin(p_auth_uid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_email citext;
  v_user uuid;
  v_role uuid;
begin
  -- The auth user must exist and have a confirmed email.
  select email into v_email from auth.users
  where id = p_auth_uid and email_confirmed_at is not null;
  if v_email is null then
    raise exception 'Auth user not found or email not confirmed';
  end if;

  -- Refuse if any membership_admin already exists (defense in depth — execute is
  -- also revoked from non-owners below).
  if exists (
    select 1 from public.role_assignments ra
    join public.roles r on r.id = ra.role_id
    where r.key = 'membership_admin' and ra.is_active = true
  ) then
    raise exception 'A membership_admin already exists';
  end if;

  -- Create/activate the app user row WITHOUT a student_id (admin access does not
  -- require one). is_pending=false, is_rejected=false so current_app_user_id() works.
  insert into public.users (auth_user_id, student_id, email, is_pending, is_rejected, email_verified, approved_at)
  values (p_auth_uid, null, v_email, false, false, true, now())
  on conflict (auth_user_id) do update set
    is_pending = false, is_rejected = false, email_verified = true, approved_at = now()
  returning id into v_user;

  select id into v_role from public.roles where key = 'membership_admin';
  if v_role is null then
    raise exception 'membership_admin role missing — run seed_roles_and_teams.sql first';
  end if;

  insert into public.role_assignments (user_id, role_id, is_active, assigned_by)
  select v_user, v_role, true, v_user
  where not exists (
    select 1 from public.role_assignments
    where user_id = v_user and role_id = v_role and is_active = true
  );

  -- Audit log — no student ID (there is none for this admin).
  insert into public.audit_logs (actor_user_id, action_type, entity_type, entity_id, after_state)
  values (v_user, 'approve_member', 'user', v_user,
    jsonb_build_object('bootstrap', true, 'role', 'membership_admin'));
end;
$$;

-- Only the database owner / trusted setup process may call this.
revoke execute on function public.bootstrap_first_admin(uuid) from public, anon, authenticated;

commit;