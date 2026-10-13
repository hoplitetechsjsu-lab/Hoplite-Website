-- 009: security remediation for pgTAP Phase 2 findings (F1–F10)
-- Class: implementation defects fixed before Phase 2 closes.
begin;

-- ---------------------------------------------------------------------------
-- F1 / F7 / F9: revoke privileged SECURITY DEFINER execute from PUBLIC/anon
-- ---------------------------------------------------------------------------
revoke all on function public.get_admin_member_queue() from public;
revoke all on function public.get_admin_member_queue() from anon;
revoke all on function public.get_admin_member_queue() from authenticated;
grant execute on function public.get_admin_member_queue() to authenticated;

revoke all on function public.recalculate_membership(uuid) from public;
revoke all on function public.recalculate_membership(uuid) from anon;
revoke all on function public.recalculate_membership(uuid) from authenticated;
-- Invoked by triggers and Edge Functions (service_role / postgres).

revoke all on function public.merge_guest_attendance_into_user(uuid) from public;
revoke all on function public.merge_guest_attendance_into_user(uuid) from anon;
revoke all on function public.merge_guest_attendance_into_user(uuid) from authenticated;

revoke all on function public.log_audit(public.audit_action, text, uuid, jsonb, jsonb) from public;
revoke all on function public.log_audit(public.audit_action, text, uuid, jsonb, jsonb) from anon;
revoke all on function public.log_audit(public.audit_action, text, uuid, jsonb, jsonb) from authenticated;
-- Called only from other security-definer functions / service_role.

-- ---------------------------------------------------------------------------
-- F2 / F3: protect membership flags and student_id/email from client updates
-- ---------------------------------------------------------------------------
create or replace function public.protect_users_sensitive_columns()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Membership state transitions must go through RPCs / Edge Functions.
  if new.is_pending is distinct from old.is_pending
     or new.is_rejected is distinct from old.is_rejected
     or new.is_deactivated is distinct from old.is_deactivated
     or new.approved_by is distinct from old.approved_by
     or new.approved_at is distinct from old.approved_at
     or new.email_verified is distinct from old.email_verified
     or new.auth_user_id is distinct from old.auth_user_id
  then
    if current_setting('role', true) in ('authenticated', 'anon')
       or nullif(current_setting('request.jwt.claim.role', true), '') in ('authenticated', 'anon')
    then
      raise exception 'Membership state changes require authorized server workflow';
    end if;
  end if;

  -- student_id and email are set at registration; clients cannot rewrite them.
  if new.student_id is distinct from old.student_id
     or new.email is distinct from old.email
  then
    if current_setting('role', true) in ('authenticated', 'anon')
       or nullif(current_setting('request.jwt.claim.role', true), '') in ('authenticated', 'anon')
    then
      raise exception 'student_id and email cannot be changed by client roles';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_protect_users_sensitive on public.users;
create trigger trg_protect_users_sensitive
  before update on public.users
  for each row execute function public.protect_users_sensitive_columns();

-- Site editors may still update non-sensitive columns via users_update policy;
-- membership approval remains membership_admin-only via Edge Functions.

-- ---------------------------------------------------------------------------
-- F4: project managers can read/update their assigned (incl. unpublished) projects
-- ---------------------------------------------------------------------------
drop policy if exists proj_select on public.projects;
create policy proj_select on public.projects for select
  using (
    is_published = true
    or public.can_edit_all_projects()
    or public.can_edit_project(id)
    or public.can_edit_site()
  );

-- ---------------------------------------------------------------------------
-- F5: at most one active holder of a high-level unique role
-- ---------------------------------------------------------------------------
-- A partial unique index cannot reference public.roles (no subqueries in index
-- predicates), so enforce it with a trigger. An advisory lock per role
-- serialises concurrent inserts so two transactions cannot both pass the check.
create or replace function public.enforce_single_active_high_level_role()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.is_active
     and exists (select 1 from public.roles r where r.id = new.role_id and r.is_high_level_unique)
  then
    perform pg_advisory_xact_lock(hashtextextended('role_assignments:' || new.role_id::text, 0));
    if exists (
      select 1 from public.role_assignments ra
      where ra.role_id = new.role_id
        and ra.is_active
        and ra.id is distinct from new.id
    ) then
      raise exception 'Role already has an active holder (high-level unique role)'
        using errcode = '23505';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_single_active_high_level_role on public.role_assignments;
