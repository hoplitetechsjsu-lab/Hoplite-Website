import React from 'react'
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

vi.mock('@/lib/supabaseClient', () => import('@/test/supabaseMock'))
vi.mock('@/lib/AuthContext', () => import('@/test/authMock'))

import { mockDb, supabase } from '@/test/supabaseMock'
import { signedIn } from '@/test/authMock'
import { renderAt } from '@/test/utils'
import CompleteProfile from '@/pages/CompleteProfile'

const setup = () =>
  renderAt(<CompleteProfile />, { path: '/complete-profile', extraRoutes: { '/': <div>home page</div> } })

describe('CompleteProfile', () => {
  beforeEach(() => {
    mockDb.reset()
    signedIn()
  })

  it('submits only the trimmed student_id to register-member and then goes home', async () => {
    const user = userEvent.setup()
    setup()
    await user.type(await screen.findByLabelText('Student ID'), '  012345678  ')
    await user.click(screen.getByRole('button', { name: /Request membership/i }))
    await waitFor(() => expect(screen.getByText('home page')).toBeInTheDocument())
    expect(supabase.functions.invoke).toHaveBeenCalledTimes(1)
    expect(supabase.functions.invoke).toHaveBeenCalledWith('register-member', { body: { student_id: '012345678' } })
  })

  it('does not call the function for a whitespace-only student ID', async () => {
    const user = userEvent.setup()
    setup()
    await user.type(await screen.findByLabelText('Student ID'), '   ')
    await user.click(screen.getByRole('button', { name: /Request membership/i }))
    expect(await screen.findByText(/Student ID is required/)).toBeInTheDocument()
    expect(supabase.functions.invoke).not.toHaveBeenCalled()
  })

  it('shows the error returned by the Edge Function and stays on the page', async () => {
    mockDb.setInvoke('register-member', { data: null, error: { message: 'Student ID already in use' } })
    const user = userEvent.setup()
    setup()
    await user.type(await screen.findByLabelText('Student ID'), '999')
    await user.click(screen.getByRole('button', { name: /Request membership/i }))
    expect(await screen.findByText('Student ID already in use')).toBeInTheDocument()
    expect(screen.queryByText('home page')).not.toBeInTheDocument()
  })

  it('redirects away when a membership record already exists', async () => {
    mockDb.setTable('users', [{ id: 'u1', auth_user_id: 'auth-1', is_pending: true, is_rejected: false, email_verified: true, is_deactivated: false }])
    setup()
    expect(await screen.findByText('home page')).toBeInTheDocument()
    expect(supabase.functions.invoke).not.toHaveBeenCalled()
  })
})
