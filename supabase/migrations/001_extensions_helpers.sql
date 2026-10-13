-- 001: extensions, enums, helpers
begin;

create extension if not exists pgcrypto;
create extension if not exists citext;

create type public.semester_term as enum ('spring', 'fall');
create type public.role_request_status as enum ('pending', 'approved', 'rejected', 'withdrawn');
create type public.project_status as enum ('active', 'completed');
create type public.export_type as enum (
  'weekly_digest','event_attendance','all_members','active_members',
  'all_officers','all_profiles','project_roster','project_applicants'
);
create type public.audit_action as enum (
  'create','update','delete','approve','reject','withdraw','assign_role',
  'remove_role','auto_replace_role','check_in','manual_attendance_add',
  'manual_attendance_remove','guest_merge','generate_export',
  'password_reset_request','password_reset_complete','deactivate_user',
  'reactivate_user','delete_media','register_member','approve_member','reject_member'
);

create or replace function public.set_updated_at() returns trigger
language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;

-- Normalized email hash for indexed guest lookups (cheap merge, no full scan).
create or replace function public.hash_email(p_email text) returns text
language sql immutable as $$
  select encode(digest(lower(trim(p_email)), 'sha256'), 'hex');
$$;

-- Spring = Jan–Jul, Fall = Aug–Dec. No summer term modeled.
create or replace function public.semester_key_for(ts timestamptz) returns text
language sql immutable as $$
  select case
    when extract(month from ts) between 1 and 7
      then 'spring-' || extract(year from ts)::int
    else 'fall-' || extract(year from ts)::int
  end;
$$;

create or replace function public.current_semester_key() returns text
language sql stable as $$
  select public.semester_key_for(now());
$$;

commit;