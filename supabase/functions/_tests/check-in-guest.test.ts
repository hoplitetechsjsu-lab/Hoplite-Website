import { assert, assertEquals } from 'jsr:@std/assert@1';
import handler from '../check-in-guest/index.ts';
import { contextCalls } from './mocks/supabase-server.ts';
import { assertCors, makeWorld, readJson, req } from './helpers.ts';

const call = (r: Request) => handler.fetch(r);

Deno.test('check-in-guest: OPTIONS -> 200 + CORS', async () => {
  makeWorld();
  const res = await call(req(null, { method: 'OPTIONS' }));
  assertEquals(res.status, 200);
  assertCors(res);
});

Deno.test('check-in-guest: public endpoint — needs no JWT and requests auth "none"', async () => {
  const w = makeWorld();
  const qr = await w.qr(w.event());
  contextCalls.length = 0;
  const res = await call(req({ token: qr, email: 'g@example.test' })); // no Authorization header
  assertEquals(res.status, 200);
  assertEquals(contextCalls, [{ auth: 'none', hasAuthHeader: false }]);
});

Deno.test('check-in-guest: missing token and/or email -> 400; malformed JSON -> error', async () => {
  makeWorld();
  for (const body of [{}, { token: 'x' }, { email: 'a@b.c' }, { token: '', email: 'a@b.c' }, { token: 'x', email: '' }]) {
    const res = await call(req(body));
    assertEquals(res.status, 400, JSON.stringify(body));
    assertEquals((await readJson(res)).error, 'token and email required');
  }
  assert((await call(req(null, { raw: '<<<' }))).status >= 400);
});

Deno.test('check-in-guest: invalid token -> 404; expired -> 410; deactivated -> 404; nothing stored', async () => {
  const w = makeWorld();
  const email = 'g@example.test';
  assertEquals((await call(req({ token: 'bogus', email }))).status, 404);
  const expired = await w.qr(w.event(), { expiresInMs: -1000 });
  assertEquals((await call(req({ token: expired, email }))).status, 410);
  const closed = await w.qr(w.event(), { active: false });
  assertEquals((await call(req({ token: closed, email }))).status, 404);
  assertEquals(w.db.tables.guest_identities.length, 0);
  assertEquals(w.db.tables.guest_attendances.length, 0);
});

Deno.test('check-in-guest: valid token -> 200 merged:false; email normalised; identity + attendance stored', async () => {
  const w = makeWorld();
  const eventId = w.event();
  const qr = await w.qr(eventId);
  const res = await call(req({ token: qr, email: '  Guest@Example.TEST ' }));
  assertEquals(res.status, 200);
  assertCors(res);
  assertEquals(await readJson(res), { status: 'checked_in', merged: false });
  assertEquals(w.db.tables.guest_identities.length, 1);
  const gi = w.db.tables.guest_identities[0];
  assertEquals(gi.normalized_email, 'guest@example.test');
  assert(/^[0-9a-f]{64}$/.test(gi.normalized_email_hash));
  assertEquals(w.db.tables.guest_attendances.length, 1);
  assertEquals(w.db.tables.guest_attendances[0].event_id, eventId);
  assertEquals(w.db.tables.guest_attendances[0].guest_identity_id, gi.id);
  assertEquals(w.db.tables.guest_attendances[0].source, 'qr_guest');
});

Deno.test('check-in-guest: duplicate check-in (any email casing) is idempotent', async () => {
  const w = makeWorld();
  const qr = await w.qr(w.event());
  assertEquals((await call(req({ token: qr, email: 'dup@example.test' }))).status, 200);
  assertEquals((await call(req({ token: qr, email: 'DUP@example.test' }))).status, 200);
  assertEquals(w.db.tables.guest_identities.length, 1);
  assertEquals(w.db.tables.guest_attendances.length, 1);
});

Deno.test('check-in-guest: same guest at two events -> two attendances, one identity', async () => {
  const w = makeWorld();
  const a = await w.qr(w.event());
  const b = await w.qr(w.event());
  await call(req({ token: a, email: 'two@example.test' }));
  await call(req({ token: b, email: 'two@example.test' }));
  assertEquals(w.db.tables.guest_identities.length, 1);
  assertEquals(w.db.tables.guest_attendances.length, 2);
});

Deno.test('check-in-guest: email matching an approved member merges into the account', async () => {
  const w = makeWorld();
  const m = w.member('member');
  const eventId = w.event();
  const qr = await w.qr(eventId);
  const res = await call(req({ token: qr, email: m.email.toUpperCase() }));
  assertEquals(res.status, 200);
  assertEquals(await readJson(res), { status: 'checked_in', merged: true });
  assert(w.db.rpcCalls.some((c) => c.name === 'merge_guest_attendance_into_user' && c.args?.p_user_id === m.userId));
  const att = w.db.tables.attendances.filter((a) => a.user_id === m.userId);
  assertEquals(att.length, 1);
  assertEquals(att[0].source, 'guest_merge');
  assertEquals(w.db.tables.guest_attendances[0].merged, true);
});

Deno.test('check-in-guest: pending / rejected / deactivated account email does NOT merge', async () => {
  for (const flags of [{ is_pending: true }, { is_rejected: true }, { is_deactivated: true }]) {
    const w = makeWorld();
    const m = w.member('acct', flags);
    const qr = await w.qr(w.event());
    const res = await call(req({ token: qr, email: m.email }));
    assertEquals(res.status, 200, JSON.stringify(flags));
    assertEquals((await readJson(res)).merged, false, JSON.stringify(flags));
    assertEquals(w.db.tables.attendances.length, 0);
  }
});

Deno.test('check-in-guest: guest attendance insert error -> 400 JSON error', async () => {
  const w = makeWorld();
  const qr = await w.qr(w.event());
  w.db.failNext('guest_attendances', 'upsert', 'boom');
  const res = await call(req({ token: qr, email: 'e@example.test' }));
  assertEquals(res.status, 400);
  assertEquals((await readJson(res)).error, 'boom');
});

Deno.test('check-in-guest: audit log records check_in', async () => {
  const w = makeWorld();
  const qr = await w.qr(w.event());
  await call(req({ token: qr, email: 'a@example.test' }));
  assertEquals(w.db.tables.audit_logs[0].p_action, 'check_in');
});
