# Supabase backend — SJSU Club Platform

Deployable Supabase artifacts for the Vite/React frontend. The frontend uses the
**publishable key** only; the secret key lives only in the Edge Function
environment. All privileged operations run server-side.

> **Status: ready to deploy — NOT security-verified** until migrations, RLS, and
> Edge Functions are applied and the tests below pass against the live project.

## Local development (Docker)

```bash
supabase start        # local Postgres/Auth/Storage/Edge runtime
supabase db reset     # migrations 001…008 + seeds from config.toml [db.seed]
```

- Use `supabase db reset` locally — **not** `db push` — so schema and fixtures are reproducible.
- Seeds run in order: `seed_roles_and_teams.sql` (roles, teams, approval rules), then `seed.sql` (**local fixtures only**: published/unpublished events and projects, fixture members and role assignments).
- Fixture members have fixed `auth_user_id` values but no `auth.users` row (there is no FK), so they appear in public charts but **cannot log in**. Login-based tests need a helper that creates auth users (see `POST_MVP.md`).
- Local email is captured by Inbucket/Mailpit (`http://127.0.0.1:54324`).
- Google OAuth is **config/smoke only** locally (disabled `[auth.external.google]` block in `config.toml`; secret via `supabase/.env`, see `.env.example`). Hosted Google OAuth is mandatory.
- Public discovery (migration 008): published events/projects and the leadership/project chart views are readable by `anon`. Unpublished rows and student IDs/emails stay private.
- See `../ENV_INVENTORY.md` for all environment variables.

## Deploy order (hosted project — remote-only path)

> `supabase link` and `supabase db push` target a **hosted** project. They are not part of the local workflow. Never apply `seed.sql` (fixtures) to hosted.

1. Set the project ref in your shell: `export SUPABASE_PROJECT_REF=<project-ref>`, then `npm run supabase:link`.
2. Apply migrations `migrations/001` → `008` in order (`supabase db push` or SQL Editor).
3. Apply `seed_roles_and_teams.sql` only (creates the `membership_admin` role).
4. Deploy Edge Functions (required — source in this repo is not live until deployed):

   ```bash
   npm run supabase:functions:deploy
   ```

5. Supabase Dashboard → Authentication → enable Email + Google (mandatory on hosted); set email-
   confirmation redirect to `<app-origin>/` and password-reset to
   `<app-origin>/reset-password`.
6. Confirm platform secrets exist under Edge Functions → Secrets
   (`SUPABASE_SECRET_KEYS`, `SUPABASE_PUBLISHABLE_KEYS` — usually auto-provisioned).
7. **Bootstrap the first admin (one-time, owner-only):** after the target person
   signs up and verifies email, run as the database owner:

   ```sql
   select public.bootstrap_first_admin('<verified-auth-user-uuid>'::uuid);
   drop function public.bootstrap_first_admin(uuid);  -- optional
   ```

8. Frontend env: `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY`
   (publishable only — never a secret key).

## Registration flow

1. Sign up (email/password or Google) → verify email.
2. Authenticated user submits student ID via `register-member` → pending row.
3. A `membership_admin` approves/rejects via `approve-member` / `reject-member`.

`register-member` derives the caller from the JWT; `auth_user_id` is never
accepted from the body.

## Edge Functions

| Function | Purpose |
| --- | --- |
| `register-member` | Pending `users` row for the authenticated caller |
| `approve-member` | Admin approval |
| `reject-member` | Admin rejection (requires reason) |
| `check-in-guest` / `check-in-user` | QR check-in |

Imports must use `npm:@supabase/server` (see `functions/_shared/supabase.ts`).
Vite excludes this directory from the frontend build.

### CORS / 404 diagnosis

If the browser shows `OPTIONS /functions/v1/register-member → 404`, the function
is not deployed (or is on a different project than `VITE_SUPABASE_URL`). Deploy
it; do not change student-ID handling until `OPTIONS` returns 200/204 and a
`POST` appears in the logs.

### Edge Function tests (Phase 2.15 / 2.16)

**Unit tests (2.15)** — Deno, no network/DB. `npm run test:functions` (needs [Deno](https://deno.com) 2.x; `brew install deno`).
`supabase/functions/_tests/deno.json` import-maps `npm:@supabase/server` to
`_tests/mocks/supabase-server.ts`, a deterministic `createSupabaseContext` backed by an
in-memory fake (`_tests/mocks/fake-supabase.ts`). Bearer `valid:<authId>` = verified JWT,
`junk`/`expired`/none = 401. The directory is `_tests` (underscore) so the Supabase CLI never treats it as a function.

**HTTP integration (2.16)** — real gateway + Edge Runtime + Auth + Postgres.

1. `supabase start` and `npm run db:reset` (roles seed required).
2. In another terminal: `supabase functions serve`.
   **Use Supabase CLI >= 2.120.** Older CLIs (2.78 verified) do not inject
   `SUPABASE_PUBLISHABLE_KEYS` / `SUPABASE_SECRET_KEYS` into the local Edge Runtime, so every
   `createSupabaseContext` call fails with `No default publishable key found`
   (and `--env-file` cannot set `SUPABASE_*` names). The suite detects this and aborts with that message.
3. `npm run test:functions:http` (`scripts/test-functions-http.mjs`, Node `node:test`).
   Keys come from `supabase status -o env` (or `API_URL` / `PUBLISHABLE_KEY` / `SERVICE_ROLE_KEY`).
   Users are created through the Auth Admin API; test rows are tagged per run and deleted afterwards.
   The "unverified email" case flips `auth.users.email_confirmed_at` via `docker exec <db container> psql`
   (override the container with `DB_CONTAINER`).

Locally, Kong answers `OPTIONS` itself, so the CORS regression test proves the preflight returns 200/204 with
`authorization, content-type, apikey, x-client-info` allowed; on hosted projects `OPTIONS` reaches the
function, which is covered by the unit tests (`callerContext`/`publicContext`).

## Student ID privacy

Stored as nullable private text (max 32 chars). Readable only by the user or
site admins. Never returned by queue RPCs, charts, or Edge Function responses.

## Test plan (before calling the deploy "verified")

1. Unauthorized `bootstrap_first_admin` is denied for non-owners.
2. Non-admin `get_admin_member_queue` returns empty; anon denied.
3. Admin approval works once; self-approval and re-approval rejected.
4. Rejection requires a reason; rejected users cannot act.
5. Pending users cannot read member-only data via RLS.
6. Anonymous users can read published events/projects and the chart views, but not unpublished rows, `users`, or `profiles` (migration 008).

## pgTAP tests (`supabase/tests/`)

Run with the local stack up and the seed loaded (`supabase start` → `npm run db:reset`), then `npm run db:test` (`supabase test db`).

- One file per Phase 2 area (`001_public_discovery` … `012_exports`); each runs in a single rolled-back transaction, so the database is left unchanged.
- Each file embeds the same small `tests.*` harness. `tests.n` / `tests.err` / `tests.js` temporarily switch to `anon` / `authenticated` / `service_role` and set the JWT `sub` claim; fixture members from `seed.sql` can be impersonated by their `auth_user_id` (no `auth.users` row needed).
- Tests marked `TODO` document known gaps (see "pgTAP findings" in `POST_MVP.md`); `skip` marks behaviour that lives in Edge Functions and is deferred.
