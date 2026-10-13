-- 008: public discovery (repairs 004/005)
--
-- INTENTIONAL BEHAVIOR: published events, published projects, and the curated
-- leadership / project org charts are PUBLIC. Anonymous visitors can discover
-- what the club is doing and who leads it without signing in. This replaces the
-- earlier "member-only" gating (`current_app_user_id() is not null`) from 004/005.
--
-- What stays private:
--   * Unpublished events/projects: readable only by event/project editors and
--     site editors (unchanged).
--   * student_id, email, and every other private column: the chart views project
--     ONLY name, photo path, LinkedIn URL, role, team, and assignment dates.
--   * Teams of unpublished projects: project_chart_current only includes
--     assignments on published projects.
--   * Pending and deactivated users are excluded from the current charts (same
--     filters as before).
--
-- Views run with owner privileges (they bypass RLS on the underlying tables) and
-- are marked security_barrier so caller-supplied predicates cannot be pushed down
-- ahead of the view's own filters.
--
-- Published historical events/projects (is_past = true) need no extra handling:
-- the select policies key off is_published only.
begin;

-- ---------------------------------------------------------------------------
-- Policies: published rows are readable by anyone (anon + authenticated).
-- ---------------------------------------------------------------------------
drop policy if exists events_select on public.events;
create policy events_select on public.events for select
  using (is_published = true or public.can_edit_all_events() or public.can_edit_site());

drop policy if exists proj_select on public.projects;
create policy proj_select on public.projects for select
  using (is_published = true or public.can_edit_all_projects() or public.can_edit_site());

-- ---------------------------------------------------------------------------
-- Chart views: drop the current_app_user_id() gate; keep every other filter.
-- Column lists are unchanged so CREATE OR REPLACE is valid.
-- ---------------------------------------------------------------------------
create or replace view public.leadership_chart_current
with (security_barrier = true) as
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
  and u.is_pending = false;

create or replace view public.leadership_chart_history
with (security_barrier = true) as
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
where r.category = 'leadership';

-- Only assignments on PUBLISHED projects are public; unpublished project teams
-- stay private.
create or replace view public.project_chart_current
with (security_barrier = true) as
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
  and pr.is_published = true
  and r.key in ('project_manager','project_member')
  and u.is_deactivated = false
  and u.is_pending = false;

-- ---------------------------------------------------------------------------
-- Grants: read-only for anon + authenticated. Reset first so no default
-- privilege can leave write grants on these owner-bypass views.
-- ---------------------------------------------------------------------------
revoke all on public.leadership_chart_current from anon, authenticated;
revoke all on public.leadership_chart_history from anon, authenticated;
revoke all on public.project_chart_current from anon, authenticated;

grant select on public.leadership_chart_current to anon, authenticated;
grant select on public.leadership_chart_history to anon, authenticated;
grant select on public.project_chart_current to anon, authenticated;

comment on view public.leadership_chart_current is
  'Public (anon-readable) curated leadership chart. Never add student_id/email columns.';
comment on view public.leadership_chart_history is
  'Public (anon-readable) curated leadership history. Never add student_id/email columns.';
comment on view public.project_chart_current is
  'Public (anon-readable) project teams for PUBLISHED projects only. Never add student_id/email columns.';

commit;
