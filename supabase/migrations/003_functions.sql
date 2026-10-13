-- 003: security-definer functions and RPCs (all server-side authorization)
begin;

-- The acting app user. Pending and deactivated users resolve to NULL (cannot act).
create or replace function public.current_app_user_id() returns uuid
language sql stable security definer set search_path = public as $$
  select u.id from public.users u
  where u.auth_user_id = auth.uid()
    and u.is_pending = false
    and u.is_deactivated = false
    and u.is_rejected = false
  limit 1;
$$;

create or replace function public.user_has_active_role(p_user_id uuid, p_role_keys text[]) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.role_assignments ra
    join public.roles r on r.id = ra.role_id
    where ra.user_id = p_user_id and ra.is_active = true and r.key = any(p_role_keys)
  );
$$;

create or replace function public.me_has_role(p_role_keys text[]) returns boolean
language sql stable security definer set search_path = public as $$
  select public.user_has_active_role(public.current_app_user_id(), p_role_keys);
$$;

create or replace function public.can_edit_roles() returns boolean
language sql stable security definer set search_path = public as $$
  select public.me_has_role(array['president','vp','website_coordinator']);
$$;

create or replace function public.can_edit_site() returns boolean
language sql stable security definer set search_path = public as $$
  select public.me_has_role(array['president','vp','website_coordinator','website_lead']);
$$;

create or replace function public.can_edit_all_projects() returns boolean
language sql stable security definer set search_path = public as $$
  select public.me_has_role(array['president','vp','website_coordinator','website_lead','technical_sourcing_coordinator','technical_sourcing_lead']);
$$;

create or replace function public.can_edit_all_events() returns boolean
language sql stable security definer set search_path = public as $$
  select public.me_has_role(array['president','vp','website_coordinator','website_lead','events_coordinator','events_lead']);
$$;

