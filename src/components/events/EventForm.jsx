import React, { useState } from 'react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Switch } from '@/components/ui/switch';

// Converts a stored timestamptz (UTC ISO) to a datetime-local string in the
// user's local time for editing.
function toLocalInput(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  const pad = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

const empty = {
  title: '', description: '', location: '',
  starts_at: '', ends_at: '',
  semester: 'fall', year: new Date().getFullYear(), is_published: false,
};

export default function EventForm({ initial, onSubmit, onCancel, submitting }) {
  const [form, setForm] = useState(() => ({
    ...empty,
    ...(initial
      ? {
          title: initial.title ?? '',
          description: initial.description ?? '',
          location: initial.location ?? '',
          starts_at: toLocalInput(initial.starts_at),
          ends_at: toLocalInput(initial.ends_at),
          semester: initial.semester ?? 'fall',
          year: initial.year ?? new Date().getFullYear(),
          is_published: initial.is_published ?? false,
        }
      : {}),
  }));

  const set = (k, v) => setForm((f) => ({ ...f, [k]: v }));

  const submit = (e) => {
    e.preventDefault();
    if (!form.title.trim() || !form.starts_at || !form.ends_at) return;
    onSubmit({
      ...form,
      title: form.title.trim(),
      // Convert local datetime input to unambiguous UTC ISO for timestamptz.
      starts_at: form.starts_at ? new Date(form.starts_at).toISOString() : null,
      ends_at: form.ends_at ? new Date(form.ends_at).toISOString() : null,
      year: Number(form.year),
    });
  };

  return (
    <form onSubmit={submit} className="space-y-4">
      <div className="space-y-2">
        <Label htmlFor="ev-title">Title</Label>
        <Input id="ev-title" value={form.title} onChange={(e) => set('title', e.target.value)} required />
      </div>
      <div className="space-y-2">
        <Label htmlFor="ev-desc">Description</Label>
        <Textarea id="ev-desc" value={form.description} onChange={(e) => set('description', e.target.value)} rows={3} />
      </div>
      <div className="space-y-2">
        <Label htmlFor="ev-loc">Location</Label>
        <Input id="ev-loc" value={form.location} onChange={(e) => set('location', e.target.value)} />
      </div>
      <div className="grid grid-cols-2 gap-3">
        <div className="space-y-2">
          <Label htmlFor="ev-start">Starts at</Label>
          <Input id="ev-start" type="datetime-local" value={form.starts_at} onChange={(e) => set('starts_at', e.target.value)} required />
        </div>
        <div className="space-y-2">
          <Label htmlFor="ev-end">Ends at</Label>
          <Input id="ev-end" type="datetime-local" value={form.ends_at} onChange={(e) => set('ends_at', e.target.value)} required />
        </div>
      </div>
      <div className="grid grid-cols-2 gap-3">
        <div className="space-y-2">
          <Label>Semester</Label>
          <Select value={form.semester} onValueChange={(v) => set('semester', v)}>
            <SelectTrigger><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value="fall">Fall</SelectItem>
              <SelectItem value="spring">Spring</SelectItem>
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-2">
          <Label htmlFor="ev-year">Year</Label>
          <Input id="ev-year" type="number" min={2024} value={form.year} onChange={(e) => set('year', e.target.value)} required />
        </div>
      </div>
      <div className="flex items-center gap-3">
        <Switch id="ev-pub" checked={form.is_published} onCheckedChange={(v) => set('is_published', v)} />
        <Label htmlFor="ev-pub" className="cursor-pointer">Published (visible to members)</Label>
      </div>
      <div className="flex justify-end gap-2 pt-2">
        <Button type="button" variant="outline" onClick={onCancel} disabled={submitting}>Cancel</Button>
        <Button type="submit" disabled={submitting}>{initial ? 'Save changes' : 'Create event'}</Button>
      </div>
    </form>
  );
}