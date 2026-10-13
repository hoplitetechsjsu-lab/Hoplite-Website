# TO DO

Actionable remaining work after the code-complete MVP. Every item should end as **done**, **moved to `POST_MVP.md` with rationale**, or **removed**. Do not leave proposal requirements unaddressed.

Status sources:

- [`MVP_STATUS.md`](MVP_STATUS.md) — subsystem terminal states
- [`POST_MVP.md`](POST_MVP.md) — deferred backlog detail
- [`PHASE5_STAGING.md`](PHASE5_STAGING.md) — hosted verification checklist
- [`ACCEPTANCE_MATRIX.md`](ACCEPTANCE_MATRIX.md) — local manual acceptance

---

## P0 — Blocks deployment-verified MVP

These are required before calling the product production-ready. Code-complete local MVP does **not** require them.

- [ ] Complete [`PHASE5_STAGING.md`](PHASE5_STAGING.md) against a **staging** Supabase project
  - [ ] Apply migrations (`db push`); seed roles/teams only (never `seed.sql` on hosted)
  - [ ] Deploy all Edge Functions; confirm `OPTIONS` → 200/204 + CORS from the real frontend origin
  - [ ] Configure Site URL / redirect URLs; verify email confirmation + password recovery delivery
  - [ ] Full **Google OAuth** (hosted mandatory)
  - [ ] Bootstrap first admin; smoke public/member/admin workflows
  - [ ] Confirm no secrets or service-role keys in the frontend bundle
- [ ] Enable GitHub branch protection on `main` (see [`MAINTAINERS.md`](MAINTAINERS.md))
  - [ ] Require PR + required CI: `frontend`, `database`, `edge-functions`, `secret-exposure`
  - [ ] Require review / Code Owners for `supabase/`
- [ ] Replace remaining maintainer placeholders (monitored security contact in [`SECURITY.md`](SECURITY.md) / [`MAINTAINERS.md`](MAINTAINERS.md); CODEOWNERS team when an org team exists)

---

## P1 — Product gaps (backend exists; UI missing)

Track detail in [`POST_MVP.md`](POST_MVP.md). Prefer smallest viable UI + a Vitest test.

- [ ] Role request / approval UI (`submit_role_request`, approve/reject/withdraw)
- [ ] QR member + guest check-in UI
- [ ] Member profile edit + photo upload (Storage)
- [ ] Member attendance / rolling membership dashboard
- [ ] Public project org chart + leadership history UI
- [ ] Events/Projects create/edit/delete handlers (visibility exists; handlers deferred)
- [ ] Exports generation + CSV download UI (or keep deferred with explicit rationale)
- [ ] Audit log viewer (read-only for authorized roles)
- [ ] Project rollover RPC/UI (or keep deferred)
- [ ] Member deactivation UI

---

## P2 — Verification & quality

- [ ] Run and tick [`ACCEPTANCE_MATRIX.md`](ACCEPTANCE_MATRIX.md) against local stack
- [ ] Frontend tests for Login / Register / ForgotPassword / ResetPassword
- [ ] Make `npm run typecheck` blocking in CI (clear ~177 JSDoc/shadcn errors — see `POST_MVP.md`)
- [ ] Promote `edge-functions-http` CI job to a required check once stable
- [ ] Pin Supabase CLI version in CI (exact ≥ 2.120 instead of `latest`)
- [ ] Reusable `auth.users` test helper for login-based suites (seed fixtures cannot sign in)

---

## P3 — Cleanup

- [ ] Remove Base44 compatibility stubs (`isLoadingPublicSettings`, `appPublicSettings`) once unused
- [ ] Replace Wix image helpers with Supabase Storage URLs
- [ ] Tighten Edge Function CORS allowlist via env (currently `*`)
- [ ] Event-closed check in `check-in-user` (token-only today)

---

## Done recently (do not re-open without cause)

- Public discovery RLS/views (`008`) + security remediation (`009`)
- Local reproducible env (Node 22, `supabase start`, `db reset`, seeds)
- pgTAP (368), Vitest (48), Edge Function Deno (73) + HTTP suites
- Public Home / About / Events / Projects + leadership chart
- Contributor docs, CI, issue/PR templates, `SECURITY.md`, Code of Conduct

---

## How to pick up work

1. Read [`CONTRIBUTING.md`](CONTRIBUTING.md).
2. Prefer items labeled good first issue / help wanted on GitHub, or a single checkbox above.
3. Open a focused PR; note any Edge Function deploy needs in the PR template.