create or replace function public.can_edit_project(p_project_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.can_edit_all_projects() or exists (
    select 1 from public.project_assignments pa
    join public.roles r on r.id = pa.role_id
    where pa.project_id = p_project_id
      and pa.user_id = public.current_app_user_id()
      and pa.is_active = true
      and r.key = 'project_manager'
  );
$$;

create or replace function public.can_manage_user_media() returns boolean
language sql stable security definer set search_path = public as $$
  select public.me_has_role(array['president','vp','website_coordinator','website_lead']);
$$;

create or replace function public.can_read_audit_logs() returns boolean
language sql stable security definer set search_path = public as $$
  select public.me_has_role(array['president','vp','website_coordinator','website_lead']);
$$;

-- Least-privilege: only the dedicated membership_admin role can approve/reject
-- members. Broad site-edit roles are intentionally NOT included here.
create or replace function public.can_approve_membership() returns boolean
language sql stable security definer set search_path = public as $$
  select public.me_has_role(array['membership_admin']);
$$;

create or replace function public.can_approve_role_request(p_target_role_id uuid, p_target_team_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.role_assignments ra
    join public.approval_rules ar on ar.approver_role_id = ra.role_id and ar.is_active = true
    where ra.user_id = public.current_app_user_id()
      and ra.is_active = true
      and ar.target_role_id = p_target_role_id
      and (ar.team_scope_id is null or ar.team_scope_id = p_target_team_id)
  );
$$;

create or replace function public.log_audit(
  p_action public.audit_action, p_entity_type text, p_entity_id uuid,
  p_before jsonb, p_after jsonb
) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.audit_logs(actor_user_id, action_type, entity_type, entity_id, before_state, after_state)
  values (public.current_app_user_id(), p_action, p_entity_type, p_entity_id, p_before, p_after);
end;
$$;

-- Membership: rolling 30-day window; active if >= 2 qualifying attendances.
create or replace function public.recalculate_membership(p_user_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_count int;
begin
  select count(*) into v_count from public.attendances a
  where a.user_id = p_user_id
    and a.counts_for_membership = true
    and a.checked_in_at >= now() - interval '30 days';
  insert into public.membership_status (user_id, is_active, qualifying_attendance_count, window_start, window_end, calculated_at)
  values (p_user_id, v_count >= 2, v_count, now() - interval '30 days', now(), now())
  on conflict (user_id) do update set
    is_active = excluded.is_active,
    qualifying_attendance_count = excluded.qualifying_attendance_count,
    window_start = excluded.window_start,
    window_end = excluded.window_end,
    calculated_at = excluded.calculated_at;
end;
$$;

-- Merge a guest identity's attendance into a real user account (indexed email lookup).
create or replace function public.merge_guest_attendance_into_user(p_user_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_email citext;
  v_guest_id uuid;
  v_merged_count int := 0;
begin
  select email into v_email from public.users where id = p_user_id;
  select id into v_guest_id from public.guest_identities
  where normalized_email = lower(trim(v_email::text));

  if v_guest_id is null then
    perform public.recalculate_membership(p_user_id);
    return 0;
  end if;

  insert into public.attendances (event_id, user_id, checked_in_at, source, counts_for_membership, created_by)
  select ga.event_id, p_user_id, ga.checked_in_at, 'guest_merge', true, null
  from public.guest_attendances ga
  where ga.guest_identity_id = v_guest_id and ga.merged = false
  on conflict (event_id, user_id) do nothing;
  get diagnostics v_merged_count = row_count;

  update public.guest_attendances
  set merged = true, merged_into_user_id = p_user_id, merged_at = now()
  where guest_identity_id = v_guest_id and merged = false;

  perform public.recalculate_membership(p_user_id);
  return v_merged_count;
end;
$$;

create or replace function public.after_attendance_recalc() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.recalculate_membership(new.user_id);
  return new;
end;
$$;
create trigger trg_attendances_recalc_membership
  after insert on public.attendances
  for each row execute function public.after_attendance_recalc();

-- Role requests: 5/semester max, 2 pending max; rejected counts, withdrawn does not.
create or replace function public.submit_role_request(
  p_target_role_id uuid, p_target_team_id uuid, p_justification text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_requester uuid := public.current_app_user_id();
  v_pending int;
  v_total int;
  v_id uuid;
begin
  if v_requester is null then raise exception 'Not authenticated'; end if;

  select count(*) into v_pending from public.role_requests
  where requester_id = v_requester and status = 'pending';
  if v_pending >= 2 then raise exception 'Maximum pending role requests reached'; end if;

  select count(*) into v_total from public.role_requests
  where requester_id = v_requester
    and status in ('pending','approved','rejected')
    and public.semester_key_for(created_at) = public.current_semester_key();
  if v_total >= 5 then raise exception 'Maximum semester role requests reached'; end if;

  insert into public.role_requests(requester_id, target_role_id, target_team_id, justification)
  values (v_requester, p_target_role_id, p_target_team_id, p_justification)
  returning id into v_id;

  perform public.log_audit('create','role_request',v_id,null,jsonb_build_object(
    'requester_id', v_requester,
    'target_role_id', p_target_role_id,
    'target_team_id', p_target_team_id
  ));
  return v_id;
end;
$$;

create or replace function public.approve_role_request(p_request_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_req public.role_requests%rowtype;
  v_role public.roles%rowtype;
begin
  select * into v_req from public.role_requests
  where id = p_request_id and status = 'pending' for update;
  if not found then raise exception 'Role request not found or not pending'; end if;

  if not public.can_approve_role_request(v_req.target_role_id, v_req.target_team_id) then
    raise exception 'Not authorized to approve this role request';
  end if;

  select * into v_role from public.roles where id = v_req.target_role_id;

  -- High-level unique roles (President, VP, Coordinators): previous holder loses it.
  if v_role.is_high_level_unique then
    update public.role_assignments set is_active = false, ended_at = now()
    where role_id = v_role.id and is_active = true;
    perform public.log_audit('auto_replace_role','role_assignment',null,null,
      jsonb_build_object('role_id', v_role.id));
  end if;

  insert into public.role_assignments(user_id, role_id, team_id, assigned_by)
  values (v_req.requester_id, v_req.target_role_id, v_req.target_team_id, public.current_app_user_id());

  update public.role_requests
  set status = 'approved', decided_by = public.current_app_user_id(), decided_at = now()
  where id = p_request_id;

  perform public.log_audit('approve','role_request',p_request_id,null,jsonb_build_object('status','approved'));
end;
$$;

create or replace function public.reject_role_request(p_request_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_req public.role_requests%rowtype;
begin
  select * into v_req from public.role_requests
  where id = p_request_id and status = 'pending' for update;
  if not found then raise exception 'Role request not found or not pending'; end if;

  if not public.can_approve_role_request(v_req.target_role_id, v_req.target_team_id) then
    raise exception 'Not authorized to reject this role request';
  end if;

  update public.role_requests
  set status = 'rejected', decided_by = public.current_app_user_id(), decided_at = now()
  where id = p_request_id;

  perform public.log_audit('reject','role_request',p_request_id,null,jsonb_build_object('status','rejected'));
end;
$$;

-- Withdraw a pending request (does not count toward the semester total).
create or replace function public.withdraw_role_request(p_request_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_req public.role_requests%rowtype;
begin
  select * into v_req from public.role_requests
  where id = p_request_id and status = 'pending' for update;
  if not found then raise exception 'Role request not found or not pending'; end if;
  if v_req.requester_id <> public.current_app_user_id() then
    raise exception 'Not authorized';
  end if;
  update public.role_requests
  set status = 'withdrawn', withdrawn_at = now()
  where id = p_request_id;
  perform public.log_audit('withdraw','role_request',p_request_id,null,jsonb_build_object('status','withdrawn'));
end;
$$;

-- Admin member-approval queue. Returns pending + rejected members with NO
-- student_id. Unauthorized callers (no membership_admin role) get an empty set;
-- execute is also revoked from anon.
create or replace function public.get_admin_member_queue() returns table(
  user_id uuid, email citext, created_at timestamptz,
  is_pending boolean, is_rejected boolean, is_deactivated boolean, email_verified boolean
) language plpgsql security definer set search_path = public as $$
begin
  if not public.can_approve_membership() then
    return;
  end if;
  return query
    select u.id, u.email, u.created_at, u.is_pending, u.is_rejected, u.is_deactivated, u.email_verified
    from public.users u
    where u.is_pending = true or u.is_rejected = true
    order by u.is_pending desc, u.created_at asc;
end;
$$;
revoke execute on function public.get_admin_member_queue() from anon;

commit;