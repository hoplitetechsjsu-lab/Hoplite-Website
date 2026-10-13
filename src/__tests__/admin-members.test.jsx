import React from 'react'
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

vi.mock('@/lib/supabaseClient', () => import('@/test/supabaseMock'))
vi.mock('@/lib/AuthContext', () => import('@/test/authMock'))

import { mockDb, supabase } from '@/test/supabaseMock'
import { signedIn } from '@/test/authMock'
import { renderAt } from '@/test/utils'
import AdminMembers from '@/pages/AdminMembers'

const admin = { id: 'admin-1', auth_user_id: 'auth-1', is_pending: false, is_rejected: false, email_verified: true, is_deactivated: false }
const row = (over) => ({
  user_id: 'u2', email: 'newbie@sjsu.edu', email_verified: true, is_pending: true, is_rejected: false,
  created_at: '2026-10-01T00:00:00Z', ...over,
})

function setup({ queue, authorized = true }) {
  signedIn()
  mockDb.setTable('users', [admin])
  mockDb.setRpc('can_approve_membership', authorized)
  mockDb.setRpc('get_admin_member_queue', queue)
  return renderAt(<AdminMembers />, { path: '/admin/members' })
}

describe('AdminMembers approval queue', () => {
  beforeEach(() => mockDb.reset())

  it('shows approve/reject for other pending members only', async () => {
    setup({ queue: [row(), row({ user_id: 'admin-1', email: 'admin@sjsu.edu' }), row({ user_id: 'u3', email: 'old@sjsu.edu', is_pending: false, is_rejected: true })] })
    expect(await screen.findByText('newbie@sjsu.edu')).toBeInTheDocument()
    expect(screen.getAllByRole('button', { name: /^Approve$/ })).toHaveLength(1) // not self, not rejected
    expect(screen.getAllByRole('button', { name: /^Reject$/ })).toHaveLength(1)
    expect(screen.getByText('You')).toBeInTheDocument()
  })

  it('never displays a student ID', async () => {
    const { container } = setup({ queue: [row({ student_id: '012345678' })] })
    await screen.findByText('newbie@sjsu.edu')
    expect(container.textContent).not.toMatch(/012345678/)
  })

  it('approve: confirm dialog then invokes approve-member and refetches', async () => {
    const user = userEvent.setup()
    setup({ queue: [row()] })
    await user.click(await screen.findByRole('button', { name: /^Approve$/ }))
    const dialog = await screen.findByRole('dialog')
    expect(within(dialog).getByText(/Approve membership\?/)).toBeInTheDocument()
    expect(supabase.functions.invoke).not.toHaveBeenCalled() // nothing until confirmed
    await user.click(within(dialog).getByRole('button', { name: /^Approve$/ }))
    await waitFor(() => expect(supabase.functions.invoke).toHaveBeenCalledWith('approve-member', { body: { user_id: 'u2' } }))
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())
    expect(supabase.rpc.mock.calls.filter((c) => c[0] === 'get_admin_member_queue').length).toBeGreaterThanOrEqual(2)
  })

  it('reject: requires a reason, then invokes reject-member with it', async () => {
    const user = userEvent.setup()
    setup({ queue: [row()] })
    await user.click(await screen.findByRole('button', { name: /^Reject$/ }))
    const dialog = await screen.findByRole('dialog')
    const confirm = within(dialog).getByRole('button', { name: /^Reject$/ })
    expect(confirm).toBeDisabled()
    await user.type(within(dialog).getByLabelText('Reason for rejection'), '   ')
    expect(confirm).toBeDisabled()
    await user.type(within(dialog).getByLabelText('Reason for rejection'), 'Not a student')
    expect(confirm).toBeEnabled()
    await user.click(confirm)
    await waitFor(() =>
      expect(supabase.functions.invoke).toHaveBeenCalledWith('reject-member', { body: { user_id: 'u2', reason: 'Not a student' } }),
    )
  })

  it('surfaces a function error and keeps the dialog open', async () => {
    mockDb.setInvoke('approve-member', { data: null, error: { message: 'Cannot approve yourself' } })
    const user = userEvent.setup()
    setup({ queue: [row()] })
    await user.click(await screen.findByRole('button', { name: /^Approve$/ }))
    await user.click(within(await screen.findByRole('dialog')).getByRole('button', { name: /^Approve$/ }))
    expect(await screen.findAllByText('Cannot approve yourself')).not.toHaveLength(0)
    expect(screen.getByRole('dialog')).toBeInTheDocument()
  })

  it('shows Not authorized and never fetches the queue for non-admins', async () => {
    setup({ queue: [row()], authorized: false })
    expect(await screen.findByText('Not authorized')).toBeInTheDocument()
    expect(screen.queryByText('newbie@sjsu.edu')).not.toBeInTheDocument()
    expect(supabase.rpc.mock.calls.map((c) => c[0])).not.toContain('get_admin_member_queue')
  })
})
