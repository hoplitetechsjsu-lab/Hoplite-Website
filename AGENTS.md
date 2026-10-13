# AGENTS.md

## Project Context

Open-source SJSU club website (Vite + React frontend, Supabase backend). Keep changes focused on the user's request and match existing conventions.

Start with `README.md` for local setup, env vars, and Edge Function deployment.

## Key Paths

- `src/` — frontend application
- `src/lib/supabaseClient.js` — Supabase browser client (publishable key only)
- `src/lib/AuthContext.jsx` / `src/lib/authAdapter.jsx` — auth provider
- `supabase/migrations/` — Postgres schema, RLS, RPCs (applied in order; local via `db reset`)
- `supabase/seed*.sql` — roles/teams seed + local fixtures; `supabase/config.toml` `[db.seed]` wires them
- `supabase/functions/` — Deno Edge Functions (deploy with Supabase CLI)
- `vite.config.js` — Vite + `@` alias; excludes `supabase/functions` from the bundle

## Working Notes

- Node 22 is pinned (`.nvmrc`, `engines`). Use `nvm use`.
- Local backend workflow: Docker running → `supabase start` → `npm run db:reset` (**not** `db push`) → `npm ci` → `npm run dev` with `.env.local` pointing at `http://127.0.0.1:54321`.
- `supabase link` / `db push` are the **remote-only** path. Set `SUPABASE_PROJECT_REF` in the environment; never hardcode a project ref in the repo.
- Schema changes go in a new `supabase/migrations/NNN_*.sql` file (additive); do not edit applied migrations. Local seeds: `supabase/seed_roles_and_teams.sql` (safe for hosted) then `supabase/seed.sql` (local fixtures only).
- Public discovery is intentional (migration 008): published events/projects and the curated charts are anon-readable; chart views must never expose `student_id`/`email`.
- Google OAuth: local = config/smoke only; hosted is mandatory. See `CONTRIBUTING.md`, `POST_MVP.md`, and `ENV_INVENTORY.md`.
- Edge Functions are **not** deployed by editing this repo alone. After changing `supabase/functions/`, run `npm run supabase:functions:deploy` (or deploy a single function).
- Keep Edge Function imports as `npm:@supabase/server` — never `esm.sh`.
- Never put secret/service-role keys in `VITE_*` env vars or frontend code.
- Prefer fixing deployment/routing (`OPTIONS` 404) before changing student-ID validation or RLS.
- Run `npm run lint` / `npm run build` before finishing frontend changes.
