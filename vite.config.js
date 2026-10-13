import path from 'node:path'
import { fileURLToPath } from 'node:url'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

// Supabase Edge Functions (supabase/functions/**) are Deno modules deployed via
// the Supabase CLI — they are NOT part of the frontend bundle. Vite cannot
// resolve Deno-only `npm:` specifiers (e.g. npm:@supabase/server), so stub any
// accidental import under supabase/ and keep those files out of the graph.
const excludeSupabaseFromVite = () => ({
  name: 'exclude-supabase-from-vite',
  enforce: 'pre',
  load(id) {
    if (id.includes(`${path.sep}supabase${path.sep}`) || id.includes('/supabase/')) {
      return 'export default {};'
    }
  },
})

export default defineConfig({
  plugins: [excludeSupabaseFromVite(), react()],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
  server: {
    fs: {
      // Never serve Edge Function sources through the Vite dev server.
      deny: ['**/supabase/functions/**'],
    },
  },
})
