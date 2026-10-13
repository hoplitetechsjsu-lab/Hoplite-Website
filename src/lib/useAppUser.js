import { useState, useEffect } from 'react';
import { supabase } from '@/lib/supabaseClient';
import { useAuth } from '@/lib/authAdapter';

// Fetches the current user's app record (public.users). Returns null when no
// membership record exists yet (e.g. just verified email, before completing profile).
// RLS allows a user to read their own row by auth_user_id.
export function useAppUser() {
  const { user } = useAuth();
  const [appUser, setAppUser] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!user) {
      setAppUser(null);
      setLoading(false);
      return;
    }
    let active = true;
    setLoading(true);
    supabase
      .from('users')
      .select('id, is_pending, is_rejected, email_verified, is_deactivated')
      .eq('auth_user_id', user.id)
      .maybeSingle()
      .then(({ data }) => {
        if (active) {
          setAppUser(data);
          setLoading(false);
        }
      });
    return () => {
      active = false;
    };
  }, [user]);

  return { appUser, loading };
}