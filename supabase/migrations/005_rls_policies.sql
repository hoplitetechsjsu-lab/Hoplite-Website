-- 005: row-level security policies
begin;

alter table public.users enable row level security;
alter table public.profiles enable row level security;
alter table public.student_id_collisions enable row level security;
alter table public.roles enable row level security;
alter table public.teams enable row level security;
alter table public.role_assignments enable row level security;
alter table public.approval_rules enable row level security;
alter table public.role_requests enable row level security;
alter table public.events enable row level security;
alter table public.event_qr_tokens enable row level security;
alter table public.guest_identities enable row level security;
alter table public.guest_attendances enable row level security;
alter table public.attendances enable row level security;
alter table public.membership_status enable row level security;
alter table public.projects enable row level security;
alter table public.project_assignments enable row level security;
alter table public.export_jobs enable row level security;
alter table public.audit_logs enable row level security;
alter table public.user_deactivations enable row level security;

-- users: self or site admins. student_id is never exposed publicly (charts use views).
-- users: self by auth_user_id (so pending users can read their own row to see
-- their pending status) or site admins. student_id is never exposed publicly.
create policy users_select on public.users for select
  using (auth_user_id = auth.uid() or public.can_edit_site());
create policy users_insert_server on public.users for insert with check (false);
create policy users_update on public.users for update
  using (id = public.current_app_user_id() or public.can_edit_site())
  with check (id = public.current_app_user_id() or public.can_edit_site());

create policy profiles_select on public.profiles for select
  using (user_id = public.current_app_user_id() or public.can_edit_site());
create policy profiles_insert on public.profiles for insert
  with check (user_id = public.current_app_user_id());
create policy profiles_update on public.profiles for update
  using (user_id = public.current_app_user_id() or public.can_edit_site())
  with check (user_id = public.current_app_user_id() or public.can_edit_site());
create policy profiles_delete on public.profiles for delete
  using (user_id = public.current_app_user_id() or public.can_edit_site());

create policy collisions_select on public.student_id_collisions for select
  using (public.can_approve_membership() or public.can_edit_site());
create policy collisions_insert on public.student_id_collisions for insert
  with check (public.can_approve_membership() or public.can_edit_site());

create policy roles_read on public.roles for select to authenticated using (true);
create policy teams_read on public.teams for select to authenticated using (true);

create policy ra_select on public.role_assignments for select
  using (user_id = public.current_app_user_id() or public.can_edit_site());
create policy ra_write on public.role_assignments for all using (false) with check (false);

create policy ar_read on public.approval_rules for select to authenticated using (true);

create policy rr_select on public.role_requests for select
  using (requester_id = public.current_app_user_id()
    or public.can_edit_site()
    or public.can_approve_role_request(target_role_id, target_team_id));
create policy rr_insert on public.role_requests for insert with check (false);
create policy rr_update on public.role_requests for update using (false) with check (false);

-- Events are member-only: an active (non-pending) membership is required to read
-- even published events. Pending and anonymous users get nothing.
create policy events_select on public.events for select
  using ((is_published = true and public.current_app_user_id() is not null) or public.can_edit_all_events() or public.can_edit_site());
create policy events_insert on public.events for insert
  with check (public.can_edit_all_events());
create policy events_update on public.events for update
  using (public.can_edit_all_events()) with check (public.can_edit_all_events());
create policy events_delete on public.events for delete
  using (public.can_edit_all_events());

create policy qr_select on public.event_qr_tokens for select
  using (public.can_edit_all_events());
create policy qr_write on public.event_qr_tokens for all
  using (public.can_edit_all_events()) with check (public.can_edit_all_events());

create policy gi_none on public.guest_identities for all using (false) with check (false);

create policy ga_select on public.guest_attendances for select
  using (public.can_edit_all_events() or public.can_edit_site());
create policy ga_write on public.guest_attendances for all using (false) with check (false);

create policy att_select on public.attendances for select
  using (user_id = public.current_app_user_id() or public.can_edit_all_events() or public.can_edit_site());
create policy att_insert on public.attendances for insert with check (false);
create policy att_delete on public.attendances for delete using (false);

create policy ms_select on public.membership_status for select
  using (user_id = public.current_app_user_id() or public.can_edit_site());
create policy ms_write on public.membership_status for all using (false) with check (false);

-- Projects are member-only (see events_select).
create policy proj_select on public.projects for select
  using ((is_published = true and public.current_app_user_id() is not null) or public.can_edit_all_projects() or public.can_edit_site());
create policy proj_insert on public.projects for insert
  with check (public.can_edit_all_projects() or public.can_edit_site());
create policy proj_update on public.projects for update
  using (public.can_edit_all_projects() or public.can_edit_project(id) or public.can_edit_site())
  with check (public.can_edit_all_projects() or public.can_edit_project(id) or public.can_edit_site());
create policy proj_delete on public.projects for delete
  using (public.can_edit_all_projects() or public.can_edit_project(id) or public.can_edit_site());

create policy pa_select on public.project_assignments for select
  using (user_id = public.current_app_user_id()
    or public.can_edit_all_projects()
    or public.can_edit_project(project_id)
    or public.can_edit_site());
create policy pa_insert on public.project_assignments for insert
  with check (public.can_edit_all_projects() or public.can_edit_project(project_id) or public.can_edit_site());
create policy pa_update on public.project_assignments for update
  using (public.can_edit_all_projects() or public.can_edit_project(project_id) or public.can_edit_site())
  with check (public.can_edit_all_projects() or public.can_edit_project(project_id) or public.can_edit_site());
create policy pa_delete on public.project_assignments for delete
  using (public.can_edit_all_projects() or public.can_edit_project(project_id) or public.can_edit_site());

create policy ej_select on public.export_jobs for select
  using (requested_by = public.current_app_user_id() or public.can_edit_site());
create policy ej_insert on public.export_jobs for insert with check (false);
create policy ej_update on public.export_jobs for update using (false) with check (false);

create policy audit_select on public.audit_logs for select using (public.can_read_audit_logs());
create policy audit_insert on public.audit_logs for insert with check (false);
-- Audit logs are append-only: no user (even an admin) can update or delete them
-- through the client. Only the service role (Edge Functions) can write rows.
create policy audit_update on public.audit_logs for update using (false) with check (false);
create policy audit_delete on public.audit_logs for delete using (false);

create policy ud_select on public.user_deactivations for select using (public.can_edit_site());
create policy ud_insert on public.user_deactivations for insert with check (false);
create policy ud_update on public.user_deactivations for update using (false) with check (false);
create policy ud_delete on public.user_deactivations for delete using (false);

commit;