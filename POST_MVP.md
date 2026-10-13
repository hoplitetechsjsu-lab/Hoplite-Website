# Post-MVP backlog

Items intentionally deferred from the MVP. Move an item out of this file when it is scheduled.

## Auth

- **Full local Google OAuth flow.** Locally, Google OAuth is config/smoke only (disabled `[auth.external.google]` block in `supabase/config.toml`; email/password is the supported local sign-in path). Making the complete OAuth round trip work against the local stack is deferred. Hosted Google OAuth is **mandatory** and is verified in the hosted deployment phase (Phase 5).

## Testing

- ~~Test helper that creates real `auth.users`~~ — **done for Edge Functions** (`scripts/test-functions-http.mjs` uses the Auth Admin API). `supabase/seed.sql` fixture members still have no `auth.users` rows and cannot sign in; a reusable helper for other suites is deferred.
- ~~pgTAP tests under `supabase/tests/`~~ — **done for Phase 2.2–2.14** (`npm run db:test`, 12 files, 368 assertions). Findings F1–F10 from the first run were fixed in migration `009_security_remediation.sql` and are now real (non-`todo`) assertions; remaining items are deferred here.

### Deferred pgTAP / integration coverage (not verifiable in SQL yet)

- ~~**2.5 Edge Function approval flow**~~ — **done** (2.15 Deno unit tests + 2.16 HTTP tests: self-approval 400, non-pending 409, open collision 409, `membership_admin` requirement, guest merge on approval, audit row). The pgTAP skips in `004_approval_bootstrap.test.sql` remain as pointers.
- ~~**2.11 Check-in Edge Functions**~~ — **done** (2.15 + 2.16: 404/410/401/403, idempotent duplicates, guest merge eligibility). Token hashing/uniqueness and table locks are also covered in SQL.
- **2.12 Storage**: signed-URL issuance and per-user profile-photo ownership are Storage API / Edge Function behaviour. Skipped in `010_storage_policies.test.sql`. Bucket file-size/MIME limits are undefined (TODO test).
- **2.14 Exports** (`export_jobs`): only the table, enum and RLS exist; there is **no export RPC or Edge Function**. Deferred: per-export-type authorization matrix, CSV contents (no `student_id`; emails only where allowed), file expiry/signed URLs, `generate_export` audit row. Skipped in `012_exports.test.sql` (which also fails a NOTE test as soon as an export function appears, prompting real tests).
- **2.10 Project rollover**: no rollover RPC exists. Rollover is only asserted at schema/RLS level (same project row, semester/year update, team carries over). Revisit if an RPC is added.
- **Concurrency** (two simultaneous approvals of a unique role, quota races on role requests) cannot be asserted in single-transaction pgTAP.
- **2.4 Time-based rolling window** is asserted via fixed `now()` inside a transaction (inclusive 30-day boundary); wall-clock decay over days is not simulated end to end.

### Edge Function tests (2.15 / 2.16) — status and deferrals

Done: `npm run test:functions` (73 Deno tests, mocked) and `npm run test:functions:http` (48 HTTP tests against local `supabase functions serve`). Deferred:

