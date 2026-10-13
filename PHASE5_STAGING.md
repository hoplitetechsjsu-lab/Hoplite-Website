# Phase 5 — hosted / staging verification checklist

**Status: not done.** Nothing below is ticked until someone runs it against a real hosted Supabase project and real frontend origin.

## What this phase does and does not block

- **Phase 5 blocks calling the product _deployment-verified_ or _production-ready_.** Local tests (pgTAP, Deno, mocked Vitest, local HTTP) do not prove the hosted project, DNS/redirects, email delivery, or Google OAuth work.
- **A code-complete MVP is reachable without live credentials.** Phases 1–4 and 6 (code, tests, CI, docs) can be finished and merged with only the local stack. Phase 5 needs a hosted project, a deployed frontend origin, and Google OAuth credentials, so it is a maintainer task.

Use a staging project first; repeat the relevant rows on production.

Setup: `export SUPABASE_PROJECT_REF=<ref>`, `supabase login`, `npm run supabase:link`.

## 1. Database

- [ ] `supabase db push` applies every migration in `supabase/migrations/` without error
- [ ] `seed_roles_and_teams.sql` applied; `supabase/seed.sql` **not** applied
- [ ] Bootstrap first admin (migration `007`; see `supabase/README.md`) and confirm that user is a membership admin
- [ ] Anonymous API call to `users` / `members`-type tables returns no private rows; `leadership_chart_current` response has no `student_id` or `email`
- [ ] Storage buckets exist with the expected public/private settings and limits

## 2. Edge Functions

- [ ] `npm run supabase:functions:deploy` succeeds for all functions (`register-member`, `approve-member`, `reject-member`, `check-in-user`, `check-in-guest`)
- [ ] `OPTIONS /functions/v1/register-member` from the real frontend origin returns 200/204 (not 404) with CORS headers allowing `authorization, content-type, apikey, x-client-info`
- [ ] Unauthenticated `POST` returns 401; a signed-in `POST` with a valid student ID returns success
- [ ] Function logs show no `No default publishable key found` or secret/config errors
- [ ] Redeployed after the check-in `upsert` fix (see `POST_MVP.md`)

## 3. Secrets and keys

- [ ] Function secrets set via `supabase secrets set` (none committed)
- [ ] Frontend host has only `VITE_SUPABASE_URL` + `VITE_SUPABASE_PUBLISHABLE_KEY`
- [ ] Built bundle contains no `sb_secret_`, `service_role`, or `eyJ…` service JWT (`grep` the deployed JS)
- [ ] Legacy anon/service JWT keys disabled or rotated if previously exposed
- [ ] CI `secret-exposure` green on the release commit

## 4. Auth configuration and redirects

- [ ] Dashboard → Authentication → URL Configuration: **Site URL** = real frontend origin
- [ ] Redirect URLs include `/`, `/reset-password`, and the OAuth callback for that origin
- [ ] Email signup + confirmation works end to end
- [ ] Password reset email arrives (hosted SMTP configured, not the default rate-limited sender for production) and `/reset-password` completes
- [ ] CORS: browser requests from the real origin succeed; other origins behave as intended (CORS is currently `*`; see `POST_MVP.md`)

## 5. Google OAuth (mandatory)

- [ ] Google Cloud OAuth client created; authorized redirect URI = `https://<project-ref>.supabase.co/auth/v1/callback`
- [ ] Provider enabled in Dashboard with client id + secret
- [ ] New Google user: sign in → Complete Profile → pending → approved by admin → member
- [ ] Returning Google user signs in and lands on the correct page; `returnTo` redirect works
- [ ] Email/password and Google accounts with the same email behave as intended (linking/duplicate policy decided)

## 6. Product flows on hosted

- [ ] Run [`ACCEPTANCE_MATRIX.md`](ACCEPTANCE_MATRIX.md) against the hosted frontend (new user → pending → approve/reject → editor roles)
- [ ] Approve and reject members; audit rows are written
- [ ] Publish an event/project: visible to anonymous; draft is not

## 7. QR check-in end to end

- [ ] Create an event + active QR token; member scans → attendance recorded
- [ ] Duplicate scan is idempotent; expired/deactivated token rejected (404/410)
- [ ] Guest check-in works, and the guest merges into the user on approval
- [ ] (Optional) run `npm run test:functions:http` with `API_URL` / keys pointed at a **staging** project (see `POST_MVP.md` for caveats; never production)

## 8. No secret exposure (final pass)

- [ ] Network tab on every public page: no `student_id`, no email, no privileged keys
- [ ] Repository history and PRs contain no keys; secret scanning alerts are clear
- [ ] `SECURITY.md` contact and private reporting are live

## Sign-off

| Environment | Date | Verified by | Commit | Notes |
| --- | --- | --- | --- | --- |
|  |  |  |  |  |

When all sections are ticked for production, update `MVP_STATUS.md` ("Hosted/staging verification" and "Google OAuth hosted" → implemented-and-verified).
