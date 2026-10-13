import React, { useState, useEffect } from 'react';
import { supabase } from '@/lib/supabaseClient';
import { fetchEvents } from '@/lib/publicData';
import { useAppUser } from '@/lib/useAppUser';
import { usePermissions } from '@/lib/usePermissions';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from '@/components/ui/dialog';
import EventForm from '@/components/events/EventForm';
import PublicLayout from '@/components/PublicLayout';
import { CalendarDays, MapPin, Plus, Pencil, Trash2, Loader2 } from 'lucide-react';

function fmt(iso) {
  return iso ? new Date(iso).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' }) : '';
}

export default function Events() {
  const { appUser, loading } = useAppUser();
  const perms = usePermissions();
  const [events, setEvents] = useState([]);
  const [loadingEvents, setLoadingEvents] = useState(true);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editing, setEditing] = useState(null);
  const [submitting, setSubmitting] = useState(false);

  const load = async () => {
    setLoadingEvents(true);
    // Public page: published events only, unless the viewer can edit events.
    const { data } = await fetchEvents({ includeDrafts: perms.events });
    setEvents(data);
    setLoadingEvents(false);
  };

  useEffect(() => {
    if (loading || !perms.loaded) return;
    load();
  }, [loading, perms.loaded, perms.events]);

  const openCreate = () => { setEditing(null); setDialogOpen(true); };
  const openEdit = (ev) => { setEditing(ev); setDialogOpen(true); };

  const handleSubmit = async (values) => {
    setSubmitting(true);
    if (editing) {
      await supabase.from('events').update(values).eq('id', editing.id);
    } else {
      await supabase.from('events').insert({ ...values, created_by: appUser?.id ?? null });
    }
    setSubmitting(false);
    setDialogOpen(false);
    setEditing(null);
    load();
  };

  const handleDelete = async (id) => {
    if (!window.confirm('Delete this event? Attendance records for it will also be removed.')) return;
    await supabase.from('events').delete().eq('id', id);
    load();
  };

  return (
    <PublicLayout>
      <div className="flex items-center justify-between mb-6">
        <div className="flex items-center gap-3">
          <h1 className="text-2xl font-heading flex items-center gap-2"><CalendarDays className="w-6 h-6" />Events</h1>
        </div>
        {perms.events && (
          <Dialog open={dialogOpen} onOpenChange={(o) => { setDialogOpen(o); if (!o) setEditing(null); }}>
            <DialogTrigger asChild>
              <Button onClick={openCreate}><Plus className="w-4 h-4 mr-2" />New event</Button>
            </DialogTrigger>
            <DialogContent className="max-w-lg">
              <DialogHeader>
                <DialogTitle>{editing ? 'Edit event' : 'Create event'}</DialogTitle>
              </DialogHeader>
              <EventForm
                initial={editing}
                submitting={submitting}
                onSubmit={handleSubmit}
                onCancel={() => { setDialogOpen(false); setEditing(null); }}
              />
            </DialogContent>
          </Dialog>
        )}
      </div>

      {loadingEvents ? (
        <div className="flex justify-center py-20"><Loader2 className="w-8 h-8 animate-spin text-muted-foreground" /></div>
      ) : events.length === 0 ? (
        <p className="text-center text-muted-foreground py-20">No events yet.</p>
      ) : (
        <div className="space-y-3">
          {events.map((ev) => (
            <div key={ev.id} className="rounded-xl border border-border bg-card p-5">
              <div className="flex items-start justify-between gap-4">
                <div className="min-w-0">
                  <div className="flex items-center gap-2 flex-wrap">
                    <h2 className="text-lg font-heading truncate">{ev.title}</h2>
                    {!ev.is_published && <Badge variant="outline">Draft</Badge>}
                    <Badge variant="secondary" className="capitalize">{ev.semester} {ev.year}</Badge>
                  </div>
                  <p className="text-sm text-muted-foreground mt-1 flex items-center gap-1.5">
                    <CalendarDays className="w-4 h-4" />{fmt(ev.starts_at)} — {fmt(ev.ends_at)}
                  </p>
                  {ev.location && (
                    <p className="text-sm text-muted-foreground flex items-center gap-1.5 mt-0.5">
                      <MapPin className="w-4 h-4" />{ev.location}
                    </p>
                  )}
                  {ev.description && <p className="text-sm mt-2 whitespace-pre-wrap">{ev.description}</p>}
                </div>
                {perms.events && (
                  <div className="flex gap-2 shrink-0">
                    <Button variant="outline" size="icon" onClick={() => openEdit(ev)}><Pencil className="w-4 h-4" /></Button>
                    <Button variant="outline" size="icon" onClick={() => handleDelete(ev.id)}><Trash2 className="w-4 h-4" /></Button>
                  </div>
                )}
              </div>
            </div>
          ))}
        </div>
      )}

      {perms.events && editing && (
        <Dialog open={dialogOpen} onOpenChange={(o) => { setDialogOpen(o); if (!o) setEditing(null); }}>
          <DialogContent className="max-w-lg">
            <DialogHeader><DialogTitle>Edit event</DialogTitle></DialogHeader>
            <EventForm initial={editing} submitting={submitting} onSubmit={handleSubmit} onCancel={() => { setDialogOpen(false); setEditing(null); }} />
          </DialogContent>
        </Dialog>
      )}
    </PublicLayout>
  );
}