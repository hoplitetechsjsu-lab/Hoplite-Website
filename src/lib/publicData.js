import { supabase } from '@/lib/supabaseClient';

// Public-surface queries (migration 008). Published events/projects and the
// curated leadership chart are anon-readable. Column lists are explicit and
// MUST NOT include student_id / email — never switch these to select('*').

export const EVENT_COLUMNS =
  'id, title, description, location, starts_at, ends_at, semester, year, is_published';

export const PROJECT_COLUMNS =
  'id, name, description, image_path, status, semester, year, is_published';

export const LEADERSHIP_COLUMNS =
  'assignment_id, first_name, last_name, linkedin_url, role_key, role_name, team_key, team_name, assigned_at';

// `includeDrafts` is only for users who can edit; RLS still enforces visibility
// server-side, this just stops editors' public pages from filtering drafts out.
export async function fetchEvents({ includeDrafts = false } = {}) {
  let q = supabase.from('events').select(EVENT_COLUMNS);
  if (!includeDrafts) q = q.eq('is_published', true);
  const { data, error } = await q.order('starts_at', { ascending: false });
  return { data: data ?? [], error };
}

export async function fetchProjects({ includeDrafts = false } = {}) {
  let q = supabase.from('projects').select(PROJECT_COLUMNS);
  if (!includeDrafts) q = q.eq('is_published', true);
  const { data, error } = await q.order('updated_at', { ascending: false });
  return { data: data ?? [], error };
}

export async function fetchLeadershipChart() {
  const { data, error } = await supabase
    .from('leadership_chart_current')
    .select(LEADERSHIP_COLUMNS);
  return { data: data ?? [], error };
}
