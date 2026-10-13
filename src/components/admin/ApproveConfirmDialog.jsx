import React from "react";
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Loader2 } from "lucide-react";

export default function ApproveConfirmDialog({ open, member, loading, onConfirm, onCancel }) {
  return (
    <Dialog open={open} onOpenChange={(o) => !o && onCancel()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Approve membership?</DialogTitle>
          <DialogDescription>
            Approve {member?.email}? They'll gain member access immediately. This action is recorded in the audit log.
          </DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button variant="outline" onClick={onCancel} disabled={loading}>Cancel</Button>
          <Button onClick={onConfirm} disabled={loading}>
            {loading ? (<><Loader2 className="w-4 h-4 mr-2 animate-spin" />Approving...</>) : ("Approve")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}