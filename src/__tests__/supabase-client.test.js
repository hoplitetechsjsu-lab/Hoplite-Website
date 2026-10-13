import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'

// Real supabaseClient.js (not the shared mock); only createClient is stubbed.
const createClient = vi.fn(() => ({ __client: true }))
vi.mock('@supabase/supabase-js', () => ({ createClient }))

describe('supabaseClient env guard', () => {
  beforeEach(() => vi.resetModules())
  afterEach(() => vi.unstubAllEnvs())

  it('throws a helpful error when the URL is missing', async () => {
    vi.stubEnv('VITE_SUPABASE_URL', '')
    vi.stubEnv('VITE_SUPABASE_PUBLISHABLE_KEY', 'pk')
    await expect(import('@/lib/supabaseClient')).rejects.toThrow(/Missing VITE_SUPABASE_URL or VITE_SUPABASE_PUBLISHABLE_KEY/)
    expect(createClient).not.toHaveBeenCalled()
  })

  it('throws when the publishable key is missing', async () => {
    vi.stubEnv('VITE_SUPABASE_URL', 'http://127.0.0.1:54321')
    vi.stubEnv('VITE_SUPABASE_PUBLISHABLE_KEY', '')
    await expect(import('@/lib/supabaseClient')).rejects.toThrow(/Missing VITE_SUPABASE_URL/)
  })

  it('creates the client with only the url + publishable key', async () => {
    vi.stubEnv('VITE_SUPABASE_URL', 'http://127.0.0.1:54321')
    vi.stubEnv('VITE_SUPABASE_PUBLISHABLE_KEY', 'pk-test')
    const mod = await import('@/lib/supabaseClient')
    expect(mod.supabase).toEqual({ __client: true })
    expect(createClient).toHaveBeenCalledWith('http://127.0.0.1:54321', 'pk-test', expect.objectContaining({ auth: expect.any(Object) }))
  })
})

describe('vitest shares vite.config.js behaviour', () => {
  it('resolves the @ alias', async () => {
    const mod = await import('@/lib/utils')
    expect(mod).toBeTruthy()
  })

  it('stubs supabase/** modules via exclude-supabase-from-vite (Deno code is never executed)', async () => {
    const mod = await import('../../supabase/functions/_shared/cors.ts')
    expect(mod.default).toEqual({})
  })
})
