import React from 'react';
import PublicLayout from '@/components/PublicLayout';

// Minimal public About page. Static copy — edit freely.
export default function About() {
  return (
    <PublicLayout>
      <h1 className="text-3xl font-heading mb-4">About the club</h1>
      <p className="text-muted-foreground mb-3">
        We are a student-run SJSU club that builds projects, hosts events, and helps members grow together.
      </p>
      <p className="text-muted-foreground mb-3">
        Anyone can browse our published events, projects, and leadership team. Join the club to take part:
        sign up, submit your student ID, and a club administrator will approve your membership.
      </p>
      <p className="text-sm text-muted-foreground">
        Student IDs are stored privately and are never displayed publicly.
      </p>
    </PublicLayout>
  );
}
