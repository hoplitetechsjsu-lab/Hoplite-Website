// Minimal in-memory stand-in for the slice of supabase-js the Edge Functions use:
//   from(t).select().eq()...maybeSingle()/single(), insert().select().single(),
//   update().eq(), upsert(row, { onConflict, ignoreDuplicates }), rpc(), auth.getUser().
// It also mirrors the SQL semantics of the authorization RPCs closely enough for the
// functions' branching to be exercised (current_app_user_id, can_approve_membership).
// Real RLS / SQL behaviour is covered by supabase/tests/*.sql and the HTTP suite.

// deno-lint-ignore-file no-explicit-any
export type Row = Record<string, any>;

type DbError = { message: string; code?: string };
type Result = { data: any; error: DbError | null };

export interface RpcCall {
  client: 'caller' | 'admin';
  name: string;
  args: Row | undefined;
}

export interface AuthIdentity {
  id: string;
  email: string;
  email_confirmed_at: string | null;
}

// Unique constraints enforced on insert/upsert (mirrors 002_tables.sql).
const UNIQUE: Record<string, string[][]> = {
  users: [['auth_user_id'], ['email']],
  attendances: [['event_id', 'user_id']],
  guest_attendances: [['event_id', 'guest_identity_id']],
  guest_identities: [['normalized_email']],
  event_qr_tokens: [['token_hash']],
};

let seq = 0;
export const newId = (prefix = 'id') => `${prefix}-${++seq}`;

export class FakeDb {
  tables: Record<string, Row[]> = {
    users: [],
    role_assignments: [],
    roles: [{ id: 'role-membership-admin', key: 'membership_admin' }],
    student_id_collisions: [],
    event_qr_tokens: [],
    attendances: [],
    guest_identities: [],
    guest_attendances: [],
    audit_logs: [],
  };
  rpcCalls: RpcCall[] = [];
  /** Every write: { table, op, row } — handy for "nothing was written" assertions. */
  writes: { table: string; op: string; row: Row }[] = [];
  /** Force an error for a table/op, e.g. failNext('users','insert'). */
  private failures = new Map<string, string>();

  failNext(table: string, op: string, message: string) {
    this.failures.set(`${table}:${op}`, message);
  }
  takeFailure(table: string, op: string): string | undefined {
    const k = `${table}:${op}`;
    const m = this.failures.get(k);
    this.failures.delete(k);
    return m;
  }

  insertRow(table: string, row: Row): Row {
    this.tables[table] ??= [];
    for (const cols of UNIQUE[table] ?? []) {
      const dup = this.tables[table].some((r) => cols.every((c) => r[c] === row[c] && row[c] !== undefined));
      if (dup) throw { message: `duplicate key value violates unique constraint on ${table}(${cols.join(',')})`, code: '23505' };
    }
    const full = { id: newId(table), ...row };
    this.tables[table].push(full);
    this.writes.push({ table, op: 'insert', row: full });
    return full;
  }

  // -- DB-side semantics of the authorization RPCs --------------------------------
  currentAppUserId(authUserId: string): string | null {
    const u = this.tables.users.find(
      (r) => r.auth_user_id === authUserId && !r.is_pending && !r.is_deactivated && !r.is_rejected,
    );
    return u?.id ?? null;
  }
  canApproveMembership(authUserId: string): boolean {
    const uid = this.currentAppUserId(authUserId);
    if (!uid) return false;
    const role = this.tables.roles.find((r) => r.key === 'membership_admin');
    return this.tables.role_assignments.some(
      (ra) => ra.user_id === uid && ra.role_id === role?.id && ra.is_active,
    );
  }
  mergeGuestAttendance(userId: string): number {
    const user = this.tables.users.find((u) => u.id === userId);
    if (!user) return 0;
    const guest = this.tables.guest_identities.find(
      (g) => g.normalized_email === String(user.email).toLowerCase().trim(),
    );
    if (!guest) return 0;
    let n = 0;
    for (const ga of this.tables.guest_attendances.filter((g) => g.guest_identity_id === guest.id && !g.merged)) {
      const exists = this.tables.attendances.some((a) => a.event_id === ga.event_id && a.user_id === userId);
      if (!exists) {
        this.insertRow('attendances', { event_id: ga.event_id, user_id: userId, source: 'guest_merge' });
        n++;
      }
      ga.merged = true;
      ga.merged_into_user_id = userId;
    }
    return n;
  }
}

