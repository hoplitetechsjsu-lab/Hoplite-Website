// Phase 2.16 — HTTP integration tests for the Edge Functions, run against the LOCAL
// stack through the real gateway (Kong) + Edge Runtime.
//
// Prerequisites (see supabase/README.md "Edge Function tests"):
//   1. Docker running, `supabase start`, `npm run db:reset` (roles seed required)
//   2. `supabase functions serve` running in another terminal, using a Supabase CLI
//      new enough to inject SUPABASE_PUBLISHABLE_KEYS / SUPABASE_SECRET_KEYS into the
//      Edge Runtime (verified with CLI 2.120; 2.78 does NOT inject them, so every
//      `createSupabaseContext` call returns "No default publishable key found").
//
// Run: npm run test:functions:http
//
// Nothing is mocked: users are created through the Auth Admin API (service role),
// sign in with email+password, and call the functions with their real access token.
// Test data uses a unique per-run tag and is removed in the `after` hook.

import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';

// ---------------------------------------------------------------------------
// Config: env first, else `supabase status -o env` (local stack).
// ---------------------------------------------------------------------------
function loadStatusEnv() {
  try {
    const out = execFileSync('supabase', ['status', '-o', 'env'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    const env = {};
    for (const line of out.split('\n')) {
      const m = line.match(/^([A-Z0-9_]+)="?(.*?)"?$/);
      if (m) env[m[1]] = m[2];
    }
    return env;
  } catch {
    return {};
  }
}
const status = process.env.API_URL && process.env.SERVICE_ROLE_KEY ? {} : loadStatusEnv();
const API_URL = process.env.API_URL ?? status.API_URL ?? 'http://127.0.0.1:54321';
const PUBLISHABLE_KEY =
  process.env.PUBLISHABLE_KEY ?? process.env.ANON_KEY ?? status.PUBLISHABLE_KEY ?? status.ANON_KEY;
// Legacy service_role JWT works against PostgREST and GoTrue admin on every CLI version.
const SERVICE_KEY = process.env.SERVICE_ROLE_KEY ?? status.SERVICE_ROLE_KEY ?? status.SECRET_KEY;
const DB_CONTAINER = process.env.DB_CONTAINER ?? 'supabase_db_Hoplite-Website';
const FN = `${API_URL}/functions/v1`;
const ORIGIN = 'http://localhost:5173';
const FUNCTIONS = [
  'register-member',
  'approve-member',
  'reject-member',
  'check-in-user',
  'check-in-guest',
];

if (!PUBLISHABLE_KEY || !SERVICE_KEY) {
  console.error('Missing keys. Start the stack (`supabase start`) or set API_URL / PUBLISHABLE_KEY / SERVICE_ROLE_KEY.');
  process.exit(1);
}

const TAG = randomUUID().slice(0, 8);
const PASSWORD = 'Test-Passw0rd!-' + TAG;
const sha256 = (s) => createHash('sha256').update(s).digest('hex');

// ---------------------------------------------------------------------------
// Low-level helpers
// ---------------------------------------------------------------------------
const serviceHeaders = {
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
  'Content-Type': 'application/json',
};

async function rest(method, path, body, prefer = 'return=representation') {
  const res = await fetch(`${API_URL}/rest/v1/${path}`, {
    method,
    headers: { ...serviceHeaders, Prefer: prefer },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  const data = text ? JSON.parse(text) : null;
  if (!res.ok) throw new Error(`REST ${method} ${path} -> ${res.status}: ${text}`);
  return data;
}

async function adminCreateAuthUser(email) {
  const res = await fetch(`${API_URL}/auth/v1/admin/users`, {
    method: 'POST',
    headers: serviceHeaders,
    body: JSON.stringify({ email, password: PASSWORD, email_confirm: true }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(`create auth user failed: ${JSON.stringify(body)}`);
  return body.id;
}

async function signIn(email) {
  const res = await fetch(`${API_URL}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: PUBLISHABLE_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password: PASSWORD }),
  });
  const body = await res.json();
  if (!res.ok) throw new Error(`sign-in failed: ${JSON.stringify(body)}`);
  return body.access_token;
}

// GoTrue's admin API cannot un-confirm an email, and unconfirmed users cannot sign in,
// so: create confirmed -> sign in -> clear email_confirmed_at in SQL. The already-issued
// JWT stays valid while auth.getUser() now reports the email as unverified.
function unconfirmEmail(authUserId) {
  execFileSync(
    'docker',
    ['exec', DB_CONTAINER, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-c',
      `update auth.users set email_confirmed_at = null where id = '${authUserId}'`],
    { stdio: ['ignore', 'ignore', 'pipe'] }
  );
}

async function callFn(name, { token, body, method = 'POST', headers = {}, rawBody } = {}) {
  const h = { apikey: PUBLISHABLE_KEY, 'Content-Type': 'application/json', ...headers };
  if (token) h.Authorization = `Bearer ${token}`;
  const res = await fetch(`${FN}/${name}`, {
    method,
    headers: h,
    body: method === 'GET' ? undefined : (rawBody ?? (body === undefined ? undefined : JSON.stringify(body))),
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* non-JSON */ }
  return { status: res.status, headers: res.headers, text, json };
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------
const created = { authUsers: [], userIds: [], eventIds: [], guestEmails: [] };

/** Auth user (+ session). `member` => approved public.users row. Returns ids + token. */
async function makeActor(label, { member = false, pending = false } = {}) {
  const email = `fn-http-${TAG}-${label}@example.test`;
  const authId = await adminCreateAuthUser(email);
  created.authUsers.push(authId);
  let userId = null;
  if (member || pending) {
    const [row] = await rest('POST', 'users', {
      auth_user_id: authId,
      email,
      student_id: `T${TAG}${label}`.slice(0, 32),
      is_pending: pending,
      email_verified: true,
    });
    userId = row.id;
    created.userIds.push(userId);
  }
  return { email, authId, userId, token: await signIn(email) };
}

async function makeAdmin(label) {
  const a = await makeActor(label, { member: true });
  const [role] = await rest('GET', 'roles?key=eq.membership_admin&select=id');
  assert.ok(role, 'membership_admin role missing — run `npm run db:reset` (seed_roles_and_teams.sql)');
  await rest('POST', 'role_assignments', { user_id: a.userId, role_id: role.id, is_active: true });
  return a;
}

async function makeEvent(title) {
  const now = Date.now();
  const [ev] = await rest('POST', 'events', {
    title: `fn-http-${TAG}-${title}`,
    starts_at: new Date(now - 3600e3).toISOString(),
    ends_at: new Date(now + 3600e3).toISOString(),
    semester: 'fall',
    year: 2026,
    is_published: true,
  });
  created.eventIds.push(ev.id);
  return ev;
}

async function makeQrToken(eventId, { expiresInMs = 3600e3, active = true } = {}) {
  const token = `qr-${TAG}-${randomUUID()}`;
  await rest('POST', 'event_qr_tokens', {
    event_id: eventId,
    token_hash: sha256(token),
    expires_at: new Date(Date.now() + expiresInMs).toISOString(),
    is_active: active,
  });
  return token;
}

const userRow = async (id) => (await rest('GET', `users?id=eq.${id}&select=*`))[0];
const userByAuth = async (authId) => (await rest('GET', `users?auth_user_id=eq.${authId}&select=*`))[0];

// ---------------------------------------------------------------------------
describe('Edge Functions over HTTP (local gateway + edge runtime)', () => {
  let admin;
  let plainMember;

  before(async () => {
    // Fail fast with a readable message if the stack / functions are not up.
    const ping = await fetch(`${FN}/check-in-guest`, { method: 'OPTIONS' }).catch((e) => e);
    if (ping instanceof Error) {
      throw new Error(`Cannot reach ${FN}. Run \`supabase start\` and \`supabase functions serve\`. (${ping.message})`);
    }
    const probe = await callFn('check-in-guest', { body: {} });
    if (probe.status === 500 && /publishable key/i.test(probe.text)) {
      throw new Error(
        'Edge Runtime has no SUPABASE_PUBLISHABLE_KEYS. Upgrade the Supabase CLI (>= 2.120) and restart ' +
          '`supabase functions serve` — see supabase/README.md "Edge Function tests".'
      );
    }
    admin = await makeAdmin('admin');
    plainMember = await makeActor('plain', { member: true });
  });

  after(async () => {
    for (const id of created.eventIds) await rest('DELETE', `events?id=eq.${id}`).catch(() => {});
    for (const email of created.guestEmails) {
      await rest('DELETE', `guest_identities?normalized_email=eq.${encodeURIComponent(email)}`).catch(() => {});
    }
    for (const id of created.userIds) {
      await rest('DELETE', `role_assignments?user_id=eq.${id}`).catch(() => {});
      await rest('DELETE', `student_id_collisions?new_user_id=eq.${id}`).catch(() => {});
      await rest('DELETE', `users?id=eq.${id}`).catch(() => {});
    }
    for (const id of created.authUsers) {
      await fetch(`${API_URL}/auth/v1/admin/users/${id}`, { method: 'DELETE', headers: serviceHeaders }).catch(() => {});
    }
  });

  // -------------------------------------------------------------------------
  describe('CORS preflight (regression: browser saw OPTIONS /functions/v1/register-member -> 404)', () => {
    for (const name of FUNCTIONS) {
      test(`OPTIONS ${name}: 200/204 with CORS headers`, async () => {
        const res = await fetch(`${FN}/${name}`, {
          method: 'OPTIONS',
          headers: {
            Origin: ORIGIN,
            'Access-Control-Request-Method': 'POST',
            'Access-Control-Request-Headers': 'authorization,content-type,apikey,x-client-info',
          },
        });
        assert.ok([200, 204].includes(res.status), `expected 200/204, got ${res.status}`);
        assert.notEqual(res.status, 404);
        const allowOrigin = res.headers.get('access-control-allow-origin');
        assert.ok(allowOrigin === '*' || allowOrigin === ORIGIN, `bad allow-origin: ${allowOrigin}`);
        const allowHeaders = (res.headers.get('access-control-allow-headers') ?? '').toLowerCase();
        for (const h of ['authorization', 'content-type', 'apikey', 'x-client-info']) {
          assert.ok(allowHeaders.includes(h), `allow-headers missing ${h}: ${allowHeaders}`);
        }
        const allowMethods = (res.headers.get('access-control-allow-methods') ?? '').toUpperCase();
        assert.ok(allowMethods.includes('POST'), `allow-methods missing POST: ${allowMethods}`);
      });
    }

    test('OPTIONS preflight needs no Authorization header (browsers never send one)', async () => {
      const res = await fetch(`${FN}/register-member`, {
        method: 'OPTIONS',
        headers: { Origin: ORIGIN, 'Access-Control-Request-Method': 'POST' },
      });
      assert.ok([200, 204].includes(res.status), `got ${res.status}`);
      assert.ok(res.headers.get('access-control-allow-origin'));
    });

    test('function-generated responses carry CORS headers (check-in-guest 400)', async () => {
      const res = await callFn('check-in-guest', { body: {}, headers: { Origin: ORIGIN } });
      assert.equal(res.status, 400);
      assert.equal(res.headers.get('access-control-allow-origin'), '*');
    });

    test('function-generated responses carry CORS headers (register-member 400)', async () => {
      const a = await makeActor('cors');
      const res = await callFn('register-member', { token: a.token, body: {}, headers: { Origin: ORIGIN } });
      assert.equal(res.status, 400);
      assert.equal(res.headers.get('access-control-allow-origin'), '*');
    });
  });

  // -------------------------------------------------------------------------
  describe('register-member', () => {
    test('no Authorization header -> 401', async () => {
      const res = await callFn('register-member', { body: { student_id: '1' } });
      assert.equal(res.status, 401);
    });

    test('garbage JWT -> 401', async () => {
      const res = await callFn('register-member', { token: 'not-a-jwt', body: { student_id: '1' } });
      assert.equal(res.status, 401);
    });

    test('publishable key used as bearer (not a user JWT) -> 401', async () => {
      const res = await callFn('register-member', { token: PUBLISHABLE_KEY, body: { student_id: '1' } });
      assert.equal(res.status, 401);
    });

    test('unverified email -> 403 and no users row', async () => {
      const a = await makeActor('unverified');
      unconfirmEmail(a.authId);
      const res = await callFn('register-member', { token: a.token, body: { student_id: `U${TAG}` } });
      assert.equal(res.status, 403);
      assert.match(res.json.error, /not verified/i);
      assert.equal(await userByAuth(a.authId), undefined);
    });

    test('malformed JSON body -> 4xx/5xx JSON error (never 200)', async () => {
      const a = await makeActor('badjson');
      const res = await callFn('register-member', { token: a.token, rawBody: '{not json' });
      assert.ok(res.status >= 400, `got ${res.status}`);
      assert.equal(await userByAuth(a.authId), undefined);
    });

    test('missing / empty / non-string student_id -> 400', async () => {
      const a = await makeActor('badsid');
      for (const body of [{}, { student_id: '' }, { student_id: '   ' }, { student_id: 12345 }]) {
        const res = await callFn('register-member', { token: a.token, body });
        assert.equal(res.status, 400, JSON.stringify(body));
      }
      assert.equal(await userByAuth(a.authId), undefined);
    });

    test('oversized student_id (>32 chars) -> 400', async () => {
      const a = await makeActor('bigsid');
      const res = await callFn('register-member', { token: a.token, body: { student_id: 'x'.repeat(33) } });
      assert.equal(res.status, 400);
      assert.equal(await userByAuth(a.authId), undefined);
    });

    test('happy path: pending record from JWT identity; body auth_user_id ignored; student_id not echoed', async () => {
      const a = await makeActor('happy');
      const sid = `H${TAG}`;
      const victim = randomUUID();
      const res = await callFn('register-member', {
        token: a.token,
        body: { student_id: ` ${sid} `, auth_user_id: victim, email: 'attacker@example.test', is_pending: false },
      });
      assert.equal(res.status, 200, res.text);
      assert.deepEqual(res.json, { status: 'pending', collision: false });
      assert.ok(!res.text.includes(sid), 'student_id leaked in response');

      const row = await userByAuth(a.authId);
      assert.ok(row, 'users row should exist for the JWT identity');
      created.userIds.push(row.id);
      assert.equal(row.auth_user_id, a.authId);
      assert.equal(row.email, a.email);
      assert.equal(row.student_id, sid, 'student_id is trimmed and stored server-side');
      assert.equal(row.is_pending, true);
      assert.equal(row.is_rejected, false);
      assert.equal((await rest('GET', `users?auth_user_id=eq.${victim}&select=id`)).length, 0);
    });

    test('duplicate registration -> 409', async () => {
      const a = await makeActor('dup');
      const first = await callFn('register-member', { token: a.token, body: { student_id: `D${TAG}` } });
      assert.equal(first.status, 200, first.text);
      created.userIds.push((await userByAuth(a.authId)).id);
      const second = await callFn('register-member', { token: a.token, body: { student_id: `D2${TAG}` } });
      assert.equal(second.status, 409);
    });

    test('student-ID collision: 200 with collision flag; open collision row recorded', async () => {
      const first = await makeActor('col1');
      const second = await makeActor('col2');
      const sid = `C${TAG}`;
      assert.equal((await callFn('register-member', { token: first.token, body: { student_id: sid } })).status, 200);
      const r2 = await callFn('register-member', { token: second.token, body: { student_id: sid } });
      assert.equal(r2.status, 200, r2.text);
      assert.deepEqual(r2.json, { status: 'pending', collision: true });
      assert.ok(!r2.text.includes(sid));
      const u1 = await userByAuth(first.authId);
      const u2 = await userByAuth(second.authId);
      created.userIds.push(u1.id, u2.id);
      const rows = await rest('GET', `student_id_collisions?new_user_id=eq.${u2.id}&select=*`);
      assert.equal(rows.length, 1);
      assert.equal(rows[0].existing_user_id, u1.id);
      assert.equal(rows[0].resolution_status, 'open');
    });
  });

  // -------------------------------------------------------------------------
  describe('approve-member / reject-member', () => {
    async function pendingMember(label) {
      return makeActor(label, { pending: true });
    }

    test('no Authorization -> 401 (both)', async () => {
      assert.equal((await callFn('approve-member', { body: { user_id: randomUUID() } })).status, 401);
      assert.equal((await callFn('reject-member', { body: { user_id: randomUUID(), reason: 'x' } })).status, 401);
    });

    test('garbage JWT -> 401 (both)', async () => {
      assert.equal((await callFn('approve-member', { token: 'nope', body: { user_id: randomUUID() } })).status, 401);
      assert.equal((await callFn('reject-member', { token: 'nope', body: { user_id: randomUUID(), reason: 'x' } })).status, 401);
    });

    test('missing user_id -> 400 (both)', async () => {
      assert.equal((await callFn('approve-member', { token: admin.token, body: {} })).status, 400);
      assert.equal((await callFn('reject-member', { token: admin.token, body: { reason: 'x' } })).status, 400);
    });

    test('malformed JSON -> error status, not 200', async () => {
      const res = await callFn('approve-member', { token: admin.token, rawBody: '{oops' });
      assert.ok(res.status >= 400);
    });

    test('plain member (no membership_admin) -> 403 and target unchanged', async () => {
      const target = await pendingMember('deny-target');
      const a = await callFn('approve-member', { token: plainMember.token, body: { user_id: target.userId } });
      assert.equal(a.status, 403);
      const r = await callFn('reject-member', { token: plainMember.token, body: { user_id: target.userId, reason: 'nope' } });
      assert.equal(r.status, 403);
      const row = await userRow(target.userId);
      assert.equal(row.is_pending, true);
      assert.equal(row.is_rejected, false);
    });

    test('pending (unapproved) caller -> 403', async () => {
      const target = await pendingMember('p-target');
      const caller = await pendingMember('p-caller');
      const res = await callFn('approve-member', { token: caller.token, body: { user_id: target.userId } });
      assert.equal(res.status, 403);
    });

    test('admin approves pending member -> 200, approved_by set; double approve -> 409', async () => {
      const target = await pendingMember('approve-ok');
      const res = await callFn('approve-member', { token: admin.token, body: { user_id: target.userId } });
      assert.equal(res.status, 200, res.text);
      assert.deepEqual(res.json, { status: 'approved' });
      const row = await userRow(target.userId);
      assert.equal(row.is_pending, false);
      assert.equal(row.approved_by, admin.userId);
      assert.ok(row.approved_at);
      assert.ok(!res.text.includes(row.student_id));

      const again = await callFn('approve-member', { token: admin.token, body: { user_id: target.userId } });
      assert.equal(again.status, 409);
    });

    test('admin cannot approve or reject own account -> 400', async () => {
      const a = await callFn('approve-member', { token: admin.token, body: { user_id: admin.userId } });
      assert.equal(a.status, 400);
      const r = await callFn('reject-member', { token: admin.token, body: { user_id: admin.userId, reason: 'self' } });
      assert.equal(r.status, 400);
      assert.equal((await userRow(admin.userId)).is_rejected, false);
    });

    test('unknown user_id -> 404', async () => {
      assert.equal((await callFn('approve-member', { token: admin.token, body: { user_id: randomUUID() } })).status, 404);
      assert.equal((await callFn('reject-member', { token: admin.token, body: { user_id: randomUUID(), reason: 'x' } })).status, 404);
    });

    test('open student-ID collision blocks approval -> 409', async () => {
      const existing = await makeActor('colx-existing', { member: true });
      const target = await pendingMember('colx-target');
      await rest('POST', 'student_id_collisions', {
        student_id: `X${TAG}`,
        new_user_id: target.userId,
        existing_user_id: existing.userId,
        resolution_status: 'open',
      });
      const res = await callFn('approve-member', { token: admin.token, body: { user_id: target.userId } });
      assert.equal(res.status, 409);
      assert.equal((await userRow(target.userId)).is_pending, true);
    });

    test('reject without reason (missing / blank / non-string) -> 400, member unchanged', async () => {
      const target = await pendingMember('rej-noreason');
      for (const reason of [undefined, '', '   ', 42]) {
        const res = await callFn('reject-member', { token: admin.token, body: { user_id: target.userId, reason } });
        assert.equal(res.status, 400, String(reason));
      }
      assert.equal((await userRow(target.userId)).is_rejected, false);
    });

    test('admin rejects pending member with reason -> 200; then re-reject / approve -> 409', async () => {
      const target = await pendingMember('rej-ok');
      const res = await callFn('reject-member', { token: admin.token, body: { user_id: target.userId, reason: ' not a student ' } });
      assert.equal(res.status, 200, res.text);
      assert.deepEqual(res.json, { status: 'rejected' });
      const row = await userRow(target.userId);
      assert.equal(row.is_rejected, true);
      assert.equal(row.is_pending, false);

      const again = await callFn('reject-member', { token: admin.token, body: { user_id: target.userId, reason: 'again' } });
      assert.equal(again.status, 409);
      const approve = await callFn('approve-member', { token: admin.token, body: { user_id: target.userId } });
      assert.equal(approve.status, 409);
    });

    test('reject of an already-approved member -> 409', async () => {
      const target = await pendingMember('rej-after-approve');
      assert.equal((await callFn('approve-member', { token: admin.token, body: { user_id: target.userId } })).status, 200);
      const res = await callFn('reject-member', { token: admin.token, body: { user_id: target.userId, reason: 'late' } });
      assert.equal(res.status, 409);
    });

    test('end-to-end: register -> approve -> approved member can check in', async () => {
      const a = await makeActor('e2e');
      const reg = await callFn('register-member', { token: a.token, body: { student_id: `E${TAG}` } });
      assert.equal(reg.status, 200, reg.text);
      const row = await userByAuth(a.authId);
      created.userIds.push(row.id);

      const ev = await makeEvent('e2e');
      const qr = await makeQrToken(ev.id);
      const before = await callFn('check-in-user', { token: a.token, body: { token: qr } });
      assert.equal(before.status, 403, 'pending member cannot check in');

      assert.equal((await callFn('approve-member', { token: admin.token, body: { user_id: row.id } })).status, 200);
      const after = await callFn('check-in-user', { token: a.token, body: { token: qr } });
      assert.equal(after.status, 200, after.text);
    });
  });

  // -------------------------------------------------------------------------
  describe('check-in-user', () => {
    test('no Authorization -> 401; garbage JWT -> 401', async () => {
      assert.equal((await callFn('check-in-user', { body: { token: 'x' } })).status, 401);
      assert.equal((await callFn('check-in-user', { token: 'junk', body: { token: 'x' } })).status, 401);
    });

    test('missing token -> 400; malformed JSON -> error', async () => {
      assert.equal((await callFn('check-in-user', { token: plainMember.token, body: {} })).status, 400);
      assert.ok((await callFn('check-in-user', { token: plainMember.token, rawBody: '[' })).status >= 400);
    });

    test('authenticated but no members row (never registered) -> 403', async () => {
      const a = await makeActor('ci-nomember');
      const ev = await makeEvent('ci-nomember');
      const qr = await makeQrToken(ev.id);
      assert.equal((await callFn('check-in-user', { token: a.token, body: { token: qr } })).status, 403);
    });

    test('pending member -> 403 and no attendance', async () => {
      const a = await makeActor('ci-pending', { pending: true });
      const ev = await makeEvent('ci-pending');
      const qr = await makeQrToken(ev.id);
      assert.equal((await callFn('check-in-user', { token: a.token, body: { token: qr } })).status, 403);
      assert.equal((await rest('GET', `attendances?event_id=eq.${ev.id}&select=id`)).length, 0);
    });

    test('invalid token -> 404', async () => {
      const res = await callFn('check-in-user', { token: plainMember.token, body: { token: `bogus-${TAG}` } });
      assert.equal(res.status, 404);
    });

    test('expired token -> 410', async () => {
      const ev = await makeEvent('ci-expired');
      const qr = await makeQrToken(ev.id, { expiresInMs: -60e3 });
      assert.equal((await callFn('check-in-user', { token: plainMember.token, body: { token: qr } })).status, 410);
    });

    test('deactivated token (closed event check-in) -> 404', async () => {
      const ev = await makeEvent('ci-closed');
      const qr = await makeQrToken(ev.id, { active: false });
      assert.equal((await callFn('check-in-user', { token: plainMember.token, body: { token: qr } })).status, 404);
      assert.equal((await rest('GET', `attendances?event_id=eq.${ev.id}&select=id`)).length, 0);
    });

    test('valid token -> 200, attendance recorded; duplicate is idempotent', async () => {
      const a = await makeActor('ci-ok', { member: true });
      const ev = await makeEvent('ci-ok');
      const qr = await makeQrToken(ev.id);
      const first = await callFn('check-in-user', { token: a.token, body: { token: qr } });
      assert.equal(first.status, 200, first.text);
      assert.deepEqual(first.json, { status: 'checked_in' });
      const second = await callFn('check-in-user', { token: a.token, body: { token: qr } });
      assert.equal(second.status, 200, second.text);
      const rows = await rest('GET', `attendances?event_id=eq.${ev.id}&user_id=eq.${a.userId}&select=*`);
      assert.equal(rows.length, 1);
      assert.equal(rows[0].source, 'qr_user');
    });

    test('two distinct events -> membership_status becomes active (>= 2 qualifying)', async () => {
      const a = await makeActor('ci-membership', { member: true });
      for (const t of ['m1', 'm2']) {
        const ev = await makeEvent(t);
        const qr = await makeQrToken(ev.id);
        assert.equal((await callFn('check-in-user', { token: a.token, body: { token: qr } })).status, 200);
      }
      const [ms] = await rest('GET', `membership_status?user_id=eq.${a.userId}&select=*`);
      assert.equal(ms.qualifying_attendance_count, 2);
      assert.equal(ms.is_active, true);
    });
  });

  // -------------------------------------------------------------------------
  describe('check-in-guest (public, QR-token secured)', () => {
    const guestEmail = (label) => {
      const e = `guest-${TAG}-${label}@example.test`;
      created.guestEmails.push(e);
      return e;
    };

    test('works without a user JWT (verify_jwt = false); missing fields -> 400', async () => {
      assert.equal((await callFn('check-in-guest', { body: {} })).status, 400);
      assert.equal((await callFn('check-in-guest', { body: { token: 'x' } })).status, 400);
      assert.equal((await callFn('check-in-guest', { body: { email: 'a@b.c' } })).status, 400);
    });

    test('malformed JSON -> error status', async () => {
      assert.ok((await callFn('check-in-guest', { rawBody: 'nope' })).status >= 400);
    });

    test('invalid token -> 404; expired -> 410; inactive -> 404', async () => {
      const email = guestEmail('bad');
      assert.equal((await callFn('check-in-guest', { body: { token: 'nope', email } })).status, 404);
      const ev = await makeEvent('g-bad');
      const expired = await makeQrToken(ev.id, { expiresInMs: -60e3 });
      assert.equal((await callFn('check-in-guest', { body: { token: expired, email } })).status, 410);
      const inactive = await makeQrToken(ev.id, { active: false });
      assert.equal((await callFn('check-in-guest', { body: { token: inactive, email } })).status, 404);
    });

    test('valid token -> 200 merged:false; email normalized; duplicate idempotent', async () => {
      const email = guestEmail('ok');
      const ev = await makeEvent('g-ok');
      const qr = await makeQrToken(ev.id);
      const first = await callFn('check-in-guest', { body: { token: qr, email: `  ${email.toUpperCase()} ` } });
      assert.equal(first.status, 200, first.text);
      assert.deepEqual(first.json, { status: 'checked_in', merged: false });
      const second = await callFn('check-in-guest', { body: { token: qr, email } });
      assert.equal(second.status, 200, second.text);
      const [gi] = await rest('GET', `guest_identities?normalized_email=eq.${encodeURIComponent(email)}&select=id`);
      assert.ok(gi, 'guest identity stored under lower-cased email');
      const rows = await rest('GET', `guest_attendances?event_id=eq.${ev.id}&guest_identity_id=eq.${gi.id}&select=*`);
      assert.equal(rows.length, 1);
      assert.equal(rows[0].merged, false);
    });

    test('guest email matching an approved member merges attendance into the account', async () => {
      const m = await makeActor('g-merge', { member: true });
      const ev = await makeEvent('g-merge');
      const qr = await makeQrToken(ev.id);
      const res = await callFn('check-in-guest', { body: { token: qr, email: m.email } });
      assert.equal(res.status, 200, res.text);
      assert.deepEqual(res.json, { status: 'checked_in', merged: true });
      const rows = await rest('GET', `attendances?event_id=eq.${ev.id}&user_id=eq.${m.userId}&select=*`);
      assert.equal(rows.length, 1);
      assert.equal(rows[0].source, 'guest_merge');
      created.guestEmails.push(m.email);
    });

    test('guest email matching a PENDING member does not merge', async () => {
      const p = await makeActor('g-pending', { pending: true });
      const ev = await makeEvent('g-pending');
      const qr = await makeQrToken(ev.id);
      const res = await callFn('check-in-guest', { body: { token: qr, email: p.email } });
      assert.equal(res.status, 200, res.text);
      assert.equal(res.json.merged, false);
      assert.equal((await rest('GET', `attendances?event_id=eq.${ev.id}&select=id`)).length, 0);
      created.guestEmails.push(p.email);
    });

    test('guest check-in then approval merges prior guest attendance (approve-member)', async () => {
      const a = await makeActor('g-then-approve', { pending: true });
      const ev = await makeEvent('g-then-approve');
      const qr = await makeQrToken(ev.id);
      assert.equal((await callFn('check-in-guest', { body: { token: qr, email: a.email } })).status, 200);
      created.guestEmails.push(a.email);
      assert.equal((await callFn('approve-member', { token: admin.token, body: { user_id: a.userId } })).status, 200);
      const rows = await rest('GET', `attendances?event_id=eq.${ev.id}&user_id=eq.${a.userId}&select=source`);
      assert.equal(rows.length, 1);
      assert.equal(rows[0].source, 'guest_merge');
    });
  });
});
