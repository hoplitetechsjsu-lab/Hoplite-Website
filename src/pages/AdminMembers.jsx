import React, { useState, useEffect, useCallback } from "react";
import { Link } from "react-router-dom";
import { supabase } from "@/lib/supabaseClient";
import { useAppUser } from "@/lib/useAppUser";
import { Button } from "@/components/ui/button";
import { Loader2, ShieldCheck, ArrowLeft } from "lucide-react";
import MemberQueueItem from "@/components/admin/MemberQueueItem";
import ApproveConfirmDialog from "@/components/admin/ApproveConfirmDialog";
import RejectMemberDialog from "@/components/admin/RejectMemberDialog";

// Admin membership-approval queue. Data comes from the get_admin_member_queue
// RPC (no student ID). Approve/reject go through Edge Functions that re-check
// the caller's role server-side, forbid self-approval, prevent duplicate
// resolution, and write audit logs.
export default function AdminMembers() {
  const { appUser, loading: userLoading } = useAppUser();
  const [queue, setQueue] = useState([]);
  const [loading, setLoading] = useState(true);
  const [authorized, setAuthorized] = useState(false);
  const [actionMember, setActionMember] = useState(null);
  const [dialog, setDialog] = useState(null); // 'approve' | 'reject' | null
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const fetchQueue = useCallback(async () => {
    const { data: can } = await supabase.rpc("can_approve_membership");
    setAuthorized(!!can);
    if (!can) { setQueue([]); setLoading(false); return; }
    const { data, error: rpcErr } = await supabase.rpc("get_admin_member_queue");
    if (rpcErr) { setError(rpcErr.message); setQueue([]); }
    else setQueue(data ?? []);
    setLoading(false);
  }, []);

  useEffect(() => { fetchQueue(); }, [fetchQueue]);

  const openApprove = (m) => { setActionMember(m); setDialog("approve"); setError(""); };
  const openReject = (m) => { setActionMember(m); setDialog("reject"); setError(""); };
  const closeDialog = () => { setDialog(null); setActionMember(null); };

  const doApprove = async () => {
    setBusy(true); setError("");
    const { error: invokeErr } = await supabase.functions.invoke("approve-member", {
      body: { user_id: actionMember.user_id },
    });
    setBusy(false);
    if (invokeErr) { setError(invokeErr.message); return; }
    closeDialog();
    await fetchQueue();
  };

  const doReject = async (reason) => {
    setBusy(true); setError("");
    const { error: invokeErr } = await supabase.functions.invoke("reject-member", {
      body: { user_id: actionMember.user_id, reason },
    });
    setBusy(false);
    if (invokeErr) { setError(invokeErr.message); return; }
    closeDialog();
    await fetchQueue();
  };

  if (userLoading || loading) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <Loader2 className="w-8 h-8 animate-spin text-muted-foreground" />
      </div>
    );
  }

  if (!authorized) {
    return (
      <div className="min-h-screen flex flex-col items-center justify-center gap-3 px-4 text-center">
        <ShieldCheck className="w-10 h-10 text-muted-foreground" />
        <h1 className="text-xl font-heading">Not authorized</h1>
        <p className="text-muted-foreground">You don't have permission to manage memberships.</p>
        <Button variant="outline" asChild><Link to="/">Back to home</Link></Button>
      </div>
    );
  }

  const pending = queue.filter((m) => m.is_pending);
  const rejected = queue.filter((m) => m.is_rejected);

  return (
    <div className="min-h-screen max-w-2xl mx-auto px-4 py-10">
      <div className="flex items-center justify-between mb-6">
        <div>
          <h1 className="text-2xl font-heading">Membership approvals</h1>
          <p className="text-sm text-muted-foreground">Review pending membership requests</p>
        </div>
        <Button variant="ghost" size="sm" asChild>
          <Link to="/"><ArrowLeft className="w-4 h-4 mr-1" />Home</Link>
        </Button>
      </div>

      {error && (
        <div className="mb-4 p-3 rounded-lg bg-destructive/10 text-destructive text-sm">{error}</div>
      )}

      <section className="mb-8">
        <h2 className="text-sm font-medium text-muted-foreground mb-2">Pending ({pending.length})</h2>
        {pending.length === 0 ? (
          <p className="text-sm text-muted-foreground py-4">No pending requests.</p>
        ) : (
          <div className="rounded-lg border border-border px-4 bg-card">
            {pending.map((m) => (
              <MemberQueueItem
                key={m.user_id}
                member={m}
                isSelf={m.user_id === appUser?.id}
                disabled={busy}
                onApprove={() => openApprove(m)}
                onReject={() => openReject(m)}
              />
            ))}
          </div>
        )}
      </section>

      {rejected.length > 0 && (
        <section>
          <h2 className="text-sm font-medium text-muted-foreground mb-2">Rejected ({rejected.length})</h2>
          <div className="rounded-lg border border-border px-4 bg-card">
            {rejected.map((m) => (
              <MemberQueueItem key={m.user_id} member={m} isSelf={m.user_id === appUser?.id} disabled={busy} />
            ))}
          </div>
        </section>
      )}

      <ApproveConfirmDialog
        open={dialog === "approve"}
        member={actionMember}
        loading={busy}
        onConfirm={doApprove}
        onCancel={closeDialog}
      />
      <RejectMemberDialog
        open={dialog === "reject"}
        member={actionMember}
        loading={busy}
        onConfirm={doReject}
        onCancel={closeDialog}
      />
    </div>
  );
}