# Maintainers guide

Repository setup and operations for people with admin access. Contributors: see [`CONTRIBUTING.md`](CONTRIBUTING.md).

## One-time repository placeholders

Replace before publishing:

- `.github/CODEOWNERS`: `@OWNER` → your user/team.
- `.github/ISSUE_TEMPLATE/config.yml` and `SECURITY.md`: `OWNER/REPO`, `<SECURITY_CONTACT_EMAIL>`.
- `CODE_OF_CONDUCT.md`: `<CONDUCT_CONTACT_EMAIL>`.

## GitHub settings

### Branch protection for `main`

Settings → Branches → Add rule (or a Ruleset) for `main`:

- ✅ **Require a pull request before merging**
  - ✅ Require approvals: **1** (2 for changes under `supabase/` if you have the maintainers)
  - ✅ **Require review from Code Owners** (`supabase/` is owned in `.github/CODEOWNERS`)
  - ✅ Dismiss stale approvals when new commits are pushed
- ✅ **Require status checks to pass before merging**
  - ✅ **Require branches to be up to date before merging**
  - Required checks (names are the job names in `.github/workflows/ci.yml`):

    | Check | Required? | Why |
    | --- | --- | --- |
    | `frontend` | **Yes** | lint, build, unit tests. Typecheck inside it is `continue-on-error` until the known errors are fixed |
    | `database` | **Yes** | migrations apply cleanly, `db lint`, all pgTAP (RLS/grants) |
    | `edge-functions` | **Yes** | Deno unit tests, no Docker, stable |
    | `secret-exposure` | **Yes** | blocks committed secrets / privileged `VITE_*` |
    | `edge-functions-http` | **Not yet** | Docker + `functions serve`; marked `continue-on-error`. Make it required (and remove `continue-on-error`) after it has been green for a couple of weeks |

  - A job only appears in the "add required check" search after it has run once on a PR or push.
- ✅ Require conversation resolution before merging
- ✅ **Do not allow bypassing** the above settings (include administrators)
- ✅ **Block force pushes** and deletions
- ✅ Restrict direct pushes to `main` (everything goes through a PR)

### Other settings

- **Actions:** Settings → Actions → General → allow Actions; set workflow permissions to **read-only** (the workflow declares `contents: read`). Fork PR workflows should require approval for first-time contributors.
- **Issues:** enabled. The templates in `.github/ISSUE_TEMPLATE/` disable blank issues and route vulnerabilities to private reporting.
- **Labels:** create `bug`, `enhancement` (used by templates), plus **`good first issue`** and **`help wanted`**. Also useful: `database`, `edge-functions`, `frontend`, `security`, `docs`.
- **Private vulnerability reporting:** Settings → Code security → enable "Private vulnerability reporting" (referenced by `SECURITY.md`).
- **Dependabot:** `.github/dependabot.yml` updates npm and GitHub Actions weekly. Enable Dependabot alerts and security updates under Code security. Dependabot PRs run the same CI; review `supabase/`-adjacent bumps (e.g. `@supabase/supabase-js`) with the Edge Functions in mind.
- **Secret scanning + push protection:** enable both (free for public repos). `secret-exposure` is a second line of defense.
- Enable "Automatically delete head branches" and prefer squash merges.

## Deployment notes

CI **never deploys**. Merging to `main` does not update Supabase.

- **Migrations:** `export SUPABASE_PROJECT_REF=<ref>; npm run supabase:link; supabase db push`. Never run `supabase/seed.sql` against hosted. Apply `seed_roles_and_teams.sql` once (safe for hosted).
- **Edge Functions:** `npm run supabase:functions:deploy` after any change under `supabase/functions/`. Check the PR template box "Edge Function changes". A missing deploy shows as `OPTIONS … 404`.
- **Secrets:** `supabase secrets set NAME=value`. `SUPABASE_URL` and keys are injected by the platform. Never use `VITE_*` for secrets.
- **Frontend hosting:** set `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` in the host's build env.
- **Auth config** (Site URL, redirect URLs, SMTP, Google OAuth) lives in the Supabase Dashboard, not in git.
- **Before calling a deployment verified**, complete [`PHASE5_STAGING.md`](PHASE5_STAGING.md).
- If a key leaks, follow the "If a secret leaks" steps in [`SECURITY.md`](SECURITY.md).

## Reviewing changes under `supabase/`

Check: new migration file (applied ones untouched); RLS enabled on new tables; no new grants to `anon`/`PUBLIC` on privileged functions; views never expose `student_id`/`email`; pgTAP coverage added; Edge Function changes noted for deploy.
