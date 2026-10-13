import { defineConfig, mergeConfig } from 'vitest/config'
import viteConfig from './vite.config.js'

// Reuses vite.config.js wholesale so tests share the `@` alias, the React
// plugin, and the `exclude-supabase-from-vite` plugin (supabase/** modules are
// stubbed, never executed — Edge Functions are Deno code, not frontend code).
export default mergeConfig(
  viteConfig,
  defineConfig({
    test: {
      environment: 'jsdom',
      globals: true,
      setupFiles: ['./src/test/setup.js'],
      include: ['src/**/*.test.{js,jsx}'],
      exclude: ['node_modules/**', 'dist/**', 'supabase/**'],
      css: false,
      clearMocks: true,
      // Dummy public-safe values so modules importing the real supabase client
      // never hit the env guard by accident. The guard itself is tested in
      // src/lib/supabaseClient.test.js by overriding these.
      env: {
        VITE_SUPABASE_URL: 'http://127.0.0.1:54321',
        VITE_SUPABASE_PUBLISHABLE_KEY: 'test-publishable-key',
      },
    },
  }),
)
