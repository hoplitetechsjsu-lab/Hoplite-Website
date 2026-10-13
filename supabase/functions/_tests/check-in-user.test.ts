import { assert, assertEquals } from 'jsr:@std/assert@1';
import handler from '../check-in-user/index.ts';
import { assertCors, makeWorld, readJson, req } from './helpers.ts';

const call = (r: Request) => handler.fetch(r);

Deno.test('check-in-user: OPTIONS -> 200 + CORS', async () => {
  makeWorld();
  const res = await call(req(null, { method: 'OPTIONS' }));
  assertEquals(res.status, 200);
  assertCors(res);
});

Deno.test('check-in-user: missing / invalid / expired JWT -> 401', async () => {
  const w = makeWorld();
  for (const token of [null, 'junk', 'expired']) {
    const res = await call(req({ token: 'qr' }, { token }));
    assertEquals(res.status, 401, String(token));
    assertCors(res);
  }
  assertEquals(w.db.writes.length, 0);
});

Deno.test('check-in-user: missing token -> 400; malformed JSON -> error', async () => {
  const w = makeWorld();
  const m = w.member('m');
  assertEquals((await call(req({}, { token: m.token }))).status, 400);
  assertEquals((await call(req({ token: '' }, { token: m.token }))).status, 400);
  const bad = await call(req(null, { token: m.token, raw: '{{' }));
  assert(bad.status >= 400);
});

Deno.test('check-in-user: caller with no membership row / pending / rejected / deactivated -> 403', async () => {
  const w = makeWorld();
  const eventId = w.event();
  const qr = await w.qr(eventId);
  const callers = [
    w.authUser('nomember'),
    w.member('pending', { is_pending: true }),
    w.member('rejected', { is_rejected: true, is_pending: false }),
    w.member('deactivated', { is_deactivated: true }),
  ];
  for (const c of callers) {
    const res = await call(req({ token: qr }, { token: c.token }));
    assertEquals(res.status, 403, c.email);
  }
  assertEquals(w.db.tables.attendances.length, 0);
});

Deno.test('check-in-user: invalid token -> 404', async () => {
  const w = makeWorld();
  const m = w.member('m');
  const res = await call(req({ token: 'never-issued' }, { token: m.token }));
  assertEquals(res.status, 404);
  assertEquals((await readJson(res)).error, 'Invalid check-in token');
  assertEquals(w.db.tables.attendances.length, 0);
});

Deno.test('check-in-user: expired token -> 410', async () => {
  const w = makeWorld();
  const m = w.member('m');
  const qr = await w.qr(w.event(), { expiresInMs: -1000 });
  const res = await call(req({ token: qr }, { token: m.token }));
  assertEquals(res.status, 410);
  assertEquals(w.db.tables.attendances.length, 0);
});

Deno.test('check-in-user: deactivated token (closed event) -> 404', async () => {
  const w = makeWorld();
  const m = w.member('m');
  const qr = await w.qr(w.event(), { active: false });
  const res = await call(req({ token: qr }, { token: m.token }));
  assertEquals(res.status, 404);
  assertEquals(w.db.tables.attendances.length, 0);
});

Deno.test('check-in-user: valid token -> 200; attendance stored under caller app-user id with source qr_user', async () => {
  const w = makeWorld();
  const m = w.member('m');
  const eventId = w.event();
  const qr = await w.qr(eventId);
  const res = await call(req({ token: qr }, { token: m.token }));
  assertEquals(res.status, 200);
  assertCors(res);
  assertEquals(await readJson(res), { status: 'checked_in' });
  assertEquals(w.db.tables.attendances.length, 1);
  const a = w.db.tables.attendances[0];
  assertEquals(a.event_id, eventId);
  assertEquals(a.user_id, m.userId);
  assertEquals(a.source, 'qr_user');
  assert(w.db.rpcCalls.some((c) => c.name === 'recalculate_membership' && c.args?.p_user_id === m.userId));
  assertEquals(w.db.tables.audit_logs[0].p_action, 'check_in');
});

Deno.test('check-in-user: duplicate scan is idempotent (200, still one attendance row)', async () => {
  const w = makeWorld();
  const m = w.member('m');
  const qr = await w.qr(w.event());
  assertEquals((await call(req({ token: qr }, { token: m.token }))).status, 200);
  assertEquals((await call(req({ token: qr }, { token: m.token }))).status, 200);
  assertEquals(w.db.tables.attendances.length, 1);
});

Deno.test('check-in-user: user identity comes from JWT, not body (body user_id ignored)', async () => {
  const w = makeWorld();
  const me = w.member('me');
  const other = w.member('other');
  const qr = await w.qr(w.event());
  await call(req({ token: qr, user_id: other.userId }, { token: me.token }));
  assertEquals(w.db.tables.attendances.length, 1);
  assertEquals(w.db.tables.attendances[0].user_id, me.userId);
});

Deno.test('check-in-user: raw token is never stored (only SHA-256 hash is looked up)', async () => {
  const w = makeWorld();
  const m = w.member('m');
  const qr = await w.qr(w.event());
  await call(req({ token: qr }, { token: m.token }));
  assert(!JSON.stringify(w.db.tables).includes(qr));
});

Deno.test('check-in-user: attendance insert error -> 400 JSON error', async () => {
  const w = makeWorld();
  const m = w.member('m');
  const qr = await w.qr(w.event());
  w.db.failNext('attendances', 'upsert', 'boom');
  const res = await call(req({ token: qr }, { token: m.token }));
  assertEquals(res.status, 400);
  assertEquals((await readJson(res)).error, 'boom');
});
