// Shared fixtures for the Deno unit tests (mocked createSupabaseContext, in-memory DB).
// deno-lint-ignore-file no-explicit-any
import { type AuthIdentity, FakeDb, newId, type Row } from './mocks/fake-supabase.ts';
import { installContext } from './mocks/supabase-server.ts';

export { FakeDb };
export type Handler = { fetch: (req: Request) => Promise<Response> };

export const URL_BASE = 'http://localhost/functions/v1/fn';

export function req(
  body: unknown,
  { token, method = 'POST', raw, headers = {} }: {
    token?: string | null;
    method?: string;
    raw?: string;
    headers?: Record<string, string>;
  } = {},
): Request {
  const h: Record<string, string> = { 'Content-Type': 'application/json', ...headers };
  if (token) h.Authorization = `Bearer ${token}`;
  return new Request(URL_BASE, {
    method,
    headers: h,
    body: method === 'GET' || method === 'OPTIONS' ? undefined : (raw ?? JSON.stringify(body)),
  });
}

export async function readJson(res: Response): Promise<any> {
  const text = await res.text();
  try { return JSON.parse(text); } catch { return text; }
}

export function assertCors(res: Response) {
  if (res.headers.get('Access-Control-Allow-Origin') !== '*') throw new Error('missing CORS allow-origin');
  if (!res.headers.get('Access-Control-Allow-Headers')?.includes('authorization')) {
    throw new Error('missing CORS allow-headers');
  }
}

export interface World {
  db: FakeDb;
  identities: AuthIdentity[];
  /** Create an auth identity (JWT subject). token => `valid:<authId>` */
  authUser(label: string, opts?: { verified?: boolean }): { authId: string; email: string; token: string };
  /** auth identity + public.users row. */
  member(label: string, opts?: Partial<Row> & { admin?: boolean }): {
    authId: string; email: string; token: string; userId: string;
  };
  event(): string;
  qr(eventId: string, opts?: { expiresInMs?: number; active?: boolean }): Promise<string>;
}

export async function sha256(s: string): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export function makeWorld(): World {
  const db = new FakeDb();
  const identities: AuthIdentity[] = [];
  const w: World = {
    db,
    identities,
    authUser(label, { verified = true } = {}) {
      const authId = newId(`auth-${label}`);
      const email = `${label}@example.test`;
      identities.push({ id: authId, email, email_confirmed_at: verified ? '2026-01-01T00:00:00Z' : null });
      installContext(db, identities);
      return { authId, email, token: `valid:${authId}` };
    },
    member(label, { admin = false, ...overrides } = {}) {
      const a = w.authUser(label);
      const row = db.insertRow('users', {
        auth_user_id: a.authId,
        email: a.email,
        student_id: `SID-${label}`,
        is_pending: false,
        is_deactivated: false,
        is_rejected: false,
        email_verified: true,
        ...overrides,
      });
      if (admin) {
        db.insertRow('role_assignments', { user_id: row.id, role_id: 'role-membership-admin', is_active: true });
      }
      db.writes.length = 0;
      return { ...a, userId: row.id };
    },
    event: () => newId('event'),
    async qr(eventId, { expiresInMs = 3600_000, active = true } = {}) {
      const token = `qr-${newId('tok')}`;
      db.insertRow('event_qr_tokens', {
        event_id: eventId,
        token_hash: await sha256(token),
        expires_at: new Date(Date.now() + expiresInMs).toISOString(),
        is_active: active,
      });
      db.writes.length = 0;
      return token;
    },
  };
  installContext(db, identities);
  return w;
}
