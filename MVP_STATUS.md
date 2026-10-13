# MVP status ledger

Every proposal subsystem ends in exactly one terminal state:

- **implemented-and-verified** — built, and automated tests in this repo exercise it
- **deferred** — not built or not verified; rationale in `POST_MVP.md`
- **removed** — intentionally taken out of scope

"In the proposal but unaddressed" is forbidden.

_Last verified locally: `npm run db:test` (368), `npm run test:unit` (48), `npm run test:functions` (73), `npm run build`. Hosted Phase 5 is separate (`PHASE5_STAGING.md`)._

## Public surface

| Subsystem | Status | Evidence |
| --- | --- | --- |
| Public website home | implemented-and-verified | Vitest `public-pages`, `app-routes`; routes public |
| About | implemented-and-verified | Vitest + `/about` |
| Published upcoming/historical events | implemented-and-verified | Vitest public list; pgTAP `001`, `008` |
| Published active/completed projects | implemented-and-verified | Vitest; pgTAP `001`, `008` |
| Current leadership (public-safe) | implemented-and-verified | Vitest leadership chart; pgTAP `001`; migration `008` |
| Historical leadership UI | deferred | View exists; no UI — `POST_MVP.md` |
| Project team charts UI | deferred | View exists; no UI — `POST_MVP.md` |
| Membership registration/auth entry points | implemented-and-verified | Pages exist; Complete Profile Vitest; register-member Deno+HTTP |
| Student ID / private fields never public | implemented-and-verified | pgTAP `001`–`002`; Vitest private-field checks |

## Auth & membership

| Subsystem | Status | Evidence |
| --- | --- | --- |
| Email/password auth pages | deferred (frontend tests) | Implemented; page unit tests deferred — `POST_MVP.md` |
| Email confirmation (local Mailpit) | implemented-and-verified | `config.toml` confirmations on; local stack |
| Password recovery pages | deferred (E2E) | Pages exist; E2E in acceptance matrix |
| Google OAuth local | deferred | config/smoke only — `POST_MVP.md` |
| Google OAuth hosted | deferred | Mandatory Phase 5 — `PHASE5_STAGING.md` |
| Profile completion → `register-member` | implemented-and-verified | Vitest + Deno + HTTP |
| Pending membership state | implemented-and-verified | pgTAP + Vitest gating |
| Membership approval/rejection UI | implemented-and-verified | Vitest `admin-members` |
| Membership approval/rejection Edge Functions | implemented-and-verified | Deno + HTTP suites |
| Bootstrap first admin | implemented-and-verified | pgTAP `004`; migration `007` |
| Rolling 30-day membership (≥2) | implemented-and-verified | pgTAP `003` |
| Student-ID privacy | implemented-and-verified | pgTAP `002`; migration `009` column guard |
| Member attendance/roles dashboard (full) | deferred | Minimal Home panel only — `POST_MVP.md` |
| Deactivation workflow UI | deferred | Schema + RLS; no UI — `POST_MVP.md` |

## Roles

| Subsystem | Status | Evidence |
| --- | --- | --- |
| Full role matrix (seed + permission functions) | implemented-and-verified | Seed + pgTAP `005`, `006` |
| Role-request RPCs (limits, withdraw, approve/reject) | implemented-and-verified | pgTAP `005`, `007`; self-approve denied (`009`) |
| Role-request UI | deferred | `POST_MVP.md` |
| Unique-role replacement + history | implemented-and-verified | pgTAP `007`; trigger in `009` |

## Events / attendance / QR

| Subsystem | Status | Evidence |
| --- | --- | --- |
| Event RLS + published/unpublished | implemented-and-verified | pgTAP `001`, `006`, `008` |
| Event admin UI CRUD handlers | deferred | Visibility only — `POST_MVP.md` |
| QR check-in Edge Functions | implemented-and-verified | Deno + HTTP; upsert fix |
| QR / guest check-in UI | deferred | `POST_MVP.md` |
| Guest merge (SQL + on approval) | implemented-and-verified | pgTAP `009`; Edge HTTP |

## Projects

| Subsystem | Status | Evidence |
| --- | --- | --- |
| Project RLS + PM edit assigned | implemented-and-verified | pgTAP `006`; `009` F4 fix |
| Project admin UI CRUD handlers | deferred | `POST_MVP.md` |
| Project rollover RPC/UI | deferred | Schema-level only — `POST_MVP.md` |

## Storage / media / exports / audit

| Subsystem | Status | Evidence |
| --- | --- | --- |
| Storage buckets + policies + MIME/size | implemented-and-verified | pgTAP `010`; migration `009` |
| Profile/media upload UI | deferred | `POST_MVP.md` |
| Exports generation + UI | deferred | Table/RLS only — `POST_MVP.md` |
| Audit append-only | implemented-and-verified | pgTAP `011`; migration `009` |
| Audit viewer UI | deferred | `POST_MVP.md` |

## Platform

| Subsystem | Status | Evidence |
| --- | --- | --- |
| Reproducible local env (Node 22, start, db reset, seed) | implemented-and-verified | README; migrations+seed on start |
| DB lint + pgTAP | implemented-and-verified | `db:lint`, `db:test` |
| Edge Function unit + HTTP tests | implemented-and-verified | `test:functions`, `test:functions:http` |
| Frontend Vitest | implemented-and-verified | `test:unit` |
| Local acceptance matrix (manual) | deferred | `ACCEPTANCE_MATRIX.md` unchecked |
| Hosted/staging verification (Phase 5) | deferred | Blocks deployment-verified MVP — `PHASE5_STAGING.md` |
| CI + contributor readiness (Phase 6) | implemented-and-verified | `.github/`, `SECURITY.md`, `MAINTAINERS.md` (this phase) |

## Removed

| Item | Notes |
| --- | --- |
| Base44 integration | Compatibility stubs only in `AuthContext` |
| Member-only gating of public Home/Events/Projects | Replaced by public discovery (`008`) |
| Hardcoded Supabase project ref in templates/scripts | Parameterized via `SUPABASE_PROJECT_REF` / placeholders |
