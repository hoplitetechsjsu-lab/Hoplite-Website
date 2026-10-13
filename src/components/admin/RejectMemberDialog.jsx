import React, { useState, useEffect } from "react";
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { Loader2 } from "lucide-react";

// Rejection requires a non-empty reason (enforced here and server-side).
export default function RejectMemberDialog({ open, member, loading, onConfirm, onCancel }) {
  const [reason, setReason] = useState("");
  useEffect(() => { if (open) setReason(""); }, [open]);
  const trimmed = reason.trim();

  return (
    <Dialog open={open} onOpenChange={(o) => !o && onCancel()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Reject membership?</DialogTitle>
          <DialogDescription>
            Reject {member?.email}? A reason is required and will be recorded in the audit log.
          </DialogDescription>
        </DialogHeader>
        <div className="space-y-2">
          <Label htmlFor="reason">Reason for rejection</Label>
          <Textarea
            id="reason" rows={3} autoFocus
            placeholder="e.g. Not a current SJSU student"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            disabled={loading}
          />
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={onCancel} disabled={loading}>Cancel</Button>
          <Button variant="destructive" onClick={() => onConfirm(trimmed)} disabled={loading || !trimmed}>
            {loading ? (<><Loader2 className="w-4 h-4 mr-2 animate-spin" />Rejecting...</>) : ("Reject")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}