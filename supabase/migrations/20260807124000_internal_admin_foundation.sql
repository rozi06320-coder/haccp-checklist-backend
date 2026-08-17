create table public.internal_admin_memberships (
  user_id uuid primary key references auth.users(id) on delete cascade,
  active boolean not null default true,
  created_by uuid null references auth.users(id) on delete set null,
  updated_by uuid null references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.internal_admin_memberships enable row level security;
revoke all on table public.internal_admin_memberships from public, anon, authenticated, service_role;
grant select on table public.internal_admin_memberships to authenticated;

create trigger internal_admin_memberships_set_updated_at
before update on public.internal_admin_memberships
for each row execute function private.set_updated_at();

create function private.is_internal_admin(actor_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.internal_admin_memberships membership
    join public.profiles profile on profile.id = membership.user_id
    where membership.user_id = actor_user_id
      and membership.active
      and profile.disabled_at is null
      and not profile.must_change_password
  );
$$;

revoke all on function private.is_internal_admin(uuid) from public, anon, authenticated;
grant execute on function private.is_internal_admin(uuid) to authenticated;

create policy internal_admin_memberships_select_own_or_internal_admin
on public.internal_admin_memberships
for select
to authenticated
using (
  user_id = auth.uid()
  or private.is_internal_admin(auth.uid())
);

comment on table public.internal_admin_memberships is
  'Platform-level Internal Admin access foundation. Internal Admin provisioning behavior is intentionally added in later phases.';
comment on function private.is_internal_admin(uuid) is
  'Returns true only for active Internal Admin memberships whose profile is enabled and has completed temporary password setup.';
