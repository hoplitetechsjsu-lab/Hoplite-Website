-- 002: tables
begin;

-- App users. student_id is NOT unique (collisions are stored & resolved manually).
-- student_id is private: never selected by chart views, never publicly readable.
create table public.users (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique,
  student_id text check (student_id is null or char_length(student_id) between 1 and 32),
  email citext not null unique,
  is_pending boolean not null default true,
  email_verified boolean not null default false,
  approved_by uuid references public.users(id) on delete set null,
  approved_at timestamptz,
  is_deactivated boolean not null default false,
  is_rejected boolean not null default false,
  expected_graduation_date date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger trg_users_updated_at before update on public.users
  for each row execute function public.set_updated_at();

create table public.profiles (
  user_id uuid primary key references public.users(id) on delete cascade,
  first_name text, last_name text, photo_path text, linkedin_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger trg_profiles_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();

create table public.student_id_collisions (
  id uuid primary key default gen_random_uuid(),
  student_id text not null,
  new_user_id uuid references public.users(id) on delete cascade,
  existing_user_id uuid references public.users(id) on delete set null,
  resolution_status text not null default 'open',
  notes text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
create index idx_collisions_status on public.student_id_collisions(resolution_status, created_at desc);

create table public.roles (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,
  display_name text not null,
  category text not null,
  is_high_level_unique boolean not null default false,
  is_project_role boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.teams (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,
  display_name text not null,
  team_type text not null,
  parent_team_id uuid references public.teams(id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.role_assignments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  role_id uuid not null references public.roles(id) on delete restrict,
  team_id uuid references public.teams(id) on delete set null,
  is_active boolean not null default true,
  assigned_at timestamptz not null default now(),
  ended_at timestamptz,
  assigned_by uuid references public.users(id) on delete set null,
  notes text
);
create index idx_ra_active_user on public.role_assignments(user_id, is_active);
create index idx_ra_active_role on public.role_assignments(role_id, is_active);
create index idx_ra_active_team on public.role_assignments(team_id, is_active);

create table public.approval_rules (
  id uuid primary key default gen_random_uuid(),
  approver_role_id uuid not null references public.roles(id) on delete cascade,
  target_role_id uuid not null references public.roles(id) on delete cascade,
  team_scope_id uuid references public.teams(id) on delete cascade,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (approver_role_id, target_role_id, team_scope_id)
);

create table public.role_requests (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.users(id) on delete cascade,
  target_role_id uuid not null references public.roles(id) on delete restrict,
  target_team_id uuid references public.teams(id) on delete set null,
  justification text,
  status public.role_request_status not null default 'pending',
  decided_by uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  withdrawn_at timestamptz
);
create index idx_rr_requester on public.role_requests(requester_id, created_at desc);
create index idx_rr_status on public.role_requests(status, created_at desc);

create table public.events (
  id uuid primary key default gen_random_uuid(),
  title text not null, description text, location text,
  starts_at timestamptz not null, ends_at timestamptz not null,
  semester public.semester_term not null, year int not null check (year >= 2024),
  is_published boolean not null default false, is_past boolean not null default false,
  created_by uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  constraint events_ends_after_starts check (ends_at >= starts_at)
);
create trigger trg_events_updated_at before update on public.events
  for each row execute function public.set_updated_at();

create table public.event_qr_tokens (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
create index idx_qr_event on public.event_qr_tokens(event_id, is_active);

create table public.guest_identities (
  id uuid primary key default gen_random_uuid(),
  normalized_email citext not null unique,
  normalized_email_hash text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger trg_guest_updated_at before update on public.guest_identities
  for each row execute function public.set_updated_at();

create table public.attendances (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  checked_in_at timestamptz not null default now(),
  source text not null default 'qr_user',
  counts_for_membership boolean not null default true,
  created_by uuid references public.users(id) on delete set null,
  unique (event_id, user_id)
);
create index idx_att_user_time on public.attendances(user_id, checked_in_at desc);

create table public.guest_attendances (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  guest_identity_id uuid not null references public.guest_identities(id) on delete cascade,
  checked_in_at timestamptz not null default now(),
  source text not null default 'qr_guest',
  merged boolean not null default false,
  merged_into_user_id uuid references public.users(id) on delete set null,
  merged_at timestamptz,
  unique (event_id, guest_identity_id)
);
create index idx_ga_guest on public.guest_attendances(guest_identity_id, merged, checked_in_at desc);

create table public.membership_status (
  user_id uuid primary key references public.users(id) on delete cascade,
  is_active boolean not null default false,
  qualifying_attendance_count int not null default 0,
  window_start timestamptz not null default (now() - interval '30 days'),
  window_end timestamptz not null default now(),
  calculated_at timestamptz not null default now()
);

create table public.projects (
  id uuid primary key default gen_random_uuid(),
  name text not null, description text, image_path text,
  status public.project_status not null default 'active',
  semester public.semester_term not null, year int not null check (year >= 2024),
  is_published boolean not null default false, is_past boolean not null default false,
  created_by uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create trigger trg_projects_updated_at before update on public.projects
  for each row execute function public.set_updated_at();

create table public.project_assignments (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  role_id uuid not null references public.roles(id) on delete restrict,
  is_active boolean not null default true,
  assigned_at timestamptz not null default now(),
  ended_at timestamptz,
  assigned_by uuid references public.users(id) on delete set null
);
create index idx_pa_active_project on public.project_assignments(project_id, is_active);
create unique index idx_pa_active_unique on public.project_assignments(project_id, user_id, role_id) where is_active = true;

create table public.export_jobs (
  id uuid primary key default gen_random_uuid(),
  requested_by uuid not null references public.users(id) on delete cascade,
  export_type public.export_type not null,
  filters jsonb not null default '{}'::jsonb,
  file_path text, generated_at timestamptz, expires_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid references public.users(id) on delete set null,
  action_type public.audit_action not null,
  entity_type text not null, entity_id uuid,
  before_state jsonb, after_state jsonb,
  created_at timestamptz not null default now()
);
create index idx_audit_actor on public.audit_logs(actor_user_id, created_at desc);
create index idx_audit_entity on public.audit_logs(entity_type, entity_id, created_at desc);

create table public.user_deactivations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  deactivated_at timestamptz not null default now(),
  reason text not null,
  deactivated_by uuid references public.users(id) on delete set null,
  reactivated_at timestamptz,
  reactivated_by uuid references public.users(id) on delete set null
);

-- Sync email_verified from auth.users -> public.users when the email is confirmed.
create or replace function public.sync_email_verified() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.email_confirmed_at is not null and (tg_op = 'INSERT' or old.email_confirmed_at is null) then
    update public.users set email_verified = true where auth_user_id = new.id;
  end if;
  return new;
end;
$$;
create trigger trg_sync_email_verified
  after insert or update of email_confirmed_at on auth.users
  for each row execute function public.sync_email_verified();

commit;