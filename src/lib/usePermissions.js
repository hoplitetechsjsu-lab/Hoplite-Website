import { useState, useEffect } from 'react';
import { supabase } from '@/lib/supabaseClient';
import { useAppUser } from '@/lib/useAppUser';

// Checks the caller's server-side authorization RPCs (each is security-definer and
// evaluates AS the caller, so this reflects RLS exactly). Pending/rejected users
// get all-false. Used to show/hide create/edit/delete controls on Events & Projects.
export function usePermissions() {
  const { appUser, loading } = useAppUser();
  const [perms, setPerms] = useState({ events: false, projects: false, site: false, loaded: false });

  useEffect(() => {
    if (loading) return;
    if (!appUser || appUser.is_pending || appUser.is_rejected) {
      setPerms({ events: false, projects: false, site: false, loaded: true });
      return;
    }
    let active = true;
    Promise.all([
      supabase.rpc('can_edit_all_events'),
      supabase.rpc('can_edit_all_projects'),
      supabase.rpc('can_edit_site'),
    ]).then(([{ data: e }, { data: p }, { data: s }]) => {
      if (active) setPerms({ events: !!e, projects: !!p, site: !!s, loaded: true });
    });
    return () => { active = false; };
  }, [appUser, loading]);

  return perms;
}