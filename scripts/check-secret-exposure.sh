#!/usr/bin/env bash
# Phase 6.2 — secret-exposure guard. Run locally (`npm run check:secrets`) and in CI.
# Scans files that git tracks (or would track: not ignored) for committed secrets.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

fail=0
report() { echo "::error::$1"; echo "FAIL: $1"; fail=1; }

# Tracked + untracked-but-not-ignored, excluding this script and lockfiles.
files() {
  git ls-files --cached --others --exclude-standard -z \
    | tr '\0' '\n' \
    | grep -Ev '^(package-lock\.json|scripts/check-secret-exposure\.sh|supabase/functions/_tests/deno\.lock)$' \
    | while read -r f; do [ -f "$f" ] && echo "$f"; done
}

scan() { # $1 = description, $2 = ERE
  local hits
  hits=$(files | xargs -r grep -InE -e "$2" 2>/dev/null || true)
  if [ -n "$hits" ]; then
    echo "$hits" | sed 's/^/  /'
    report "$1"
  fi
}

echo "== 1. .env files must not be tracked =="
tracked_env=$(git ls-files | grep -E '(^|/)\.env($|\.)' | grep -Ev '(^|/)\.env\.example$' || true)
if [ -n "$tracked_env" ]; then echo "$tracked_env" | sed 's/^/  /'; report "Env file(s) committed (only .env.example is allowed)"; fi
if git ls-files --error-unmatch .env.local >/dev/null 2>&1; then report ".env.local is committed"; fi

echo "== 2. Supabase secret keys (sb_secret_...) =="
scan "Supabase secret key (sb_secret_...) found in repo" 'sb_secret_[A-Za-z0-9_-]{16,}'

echo "== 3. JWT-shaped tokens (legacy anon/service_role keys) =="
scan "JWT-like token found in repo (legacy Supabase key?)" 'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'

echo "== 4. service_role key values assigned =="
scan "service_role / secret key assigned a literal value" '(SERVICE_ROLE(_KEY)?|SUPABASE_SECRET_KEY|SECRET_KEY)[A-Z_]*[[:space:]]*[=:][[:space:]]*["'\'']?(eyJ[A-Za-z0-9_-]{10,}|sb_secret_[A-Za-z0-9_-]{16,}|[A-Za-z0-9_-]{32,})'

echo "== 5. VITE_* variables must never carry privileged naming =="
scan "VITE_* variable with SERVICE_ROLE/SECRET naming (would be bundled into the browser)" 'VITE_[A-Z0-9_]*(SERVICE_ROLE|SECRET|PRIVATE)'

echo "== 6. Frontend must not reference service-role credentials =="
hits=$(files | grep -E '^(src/|index\.html|public/|vite\.config\.js)' | xargs -r grep -InEi 'service_role|sb_secret|SUPABASE_SECRET' 2>/dev/null || true)
if [ -n "$hits" ]; then echo "$hits" | sed 's/^/  /'; report "Privileged key reference in frontend code"; fi

echo "== 7. Private keys / other privileged tokens =="
scan "Private key block committed" '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----'
scan "Provider token committed (GitHub/AWS/Google/Stripe/Supabase PAT)" '(ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[0-9A-Z]{16}|sk_live_[A-Za-z0-9]{16,}|sbp_[a-f0-9]{40}|GOCSPX-[A-Za-z0-9_-]{20,})'

if [ "$fail" -ne 0 ]; then echo; echo "Secret-exposure check FAILED."; exit 1; fi
echo; echo "Secret-exposure check passed."
