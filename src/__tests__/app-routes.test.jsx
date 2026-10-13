import React from 'react'
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'

vi.mock('@/lib/supabaseClient', () => import('@/test/supabaseMock'))
vi.mock('@/lib/AuthContext', () => import('@/test/authMock'))

import { mockDb } from '@/test/supabaseMock'
import { setAuth, signedIn } from '@/test/authMock'
import App from '@/App'

const go = (path) => {
  window.history.pushState({}, '', path)
  return render(<App />)
}

// Guards the original bug: Home/Events/Projects were behind ProtectedRoute.
describe('App routing (public vs protected)', () => {
  beforeEach(() => {
    mockDb.reset()
    setAuth()
    mockDb.setTable('events', [{ id: 'e1', title: 'Hack Night', is_published: true, semester: 'fall', year: 2026 }])
    mockDb.setTable('projects', [{ id: 'p1', name: 'Rover', is_published: true, status: 'active', semester: 'fall', year: 2026 }])
  })

  it.each([
    ['/', /SJSU Club Platform/],
    ['/about', /About the club/],
    ['/events', /^Events$/],
    ['/projects', /^Projects$/],
  ])('lets anonymous visitors reach %s', async (path, heading) => {
    go(path)
    expect(await screen.findByRole('heading', { level: 1, name: heading })).toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: /^Log in$|Sign in|Welcome back/i })).not.toBeInTheDocument()
  })

  it('shows published events to anonymous visitors on /events', async () => {
    go('/events')
    expect(await screen.findByText('Hack Night')).toBeInTheDocument()
  })

  it.each(['/admin/members', '/complete-profile'])('redirects anonymous visitors from %s to /login', async (path) => {
    go(path)
    await waitFor(() => expect(window.location.pathname).toBe('/login'))
  })

  it('keeps /admin/members reachable for signed-in users (server re-checks authorization)', async () => {
    signedIn()
    mockDb.setTable('users', [{ id: 'u1', auth_user_id: 'auth-1', is_pending: false, is_rejected: false, email_verified: true, is_deactivated: false }])
    go('/admin/members')
    expect(await screen.findByText('Not authorized')).toBeInTheDocument()
    expect(window.location.pathname).toBe('/admin/members')
  })
})
