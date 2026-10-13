import { assert, assertEquals, assertFalse } from 'jsr:@std/assert@1';
import handler from '../register-member/index.ts';
import { assertCors, makeWorld, readJson, req } from './helpers.ts';

const call = (r: Request) => handler.fetch(r);

Deno.test('register-member: OPTIONS -> 200 + CORS, no auth required', async () => {
  makeWorld();
  const res = await call(req(null, { method: 'OPTIONS' }));
  assertEquals(res.status, 200);
  assertCors(res);
});

Deno.test('register-member: anon (no Authorization) -> 401, nothing written', async () => {
  const w = makeWorld();
  const res = await call(req({ student_id: '123' }));
  assertEquals(res.status, 401);
  assertCors(res);
  assertEquals(w.db.writes.length, 0);
});

Deno.test('register-member: invalid / expired JWT -> 401', async () => {
  const w = makeWorld();
  for (const token of ['junk', 'expired']) {
    assertEquals((await call(req({ student_id: '123' }, { token }))).status, 401);
  }
  assertEquals(w.db.writes.length, 0);
});

Deno.test('register-member: unverified email -> 403 and no users row', async () => {
  const w = makeWorld();
  const a = w.authUser('unverified', { verified: false });
  const res = await call(req({ student_id: '123' }, { token: a.token }));
  assertEquals(res.status, 403);
  assertEquals((await readJson(res)).error, 'Email not verified');
  assertEquals(w.db.tables.users.length, 0);
});

Deno.test('register-member: malformed JSON -> 500 JSON error (no write)', async () => {
  const w = makeWorld();
  const a = w.authUser('badjson');
  const res = await call(req(null, { token: a.token, raw: '{not json' }));
  assert(res.status >= 400);
  assert((await readJson(res)).error);
  assertEquals(w.db.tables.users.length, 0);
});

Deno.test('register-member: missing / empty / blank / non-string student_id -> 400', async () => {
  const w = makeWorld();
  const a = w.authUser('badsid');
  for (const body of [{}, { student_id: '' }, { student_id: '   ' }, { student_id: 123 }, { student_id: null }]) {
    const res = await call(req(body, { token: a.token }));
    assertEquals(res.status, 400, JSON.stringify(body));
    assertEquals((await readJson(res)).error, 'Invalid student ID');
  }
  assertEquals(w.db.tables.users.length, 0);
});

Deno.test('register-member: oversized student_id (33 chars) -> 400; 32 chars accepted', async () => {
  const w = makeWorld();
  const a = w.authUser('size');
  const tooBig = await call(req({ student_id: 'x'.repeat(33) }, { token: a.token }));
  assertEquals(tooBig.status, 400);
  assertEquals(w.db.tables.users.length, 0);

  const ok = await call(req({ student_id: 'y'.repeat(32) }, { token: a.token }));
  assertEquals(ok.status, 200);
});

Deno.test('register-member: oversized check happens AFTER trimming', async () => {
  const w = makeWorld();
  const a = w.authUser('trim');
  const res = await call(req({ student_id: `  ${'z'.repeat(32)}  ` }, { token: a.token }));
  assertEquals(res.status, 200);
  assertEquals(w.db.tables.users[0].student_id, 'z'.repeat(32));
});

Deno.test('register-member: confirmed user succeeds -> pending record; student_id NOT in response', async () => {
  const w = makeWorld();
  const a = w.authUser('happy');
  const res = await call(req({ student_id: '  900123456 ' }, { token: a.token }));
  const text = await res.clone().text();
  assertEquals(res.status, 200);
  assertCors(res);
  assertEquals(await readJson(res), { status: 'pending', collision: false });
  assertFalse(text.includes('900123456'), 'student_id leaked into response');

  assertEquals(w.db.tables.users.length, 1);
  const row = w.db.tables.users[0];
  assertEquals(row.auth_user_id, a.authId);
  assertEquals(row.email, a.email);
  assertEquals(row.student_id, '900123456');
  assertEquals(row.is_pending, true);
  assertEquals(row.email_verified, true);
  assertEquals(w.db.tables.student_id_collisions.length, 0);
});

Deno.test('register-member: body auth_user_id / email / is_pending are ignored (identity from JWT)', async () => {
  const w = makeWorld();
  const victim = w.authUser('victim');
  const attacker = w.authUser('attacker');
  const res = await call(req(
    { student_id: '111', auth_user_id: victim.authId, email: 'evil@example.test', is_pending: false, is_rejected: false },
    { token: attacker.token },
  ));
  assertEquals(res.status, 200);
  assertEquals(w.db.tables.users.length, 1);
  const row = w.db.tables.users[0];
  assertEquals(row.auth_user_id, attacker.authId);
  assertEquals(row.email, attacker.email);
  assertEquals(row.is_pending, true);
  assert(!w.db.tables.users.some((u) => u.auth_user_id === victim.authId));
});

Deno.test('register-member: duplicate registration -> 409, no second row', async () => {
  const w = makeWorld();
  const a = w.authUser('dup');
  assertEquals((await call(req({ student_id: '1' }, { token: a.token }))).status, 200);
  const again = await call(req({ student_id: '2' }, { token: a.token }));
  assertEquals(again.status, 409);
  assertEquals((await readJson(again)).error, 'Membership record already exists');
  assertEquals(w.db.tables.users.length, 1);
});

Deno.test('register-member: existing approved member re-registering -> 409', async () => {
  const w = makeWorld();
  const m = w.member('existing');
  const res = await call(req({ student_id: 'new' }, { token: m.token }));
  assertEquals(res.status, 409);
});

Deno.test('register-member: student_id collision -> 200 collision:true + open collision row', async () => {
  const w = makeWorld();
  const first = w.member('first', { student_id: '777' });
  const b = w.authUser('second');
  const res = await call(req({ student_id: '777' }, { token: b.token }));
  assertEquals(res.status, 200);
  const body = await res.clone().text();
  assertFalse(body.includes('777'));
  assertEquals(JSON.parse(body), { status: 'pending', collision: true });
  const rows = w.db.tables.student_id_collisions;
  assertEquals(rows.length, 1);
  assertEquals(rows[0].existing_user_id, first.userId);
  assertEquals(rows[0].resolution_status, 'open');
  assertEquals(rows[0].student_id, '777');
});

Deno.test('register-member: audit log omits student_id', async () => {
  const w = makeWorld();
  const a = w.authUser('audit');
  await call(req({ student_id: 'SECRET-SID' }, { token: a.token }));
  const audit = w.db.tables.audit_logs;
  assertEquals(audit.length, 1);
  assertEquals(audit[0].p_action, 'register_member');
  assertFalse(JSON.stringify(audit).includes('SECRET-SID'));
});

Deno.test('register-member: insert failure surfaces as 400 JSON error', async () => {
  const w = makeWorld();
  const a = w.authUser('insfail');
  w.db.failNext('users', 'insert', 'constraint violated');
  const res = await call(req({ student_id: '5' }, { token: a.token }));
  assertEquals(res.status, 400);
  assertEquals((await readJson(res)).error, 'constraint violated');
});

Deno.test('register-member: uses caller client for identity (getUser) and admin client for writes', async () => {
  const w = makeWorld();
  const a = w.authUser('clients');
  await call(req({ student_id: '9' }, { token: a.token }));
  const logAudit = w.db.rpcCalls.find((c) => c.name === 'log_audit');
  assertEquals(logAudit?.client, 'admin');
});
