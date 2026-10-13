# Contributing to Hoplite (SJSU Club Platform)

Thanks for helping. This project is intended to be forkable and contributor-friendly: local development must not require access to the club’s hosted Supabase project.

Please read the [Code of Conduct](CODE_OF_CONDUCT.md). For security issues, do **not** open a public issue — see [SECURITY.md](SECURITY.md).

## Ways to contribute

- Fix bugs or improve docs
- Add tests (frontend Vitest, pgTAP, or Edge Function Deno/HTTP)
- Implement a deferred product item from [`TO_DO.md`](TO_DO.md) / [`POST_MVP.md`](POST_MVP.md)
- Review pull requests and exercise the [`ACCEPTANCE_MATRIX.md`](ACCEPTANCE_MATRIX.md)

Good starting points:

1. Open issues labeled `good first issue` or `help wanted`
2. Unchecked items under **P2** / **P3** in [`TO_DO.md`](TO_DO.md)
3. Gaps marked **deferred** in [`MVP_STATUS.md`](MVP_STATUS.md) that already have backend support

## First-time setup (fork → PR)

1. Fork the repository on GitHub, then clone your fork.
2. Add the upstream remote (optional but recommended):

   ```bash
   git remote add upstream https://github.com/hoplitetechsjsu-lab/Hoplite-Website.git
   ```

3. Create a branch from an up-to-date `main`:

   ```bash
   git checkout -b your-short-description
   ```

4. Follow **Local development flow** below until `npm run dev` works.
5. Make a focused change; run the relevant checks in **Tests and checks**.
6. Push your branch and open a pull request against `hoplitetechsjsu-lab/Hoplite-Website` `main`.
7. Fill in the PR template. Respond to review feedback.

Keep PRs small and scoped. Large features should be discussed in an issue first.

## Requirements

- **Node 22** (pinned in `.nvmrc` and `engines`): `nvm use`
- Docker (running) and the **Supabase CLI** — **2.120 or newer** (older CLIs do not inject the key env vars the Edge Functions need locally)
- [Deno](https://deno.com) 2.x for the Edge Function unit tests

## Local development flow

1. Fork and clone the repo.
2. `nvm use && npm ci`
3. `supabase start` (Docker must be running).
4. `npm run db:reset` — rebuilds the local database from `supabase/migrations/` and seeds roles/teams plus local fixture events, projects, and members. Use `db:reset`, **never** `db push`, locally.
5. `cp .env.example .env.local` and set `VITE_SUPABASE_URL=http://127.0.0.1:54321` and `VITE_SUPABASE_PUBLISHABLE_KEY` from `supabase status` (use the publishable / anon key — never a service-role key).
6. `npm run dev`
7. For flows that call Edge Functions (Complete Profile, approvals, check-in), run `supabase functions serve` in another terminal.

See [`ENV_INVENTORY.md`](ENV_INVENTORY.md) for every environment variable and [`README.md`](README.md) for hosted setup.

### Local vs hosted database workflow

- **Local:** always `supabase db reset` so schema and fixtures are reproducible. Add schema changes as **new** numbered files in `supabase/migrations/`; do not edit applied migrations in place.
- **Hosted:** `supabase link` (via `export SUPABASE_PROJECT_REF=<ref>; npm run supabase:link`) and `supabase db push` are the remote-only path, normally run by maintainers. Never run `supabase/seed.sql` (local fixtures) against a hosted project.

## Tests and checks

| Command | What it covers | Needs |
| --- | --- | --- |
| `npm run lint` | ESLint | — |
| `npm run typecheck` | `tsc` over JS (has known pre-existing errors; do not add new ones — see `POST_MVP.md`) | — |
| `npm run build` | Production build (set `VITE_SUPABASE_URL` / `VITE_SUPABASE_PUBLISHABLE_KEY` to anything) | — |
| `npm run test:unit` (`npm test`) | Vitest + Testing Library, mocked Supabase client | — |
| `npm run db:test` | pgTAP: RLS, grants, RPCs, storage policies (`supabase/tests/`) | `supabase start` + `db:reset` |
| `npm run db:lint` | `supabase db lint` | running local DB |
| `npm run test:functions` | Deno unit tests for Edge Functions (mocked) | Deno |
| `npm run test:functions:http` | HTTP integration tests against the real local gateway | `supabase start`, `db:reset`, `supabase functions serve`, CLI ≥ 2.120 |
| `npm run check:secrets` | Secret-exposure guard (same script CI runs) | — |

Manual verification: [`ACCEPTANCE_MATRIX.md`](ACCEPTANCE_MATRIX.md). Project status: [`MVP_STATUS.md`](MVP_STATUS.md). Remaining work: [`TO_DO.md`](TO_DO.md) and [`POST_MVP.md`](POST_MVP.md).

## Continuous integration

`.github/workflows/ci.yml` runs on every pull request and on pushes to `main`:

| Job | Runs |
| --- | --- |
| `frontend` | `npm ci`, lint, typecheck (non-blocking for now), build with dummy env, `test:unit` |
| `database` | `supabase start`, `db reset`, `db lint`, `supabase test db` |
| `edge-functions` | `npm run test:functions` (Deno, mocked) |
| `edge-functions-http` | `supabase start`, `db reset`, `functions serve`, `test:functions:http` (non-blocking while it proves stable) |
| `secret-exposure` | `scripts/check-secret-exposure.sh` |

Maintainers choose which of these are required on `main`; see [`MAINTAINERS.md`](MAINTAINERS.md). CI cannot deploy anything: Edge Function and migration deployment to a hosted project is a separate maintainer step.

## Google OAuth

- **Local decision:** config/smoke only. `supabase/config.toml` has a disabled `[auth.external.google]` block; to smoke-test, enable it, add a client id, and set `SUPABASE_AUTH_EXTERNAL_GOOGLE_SECRET` (see `supabase/.env.example`). Email/password is the supported local sign-in path; the full OAuth round trip is not expected to work locally.
- **Hosted:** Google OAuth is mandatory and is verified on the hosted project (Supabase Dashboard → Authentication → Providers). See [`PHASE5_STAGING.md`](PHASE5_STAGING.md).

## Edge Functions

If you change anything under `supabase/functions/`, deploy with the Supabase CLI against the linked project (`npm run supabase:functions:deploy`) or note in your PR that a maintainer must. A missing function shows up as `OPTIONS … 404` in the browser — that is a deployment problem, not a frontend bug. Keep imports as `npm:@supabase/server` (never `esm.sh`).

## Security and privacy expectations

- Never commit `.env.local`, service-role keys, or other secrets. Never put secrets in `VITE_*` variables.
- The publishable key in the browser is expected; it does **not** protect the database — RLS, grants, and Edge Functions do. See [`SECURITY.md`](SECURITY.md).
- Do not expose `student_id`, private emails, guest identity, or audit data on public surfaces.
- Prefer server-side authorization (Postgres RLS / RPCs / Edge Functions) over frontend-only gating.

## Pull requests

- Keep PRs focused and fill in the PR template.
- Before opening: `npm run lint`, `npm run build`, `npm run test:unit`; plus `npm run db:reset && npm run db:test` if you touched migrations/seeds, and `npm run test:functions` if you touched Edge Functions.
- Changes under `supabase/` are reviewed by code owners (see `.github/CODEOWNERS`).
- If your change completes a [`TO_DO.md`](TO_DO.md) item, check it off (or note it) in the PR description.
