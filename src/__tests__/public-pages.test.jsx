import React from 'react'
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'

vi.mock('@/lib/supabaseClient', () => import('@/test/supabaseMock'))
vi.mock('@/lib/AuthContext', () => import('@/test/authMock'))

import { mockDb, queries, supabase } from '@/test/supabaseMock'
import { setAuth, signedIn } from '@/test/authMock'
import { renderAt } from '@/test/utils'
import Home from '@/pages/Home'
import About from '@/pages/About'
import Events from '@/pages/Events'
import Projects from '@/pages/Projects'
import LeadershipChart from '@/components/leadership/LeadershipChart'

const ev = (over) => ({
  id: 'e1', title: 'Hack Night', description: 'Build things', location: 'ENG 101',
  starts_at: '2026-10-20T01:00:00Z', ends_at: '2026-10-20T03:00:00Z',
  semester: 'fall', year: 2026, is_published: true, student_id: 'SECRET-EVENT-ID', ...over,
})
const proj = (over) => ({
  id: 'p1', name: 'Rover', description: 'A robot', image_path: null, status: 'active',
  semester: 'fall', year: 2026, is_published: true, updated_at: '2026-10-01T00:00:00Z', ...over,
})
const lead = (over) => ({
  assignment_id: 'a1', first_name: 'Ada', last_name: 'Lovelace', photo_path: 'photos/ada.png',
  linkedin_url: 'https://www.linkedin.com/in/ada', role_key: 'president', role_name: 'President',
  team_key: 'executive', team_name: 'Executive', assigned_at: '2026-08-01T00:00:00Z',
  // Never selected by the app; present so the mock would leak them if the client asked for them.
  student_id: '012345678', email: 'ada@sjsu.edu', ...over,
})

const approvedUser = { id: 'u1', auth_user_id: 'auth-1', is_pending: false, is_rejected: false, email_verified: true, is_deactivated: false }

beforeEach(() => {
  mockDb.reset()
  setAuth()
})

describe('public pages render anonymously', () => {
  it('Home shows hero, nav and Join/Log in, with no member panel', async () => {
    mockDb.setTable('leadership_chart_current', [lead()])
    renderAt(<Home />)
    expect(screen.getByRole('heading', { name: /SJSU Club Platform/i })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Log in' })).toHaveAttribute('href', '/login')
    expect(screen.getByRole('link', { name: 'Join' })).toHaveAttribute('href', '/register')
    expect(screen.queryByTestId('member-dashboard')).not.toBeInTheDocument()
    expect(screen.queryByText(/Signed in as/)).not.toBeInTheDocument()
    expect(await screen.findByText('Ada Lovelace')).toBeInTheDocument()
  })

  it('About renders anonymously', () => {
    renderAt(<About />, { path: '/about' })
    expect(screen.getByRole('heading', { name: /About the club/i })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Events' })).toBeInTheDocument()
  })
})

describe('public events', () => {
  beforeEach(() => {
    mockDb.setTable('events', [
      ev({ id: 'e1', title: 'Hack Night', is_published: true }),
      ev({ id: 'e2', title: 'Secret Planning Draft', is_published: false }),
    ])
  })

  it('shows the published event and hides the unpublished one for anon', async () => {
    renderAt(<Events />, { path: '/events' })
    expect(await screen.findByText('Hack Night')).toBeInTheDocument()
    expect(screen.queryByText('Secret Planning Draft')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /New event/i })).not.toBeInTheDocument()
  })

  it('requests published rows only and never selects student_id', async () => {
    renderAt(<Events />, { path: '/events' })
    await screen.findByText('Hack Night')
    const q = queries.find((x) => x.table === 'events')
    expect(q.filters).toContainEqual(['is_published', true])
    expect(q.columns).not.toMatch(/student_id|email/)
    expect(screen.queryByText('SECRET-EVENT-ID')).not.toBeInTheDocument()
  })

  it('lets an event editor see drafts and the create control', async () => {
    signedIn()
    mockDb.setTable('users', [approvedUser])
    mockDb.setRpc('can_edit_all_events', true)
    renderAt(<Events />, { path: '/events' })
    expect(await screen.findByText('Secret Planning Draft')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /New event/i })).toBeInTheDocument()
  })

  it('does not give a plain member edit controls or drafts', async () => {
    signedIn()
    mockDb.setTable('users', [approvedUser])
    renderAt(<Events />, { path: '/events' })
    expect(await screen.findByText('Hack Night')).toBeInTheDocument()
    expect(screen.queryByText('Secret Planning Draft')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /New event/i })).not.toBeInTheDocument()
  })
})

describe('public projects', () => {
  beforeEach(() => {
    mockDb.setTable('projects', [
      proj({ id: 'p1', name: 'Rover', is_published: true }),
      proj({ id: 'p2', name: 'Stealth Prototype', is_published: false }),
    ])
  })

  it('shows the published project and hides the unpublished one for anon', async () => {
    renderAt(<Projects />, { path: '/projects' })
    expect(await screen.findByText('Rover')).toBeInTheDocument()
    expect(screen.queryByText('Stealth Prototype')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /New project/i })).not.toBeInTheDocument()
    const q = queries.find((x) => x.table === 'projects')
    expect(q.filters).toContainEqual(['is_published', true])
    expect(q.columns).not.toMatch(/student_id|email/)
  })

  it('lets a project editor see drafts', async () => {
    signedIn()
    mockDb.setTable('users', [approvedUser])
    mockDb.setRpc('can_edit_all_projects', true)
    renderAt(<Projects />, { path: '/projects' })
    expect(await screen.findByText('Stealth Prototype')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /New project/i })).toBeInTheDocument()
  })
})