class Query implements PromiseLike<Result> {
  private op: 'select' | 'insert' | 'update' | 'upsert' = 'select';
  private payload: Row = {};
  private opts: Row = {};
  private filters: [string, any][] = [];
  private wantSingle: 'single' | 'maybe' | null = null;
  private returning = false;

  constructor(private db: FakeDb, private table: string) {}

  select(_cols?: string) {
    this.returning = true;
    return this;
  }
  insert(row: Row) { this.op = 'insert'; this.payload = row; return this; }
  update(row: Row) { this.op = 'update'; this.payload = row; return this; }
  upsert(row: Row, opts: Row = {}) { this.op = 'upsert'; this.payload = row; this.opts = opts; return this; }
  eq(col: string, val: any) { this.filters.push([col, val]); return this; }
  maybeSingle() { this.wantSingle = 'maybe'; return this; }
  single() { this.wantSingle = 'single'; return this; }

  // Anything the real postgrest-js builder lacks must fail loudly here too — this is
  // exactly the class of bug (insert().onConflict()) the HTTP suite originally caught.
  // Because the fake simply doesn't define such methods, calling them throws TypeError.

  private matches(r: Row) { return this.filters.every(([c, v]) => r[c] === v); }

  private run(): Result {
    const t = this.table;
    const forced = this.db.takeFailure(t, this.op);
    if (forced) return { data: null, error: { message: forced } };
    this.db.tables[t] ??= [];
    try {
      let rows: Row[];
      if (this.op === 'select') {
        rows = this.db.tables[t].filter((r) => this.matches(r)).map((r) => ({ ...r }));
      } else if (this.op === 'insert') {
        rows = [this.db.insertRow(t, this.payload)].map((r) => ({ ...r }));
      } else if (this.op === 'upsert') {
        const cols = String(this.opts.onConflict ?? 'id').split(',').map((s) => s.trim());
        const existing = this.db.tables[t].find((r) => cols.every((c) => r[c] === this.payload[c]));
        if (existing) {
          if (this.opts.ignoreDuplicates) rows = [];
          else { Object.assign(existing, this.payload); this.db.writes.push({ table: t, op: 'update', row: existing }); rows = [{ ...existing }]; }
        } else {
          rows = [{ ...this.db.insertRow(t, this.payload) }];
        }
      } else {
        const hit = this.db.tables[t].filter((r) => this.matches(r));
        for (const r of hit) { Object.assign(r, this.payload); this.db.writes.push({ table: t, op: 'update', row: r }); }
        rows = hit.map((r) => ({ ...r }));
      }
      if (this.wantSingle === 'maybe') return { data: rows[0] ?? null, error: null };
      if (this.wantSingle === 'single') {
        return rows.length === 1
          ? { data: rows[0], error: null }
          : { data: null, error: { message: 'JSON object requested, multiple (or no) rows returned', code: 'PGRST116' } };
      }
      return { data: this.op === 'select' || this.returning ? rows : null, error: null };
    } catch (e) {
      return { data: null, error: e as DbError };
    }
  }

  then<R1 = Result, R2 = never>(
    ok?: ((v: Result) => R1 | PromiseLike<R1>) | null,
    err?: ((r: any) => R2 | PromiseLike<R2>) | null,
  ): PromiseLike<R1 | R2> {
    return Promise.resolve().then(() => this.run()).then(ok, err);
  }
}

export function makeClient(db: FakeDb, kind: 'caller' | 'admin', identity: AuthIdentity | null) {
  return {
    from: (table: string) => new Query(db, table),
    rpc: (name: string, args?: Row): Promise<Result> => {
      db.rpcCalls.push({ client: kind, name, args });
      let data: any = null;
      switch (name) {
        case 'current_app_user_id':
          data = identity ? db.currentAppUserId(identity.id) : null;
          break;
        case 'can_approve_membership':
          data = identity ? db.canApproveMembership(identity.id) : false;
          break;
        case 'merge_guest_attendance_into_user':
          data = db.mergeGuestAttendance(args?.p_user_id);
          break;
        case 'log_audit':
          db.tables.audit_logs.push({ ...args });
          break;
        case 'recalculate_membership':
          break;
        default:
          return Promise.resolve({ data: null, error: { message: `unknown rpc ${name}` } });
      }
      return Promise.resolve({ data, error: null });
    },
    auth: {
      getUser: () =>
        Promise.resolve(
          identity
            ? { data: { user: identity }, error: null }
            : { data: { user: null }, error: { message: 'no session' } },
        ),
    },
  };
}
