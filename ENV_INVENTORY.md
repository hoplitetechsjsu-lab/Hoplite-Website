# Environment Inventory

Fork checklist: every value below must be parameterized or intentionally schema-constant. Do not commit real project refs, secrets, or club-specific hosted URLs.

## Frontend (Vite) — `.env.local` from root `.env.example`

| Variable | Purpose | Status |
| --- | --- | --- |
| `VITE_SUPABASE_URL` | Supabase API URL (local: `http://127.0.0.1:54321`, hosted: `https://<project-ref>.supabase.co`) | Parameterized |
| `VITE_SUPABASE_PUBLISHABLE_KEY` | Browser-safe publishable (anon) key | Parameterized |

Never put service-role / secret keys in `VITE_*` variables.

## Local Supabase — `supabase/config.toml` + CLI

| Item | Where | Status |
| --- | --- | --- |
| API URL | CLI default `http://127.0.0.1:54321` | Parameterized (local stack) |
| Studio | CLI default `http://127.0.0.1:54323` | Parameterized |
| Inbucket/Mailpit | CLI default (email capture) | Parameterized |
| DB | CLI default `postgresql://postgres:postgres@127.0.0.1:54322/postgres` | Parameterized |
| Auth site URL / redirect URLs | `config.toml` `[auth]` | Parameterized for local; hosted via Dashboard |
| Google OAuth client id/secret | `config.toml` `[auth.external.google]` via env | Parameterized; **local = config/smoke only** (full OAuth verified in hosted Phase 5) |
| JWT / anon / service keys | Printed by `supabase status` | Local-only; never commit |

## Edge Functions — auto-injected by Supabase runtime

| Variable | Purpose | Status |
| --- | --- | --- |
| `SUPABASE_URL` | Project URL | Platform-provided |
| `SUPABASE_ANON_KEY` / publishable | Client-grade key in functions | Platform-provided |
| `SUPABASE_SERVICE_ROLE_KEY` | Privileged server key | Platform-provided; never in frontend |
| CORS origins | `supabase/functions/_shared/cors.ts` | Currently `*` — document as intentional for MVP; tighten via env in POST_MVP if needed |

## Hosted / staging (Dashboard + secrets — not committed)

| Item | Status |
| --- | --- |
| Project ref | Parameterized via `SUPABASE_PROJECT_REF` / `supabase link` — **must not** be hardcoded in `package.json` / README examples |
| Site URL | Hosted app origin |
| Redirect URLs | `/`, `/reset-password`, OAuth callback |
| Google OAuth | Mandatory for deployment-verified MVP |
| SMTP / Auth email | Hosted provider config |
| Edge Function secrets | Dashboard / CLI |

## Storage bucket names (schema constants)

| Bucket | Public read | Client write | Status |
| --- | --- | --- | --- |
| `profile-photos` | No | Denied (service-role only) | Hardcoded schema id — keep; document |
| `project-images` | Yes | Denied | Hardcoded schema id |
| `site-assets` | Yes | Denied | Hardcoded schema id |
| `export-files` | No | Denied | Hardcoded schema id |

## Hardcoded → parameterized (Phase 6.1)

Done. No project ref is committed anywhere in the repo:

| Location | Now |
| --- | --- |
| `.env.example` | `https://<project-ref>.supabase.co` placeholder or local URL |
| `README.md`, `supabase/README.md` | `<project-ref>` / `$SUPABASE_PROJECT_REF` placeholders |
| `package.json` `supabase:link` | Requires `SUPABASE_PROJECT_REF` (fails if unset) |

## Auth redirect construction (runtime — OK)

| Location | Pattern |
| --- | --- |
| `src/pages/Register.jsx` | `window.location.origin + …` |
| `src/pages/Login.jsx` | `window.location.origin + …` |
| `src/pages/ForgotPassword.jsx` | `window.location.origin + "/reset-password"` |

## Which file feeds what

| Consumer | File |
| --- | --- |
| Vite frontend | `.env.local` (from root `.env.example`) |
| Local Supabase | `supabase/config.toml` + `supabase start` |
| Edge Functions (local) | Injected by `supabase functions serve` / local stack |
| Hosted frontend | Hosting provider env (`VITE_*` at build time) |
| Hosted Supabase | Dashboard + `supabase link` with `SUPABASE_PROJECT_REF` |

## Scope decision — Google OAuth local

**Decision: config/smoke.** Local `config.toml` includes an env-driven Google OAuth stanza so configuration is reproducible; full Google login is **not** required to pass local acceptance. Full Google OAuth is **mandatory** in Phase 5 (hosted/staging).
