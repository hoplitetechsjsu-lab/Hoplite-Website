import { vi } from 'vitest'

// Replaces '@/lib/AuthContext' (and therefore '@/lib/authAdapter'):
//   vi.mock('@/lib/AuthContext', () => import('@/test/authMock'))
//   import { setAuth } from '@/test/authMock'

const base = () => ({
  user: null,
  isAuthenticated: false,
  isLoadingAuth: false,
  authChecked: true,
  authError: null,
  logout: vi.fn(),
  navigateToLogin: vi.fn(),
  checkUserAuth: vi.fn(),
})

export let authState = base()

export const setAuth = (overrides = {}) => {
  authState = { ...base(), ...overrides }
  return authState
}

export const signedIn = (overrides = {}) =>
  setAuth({ user: { id: 'auth-1', email: 'member@sjsu.edu' }, isAuthenticated: true, ...overrides })

export const useAuth = () => authState
export const AuthProvider = ({ children }) => children
