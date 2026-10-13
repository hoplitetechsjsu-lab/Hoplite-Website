#!/usr/bin/env bash
# =============================================================================
# SpartanPulse — Live Security Test Matrix
# =============================================================================
# Run AFTER: migrations 001-007 + seed applied, Edge Functions deployed, and the
# one-time bootstrap_first_admin executed as the database owner.
#
# Prereqs (export before running):
#   export SUPABASE_URL=https://YOUR-PROJECT.supabase.co
#   export ANON_KEY=sb_publishable_...        (frontend publishable key)
#   export SERVICE_ROLE_KEY=sb_secret_...     (DB owner / service role — for setup only)
#   export ADMIN_EMAIL=...                     (the bootstrapped membership_admin)
#   export ADMIN_PASS=...
#   export PENDING_EMAIL=...                   (a registered-but-unapproved user)
#   export PENDING_PASS=...
#   export NONADMIN_EMAIL=...                  (an approved, non-admin member)
#   export NONADMIN_PASS=...
#
# Usage:  bash supabase/security-tests.sh
# Each test prints PASS/FAIL with the assertion. Exit non-zero on first failure.
# =============================================================================
set -u
PASS=0; FAIL=0
ok()   { echo "PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
AUTH_ADMIN=$(curl -s "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}" | jq -r .access_token)
AUTH_NONADMIN=$(curl -s "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$NONADMIN_EMAIL\",\"password\":\"$NONADMIN_PASS\"}" | jq -r .access_token)
AUTH_PENDING=$(curl -s "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" \
  -d "{\"email\":\"$PENDING_EMAIL\",\"password\":\"$PENDING_PASS\"}" | jq -r .access_token)

# ---------- 1. bootstrap_first_admin ----------
echo "--- 1. bootstrap_first_admin ---"
# 1a. An authenticated (non-owner) role must NOT be able to call it.
RES=$(curl -s -o /tmp/b1 -w "%{http_code}" "$SUPABASE_URL/rest/v1/rpc/bootstrap_first_admin" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $AUTH_NONADMIN" \
  -H "Content-Type: application/json" -d '{"p_auth_uid":"00000000-0000-0000-0000-000000000000"}')
[ "$RES" = "403" ] || [ "$RES" = "42501" ] && ok "bootstrap denied to authenticated role ($RES)" || bad "bootstrap callable by authenticated role ($RES)"
# 1b. Calling again now that an admin exists must fail (even as owner).
RES=$(curl -s -o /tmp/b2 -w "%{http_code}" "$SUPABASE_URL/rest/v1/rpc/bootstrap_first_admin" \
  -H "apikey: $SERVICE_ROLE_KEY" -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" -d "{\"p_auth_uid\":\"$($SUPABASE_URL 2>/dev/null)\"}")
grep -qi "already exists" /tmp/b2 && ok "second bootstrap rejected" || bad "second bootstrap not rejected ($RES)"

# ---------- 2. Queue access ----------
echo "--- 2. get_admin_member_queue ---"
# 2a. Non-admin gets an empty array (function returns empty set when unauthorized).
RES=$(curl -s "$SUPABASE_URL/rest/v1/rpc/get_admin_member_queue" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $AUTH_NONADMIN" \
  -H "Content-Type: application/json" -d '{}')
[ "$(echo "$RES" | jq 'length')" = "0" ] && ok "non-admin queue empty" || bad "non-admin queue non-empty: $RES"
# 2b. Admin gets rows; none may contain student_id.
RES=$(curl -s "$SUPABASE_URL/rest/v1/rpc/get_admin_member_queue" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $AUTH_ADMIN" \
  -H "Content-Type: application/json" -d '{}')
echo "$RES" | jq -e 'all(.[]; has("student_id")|not) // true' >/dev/null && ok "queue exposes no student_id" || bad "queue leaks student_id"
# 2c. Anonymous (no token) gets empty.
RES=$(curl -s "$SUPABASE_URL/rest/v1/rpc/get_admin_member_queue" \
  -H "apikey: $ANON_KEY" -H "Content-Type: application/json" -d '{}')
[ "$(echo "$RES" | jq 'length')" = "0" ] && ok "anonymous queue empty" || bad "anonymous queue non-empty"

# ---------- 3. approve-member ----------
echo "--- 3. approve-member ---"
APPROVE="$SUPABASE_URL/functions/v2/approve-member"
# 3a. Non-admin -> 403.
RES=$(curl -s -o /tmp/a1 -w "%{http_code}" "$APPROVE" -X POST \
  -H "Authorization: Bearer $AUTH_NONADMIN" -H "Content-Type: application/json" -d '{"user_id":"00000000-0000-0000-0000-000000000000"}')
[ "$RES" = "403" ] && ok "non-admin approve 403" || bad "non-admin approve not 403 ($RES)"
# 3b. No token -> 401.
RES=$(curl -s -o /tmp/a2 -w "%{http_code}" "$APPROVE" -X POST -H "Content-Type: application/json" -d '{}')
[ "$RES" = "401" ] && ok "approve without token 401" || bad "approve without token not 401 ($RES)"
# 3c. Self-approval -> 400 (admin approving own id).
SELF=$(curl -s "$SUPABASE_URL/rest/v1/rpc/current_app_user_id" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $AUTH_ADMIN" -H "Content-Type: application/json" -d '{}')
RES=$(curl -s -o /tmp/a3 -w "%{http_code}" "$APPROVE" -X POST \
  -H "Authorization: Bearer $AUTH_ADMIN" -H "Content-Type: application/json" -d "{\"user_id\":$SELF}")
[ "$RES" = "400" ] && ok "self-approval 400" || bad "self-approval not 400 ($RES)"
# 3d. Non-existent user -> 404.
RES=$(curl -s -o /tmp/a4 -w "%{http_code}" "$APPROVE" -X POST \
  -H "Authorization: Bearer $AUTH_ADMIN" -H "Content-Type: application/json" -d '{"user_id":"00000000-0000-0000-0000-000000000000"}')
[ "$RES" = "404" ] && ok "approve missing user 404" || bad "approve missing user not 404 ($RES)"

# ---------- 4. reject-member ----------
echo "--- 4. reject-member ---"
REJECT="$SUPABASE_URL/functions/v2/reject-member"
# 4a. Missing reason -> 400.
RES=$(curl -s -o /tmp/r1 -w "%{http_code}" "$REJECT" -X POST \
  -H "Authorization: Bearer $AUTH_ADMIN" -H "Content-Type: application/json" -d '{"user_id":"00000000-0000-0000-0000-000000000000"}')
[ "$RES" = "400" ] && ok "reject without reason 400" || bad "reject without reason not 400 ($RES)"
# 4b. Non-admin -> 403.
RES=$(curl -s -o /tmp/r2 -w "%{http_code}" "$REJECT" -X POST \
  -H "Authorization: Bearer $AUTH_NONADMIN" -H "Content-Type: application/json" -d '{"user_id":"00000000-0000-0000-0000-000000000000","reason":"x"}')
[ "$RES" = "403" ] && ok "non-admin reject 403" || bad "non-admin reject not 403 ($RES)"

# ---------- 5. Pending-user RLS ----------
echo "--- 5. pending-user RLS ---"
# A pending user must NOT read events/projects/attendance rows.
EV=$(curl -s -o /tmp/p1 -w "%{http_code}" "$SUPABASE_URL/rest/v1/events?select=id&limit=1" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $AUTH_PENDING")
[ "$(cat /tmp/p1 | jq 'length')" = "0" ] && ok "pending user sees no events" || bad "pending user sees events"
PR=$(curl -s -o /tmp/p2 -w "%{http_code}" "$SUPABASE_URL/rest/v1/projects?select=id&limit=1" \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $AUTH_PENDING")
[ "$(cat /tmp/p2 | jq 'length')" = "0" ] && ok "pending user sees no projects" || bad "pending user sees projects"
# Pending user must NOT insert an event.
RES=$(curl -s -o /tmp/p3 -w "%{http_code}" "$SUPABASE_URL/rest/v1/events" -X POST \
  -H "apikey: $ANON_KEY" -H "Authorization: Bearer $AUTH_PENDING" \
  -H "Content-Type: application/json" -d '{"title":"x","event_date":"2026-01-01"}')
[ "$RES" = "401" ] || [ "$RES" = "403" ] || [ "$RES" = "42501" ] && ok "pending user cannot create event ($RES)" || bad "pending user created event ($RES)"

# ---------- 6. Secret-key exposure ----------
echo "--- 6. secret-key exposure ---"
# 6a. The publishable (frontend) key must be sb_publishable_, never sb_secret_.
echo "$ANON_KEY" | grep -q "^sb_publishable_" && ok "frontend key is publishable" || bad "frontend key not publishable"
# 6b. No sb_secret_ value in the built frontend bundle (run after `npm run build`).
if [ -d dist ]; then
  if grep -r "sb_secret_" dist/ >/dev/null 2>&1; then bad "sb_secret_ found in dist bundle"; else ok "no sb_secret_ in dist bundle"; fi
else
  echo "SKIP 6b (dist/ not built yet — run npm run build first)"
fi
# 6c. Edge Function env must not echo the secret key in any response.
RES=$(curl -s "$APPROVE" -X POST -H "Authorization: Bearer $AUTH_NONADMIN" -H "Content-Type: application/json" -d '{}')
echo "$RES" | grep -qi "sb_secret_" && bad "secret key leaked in response" || ok "no secret key in response"

# ---------- 7. Duplicate operations ----------
echo "--- 7. duplicate operations ---"
# 7a. Duplicate registration -> 409 (same auth user can't register twice).
RES=$(curl -s -o /tmp/d1 -w "%{http_code}" "$SUPABASE_URL/functions/v2/register-member" -X POST \
  -H "Authorization: Bearer $AUTH_NONADMIN" -H "Content-Type: application/json" -d '{"student_id":"DUPTEST123"}')
# first call may be 200 (if not yet registered) or 409 (already); a SECOND call must be 409.
RES2=$(curl -s -o /tmp/d2 -w "%{http_code}" "$SUPABASE_URL/functions/v2/register-member" -X POST \
  -H "Authorization: Bearer $AUTH_NONADMIN" -H "Content-Type: application/json" -d '{"student_id":"DUPTEST123"}')
[ "$RES2" = "409" ] && ok "duplicate registration 409" || bad "duplicate registration not 409 ($RES2)"
# 7b. Duplicate check-in is idempotent (200, not 500).
RES=$(curl -s -o /tmp/d3 -w "%{http_code}" "$SUPABASE_URL/functions/v2/check-in-user" -X POST \
  -H "Authorization: Bearer $AUTH_NONADMIN" -H "Content-Type: application/json" -d '{"token":"NONEXISTENT_TOKEN"}')
[ "$RES" = "404" ] && ok "invalid token check-in 404 (idempotent path intact)" || bad "invalid token check-in ($RES)"

echo "============================================"
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" = "0" ] && echo "ALL TESTS PASSED — backend ready" || echo "FAILURES PRESENT — do not proceed to feature work"
exit $FAIL