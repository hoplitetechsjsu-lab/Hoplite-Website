import { json } from '../_shared/cors.ts';
import { callerContext } from '../_shared/supabase.ts';

// Creates the pending membership record for the AUTHENTICATED caller. The
// auth_user_id is derived from the validated JWT (ctx.supabase.auth.getUser) — it
// is never accepted from the request body — so a user can only create their own
// record, never another's. The only client-supplied field is the student ID
// (private text, length-limited).
export default {
  fetch: async (req: Request): Promise<Response> => {
    const { ctx, response } = await callerContext(req);
    if (response) return response;
    if (!ctx) return json({ error: 'Authenticated session required' }, 401);
    try {
      // Verified caller identity (JWT already validated by @supabase/server).
      const { data: userData, error: authError } = await ctx.supabase.auth.getUser();
      if (authError || !userData?.user) {
        return json({ error: 'Authenticated session required' }, 401);
      }
      const user = userData.user;
      if (!user.email_confirmed_at) return json({ error: 'Email not verified' }, 403);

      const { student_id } = await req.json();
      const sid = typeof student_id === 'string' ? student_id.trim() : '';
      if (!sid || sid.length > 32) return json({ error: 'Invalid student ID' }, 400);

      const admin = ctx.supabaseAdmin;

      // No duplicate membership record for this auth user.
      const { data: existing } = await admin
        .from('users')
        .select('id')
        .eq('auth_user_id', user.id)
        .maybeSingle();
      if (existing) return json({ error: 'Membership record already exists' }, 409);

      // Collision detection (resolved manually by admins).
      const { data: collision } = await admin
        .from('users')
        .select('id')
        .eq('student_id', sid)
        .maybeSingle();

      const { data: inserted, error: insErr } = await admin
        .from('users')
        .insert({
          auth_user_id: user.id,
          student_id: sid,
          email: user.email,
          is_pending: true,
          email_verified: true,
        })
        .select('id')
        .single();
      if (insErr) return json({ error: insErr.message }, 400);

      if (collision) {
        await admin.from('student_id_collisions').insert({
          student_id: sid,
          new_user_id: inserted.id,
          existing_user_id: collision.id,
          resolution_status: 'open',
        });
      }

      // Audit log omits the student_id value (it lives in the users table, admin-only).
      await admin.rpc('log_audit', {
        p_action: 'register_member',
        p_entity_type: 'user',
        p_entity_id: inserted.id,
        p_before: null,
        p_after: { email: user.email, pending: true, collision: !!collision },
      });

      return json({ status: 'pending', collision: !!collision }, 200);
    } catch (e) {
      return json({ error: (e as Error).message }, 500);
    }
  },
};