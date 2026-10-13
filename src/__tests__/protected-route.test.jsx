import React from 'react'
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter, Navigate, Route, Routes, Outlet } from 'react-router-dom'

vi.mock('@/lib/AuthContext', () => import('@/test/authMock'))

import { setAuth, signedIn } from '@/test/authMock'
import ProtectedRoute from '@/components/ProtectedRoute'

function renderGuarded(auth) {
  render(
    <MemoryRouter initialEntries={['/secret']}>
      <Routes>
        <Route path="/login" element={<div>login page</div>} />
        <Route element={<ProtectedRoute unauthenticatedElement={<Navigate to="/login" replace />} />}>
          <Route path="/secret" element={<div>secret content</div>} />
        </Route>
        <Route path="/public" element={<Outlet />} />
      </Routes>
    </MemoryRouter>,
  )
  return auth
}

describe('ProtectedRoute', () => {
  beforeEach(() => setAuth())

  it('redirects anonymous users to /login', () => {
    renderGuarded(setAuth())
    expect(screen.getByText('login page')).toBeInTheDocument()
    expect(screen.queryByText('secret content')).not.toBeInTheDocument()
  })

  it('renders the child route for authenticated users', () => {
    renderGuarded(signedIn())
    expect(screen.getByText('secret content')).toBeInTheDocument()
  })

  it('shows a spinner (not content) while auth is loading', () => {
    renderGuarded(setAuth({ isLoadingAuth: true, authChecked: false }))
    expect(screen.queryByText('secret content')).not.toBeInTheDocument()
    expect(screen.queryByText('login page')).not.toBeInTheDocument()
  })

  it('triggers an auth check when it has not run yet', () => {
    const auth = setAuth({ authChecked: false, isLoadingAuth: false })
    renderGuarded(auth)
    expect(auth.checkUserAuth).toHaveBeenCalled()
  })

  it('treats an auth error as unauthenticated', () => {
    renderGuarded(signedIn({ authError: { type: 'auth_required' } }))
    expect(screen.getByText('login page')).toBeInTheDocument()
  })

  it('shows the not-registered screen for user_not_registered', () => {
    renderGuarded(signedIn({ authError: { type: 'user_not_registered' } }))
    expect(screen.queryByText('secret content')).not.toBeInTheDocument()
    expect(screen.queryByText('login page')).not.toBeInTheDocument()
  })
})
