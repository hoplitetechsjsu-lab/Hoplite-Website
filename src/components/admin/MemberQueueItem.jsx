import React from "react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Check, X } from "lucide-react";
import { format } from "date-fns";

// One row in the admin queue. Shows minimal info (email, request date, status,
// verification). Never displays a student ID. Hides actions for the admin's own
// row (no self-approval) and for already-resolved members.
export default function MemberQueueItem({ member, isSelf, onApprove, onReject, disabled }) {
  const status = member.is_rejected ? "rejected" : member.is_pending ? "pending" : "approved";

  return (
    <div className="flex items-center justify-between gap-4 py-3 border-b border-border last:border-0">
      <div className="min-w-0 space-y-1">
        <div className="flex items-center gap-2 flex-wrap">
          <span className="font-medium text-foreground truncate">{member.email}</span>
          {status === "pending" && (
            <Badge variant="secondary" className="bg-amber-100 text-amber-800">Pending</Badge>
          )}
          {status === "rejected" && <Badge variant="destructive">Rejected</Badge>}
          {member.email_verified ? (
            <Badge variant="outline" className="text-emerald-700 border-emerald-300">Verified</Badge>
          ) : (
            <Badge variant="outline" className="text-muted-foreground">Unverified</Badge>
          )}
          {isSelf && <Badge variant="outline">You</Badge>}
        </div>
        <p className="text-xs text-muted-foreground">
          Requested {format(new Date(member.created_at), "MMM d, yyyy")}
        </p>
      </div>
      {status === "pending" && !isSelf && (
        <div className="flex gap-2 shrink-0">
          <Button size="sm" variant="default" onClick={onApprove} disabled={disabled}>
            <Check className="w-4 h-4" /> Approve
          </Button>
          <Button size="sm" variant="destructive" onClick={onReject} disabled={disabled}>
            <X className="w-4 h-4" /> Reject
          </Button>
        </div>
      )}
    </div>
  );
}