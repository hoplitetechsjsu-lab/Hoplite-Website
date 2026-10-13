import { createSupabaseContext } from 'npm:@supabase/server';
import { corsHeaders, json } from './cors.ts';

// Official @supabase/server pattern (createSupabaseContext). The SDK validates the
// caller's JWT (auth: 'user') INDEPENDENTLY of the secret-key admin client:
//   ctx.supabase       — publishable-key client scoped to the caller's JWT, so RLS
//                        applies. Used for authorization RPCs (can_approve_membership,
//                        current_app_user_id) so they evaluate AS the caller.
//   ctx.supabaseAdmin  — secret-key client that bypasses RLS. Carries NO user
//                        identity; used only for privileged writes / queue lookups.
//   ctx.userClaims     — verified caller identity from the JWT (id, email, role).
// The secret key alone is NEVER proof of the requesting user's identity: identity
// comes from the validated JWT, and authorization from RPCs run as the caller.
//
// SUPABASE_URL / SUPABASE_PUBLISHABLE_KEYS / SUPABASE_SECRET_KEYS / SUPABASE_JWKS
// are auto-provisioned by the Supabase platform — no manual env wiring required.

type Ctx = { supabase: any; supabaseAdmin: any; userClaims: any };

// Authenticated-user endpoints. Returns { ctx } on success, or { response } with
// the SDK's 401 when the JWT is missing/invalid (caller shapes nothing).
export async function callerContext(
  req: Request
): Promise<{ ctx: Ctx | null; response: Response | null }> {
  if (req.method === 'OPTIONS') {
    return { ctx: null, response: new Response('ok', { headers: corsHeaders }) };
  }
  const { data: ctx, error } = await createSupabaseContext(req, { auth: 'user' });
  if (error) {
    return { ctx: null, response: json({ error: error.message }, error.status ?? 401) };
  }
  return { ctx: ctx as Ctx, response: null };
}

// Public/guest endpoint (no user JWT) — secured by the QR token instead. Only
// ctx.supabaseAdmin is used; ctx.supabase is NOT meaningful here (no caller).
export async function publicContext(
  req: Request
): Promise<{ ctx: Ctx | null; response: Response | null }> {
  if (req.method === 'OPTIONS') {
    return { ctx: null, response: new Response('ok', { headers: corsHeaders }) };
  }
  const { data: ctx, error } = await createSupabaseContext(req, { auth: 'none' });
  if (error) {
    return { ctx: null, response: json({ error: error.message }, error.status ?? 401) };
  }
  return { ctx: ctx as Ctx, response: null };
}

// SHA-256 hex hash, matching the database's token_hash storage.
export async function hashToken(token: string): Promise<string> {
  const data = new TextEncoder().encode(token);
  const hash = await crypto.subtle.digest('SHA-256', data);
  return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, '0')).join('');
}