describe('public leadership chart', () => {
  it('renders from leadership_chart_current and groups by team', async () => {
    mockDb.setTable('leadership_chart_current', [
      lead(),
      lead({ assignment_id: 'a2', first_name: 'Grace', last_name: 'Hopper', role_key: 'website_lead', role_name: 'Website Lead', team_key: 'website', team_name: 'Website', linkedin_url: null }),
    ])
    renderAt(<Home />)
    const exec = await screen.findByRole('region', { name: 'Executive team' })
    expect(within(exec).getByText('Ada Lovelace')).toBeInTheDocument()
    expect(within(exec).getByText('President')).toBeInTheDocument()
    expect(within(exec).getByRole('link', { name: /Ada Lovelace on LinkedIn/ })).toHaveAttribute('href', 'https://www.linkedin.com/in/ada')
    const web = screen.getByRole('region', { name: 'Website team' })
    expect(within(web).getByText('Grace Hopper')).toBeInTheDocument()
    expect(within(web).queryByRole('link')).not.toBeInTheDocument()
    expect(queries.some((q) => q.table === 'leadership_chart_current')).toBe(true)
  })

  it('never requests or renders private fields', async () => {
    mockDb.setTable('leadership_chart_current', [lead()])
    const { container } = renderAt(<Home />)
    await screen.findByText('Ada Lovelace')
    const q = queries.find((x) => x.table === 'leadership_chart_current')
    expect(q.columns).not.toMatch(/student_id|email|photo_path/)
    expect(container.textContent).not.toMatch(/012345678|ada@sjsu\.edu/)
  })

  it('component ignores extra private columns even if the API leaked them', () => {
    const { container } = renderAt(<LeadershipChart rows={[lead()]} />)
    expect(container.textContent).toContain('Ada Lovelace')
    expect(container.textContent).not.toMatch(/012345678|ada@sjsu\.edu|ada\.png/)
  })

  it('drops non-http LinkedIn URLs', () => {
    renderAt(<LeadershipChart rows={[lead({ linkedin_url: 'javascript:alert(1)' })]} />)
    expect(screen.queryByRole('link')).not.toBeInTheDocument()
  })

  it('shows an empty state with no rows', async () => {
    renderAt(<Home />)
    expect(await screen.findByText(/Leadership roster coming soon/)).toBeInTheDocument()
  })
})

describe('member dashboard / pending gating on Home', () => {
  it('shows the dashboard with email for an approved member (no admin link)', async () => {
    signedIn()
    mockDb.setTable('users', [approvedUser])
    renderAt(<Home />)
    const panel = await screen.findByTestId('member-dashboard')
    expect(within(panel).getByText(/Signed in as member@sjsu\.edu/)).toBeInTheDocument()
    expect(within(panel).getByRole('link', { name: /Events/ })).toBeInTheDocument()
    expect(within(panel).getByRole('link', { name: /Projects/ })).toBeInTheDocument()
    expect(within(panel).queryByRole('link', { name: /Membership approvals/ })).not.toBeInTheDocument()
  })

  it('shows the admin approvals link when can_approve_membership is true', async () => {
    signedIn()
    mockDb.setTable('users', [approvedUser])
    mockDb.setRpc('can_approve_membership', true)
    renderAt(<Home />)
    expect(await screen.findByRole('link', { name: /Membership approvals/ })).toHaveAttribute('href', '/admin/members')
  })

  it('shows a pending notice and no dashboard for a pending member', async () => {
    signedIn()
    mockDb.setTable('users', [{ ...approvedUser, is_pending: true }])
    mockDb.setRpc('can_approve_membership', true)
    renderAt(<Home />)
    expect(await screen.findByText(/Pending membership approval/)).toBeInTheDocument()
    expect(screen.queryByTestId('member-dashboard')).not.toBeInTheDocument()
    expect(screen.queryByRole('link', { name: /Membership approvals/ })).not.toBeInTheDocument()
    expect(supabase.rpc.mock.calls.map((c) => c[0])).not.toContain('can_approve_membership')
  })

  it('shows a rejected notice for a rejected member', async () => {
    signedIn()
    mockDb.setTable('users', [{ ...approvedUser, is_rejected: true }])
    renderAt(<Home />)
    expect(await screen.findByText(/Membership not approved/)).toBeInTheDocument()
  })

  it('prompts a signed-in user with no membership record to complete their profile', async () => {
    signedIn()
    renderAt(<Home />)
    await waitFor(() => expect(screen.getByRole('link', { name: /Complete your membership/ })).toHaveAttribute('href', '/complete-profile'))
  })

  it('pending members get no edit permissions on Events (and see published only)', async () => {
    signedIn()
    mockDb.setTable('users', [{ ...approvedUser, is_pending: true }])
    mockDb.setTable('events', [ev(), ev({ id: 'e2', title: 'Draft', is_published: false })])
    mockDb.setRpc('can_edit_all_events', true)
    renderAt(<Events />, { path: '/events' })
    expect(await screen.findByText('Hack Night')).toBeInTheDocument()
    expect(screen.queryByText('Draft')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /New event/i })).not.toBeInTheDocument()
  })
})
