import { json } from '../_shared/cors.ts';
import { callerContext } from '../_shared/supabase.ts';

// Admin approves a pending member. Authorization is checked AS the caller
// (ctx.supabase, RLS-scoped); the write happens with the secret-key admin client
// (ctx.supabaseAdmin). Approval is blocked while an open student-ID collision
// exists. No private student ID is returned in the response.
export default {
  fetch: async (req: Request): Promise<Response> => {
    const { ctx, response } = await callerContext(req);
    if (response) return response;
    if (!ctx) return json({ error: 'Authenticated session required' }, 401);
    try {
      const { user_id } = await req.json();
      if (!user_id) return json({ error: 'user_id required' }, 400);

      // 1. Caller holds the membership_admin role (server-side, as the caller).
      const { data: canApprove } = await ctx.supabase.rpc('can_approve_membership');
      if (!canApprove) return json({ error: 'Not authorized' }, 403);

      // 2. Prevent self-approval.
      const { data: callerAppId } = await ctx.supabase.rpc('current_app_user_id');
      if (user_id === callerAppId) return json({ error: 'Cannot approve your own account' }, 400);

      // 3. Idempotency: only pending members can be approved (privileged read).
      const { data: member } = await ctx.supabaseAdmin
        .from('users')
        .select('id, is_pending, is_rejected')
        .eq('id', user_id)
        .maybeSingle();
      if (!member) return json({ error: 'Member not found' }, 404);
      if (member.is_rejected) return json({ error: 'Member was rejected' }, 409);
      if (!member.is_pending) return json({ error: 'Member is not pending' }, 409);

      // 4. Block on an unresolved collision (looked up by user, not by student_id,
      //    so the ID never enters the response).
      const { data: collision } = await ctx.supabaseAdmin
        .from('student_id_collisions')
        .select('id')
        .eq('new_user_id', user_id)
        .eq('resolution_status', 'open')
        .maybeSingle();
      if (collision) return json({ error: 'Resolve the open student-ID collision first' }, 409);

      await ctx.supabaseAdmin
        .from('users')
        .update({
          is_pending: false,
          approved_by: callerAppId,
          approved_at: new Date().toISOString(),
        })
        .eq('id', user_id);

      // Merge any prior guest attendance into the now-active account.
      await ctx.supabaseAdmin.rpc('merge_guest_attendance_into_user', { p_user_id: user_id });

      // 5. Audit log (no student_id).
      await ctx.supabaseAdmin.rpc('log_audit', {
        p_action: 'approve_member',
        p_entity_type: 'user',
        p_entity_id: user_id,
        p_before: { pending: true },
        p_after: { approved_by: callerAppId },
      });

      return json({ status: 'approved' }, 200);
    } catch (e) {
      return json({ error: (e as Error).message }, 500);
    }
  },
};