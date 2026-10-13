import React from 'react';
import { Link, NavLink } from 'react-router-dom';
import { useAuth } from '@/lib/authAdapter';
import { Button } from '@/components/ui/button';

const linkClass = ({ isActive }) =>
  `text-sm ${isActive ? 'text-foreground font-medium' : 'text-muted-foreground hover:text-foreground'}`;

// Shared chrome for the public site: nav is visible to everyone; the right-hand
// side swaps between Log in/Sign up (anon) and Log out (signed in).
export default function PublicLayout({ children, maxWidth = 'max-w-4xl' }) {
  const { isAuthenticated, logout } = useAuth();
  return (
    <div className="min-h-screen">
      <header className="border-b border-border">
        <nav aria-label="Main" className="max-w-4xl mx-auto px-4 h-14 flex items-center justify-between gap-4">
          <div className="flex items-center gap-5">
            <Link to="/" className="font-heading font-semibold">SJSU Club</Link>
            <NavLink to="/about" className={linkClass}>About</NavLink>
            <NavLink to="/events" className={linkClass}>Events</NavLink>
            <NavLink to="/projects" className={linkClass}>Projects</NavLink>
          </div>
          <div className="flex items-center gap-2">
            {isAuthenticated ? (
              <Button variant="outline" size="sm" onClick={() => logout()}>Log out</Button>
            ) : (
              <>
                <Button asChild variant="ghost" size="sm"><Link to="/login">Log in</Link></Button>
                <Button asChild size="sm"><Link to="/register">Join</Link></Button>
              </>
            )}
          </div>
        </nav>
      </header>
      <main className={`${maxWidth} mx-auto px-4 py-8`}>{children}</main>
    </div>
  );
}