create trigger trg_single_active_high_level_role
  before insert or update of role_id, is_active on public.role_assignments
  for each row execute function public.enforce_single_active_high_level_role();

-- ---------------------------------------------------------------------------
-- F6: deny self-approval / self-rejection of role requests
-- ---------------------------------------------------------------------------
create or replace function public.approve_role_request(p_request_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_req public.role_requests%rowtype;
  v_role public.roles%rowtype;
  v_actor uuid := public.current_app_user_id();
begin
  select * into v_req from public.role_requests
  where id = p_request_id and status = 'pending' for update;
  if not found then raise exception 'Role request not found or not pending'; end if;

  if v_actor is null then raise exception 'Not authenticated'; end if;
  if v_req.requester_id = v_actor then
    raise exception 'Cannot approve your own role request';
  end if;

  if not public.can_approve_role_request(v_req.target_role_id, v_req.target_team_id) then
    raise exception 'Not authorized to approve this role request';
  end if;

  select * into v_role from public.roles where id = v_req.target_role_id;

  if v_role.is_high_level_unique then
    update public.role_assignments set is_active = false, ended_at = now()
    where role_id = v_role.id and is_active = true;
    perform public.log_audit('auto_replace_role','role_assignment',null,null,
      jsonb_build_object('role_id', v_role.id));
  end if;

  insert into public.role_assignments(user_id, role_id, team_id, assigned_by)
  values (v_req.requester_id, v_req.target_role_id, v_req.target_team_id, v_actor);

  update public.role_requests
  set status = 'approved', decided_by = v_actor, decided_at = now()
  where id = p_request_id;

  perform public.log_audit('approve','role_request',p_request_id,null,jsonb_build_object('status','approved'));
end;
$$;

create or replace function public.reject_role_request(p_request_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_req public.role_requests%rowtype;
  v_actor uuid := public.current_app_user_id();
begin
  select * into v_req from public.role_requests
  where id = p_request_id and status = 'pending' for update;
  if not found then raise exception 'Role request not found or not pending'; end if;

  if v_actor is null then raise exception 'Not authenticated'; end if;
  if v_req.requester_id = v_actor then
    raise exception 'Cannot reject your own role request';
  end if;

  if not public.can_approve_role_request(v_req.target_role_id, v_req.target_team_id) then
    raise exception 'Not authorized to reject this role request';
  end if;

  update public.role_requests
  set status = 'rejected', decided_by = v_actor, decided_at = now()
  where id = p_request_id;

  perform public.log_audit('reject','role_request',p_request_id,null,jsonb_build_object('status','rejected'));
end;
$$;

-- ---------------------------------------------------------------------------
-- F8: storage file size + MIME constraints (images for media buckets)
-- ---------------------------------------------------------------------------
update storage.buckets
set
  file_size_limit = 5242880,
  allowed_mime_types = array['image/jpeg','image/png','image/webp','image/gif']
where id in ('profile-photos','project-images','site-assets');

update storage.buckets
set
  file_size_limit = 20971520,
  allowed_mime_types = array['text/csv','application/json']
where id = 'export-files';

-- ---------------------------------------------------------------------------
-- F10: harden audit_logs append-only semantics
-- ---------------------------------------------------------------------------
revoke update, delete, truncate on public.audit_logs from anon, authenticated, service_role;
revoke truncate on public.audit_logs from public;

create or replace function public.prevent_audit_mutation()
returns trigger
language plpgsql
as $$
begin
  -- The only permitted change is the FK ON DELETE SET NULL on actor_user_id
  -- (audit history outlives its actor); every other UPDATE/DELETE is refused.
  if tg_op = 'UPDATE'
     and old.actor_user_id is not null
     and new.actor_user_id is null
     and (to_jsonb(new) - 'actor_user_id') = (to_jsonb(old) - 'actor_user_id')
  then
    return new;
  end if;
  raise exception 'audit_logs is append-only';
end;
$$;

drop trigger if exists trg_audit_no_update on public.audit_logs;
create trigger trg_audit_no_update
  before update on public.audit_logs
  for each row execute function public.prevent_audit_mutation();

drop trigger if exists trg_audit_no_delete on public.audit_logs;
create trigger trg_audit_no_delete
  before delete on public.audit_logs
  for each row execute function public.prevent_audit_mutation();

-- service_role may INSERT (Edge Functions); SELECT remains RLS-gated for clients.
grant insert on public.audit_logs to service_role;
grant select on public.audit_logs to authenticated;

commit;
