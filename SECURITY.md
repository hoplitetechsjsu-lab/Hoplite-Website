# Security Policy

## What is (and is not) secret

This is a browser app backed by Supabase. Be precise about what each key does:

- **The publishable key (`VITE_SUPABASE_PUBLISHABLE_KEY`, `sb_publishable_…`) is safe to expose** in the browser bundle. It identifies the project and lets clients call the API — nothing more.
- **The publishable key does _not_ protect the database.** Access control is enforced by **Row Level Security (RLS) policies, table/function grants, and Edge Functions** (`supabase/migrations/`, `supabase/functions/`). Anyone can read the key from the bundle and call the API directly, so every table and RPC must be safe against an anonymous or arbitrary authenticated caller.
- **Secret / service-role keys (`sb_secret_…`, `SUPABASE_SERVICE_ROLE_KEY`, legacy `service_role` JWT) bypass RLS and must never be committed**, put in `VITE_*` variables, or shipped to the browser. They live only in Supabase Edge Function secrets or maintainers' local environments.
- Public discovery of published events/projects and curated leadership charts is intentional. Chart views must never expose `student_id` or `email`.

CI (`secret-exposure` job, `npm run check:secrets`) fails if secret-looking values, a committed `.env.local`, or privileged `VITE_*` names are found. This is a safety net, not a substitute for care.

## Supported versions

Only the current `main` branch (and the deployed site built from it) receives security fixes.

## Reporting a vulnerability

**Please do not open a public issue, pull request, or discussion for security problems.**

1. Preferred: use GitHub's private reporting — **Security → Report a vulnerability** on this repository: <https://github.com/hoplitetechsjsu-lab/Hoplite-Website/security/advisories/new> (enable private vulnerability reporting in repo settings if needed).
2. If private reporting is unavailable, contact the maintainers through a private channel listed in `MAINTAINERS.md` — do not file a public issue.

Please include:

- A description of the issue and its impact (for example: "anonymous user can read `users.student_id`").
- Reproduction steps or a proof of concept (request, SQL, or Edge Function call). Use a local stack or your own test project — do not test against other people's data.
- Affected files/migrations/functions if known.

Out of scope: findings that only apply to a fork's misconfiguration, missing hardening headers on third-party hosting, or the publishable key being visible in the bundle (expected).

## What to expect

- Acknowledgement within a few days; we will keep you updated on triage and fix status.
- Please allow time to fix and deploy before public disclosure. We will credit reporters who want it.

## If a secret leaks

1. **Rotate immediately** in the Supabase Dashboard (API keys) or the relevant provider; removing it from git history is not enough.
2. Redeploy Edge Functions / update secrets so the new key is in use.
3. Review `audit_logs` and Auth logs for misuse, then notify maintainers.
