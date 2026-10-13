import { assert, assertEquals } from 'jsr:@std/assert@1';
import handler from '../reject-member/index.ts';
import { assertCors, makeWorld, readJson, req } from './helpers.ts';

const call = (r: Request) => handler.fetch(r);

function setup() {
  const w = makeWorld();
  const admin = w.member('admin', { admin: true });
  const plain = w.member('plain');
  const target = w.member('target', { is_pending: true });
  return { w, admin, plain, target };
}
const row = (w: ReturnType<typeof makeWorld>, id: string) => w.db.tables.users.find((u) => u.id === id)!;

Deno.test('reject-member: OPTIONS -> 200 + CORS', async () => {
  makeWorld();
  const res = await call(req(null, { method: 'OPTIONS' }));
  assertEquals(res.status, 200);
  assertCors(res);
});

Deno.test('reject-member: missing / invalid / expired JWT -> 401', async () => {
  const { w, target } = setup();
  for (const token of [null, 'junk', 'expired']) {
    const res = await call(req({ user_id: target.userId, reason: 'x' }, { token }));
    assertEquals(res.status, 401, String(token));
  }
  assertEquals(row(w, target.userId).is_rejected, false);
});

Deno.test('reject-member: malformed JSON -> 500 JSON error', async () => {
  const { admin } = setup();
  const res = await call(req(null, { token: admin.token, raw: 'nope' }));
  assert(res.status >= 400);
  assert((await readJson(res)).error);
});

Deno.test('reject-member: missing user_id -> 400', async () => {
  const { admin } = setup();
  const res = await call(req({ reason: 'x' }, { token: admin.token }));
  assertEquals(res.status, 400);
  assertEquals((await readJson(res)).error, 'user_id required');
});

Deno.test('reject-member: reason missing / blank / non-string -> 400 (checked before authz), member unchanged', async () => {
  const { w, admin, target } = setup();
  for (const reason of [undefined, null, '', '   \n\t', 42, { a: 1 }]) {
    const res = await call(req({ user_id: target.userId, reason }, { token: admin.token }));
    assertEquals(res.status, 400, JSON.stringify(reason));
    assertEquals((await readJson(res)).error, 'A rejection reason is required');
  }
  assertEquals(row(w, target.userId).is_rejected, false);
  assertEquals(w.db.writes.length, 0);
});

Deno.test('reject-member: ordinary member -> 403, target unchanged', async () => {
  const { w, plain, target } = setup();
  const res = await call(req({ user_id: target.userId, reason: 'no' }, { token: plain.token }));
  assertEquals(res.status, 403);
  assertEquals(row(w, target.userId).is_pending, true);
  assertEquals(w.db.writes.length, 0);
});

Deno.test('reject-member: admin rejects pending member -> 200; flags set; reason trimmed in audit only', async () => {
  const { w, admin, target } = setup();
  const res = await call(req({ user_id: target.userId, reason: '  not a student  ' }, { token: admin.token }));
  assertEquals(res.status, 200);
  assertCors(res);
  assertEquals(await readJson(res), { status: 'rejected' });
  const u = row(w, target.userId);
  assertEquals(u.is_rejected, true);
  assertEquals(u.is_pending, false);
  const audit = w.db.tables.audit_logs;
  assertEquals(audit.length, 1);
  assertEquals(audit[0].p_action, 'reject_member');
  assertEquals(audit[0].p_after.reason, 'not a student');
  assertEquals(audit[0].p_after.rejected_by, admin.userId);
});

Deno.test('reject-member: self-rejection denied -> 400', async () => {
  const { w, admin } = setup();
  const res = await call(req({ user_id: admin.userId, reason: 'self' }, { token: admin.token }));
  assertEquals(res.status, 400);
  assertEquals((await readJson(res)).error, 'Cannot reject your own account');
  assertEquals(row(w, admin.userId).is_rejected, false);
});

Deno.test('reject-member: double-reject -> 409; reject-after-approve -> 409; unknown id -> 404', async () => {
  const { w, admin, target } = setup();
  assertEquals((await call(req({ user_id: target.userId, reason: 'r' }, { token: admin.token }))).status, 200);
  const again = await call(req({ user_id: target.userId, reason: 'r2' }, { token: admin.token }));
  assertEquals(again.status, 409);
  assertEquals((await readJson(again)).error, 'Member already rejected');

  const approved = w.member('approved');
  const res = await call(req({ user_id: approved.userId, reason: 'late' }, { token: admin.token }));
  assertEquals(res.status, 409);
  assertEquals((await readJson(res)).error, 'Member already approved');

  assertEquals((await call(req({ user_id: 'nope', reason: 'r' }, { token: admin.token }))).status, 404);
});

Deno.test('reject-member: rejected member can no longer act (current_app_user_id -> null)', async () => {
  const { w, admin, target } = setup();
  await call(req({ user_id: target.userId, reason: 'r' }, { token: admin.token }));
  assertEquals(w.db.currentAppUserId(target.authId), null);
});
