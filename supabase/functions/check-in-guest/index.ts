import { json } from '../_shared/cors.ts';
import { publicContext, hashToken } from '../_shared/supabase.ts';

// Guest check-in by email. PUBLIC endpoint (no user JWT) — security comes from
// the QR token, which is validated against event_qr_tokens (active + unexpired).
// Records guest attendance and opportunistically merges into an existing
// verified, non-pending user account when the email matches (so guest attendance
// counts toward membership once the account exists).
export default {
  fetch: async (req: Request): Promise<Response> => {
    const { ctx, response } = await publicContext(req);
    if (response) return response;
    if (!ctx) return json({ error: 'Invalid request' }, 400);
    try {
      const { token, email } = await req.json();
      if (!token || !email) return json({ error: 'token and email required' }, 400);

      const admin = ctx.supabaseAdmin;
      const tokenHash = await hashToken(token);
      const { data: qr } = await admin
        .from('event_qr_tokens')
        .select('event_id, expires_at, is_active')
        .eq('token_hash', tokenHash)
        .maybeSingle();
      if (!qr || !qr.is_active) return json({ error: 'Invalid check-in token' }, 404);
      if (new Date(qr.expires_at) < new Date()) return json({ error: 'Check-in token expired' }, 410);

      const normalizedEmail = String(email).toLowerCase().trim();

      // Upsert guest identity.
      const { data: guest } = await admin
        .from('guest_identities')
        .upsert(
          { normalized_email: normalizedEmail, normalized_email_hash: await hashToken(normalizedEmail) },
          { onConflict: 'normalized_email' }
        )
        .select('id')
        .single();

      // Record guest attendance (unique per event/guest).
      // Idempotent: ON CONFLICT DO NOTHING via ignoreDuplicates (postgrest-js has no
      // insert().onConflict()).
      const { error: gaErr } = await admin
        .from('guest_attendances')
        .upsert(
          { event_id: qr.event_id, guest_identity_id: guest.id, source: 'qr_guest' },
          { onConflict: 'event_id,guest_identity_id', ignoreDuplicates: true }
        );
      if (gaErr) return json({ error: gaErr.message }, 400);

      // Opportunistic merge: if a verified, non-pending, non-rejected user has this
      // email, fold the guest attendance into their account.
      const { data: match } = await admin
        .from('users')
        .select('id')
        .eq('email', normalizedEmail)
        .eq('is_pending', false)
        .eq('is_deactivated', false)
        .eq('is_rejected', false)
        .maybeSingle();

      let merged = false;
      if (match) {
        await admin.rpc('merge_guest_attendance_into_user', { p_user_id: match.id });
        merged = true;
      }

      await admin.rpc('log_audit', {
        p_action: 'check_in',
        p_entity_type: 'event',
        p_entity_id: qr.event_id,
        p_before: null,
        p_after: { guest: normalizedEmail, merged },
      });

      return json({ status: 'checked_in', merged }, 200);
    } catch (e) {
      return json({ error: (e as Error).message }, 500);
    }
  },
};