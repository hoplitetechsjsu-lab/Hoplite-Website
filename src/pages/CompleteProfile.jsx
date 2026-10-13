import React, { useState } from "react";
import { Navigate, useNavigate } from "react-router-dom";
import { supabase } from "@/lib/supabaseClient";
import { useAppUser } from "@/lib/useAppUser";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Hash, Loader2 } from "lucide-react";
import AuthLayout from "@/components/AuthLayout";

// Step 2 of registration: an authenticated (email-verified) user submits their
// student ID. The register-member Edge Function derives the caller's identity
// from their JWT — the student ID is the only field sent from the client.
const MAX_LEN = 32;

export default function CompleteProfile() {
  const navigate = useNavigate();
  const { appUser, loading } = useAppUser();
  const [studentId, setStudentId] = useState("");
  const [error, setError] = useState("");
  const [submitting, setSubmitting] = useState(false);

  if (loading) {
    return (
      <AuthLayout icon={Hash} title="Loading..." subtitle="">
        <div className="flex justify-center">
          <Loader2 className="w-6 h-6 animate-spin text-muted-foreground" />
        </div>
      </AuthLayout>
    );
  }

  // Already has a membership record — nothing to complete.
  if (appUser) return <Navigate to="/" replace />;

  const handleSubmit = async (e) => {
    e.preventDefault();
    setError("");
    const trimmed = studentId.trim();
    if (!trimmed || trimmed.length > MAX_LEN) {
      setError(`Student ID is required (max ${MAX_LEN} characters)`);
      return;
    }
    setSubmitting(true);
    try {
      const { error: invokeError } = await supabase.functions.invoke("register-member", {
        body: { student_id: trimmed },
      });
      if (invokeError) throw invokeError;
      navigate("/");
    } catch (err) {
      setError(err.message || "Failed to submit");
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <AuthLayout
      icon={Hash}
      title="Complete your membership"
      subtitle="Enter your student ID to request membership"
    >
      {error && (
        <div className="mb-4 p-3 rounded-lg bg-destructive/10 text-destructive text-sm">
          {error}
        </div>
      )}
      <form onSubmit={handleSubmit} className="space-y-4">
        <div className="space-y-2">
          <Label htmlFor="studentId">Student ID</Label>
          <Input
            id="studentId"
            type="text"
            maxLength={MAX_LEN}
            autoFocus
            placeholder="Student ID"
            value={studentId}
            onChange={(e) => setStudentId(e.target.value)}
            className="h-12"
            required
          />
          <p className="text-xs text-muted-foreground">
            Stored privately and never displayed publicly. This does not verify enrollment; an administrator must approve your membership.
          </p>
        </div>
        <Button type="submit" className="w-full h-12 font-medium" disabled={submitting}>
          {submitting ? (
            <>
              <Loader2 className="w-4 h-4 mr-2 animate-spin" />
              Submitting...
            </>
          ) : (
            "Request membership"
          )}
        </Button>
      </form>
    </AuthLayout>
  );
}