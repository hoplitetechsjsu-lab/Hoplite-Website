# SJSU Club Platform (Hoplite)

Open-source club website for membership registration, admin approvals, events, and projects. Built with **Vite**, **React**, and **Supabase** (Auth, Postgres/RLS, Edge Functions).

**Contributing:** see [`CONTRIBUTING.md`](CONTRIBUTING.md) (fork → local setup → tests → PR).  
**Remaining work:** [`TO_DO.md`](TO_DO.md) · deferred detail in [`POST_MVP.md`](POST_MVP.md) · status in [`MVP_STATUS.md`](MVP_STATUS.md).

## Stack

- Frontend: Vite + React + Tailwind + React Router
- Backend: Supabase Auth, Postgres with RLS, Edge Functions (`npm:@supabase/server`)

## Prerequisites

- Node.js **22** (see `.nvmrc`; `nvm use`). `package.json` enforces `>=22 <23`.
- [Docker](https://docs.docker.com/get-docker/) (required for the local Supabase stack)
- [Supabase CLI](https://supabase.com/docs/guides/cli) (`brew install supabase/tap/supabase`)
- A hosted Supabase project is only needed for deploy/verification (not for local development)

## Local development (recommended)

```bash
nvm use                 # Node 22
npm ci
supabase start          # needs Docker; prints API URL + publishable key
npm run db:reset        # = supabase db reset: applies migrations 001…009 + seed
cp .env.example .env.local
# Edit .env.local: set VITE_SUPABASE_URL=http://127.0.0.1:54321 and
# VITE_SUPABASE_PUBLISHABLE_KEY from `supabase status`
npm run dev
```

Open the URL Vite prints (usually `http://localhost:5173`). Local email (confirmation, password reset) is captured in the Inbucket/Mailpit UI at `http://127.0.0.1:54324`.

Use `supabase db reset` (not `db push`) locally so every developer gets the same schema and fixture data. `supabase db push` and `supabase link` are for the **hosted** project only.

Google OAuth is **config/smoke only** locally; the full OAuth round trip is mandatory and verified on the hosted project. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

Public pages (published events, projects, leadership/project charts) are readable without signing in; unpublished content and private member data stay protected by RLS.

## Hosted project setup

Only for deploying to a real Supabase project. Create a project, then:

```bash
export SUPABASE_PROJECT_REF=<your-project-ref>   # Dashboard → Project Settings → General
supabase login
npm run supabase:link
```

Set `VITE_SUPABASE_URL=https://<project-ref>.supabase.co` and the publishable key in `.env.local` (or your hosting provider's env). See [`ENV_INVENTORY.md`](ENV_INVENTORY.md) for every variable.

## Deploy Edge Functions (required)

Editing files under `supabase/functions/` does **not** deploy them. A missing function causes:

```text
OPTIONS /functions/v1/register-member → 404
```

The browser never sends the real `POST` until the function exists. Deploy from the project root:

```bash
supabase login
export SUPABASE_PROJECT_REF=<your-project-ref>
npm run supabase:link
npm run supabase:functions:deploy
```

Or deploy one function:

```bash
npm run supabase:functions:deploy:register
```

After a successful deploy, `register-member` is available at:

```text
https://<project-ref>.supabase.co/functions/v1/register-member
```

`OPTIONS` should return `200`/`204` with CORS headers; then the client `POST` from Complete Profile can run.

### Interpreting logs after deploy

| Result | Meaning |
| --- | --- |
| `OPTIONS` 200/204 + `POST` 401 | Auth / JWT issue |
| `OPTIONS` 200/204 + `POST` 400 | Request body / student ID |
| `POST` 409 | Membership already exists |
| `POST` 500 | Function runtime / secrets / SQL |
| `OPTIONS` 404 | Still missing, misnamed, or wrong project |

Edge Functions must import `@supabase/server` with the official specifier:

```ts
import { createSupabaseContext } from 'npm:@supabase/server';
```

Do not use `https://esm.sh/@supabase/server` — that can break Deno Deploy builds. Vite is configured to ignore `supabase/functions/` so the frontend build does not try to parse Deno `npm:` imports.

## Database

**Local:** `supabase start` then `npm run db:reset`. This applies `supabase/migrations/001…008` and then the seeds listed in `supabase/config.toml` (`seed_roles_and_teams.sql`, then `seed.sql` with local-only fixtures).

**Hosted (remote-only path):** `supabase link` + `supabase db push`, or run `migrations/001 … 008` in the SQL Editor, then `seed_roles_and_teams.sql`. Do **not** run `seed.sql` on a hosted project (fixture data).

See [`supabase/README.md`](supabase/README.md) for bootstrap admin, RLS notes, and the security test plan.

## Scripts

| Script | Purpose |
| --- | --- |
| `npm run dev` | Frontend only (local or hosted Supabase, per `.env.local`) |
| `npm run build` | Production frontend build |
| `npm run lint` | ESLint |
| `npm test` / `npm run test:unit` | Vitest + Testing Library + jsdom (mocked Supabase client; tests in `src/__tests__/`, helpers in `src/test/`) |
| `npm run test:watch` | Vitest in watch mode |
| `npm run supabase:start` / `supabase:stop` | Start/stop the local Supabase stack (Docker) |
| `npm run db:reset` | Rebuild the local DB from migrations + seed |
| `npm run db:lint` | `supabase db lint` against the local DB |
| `npm run db:test` | `supabase test db` (pgTAP; 12 files under `supabase/tests/`; needs `db:reset` seed fixtures) |
| `npm run typecheck` | `tsc` over JS (known pre-existing errors; non-blocking in CI) |
| `npm run test:functions` / `test:functions:http` | Edge Function Deno unit tests / HTTP integration tests (local stack) |
| `npm run check:secrets` | Secret-exposure guard (also runs in CI) |
| `npm run supabase:link` | Link CLI to a hosted project (requires `SUPABASE_PROJECT_REF`) |
| `npm run supabase:functions:deploy` | Deploy all Edge Functions (hosted) |

## Contributing and security

See [`CONTRIBUTING.md`](CONTRIBUTING.md), [`MAINTAINERS.md`](MAINTAINERS.md) (branch protection, required CI checks), [`SECURITY.md`](SECURITY.md), and [`PHASE5_STAGING.md`](PHASE5_STAGING.md) (hosted verification).

## License

MIT — see [LICENSE](LICENSE).
