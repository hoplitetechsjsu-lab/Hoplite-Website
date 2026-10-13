import React, { useState, useEffect } from 'react';
import { supabase } from '@/lib/supabaseClient';
import { fetchProjects } from '@/lib/publicData';
import { useAppUser } from '@/lib/useAppUser';
import { usePermissions } from '@/lib/usePermissions';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger } from '@/components/ui/dialog';
import { Image } from '@/components/ui/image';
import ProjectForm from '@/components/projects/ProjectForm';
import PublicLayout from '@/components/PublicLayout';
import { FolderKanban, Plus, Pencil, Trash2, Loader2 } from 'lucide-react';

export default function Projects() {
  const { appUser, loading } = useAppUser();
  const perms = usePermissions();
  const [projects, setProjects] = useState([]);
  const [loadingProjects, setLoadingProjects] = useState(true);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editing, setEditing] = useState(null);
  const [submitting, setSubmitting] = useState(false);

  const load = async () => {
    setLoadingProjects(true);
    // Public page: published projects only, unless the viewer can edit projects.
    const { data } = await fetchProjects({ includeDrafts: perms.projects });
    setProjects(data);
    setLoadingProjects(false);
  };

  useEffect(() => {
    if (loading || !perms.loaded) return;
    load();
  }, [loading, perms.loaded, perms.projects]);

  const openCreate = () => { setEditing(null); setDialogOpen(true); };
  const openEdit = (p) => { setEditing(p); setDialogOpen(true); };

  const handleSubmit = async (values) => {
    setSubmitting(true);
    if (editing) {
      await supabase.from('projects').update(values).eq('id', editing.id);
    } else {
      await supabase.from('projects').insert({ ...values, created_by: appUser?.id ?? null });
    }
    setSubmitting(false);
    setDialogOpen(false);
    setEditing(null);
    load();
  };

  const handleDelete = async (id) => {
    if (!window.confirm('Delete this project? Roster assignments will also be removed.')) return;
    await supabase.from('projects').delete().eq('id', id);
    load();
  };

  return (
    <PublicLayout>
      <div className="flex items-center justify-between mb-6">
        <div className="flex items-center gap-3">
          <h1 className="text-2xl font-heading flex items-center gap-2"><FolderKanban className="w-6 h-6" />Projects</h1>
        </div>
        {perms.projects && (
          <Dialog open={dialogOpen} onOpenChange={(o) => { setDialogOpen(o); if (!o) setEditing(null); }}>
            <DialogTrigger asChild>
              <Button onClick={openCreate}><Plus className="w-4 h-4 mr-2" />New project</Button>
            </DialogTrigger>
            <DialogContent className="max-w-lg">
              <DialogHeader>
                <DialogTitle>{editing ? 'Edit project' : 'Create project'}</DialogTitle>
              </DialogHeader>
              <ProjectForm
                initial={editing}
                submitting={submitting}
                onSubmit={handleSubmit}
                onCancel={() => { setDialogOpen(false); setEditing(null); }}
              />
            </DialogContent>
          </Dialog>
        )}
      </div>

      {loadingProjects ? (
        <div className="flex justify-center py-20"><Loader2 className="w-8 h-8 animate-spin text-muted-foreground" /></div>
      ) : projects.length === 0 ? (
        <p className="text-center text-muted-foreground py-20">No projects yet.</p>
      ) : (
        <div className="grid gap-4 sm:grid-cols-2">
          {projects.map((p) => (
            <div key={p.id} className="rounded-xl border border-border bg-card overflow-hidden flex flex-col">
              {p.image_path && (
                <div className="h-40 w-full bg-muted">
                  <Image src={p.image_path} alt={p.name} fittingType="fill" className="h-40 w-full" />
                </div>
              )}
              <div className="p-5 flex flex-col flex-1">
                <div className="flex items-center gap-2 flex-wrap">
                  <h2 className="text-lg font-heading truncate">{p.name}</h2>
                  {!p.is_published && <Badge variant="outline">Draft</Badge>}
                  <Badge variant="secondary" className="capitalize">{p.status}</Badge>
                  <Badge variant="secondary" className="capitalize">{p.semester} {p.year}</Badge>
                </div>
                {p.description && <p className="text-sm text-muted-foreground mt-2 whitespace-pre-wrap line-clamp-3">{p.description}</p>}
                {perms.projects && (
                  <div className="flex gap-2 mt-4 pt-2 border-t border-border">
                    <Button variant="outline" size="sm" onClick={() => openEdit(p)}><Pencil className="w-4 h-4 mr-1.5" />Edit</Button>
                    <Button variant="outline" size="sm" onClick={() => handleDelete(p.id)}><Trash2 className="w-4 h-4 mr-1.5" />Delete</Button>
                  </div>
                )}
              </div>
            </div>
          ))}
        </div>
      )}

      {perms.projects && editing && (
        <Dialog open={dialogOpen} onOpenChange={(o) => { setDialogOpen(o); if (!o) setEditing(null); }}>
          <DialogContent className="max-w-lg">
            <DialogHeader><DialogTitle>Edit project</DialogTitle></DialogHeader>
            <ProjectForm initial={editing} submitting={submitting} onSubmit={handleSubmit} onCancel={() => { setDialogOpen(false); setEditing(null); }} />
          </DialogContent>
        </Dialog>
      )}
    </PublicLayout>
  );
}