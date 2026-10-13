// Auth adapter — the single place the app exposes AuthProvider / useAuth.
// Swap the underlying implementation here if the auth provider changes.
export { AuthProvider, useAuth } from '@/lib/AuthContext';
