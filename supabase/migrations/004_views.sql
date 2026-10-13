-- 004: chart views (public, curated — never expose student_id or email)
begin;

-- Views run with owner privileges (bypass RLS) so the public can read the curated
-- display columns. Only name, photo, LinkedIn, role, and team are projected.
create or replace view public.leadership_chart_current as
select
  ra.id as assignment_id, u.id as user_id,
  p.first_name, p.last_name, p.photo_path, p.linkedin_url,
  r.key as role_key, r.display_name as role_name,
  t.key as team_key, t.display_name as team_name,
  ra.assigned_at
from public.role_assignments ra
join public.users u on u.id = ra.user_id
left join public.profiles p on p.user_id = u.id
join public.roles r on r.id = ra.role_id
left join public.teams t on t.id = ra.team_id
where ra.is_active = true
  and r.category = 'leadership'
  and u.is_deactivated = false
  and u.is_pending = false
  and public.current_app_user_id() is not null;

create or replace view public.leadership_chart_history as
select
  ra.id as assignment_id, u.id as user_id,
  p.first_name, p.last_name, p.photo_path, p.linkedin_url,
  r.key as role_key, r.display_name as role_name,
  t.key as team_key, t.display_name as team_name,
  ra.assigned_at, ra.ended_at, ra.is_active
from public.role_assignments ra
join public.users u on u.id = ra.user_id
left join public.profiles p on p.user_id = u.id
join public.roles r on r.id = ra.role_id
left join public.teams t on t.id = ra.team_id
where r.category = 'leadership'
  and public.current_app_user_id() is not null;

create or replace view public.project_chart_current as
select
  pa.id as assignment_id, pr.id as project_id, pr.name as project_name,
  u.id as user_id, p.first_name, p.last_name, p.photo_path, p.linkedin_url,
  r.key as role_key, r.display_name as role_name, pa.assigned_at
from public.project_assignments pa
join public.projects pr on pr.id = pa.project_id
join public.users u on u.id = pa.user_id
left join public.profiles p on p.user_id = u.id
join public.roles r on r.id = pa.role_id
where pa.is_active = true
  and r.key in ('project_manager','project_member')
  and u.is_deactivated = false
  and u.is_pending = false
  and public.current_app_user_id() is not null;

commit;