import { assert, assertEquals, assertFalse } from 'jsr:@std/assert@1';
import handler from '../approve-member/index.ts';
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

Deno.test('approve-member: OPTIONS -> 200 + CORS', async () => {
  makeWorld();
  const res = await call(req(null, { method: 'OPTIONS' }));
  assertEquals(res.status, 200);
  assertCors(res);
});

Deno.test('approve-member: missing / invalid / expired JWT -> 401', async () => {
  const { w, target } = setup();
  for (const token of [null, 'junk', 'expired']) {
    const res = await call(req({ user_id: target.userId }, { token }));
    assertEquals(res.status, 401, String(token));
    assertCors(res);
  }
  assertEquals(row(w, target.userId).is_pending, true);
});

Deno.test('approve-member: malformed JSON -> 500 JSON error', async () => {
  const { admin } = setup();
  const res = await call(req(null, { token: admin.token, raw: '{bad' }));
  assert(res.status >= 400);
  assert((await readJson(res)).error);
});

Deno.test('approve-member: missing user_id -> 400', async () => {
  const { admin } = setup();
  for (const body of [{}, { user_id: '' }, { user_id: null }]) {
    const res = await call(req(body, { token: admin.token }));
    assertEquals(res.status, 400);
    assertEquals((await readJson(res)).error, 'user_id required');
  }
});

Deno.test('approve-member: ordinary member (no membership_admin) -> 403, target unchanged', async () => {
  const { w, plain, target } = setup();
  const res = await call(req({ user_id: target.userId }, { token: plain.token }));
  assertEquals(res.status, 403);
  assertEquals(row(w, target.userId).is_pending, true);
  assertEquals(w.db.writes.length, 0);
});

Deno.test('approve-member: authenticated user with no membership row -> 403', async () => {
  const { w, target } = setup();
  const nobody = w.authUser('nobody');
  assertEquals((await call(req({ user_id: target.userId }, { token: nobody.token }))).status, 403);
});

Deno.test('approve-member: pending / rejected / deactivated admin cannot act -> 403', async () => {
  for (const flags of [{ is_pending: true }, { is_rejected: true }, { is_deactivated: true }]) {
    const w = makeWorld();
    const admin = w.member('adm', { admin: true, ...flags });
    const target = w.member('tgt', { is_pending: true });
    const res = await call(req({ user_id: target.userId }, { token: admin.token }));
    assertEquals(res.status, 403, JSON.stringify(flags));
  }
});

Deno.test('approve-member: admin approves pending member -> 200, flags + approved_by set', async () => {
  const { w, admin, target } = setup();
  const res = await call(req({ user_id: target.userId }, { token: admin.token }));
  const text = await res.clone().text();
  assertEquals(res.status, 200);
  assertCors(res);
  assertEquals(JSON.parse(text), { status: 'approved' });
  assertFalse(text.includes('SID-target'), 'student_id must not appear in response');
  const u = row(w, target.userId);
  assertEquals(u.is_pending, false);
  assertEquals(u.approved_by, admin.userId);
  assert(u.approved_at);
});

Deno.test('approve-member: authorization RPCs run as the caller; writes use the admin client', async () => {
  const { w, admin, target } = setup();
  await call(req({ user_id: target.userId }, { token: admin.token }));
  const byName = (n: string) => w.db.rpcCalls.filter((c) => c.name === n);
  assertEquals(byName('can_approve_membership')[0].client, 'caller');
  assertEquals(byName('current_app_user_id')[0].client, 'caller');
  assertEquals(byName('merge_guest_attendance_into_user')[0].client, 'admin');
  assertEquals(byName('log_audit')[0].client, 'admin');
});

Deno.test('approve-member: writes an audit row without student_id', async () => {
  const { w, admin, target } = setup();
  await call(req({ user_id: target.userId }, { token: admin.token }));
  const audit = w.db.tables.audit_logs;
  assertEquals(audit.length, 1);
  assertEquals(audit[0].p_action, 'approve_member');
  assertEquals(audit[0].p_entity_id, target.userId);
  assertFalse(JSON.stringify(audit).includes('SID-'));
});

Deno.test('approve-member: self-approval denied -> 400, nothing written', async () => {
  const { w, admin } = setup();
  const res = await call(req({ user_id: admin.userId }, { token: admin.token }));
  assertEquals(res.status, 400);
  assertEquals((await readJson(res)).error, 'Cannot approve your own account');
  assertEquals(w.db.writes.length, 0);
});

Deno.test('approve-member: double-approve denied -> 409 (not pending)', async () => {
  const { w, admin, target } = setup();
  assertEquals((await call(req({ user_id: target.userId }, { token: admin.token }))).status, 200);
  w.db.writes.length = 0;
  const again = await call(req({ user_id: target.userId }, { token: admin.token }));
  assertEquals(again.status, 409);
  assertEquals((await readJson(again)).error, 'Member is not pending');
  assertEquals(w.db.writes.length, 0);
});

Deno.test('approve-member: rejected member cannot be approved -> 409', async () => {
  const { w, admin } = setup();
  const rejected = w.member('rej', { is_pending: false, is_rejected: true });
  const res = await call(req({ user_id: rejected.userId }, { token: admin.token }));
  assertEquals(res.status, 409);
  assertEquals((await readJson(res)).error, 'Member was rejected');
});

Deno.test('approve-member: unknown user_id -> 404', async () => {
  const { admin } = setup();
  const res = await call(req({ user_id: 'does-not-exist' }, { token: admin.token }));
  assertEquals(res.status, 404);
});

Deno.test('approve-member: open student-ID collision blocks approval -> 409; resolved collision does not', async () => {
  const { w, admin, target } = setup();
  const other = w.member('other');
  const c = w.db.insertRow('student_id_collisions', {
    student_id: 'SID-target', new_user_id: target.userId, existing_user_id: other.userId, resolution_status: 'open',
  });
  const blocked = await call(req({ user_id: target.userId }, { token: admin.token }));
  assertEquals(blocked.status, 409);
  assertEquals(row(w, target.userId).is_pending, true);

  c.resolution_status = 'resolved';
  const ok = await call(req({ user_id: target.userId }, { token: admin.token }));
  assertEquals(ok.status, 200);
});

Deno.test('approve-member: approval merges prior guest attendance into the account', async () => {
  const { w, admin, target } = setup();
  const eventId = w.event();
  const guest = w.db.insertRow('guest_identities', { normalized_email: target.email });
  w.db.insertRow('guest_attendances', { event_id: eventId, guest_identity_id: guest.id, merged: false });
  const res = await call(req({ user_id: target.userId }, { token: admin.token }));
  assertEquals(res.status, 200);
  const att = w.db.tables.attendances.filter((a) => a.user_id === target.userId);
  assertEquals(att.length, 1);
  assertEquals(att[0].source, 'guest_merge');
  assertEquals(w.db.tables.guest_attendances[0].merged, true);
});
