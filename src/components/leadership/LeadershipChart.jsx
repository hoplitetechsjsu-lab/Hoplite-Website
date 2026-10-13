import React from 'react';
import { Linkedin } from 'lucide-react';

// Presentational leadership chart. Takes rows from the public
// `leadership_chart_current` view and renders ONLY name, role, team and LinkedIn.
// Fields are picked explicitly so an accidental extra column (student_id, email)
// from the API can never reach the DOM.

const ROLE_ORDER = [
  'president', 'vp', 'website_coordinator', 'events_coordinator', 'outreach_coordinator',
  'finance_coordinator', 'technical_sourcing_coordinator',
  'website_lead', 'events_lead', 'outreach_lead', 'finance_lead', 'technical_sourcing_lead',
];

const roleRank = (key) => {
  const i = ROLE_ORDER.indexOf(key);
  return i === -1 ? ROLE_ORDER.length : i;
};

const safeLinkedIn = (url) => (typeof url === 'string' && /^https?:\/\//i.test(url) ? url : null);

function groupByTeam(rows) {
  const groups = new Map();
  for (const row of rows) {
    const key = row.team_key ?? '__none__';
    if (!groups.has(key)) groups.set(key, { key, name: row.team_name ?? 'Club leadership', members: [] });
    groups.get(key).members.push(row);
  }
  const list = [...groups.values()];
  list.forEach((g) => g.members.sort((a, b) => roleRank(a.role_key) - roleRank(b.role_key)));
  list.sort((a, b) => roleRank(a.members[0].role_key) - roleRank(b.members[0].role_key));
  return list;
}

function Person({ row }) {
  const name = [row.first_name, row.last_name].filter(Boolean).join(' ') || 'Club member';
  const linkedin = safeLinkedIn(row.linkedin_url);
  return (
    <li className="flex items-center justify-between gap-3 py-2">
      <div className="min-w-0">
        <p className="font-medium truncate">{name}</p>
        <p className="text-sm text-muted-foreground truncate">{row.role_name}</p>
      </div>
      {linkedin && (
        <a
          href={linkedin}
          target="_blank"
          rel="noopener noreferrer"
          aria-label={`${name} on LinkedIn`}
          className="text-muted-foreground hover:text-foreground shrink-0"
        >
          <Linkedin className="w-4 h-4" />
        </a>
      )}
    </li>
  );
}

export default function LeadershipChart({ rows }) {
  if (!rows || rows.length === 0) {
    return <p className="text-center text-muted-foreground py-8">Leadership roster coming soon.</p>;
  }
  const groups = groupByTeam(rows);
  return (
    <div className="grid gap-4 sm:grid-cols-2" data-testid="leadership-chart">
      {groups.map((g) => (
        <section key={g.key} className="rounded-xl border border-border bg-card p-5" aria-label={`${g.name} team`}>
          <h3 className="text-lg font-heading mb-1">{g.name}</h3>
          <ul className="divide-y divide-border">
            {g.members.map((m) => <Person key={m.assignment_id} row={m} />)}
          </ul>
        </section>
      ))}
    </div>
  );
}
