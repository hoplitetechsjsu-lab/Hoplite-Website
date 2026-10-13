import { json } from '../_shared/cors.ts';
import { callerContext, hashToken } from '../_shared/supabase.ts';

// Authenticated member check-in. The caller must be an approved, active member
// (checked AS the caller via current_app_user_id). The QR token is validated
// against event_qr_tokens; attendance is recorded (membership recalculated).
export default {
  fetch: async (req: Request): Promise<Response> => {
    const { ctx, response } = await callerContext(req);
    if (response) return response;
    if (!ctx) return json({ error: 'Authenticated session required' }, 401);
    try {
      const { token } = await req.json();
      if (!token) return json({ error: 'token required' }, 400);

      // Must be an approved, active member (evaluated as the caller).
      const { data: appUserId } = await ctx.supabase.rpc('current_app_user_id');
      if (!appUserId) return json({ error: 'Account not approved or not active' }, 403);

      const admin = ctx.supabaseAdmin;
      const tokenHash = await hashToken(token);
      const { data: qr } = await admin
        .from('event_qr_tokens')
        .select('event_id, expires_at, is_active')
        .eq('token_hash', tokenHash)
        .maybeSingle();
      if (!qr || !qr.is_active) return json({ error: 'Invalid check-in token' }, 404);
      if (new Date(qr.expires_at) < new Date()) return json({ error: 'Check-in token expired' }, 410);

      // Idempotent: a repeat scan is ON CONFLICT DO NOTHING (postgrest-js has no
      // insert().onConflict(); ignoreDuplicates upsert is the supported equivalent).
      const { error: attErr } = await admin
        .from('attendances')
        .upsert(
          { event_id: qr.event_id, user_id: appUserId, source: 'qr_user' },
          { onConflict: 'event_id,user_id', ignoreDuplicates: true }
        );
      if (attErr) return json({ error: attErr.message }, 400);

      // Membership recalculation also fires via the after-insert trigger, but call
      // explicitly to be safe (the trigger fires on the service-role insert too).
      await admin.rpc('recalculate_membership', { p_user_id: appUserId });

      await admin.rpc('log_audit', {
        p_action: 'check_in',
        p_entity_type: 'event',
        p_entity_id: qr.event_id,
        p_before: null,
        p_after: { user_id: appUserId },
      });

      return json({ status: 'checked_in' }, 200);
    } catch (e) {
      return json({ error: (e as Error).message }, 500);
    }
  },
};