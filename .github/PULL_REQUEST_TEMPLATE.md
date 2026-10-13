## Summary

<!-- What does this change and why? Link related issues (Fixes #123). -->

## Checklist

- [ ] `npm run lint` passes
- [ ] `npm run typecheck` — no **new** errors (known pre-existing errors are tracked in `POST_MVP.md`)
- [ ] `npm run build` passes
- [ ] Tests pass: `npm run test:unit`, and as relevant `npm run db:test`, `npm run test:functions` (`test:functions:http` if Edge Functions changed)
- [ ] No secrets committed: no `.env.local`, service-role / `sb_secret_*` keys, or JWTs; no secrets in `VITE_*` (`npm run check:secrets`)
- [ ] Schema changes are a **new** `supabase/migrations/NNN_*.sql` file (applied migrations are not edited) and `npm run db:reset` works
- [ ] **Edge Function changes** (`supabase/functions/`): deployed to the hosted project, or noted below that a maintainer must run `npm run supabase:functions:deploy`
- [ ] Docs updated where behaviour, env vars, or setup changed

## Edge Function / deployment notes

<!-- "N/A", or: functions changed + whether they must be (re)deployed, new secrets, redirect/CORS changes. -->

## Screenshots / test notes

<!-- UI changes: before/after. Anything reviewers should try manually. -->
