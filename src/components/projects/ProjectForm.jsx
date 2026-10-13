import React, { useState } from 'react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Switch } from '@/components/ui/switch';

const empty = {
  name: '', description: '', image_path: '',
  status: 'active', semester: 'fall', year: new Date().getFullYear(), is_published: false,
};

export default function ProjectForm({ initial, onSubmit, onCancel, submitting }) {
  const [form, setForm] = useState(() => ({
    ...empty,
    ...(initial
      ? {
          name: initial.name ?? '',
          description: initial.description ?? '',
          image_path: initial.image_path ?? '',
          status: initial.status ?? 'active',
          semester: initial.semester ?? 'fall',
          year: initial.year ?? new Date().getFullYear(),
          is_published: initial.is_published ?? false,
        }
      : {}),
  }));

  const set = (k, v) => setForm((f) => ({ ...f, [k]: v }));

  const submit = (e) => {
    e.preventDefault();
    if (!form.name.trim()) return;
    onSubmit({ ...form, name: form.name.trim(), year: Number(form.year) });
  };

  return (
    <form onSubmit={submit} className="space-y-4">
      <div className="space-y-2">
        <Label htmlFor="pr-name">Project name</Label>
        <Input id="pr-name" value={form.name} onChange={(e) => set('name', e.target.value)} required />
      </div>
      <div className="space-y-2">
        <Label htmlFor="pr-desc">Description</Label>
        <Textarea id="pr-desc" value={form.description} onChange={(e) => set('description', e.target.value)} rows={3} />
      </div>
      <div className="space-y-2">
        <Label htmlFor="pr-img">Image URL (optional)</Label>
        <Input id="pr-img" type="url" placeholder="https://..." value={form.image_path} onChange={(e) => set('image_path', e.target.value)} />
      </div>
      <div className="grid grid-cols-3 gap-3">
        <div className="space-y-2">
          <Label>Status</Label>
          <Select value={form.status} onValueChange={(v) => set('status', v)}>
            <SelectTrigger><SelectValue /></SelectTrigger>
            <SelectContent>
              <SelectItem value="active">Active</SelectItem>
              <SelectItem value="completed">Completed</SelectItem>
            </SelectContent>
          </Select>
        </div>
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
          <Label htmlFor="pr-year">Year</Label>
          <Input id="pr-year" type="number" min={2024} value={form.year} onChange={(e) => set('year', e.target.value)} required />
        </div>
      </div>
      <div className="flex items-center gap-3">
        <Switch id="pr-pub" checked={form.is_published} onCheckedChange={(v) => set('is_published', v)} />
        <Label htmlFor="pr-pub" className="cursor-pointer">Published (visible to members)</Label>
      </div>
      <div className="flex justify-end gap-2 pt-2">
        <Button type="button" variant="outline" onClick={onCancel} disabled={submitting}>Cancel</Button>
        <Button type="submit" disabled={submitting}>{initial ? 'Save changes' : 'Create project'}</Button>
      </div>
    </form>
  );
}