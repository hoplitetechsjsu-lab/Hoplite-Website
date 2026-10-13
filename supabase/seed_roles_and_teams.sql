-- Seed roles, teams, and table-driven approval rules.
begin;

insert into public.roles (key, display_name, category, is_high_level_unique, is_project_role) values
  ('president', 'President', 'leadership', true, false),
  ('vp', 'Vice President', 'leadership', true, false),
  ('website_coordinator', 'Website Coordinator', 'leadership', true, false),
  ('website_lead', 'Website Lead', 'leadership', false, false),
  ('events_coordinator', 'Events Coordinator', 'leadership', true, false),
  ('events_lead', 'Events Lead', 'leadership', false, false),
  ('outreach_coordinator', 'Outreach Coordinator', 'leadership', true, false),
  ('outreach_lead', 'Outreach Lead', 'leadership', false, false),
  ('finance_coordinator', 'Finance Coordinator', 'leadership', true, false),
  ('finance_lead', 'Finance Lead', 'leadership', false, false),
  ('technical_sourcing_coordinator', 'Technical Sourcing Coordinator', 'leadership', true, false),
  ('technical_sourcing_lead', 'Technical Sourcing Lead', 'leadership', false, false),
  ('membership_admin', 'Membership Admin', 'operations', false, false),
  ('project_manager', 'Project Manager', 'project', false, true),
  ('project_member', 'Project Member', 'project', false, true)
on conflict (key) do nothing;

insert into public.teams (key, display_name, team_type) values
  ('executive', 'Executive', 'leadership'),
  ('website', 'Website', 'leadership'),
  ('events', 'Events', 'leadership'),
  ('outreach', 'Outreach', 'leadership'),
  ('finance', 'Finance', 'leadership'),
  ('technical_sourcing', 'Technical Sourcing', 'leadership')
on conflict (key) do nothing;

-- President and Website Coordinator can approve any role.
insert into public.approval_rules (approver_role_id, target_role_id, team_scope_id)
select ar.id, tr.id, null
from public.roles ar cross join public.roles tr
where ar.key in ('president','website_coordinator')
  and tr.key <> ''
on conflict do nothing;

-- VP can approve every role except President.
insert into public.approval_rules (approver_role_id, target_role_id, team_scope_id)
select ar.id, tr.id, null
from public.roles ar cross join public.roles tr
where ar.key = 'vp' and tr.key <> 'president'
on conflict do nothing;

-- Coordinators approve their own branch's Lead (team-scoped).
insert into public.approval_rules (approver_role_id, target_role_id, team_scope_id)
select ar.id, tr.id, t.id
from public.roles ar
join public.roles tr on (
  (ar.key = 'events_coordinator' and tr.key = 'events_lead') or
  (ar.key = 'outreach_coordinator' and tr.key = 'outreach_lead') or
  (ar.key = 'finance_coordinator' and tr.key = 'finance_lead') or
  (ar.key = 'technical_sourcing_coordinator' and tr.key = 'technical_sourcing_lead')
)
join public.teams t on (
  (t.key = 'events' and ar.key = 'events_coordinator') or
  (t.key = 'outreach' and ar.key = 'outreach_coordinator') or
  (t.key = 'finance' and ar.key = 'finance_coordinator') or
  (t.key = 'technical_sourcing' and ar.key = 'technical_sourcing_coordinator')
)
on conflict do nothing;

-- Technical Sourcing branch approves project roles.
insert into public.approval_rules (approver_role_id, target_role_id, team_scope_id)
select ar.id, tr.id, null
from public.roles ar cross join public.roles tr
where ar.key in ('technical_sourcing_coordinator','technical_sourcing_lead')
  and tr.key in ('project_manager','project_member')
on conflict do nothing;

commit;