-- 006: storage buckets and policies
-- All writes and signed-URL creation go through Edge Functions (service role).
-- Public buckets are anon-readable; private buckets require a signed URL.
begin;

insert into storage.buckets (id, name, public) values
  ('profile-photos', 'profile-photos', false),
  ('project-images', 'project-images', true),
  ('site-assets', 'site-assets', true),
  ('export-files', 'export-files', false)
on conflict (id) do nothing;

-- Reads: allow anon reads only on public buckets.
create policy "storage read public buckets" on storage.objects for select
  using (bucket_id in ('project-images','site-assets'));

-- Writes: clients cannot write/update/delete; only the service role (Edge Functions) can.
create policy "storage no client insert" on storage.objects for insert with check (false);
create policy "storage no client update" on storage.objects for update using (false) with check (false);
create policy "storage no client delete" on storage.objects for delete using (false);

commit;