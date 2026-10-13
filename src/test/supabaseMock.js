import { vi } from 'vitest'

// In-memory stand-in for the Supabase browser client. Usage in a test file:
//
//   vi.mock('@/lib/supabaseClient', () => import('@/test/supabaseMock'))
//   import { supabase, mockDb } from '@/test/supabaseMock'
//
// It honours `.eq()` filters and column projection (like PostgREST), so a test
// can assert that unpublished rows are never requested AND that columns that
// were not selected (e.g. student_id) never come back.

const defaults = () => ({ tables: {}, rpc: {}, invoke: {} })
let db = defaults()
export const queries = []

export const mockDb = {
  reset() {
    db = defaults()
    queries.length = 0
  },
  setTable(name, rows) {
    db.tables[name] = rows
  },
  // value or (args) => value
  setRpc(name, value) {
    db.rpc[name] = value
  },
  // { data, error } or (body) => ({ data, error })
  setInvoke(name, result) {
    db.invoke[name] = result
  },
}

function project(row, columns) {
  if (!columns || columns.trim() === '*') return { ...row }
  const out = {}
  for (const c of columns.split(',').map((x) => x.trim())) {
    if (c in row) out[c] = row[c]
  }
  return out
}

function queryBuilder(table) {
  const q = { table, columns: null, filters: [] }
  queries.push(q)
  const run = () => {
    let rows = db.tables[table] ?? []
    for (const [k, v] of q.filters) rows = rows.filter((r) => r[k] === v)
    return rows.map((r) => project(r, q.columns))
  }
  const b = {
    select: (cols) => { q.columns = cols; return b },
    eq: (k, v) => { q.filters.push([k, v]); return b },
    order: () => b,
    limit: () => b,
    maybeSingle: () => Promise.resolve({ data: run()[0] ?? null, error: null }),
    single: () => Promise.resolve({ data: run()[0] ?? null, error: null }),
    then: (resolve, reject) => Promise.resolve({ data: run(), error: null }).then(resolve, reject),
  }
  return b
}

export const supabase = {
  from: vi.fn((table) => queryBuilder(table)),
  rpc: vi.fn((name, args) => {
    const v = db.rpc[name]
    const data = typeof v === 'function' ? v(args) : v
    return Promise.resolve({ data: data ?? null, error: null })
  }),
  functions: {
    invoke: vi.fn((name, opts) => {
      const r = db.invoke[name]
      const res = typeof r === 'function' ? r(opts?.body) : r
      return Promise.resolve(res ?? { data: {}, error: null })
    }),
  },
  auth: {
    getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
    getUser: vi.fn(() => Promise.resolve({ data: { user: null } })),
    onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe() {} } } })),
    signOut: vi.fn(() => Promise.resolve({})),
  },
}
