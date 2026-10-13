# Local acceptance matrix (Phase 4.2)

Manual checklist to run against the **local** stack. Nothing is pre-checked: tick a row only after you ran it. "Auto" names the automated test that covers the frontend half (mocked client) — it does **not** replace the manual run.

Setup: `nvm use` → `supabase start` → `npm run db:reset` → `.env.local` (see `README.md`) → `npm run dev`. Email lands in Mailpit at `http://127.0.0.1:54324`. Seed fixture members have no `auth.users` rows and cannot sign in; create real users through the UI.

Automated gates first: `npm run lint`, `npm run build`, `npm test`, `npm run db:test`.

| # | Persona | Steps | Expected | Auto | Done |
| --- | --- | --- | --- | --- | --- |
| 1 | Anonymous | Open `/` | Home loads without redirect; Log in / Join visible; leadership section present | `public-pages`, `app-routes` | ☐ |
| 2 | Anonymous | Open `/about` | About page loads | `public-pages`, `app-routes` | ☐ |
| 3 | Anonymous | Open `/events` | Seed **published** events listed; draft/unpublished events absent; no "New event" | `public-pages` | ☐ |
| 4 | Anonymous | Open `/projects` | Published projects only; no "New project" | `public-pages` | ☐ |
| 5 | Anonymous | Inspect Home leadership chart + Network tab (`leadership_chart_current`) | Names/roles/teams/LinkedIn only; no `student_id`, no email in the response | `public-pages` | ☐ |
| 6 | Anonymous | Open `/admin/members` and `/complete-profile` | Redirected to `/login` | `app-routes`, `protected-route` | ☐ |
| 7 | New user | Register with email/password; confirm via Mailpit; log in | Lands on Home with "Finish joining the club" banner | `public-pages` | ☐ |
| 8 | New user | Complete Profile with a student ID | Request submitted; Home shows "Pending membership approval" (requires `register-member` served/deployed) | `complete-profile` | ☐ |
| 9 | New user | Submit an empty / whitespace student ID | Inline error; no network call | `complete-profile` | ☐ |
| 10 | Pending member | Open `/events`, `/projects` | Published content only, no edit controls | `public-pages` | ☐ |
| 11 | Pending member | Open `/admin/members` | "Not authorized" | `admin-members` | ☐ |
| 12 | Membership admin (bootstrapped, migration 007) | Home | Dashboard shows email + "Membership approvals" link | `public-pages` | ☐ |
| 13 | Membership admin | `/admin/members`: approve the pending user | Confirm dialog → user leaves queue; audit row written | `admin-members` | ☐ |
| 14 | Membership admin | Reject another pending user | Reason required; user shows under Rejected | `admin-members` | ☐ |
| 15 | Membership admin | Look for approve/reject on own row | No buttons (labelled "You") | `admin-members` | ☐ |
| 16 | Approved member | Log in again | Dashboard visible; no admin link; events/projects read-only | `public-pages` | ☐ |
| 17 | Rejected member | Log in | "Membership not approved" notice | `public-pages` | ☐ |
| 18 | Event editor (grant a role via SQL) | `/events`: create, edit, publish, delete an event | Draft visible only to editors; publishing makes it public to anon | — (handlers untested) | ☐ |
| 19 | Project editor | `/projects`: create, edit, publish, delete | Same as above | — | ☐ |
| 20 | Any | Log out | Returns to login; Home still loads anonymously | — | ☐ |
| 21 | Any | Forgot password flow via Mailpit | Reset link works; can log in with new password | — (no tests) | ☐ |

Out of scope for local acceptance (see `MVP_STATUS.md` / `POST_MVP.md`): Google OAuth round trip, hosted CORS/deploy, exports, QR check-in UI, role-request UI, profile photos.
