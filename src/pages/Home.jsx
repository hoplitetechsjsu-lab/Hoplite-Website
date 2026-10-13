import React, { useState, useEffect } from 'react';
import { Link } from 'react-router-dom';
import { useAuth } from '@/lib/authAdapter';
import { useAppUser } from '@/lib/useAppUser';
import { supabase } from '@/lib/supabaseClient';
import { Button } from '@/components/ui/button';
import PublicLayout from '@/components/PublicLayout';
import LeadershipSection from '@/components/leadership/LeadershipSection';
import { ShieldCheck, CalendarDays, FolderKanban, Info } from 'lucide-react';

// Signed-in status area. Renders nothing for anonymous visitors, so the public
// page is the same for everyone apart from this block.
function MemberPanel() {
  const { user, isAuthenticated } = useAuth();
  const { appUser, loading } = useAppUser();
  const [isAdmin, setIsAdmin] = useState(false);

  useEffect(() => {
    if (!appUser || appUser.is_pending || appUser.is_rejected) { setIsAdmin(false); return; }
    supabase.rpc('can_approve_membership').then(({ data }) => setIsAdmin(!!data));
  }, [appUser]);

  if (!isAuthenticated || loading) return null;

  // Authenticated but no membership record yet → finish registration.
  if (!appUser) {
    return (
      <div role="status" className="rounded-xl border border-border bg-card p-5 mb-8">
        <h2 className="text-lg font-heading">Finish joining the club</h2>
        <p className="text-sm text-muted-foreground mt-1">Submit your student ID to request membership.</p>
        <Button asChild className="mt-3"><Link to="/complete-profile">Complete your membership</Link></Button>
      </div>
    );
  }

  if (appUser.is_pending) {
    return (
      <div role="status" className="rounded-xl border border-border bg-card p-5 mb-8">
        <h2 className="text-lg font-heading">Pending membership approval</h2>
        <p className="text-sm text-muted-foreground mt-1">
          Your account is awaiting approval from a club administrator. Member features unlock once approved.
        </p>
      </div>
    );
  }

  if (appUser.is_rejected) {
    return (
      <div role="status" className="rounded-xl border border-border bg-card p-5 mb-8">
        <h2 className="text-lg font-heading">Membership not approved</h2>
        <p className="text-sm text-muted-foreground mt-1">
          Your membership request was not approved. Contact a club administrator if you believe this is an error.
        </p>
      </div>
    );
  }

  return (
    <div className="rounded-xl border border-border bg-card p-5 mb-8" data-testid="member-dashboard">
      <p className="text-sm text-muted-foreground">Signed in as {user?.email}</p>
      <div className="flex flex-wrap gap-3 mt-3">
        <Button asChild variant="secondary"><Link to="/events"><CalendarDays className="w-4 h-4 mr-2" />Events</Link></Button>
        <Button asChild variant="secondary"><Link to="/projects"><FolderKanban className="w-4 h-4 mr-2" />Projects</Link></Button>
        {isAdmin && (
          <Button asChild variant="secondary"><Link to="/admin/members"><ShieldCheck className="w-4 h-4 mr-2" />Membership approvals</Link></Button>
        )}
      </div>
    </div>
  );
}

export default function Home() {
  return (
    <PublicLayout>
      <section className="py-8 text-center">
        <h1 className="text-4xl font-heading mb-3">SJSU Club Platform</h1>
        <p className="text-muted-foreground max-w-xl mx-auto">
          Projects, events, and a community of builders at San José State.
        </p>
        <div className="flex flex-wrap items-center justify-center gap-3 mt-5">
          <Button asChild><Link to="/events"><CalendarDays className="w-4 h-4 mr-2" />Upcoming events</Link></Button>
          <Button asChild variant="outline"><Link to="/projects"><FolderKanban className="w-4 h-4 mr-2" />Our projects</Link></Button>
          <Button asChild variant="ghost"><Link to="/about"><Info className="w-4 h-4 mr-2" />About</Link></Button>
        </div>
      </section>
      <MemberPanel />
      <LeadershipSection />
    </PublicLayout>
  );
}
