import { json } from '../_shared/cors.ts';
import { callerContext } from '../_shared/supabase.ts';

// Admin rejects a pending membership. Same authorization rules as approve-member.
// A trimmed rejection reason is REQUIRED. Rejection sets is_pending = false and
// is_rejected = true, so the account cannot act (current_app_user_id() returns
// null) and cannot be approved later.
export default {
  fetch: async (req: Request): Promise<Response> => {
    const { ctx, response } = await callerContext(req);
    if (response) return response;
    if (!ctx) return json({ error: 'Authenticated session required' }, 401);
    try {
      const { user_id, reason } = await req.json();
      if (!user_id) return json({ error: 'user_id required' }, 400);
      const reasonText = typeof reason === 'string' ? reason.trim() : '';
      if (!reasonText) return json({ error: 'A rejection reason is required' }, 400);

      // Authorization checked AS the caller (RLS-scoped), not via the secret key.
      const { data: canApprove } = await ctx.supabase.rpc('can_approve_membership');
      if (!canApprove) return json({ error: 'Not authorized' }, 403);

      const { data: callerAppId } = await ctx.supabase.rpc('current_app_user_id');
      if (user_id === callerAppId) return json({ error: 'Cannot reject your own account' }, 400);

      const { data: member } = await ctx.supabaseAdmin
        .from('users')
        .select('id, is_pending, is_rejected')
        .eq('id', user_id)
        .maybeSingle();
      if (!member) return json({ error: 'Member not found' }, 404);
      if (member.is_rejected) return json({ error: 'Member already rejected' }, 409);
      if (!member.is_pending) return json({ error: 'Member already approved' }, 409);

      await ctx.supabaseAdmin
        .from('users')
        .update({ is_pending: false, is_rejected: true })
        .eq('id', user_id);

      await ctx.supabaseAdmin.rpc('log_audit', {
        p_action: 'reject_member',
        p_entity_type: 'user',
        p_entity_id: user_id,
        p_before: { pending: true },
        p_after: { rejected_by: callerAppId, reason: reasonText },
      });

      return json({ status: 'rejected' }, 200);
    } catch (e) {
      return json({ error: (e as Error).message }, 500);
    }
  },
};