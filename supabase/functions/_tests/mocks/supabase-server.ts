// Stand-in for `npm:@supabase/server` (wired in via _tests/deno.json). It replaces
// createSupabaseContext with a deterministic version driven by the Authorization header:
//
//   (none)               -> 401 "Missing credentials"      (auth: 'user')
//   Bearer invalid | junk-> 401 "Invalid JWT"
//   Bearer expired       -> 401 "JWT expired"
//   Bearer valid:<id>    -> verified user; identity looked up in the installed identities
//
// Tests install a FakeDb + identities with `installContext()` and read `contextCalls`
// to assert which auth mode (`user` vs `none`) each function requested.

// deno-lint-ignore-file no-explicit-any
import { type AuthIdentity, FakeDb, makeClient } from './fake-supabase.ts';

interface Installed {
  db: FakeDb;
  identities: Record<string, AuthIdentity>;
}

let installed: Installed | null = null;
export const contextCalls: { auth: string | undefined; hasAuthHeader: boolean }[] = [];

export function installContext(db: FakeDb, identities: AuthIdentity[] = []) {
  installed = { db, identities: Object.fromEntries(identities.map((i) => [i.id, i])) };
}

export async function createSupabaseContext(
  req: Request,
  options: { auth?: string } = {},
): Promise<{ data: any; error: any }> {
  if (!installed) throw new Error('installContext() was not called');
  const { db, identities } = installed;
  const header = req.headers.get('Authorization');
  contextCalls.push({ auth: options.auth, hasAuthHeader: !!header });

  if (options.auth === 'none') {
    return { data: { supabase: null, supabaseAdmin: makeClient(db, 'admin', null), userClaims: null }, error: null };
  }

  if (!header) return { data: null, error: { message: 'Missing credentials', status: 401 } };
  const token = header.replace(/^Bearer\s+/i, '');
  if (token === 'expired') return { data: null, error: { message: 'JWT expired', status: 401 } };
  if (!token.startsWith('valid:')) return { data: null, error: { message: 'Invalid JWT', status: 401 } };
  const identity = identities[token.slice('valid:'.length)];
  if (!identity) return { data: null, error: { message: 'Invalid JWT', status: 401 } };
  return {
    data: {
      supabase: makeClient(db, 'caller', identity),
      supabaseAdmin: makeClient(db, 'admin', null),
      userClaims: { id: identity.id, email: identity.email, role: 'authenticated' },
    },
    error: null,
  };
}