- **CI wiring.** `npm run test:functions` runs in CI (`edge-functions` job). The HTTP suite runs in the `edge-functions-http` job (Docker + `supabase start` + `functions serve`, Supabase CLI >= 2.120 via `supabase/setup-cli`) but is `continue-on-error` and not a required check until it has proven stable (see `MAINTAINERS.md`). Pin `SUPABASE_CLI_VERSION` in `.github/workflows/ci.yml` to an exact version once one is blessed (currently `latest`).
- **Hosted/deployed smoke test.** The HTTP suite targets the local stack. Running it against a hosted project (real `OPTIONS` reaching the function, verify_jwt at the platform) is part of Phase 5; the script reads `API_URL`/keys from env but its SQL-based "unverified email" case and cleanup assume local access.
- **Real-SDK contract test.** Unit tests mock `@supabase/server`; JWT verification itself (JWKS, `kid`, expiry) is only exercised end-to-end through the HTTP suite (invalid/garbage/publishable-key bearer). An expired-but-signed JWT HTTP case is not covered (needs a signing key or a clock override).
- **Concurrency.** Simultaneous approvals / duplicate check-ins racing are not tested (the duplicate check-in path is covered sequentially and by the DB unique constraints).
- **`check-in-user` does not check the event itself** (only the QR token's `is_active`/`expires_at`). "Closed event" is therefore tested as a deactivated token; if events can end without deactivating tokens, add an event-time check and tests.
- **Bug found and fixed by these tests:** `check-in-user` and `check-in-guest` called `insert(...).onConflict(...).doNothing()`, which does not exist in postgrest-js (every check-in returned HTTP 500). Replaced with `upsert(..., { ignoreDuplicates: true })`. **Redeploy** the two functions (`npm run supabase:functions:deploy`) for hosted environments.

### pgTAP findings

**No open findings.** F1–F10 were remediated in `supabase/migrations/009_security_remediation.sql` and are verified by regular pgTAP assertions (their former `todo` markers are removed):

- F1/F7/F9: privileged `SECURITY DEFINER` RPCs (`get_admin_member_queue`, `recalculate_membership`, `merge_guest_attendance_into_user`, `log_audit`) revoked from `PUBLIC`/`anon` (and `authenticated` where only Edge Functions/triggers call them; `service_role` keeps EXECUTE).
- F2/F3: `trg_protect_users_sensitive` blocks client roles from changing membership flags (`is_pending`, `is_rejected`, `is_deactivated`, `approved_*`, `email_verified`, `auth_user_id`) and `student_id`/`email`; approval stays with `approve-member` (service_role).
- F4: `proj_select` includes `can_edit_project(id)`.
- F5: trigger `trg_single_active_high_level_role` (a partial unique index cannot reference `roles`) rejects a second active holder of a high-level unique role.
- F6: requirement decided — `approve_role_request` / `reject_role_request` deny acting on one's own request.
- F8: 5 MiB + image MIME limits on `profile-photos`/`project-images`/`site-assets`; `export-files` limited to CSV/JSON (20 MiB). Revisit if the export implementation needs other types.
- F10: UPDATE/DELETE/TRUNCATE revoked on `audit_logs`; `trg_audit_no_update`/`trg_audit_no_delete` make it immutable even for the owner (only the FK `ON DELETE SET NULL` of `actor_user_id` is allowed).

Test-suite note: `005` and `006` temporarily disable the F5 trigger during fixture setup because they intentionally create extra holders of unique roles (including pending/deactivated ones).

- ~~Real unit tests behind `npm run test:unit`~~ — **done**: Vitest + Testing Library + jsdom with a mocked Supabase client (`src/__tests__/`, `src/test/`). These verify client behaviour only, not RLS or Edge Functions.

### Deferred frontend verification

- Component tests for `Login`, `Register`, `ForgotPassword`, `ResetPassword` (implemented, not covered by automated tests).
- Events/Projects **create/edit/delete handlers** (only control visibility and the public/draft listing are tested).
- Browser/E2E smoke against the local stack (`supabase start` + `npm run dev`): see `ACCEPTANCE_MATRIX.md` — items are unchecked until someone runs them.

## Product (not built; backend may exist)

- **Exports UI / generation** — only the `export_jobs` table exists (see 2.14 above).
- Member profile page (edit name/LinkedIn/photo) and profile-photo upload UI (Storage policies exist and have pgTAP coverage; no frontend).
- Public **project org charts** (`project_chart_current`) and **leadership history** (`leadership_chart_history`) UI. Views exist; only `leadership_chart_current` is rendered (on Home). Leadership photos are not rendered (profile photo access/URLs undecided).
- Role request / approval UI (`submit_role_request` … RPCs exist; no frontend).
- QR check-in / guest check-in UI (Edge Functions `check-in-user`, `check-in-guest` exist and have Deno unit + HTTP tests; no frontend).
- Member attendance / membership-status dashboard (rolling membership is computed in SQL only).
- Audit log viewer.
- Project rollover UI/RPC.

## Cleanup

- **Typecheck debt.** `npm run typecheck` (`tsc -p jsconfig.json`) reports ~177 pre-existing errors, mostly from untyped JS shadcn/ui wrappers (props inferred as `RefAttributes<any>`, e.g. `Label`, `Input`, `Button` children) and `AuthLayout`'s required `footer` prop (`ResetPassword`). CI runs typecheck as non-blocking (`continue-on-error` in the `frontend` job). Fix by adding JSDoc prop types / `React.ComponentPropsWithoutRef` wrappers and making `footer` optional, then remove `continue-on-error`. Do not add new errors.
- **Pin Supabase CLI in CI** to an exact >= 2.120 version instead of `latest`.

- Wix image helpers (`src/components/ui/image-helpers.js`, `image.jsx`) are legacy; document or replace with Supabase Storage URLs. Not rewritten during Base44 cleanup.
- `AuthContext` still exposes `isLoadingPublicSettings: false` / `appPublicSettings: null` as legacy compatibility stubs (Base44 removed); remove once no call sites read them.
- Tighten Edge Function CORS (`supabase/functions/_shared/cors.ts`, currently `*`) via env.
