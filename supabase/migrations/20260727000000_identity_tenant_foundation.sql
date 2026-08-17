create schema if not exists private;

revoke all on schema private from public;
revoke all on schema private from anon;
revoke all on schema private from authenticated;

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) > 0),
  slug text not null unique check (slug = lower(slug) and slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.branches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (length(btrim(name)) > 0),
  code text not null check (length(btrim(code)) > 0),
  timezone text not null default 'Asia/Riyadh' check (length(btrim(timezone)) > 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branches_organization_code_key unique (organization_id, code)
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text check (full_name is null or length(btrim(full_name)) > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.organization_memberships (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role = 'organization_manager'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (organization_id, user_id)
);

create table public.branch_memberships (
  branch_id uuid not null references public.branches(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('staff', 'branch_manager')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (branch_id, user_id)
);

create index organization_memberships_user_id_idx
  on public.organization_memberships (user_id);
create index branch_memberships_user_id_idx
  on public.branch_memberships (user_id);

create function private.is_organization_manager(target_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.organization_memberships membership
    where membership.organization_id = target_organization_id
      and membership.user_id = auth.uid()
      and membership.role = 'organization_manager'
  );
$$;

create function private.has_branch_access(target_branch_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.branch_memberships membership
    where membership.branch_id = target_branch_id
      and membership.user_id = auth.uid()
      and membership.role in ('staff', 'branch_manager')
  )
  or exists (
    select 1
    from public.branches branch
    join public.organization_memberships membership
      on membership.organization_id = branch.organization_id
    where branch.id = target_branch_id
      and membership.user_id = auth.uid()
      and membership.role = 'organization_manager'
  );
$$;

create function private.has_organization_access(target_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_organization_manager(target_organization_id)
  or exists (
    select 1
    from public.branches branch
    join public.branch_memberships membership
      on membership.branch_id = branch.id
    where branch.organization_id = target_organization_id
      and membership.user_id = auth.uid()
      and membership.role in ('staff', 'branch_manager')
  );
$$;

revoke all on function private.is_organization_manager(uuid) from public;
revoke all on function private.has_branch_access(uuid) from public;
revoke all on function private.has_organization_access(uuid) from public;
grant execute on function private.is_organization_manager(uuid) to authenticated;
grant execute on function private.has_branch_access(uuid) to authenticated;
grant execute on function private.has_organization_access(uuid) to authenticated;

create function private.set_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

revoke all on function private.set_updated_at() from public;

create trigger organizations_set_updated_at
before update on public.organizations
for each row execute function private.set_updated_at();

create trigger branches_set_updated_at
before update on public.branches
for each row execute function private.set_updated_at();

create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function private.set_updated_at();

create trigger organization_memberships_set_updated_at
before update on public.organization_memberships
for each row execute function private.set_updated_at();

create trigger branch_memberships_set_updated_at
before update on public.branch_memberships
for each row execute function private.set_updated_at();

create function private.create_profile_for_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id);
  return new;
end;
$$;

revoke all on function private.create_profile_for_new_user() from public;

create trigger create_profile_after_user_insert
after insert on auth.users
for each row execute function private.create_profile_for_new_user();

alter table public.organizations enable row level security;
alter table public.branches enable row level security;
alter table public.profiles enable row level security;
alter table public.organization_memberships enable row level security;
alter table public.branch_memberships enable row level security;

create policy organizations_select_authorized
on public.organizations
for select
to authenticated
using (private.has_organization_access(id));

create policy branches_select_authorized
on public.branches
for select
to authenticated
using (private.has_branch_access(id));

create policy profiles_select_own
on public.profiles
for select
to authenticated
using (id = auth.uid());

create policy profiles_update_own
on public.profiles
for update
to authenticated
using (id = auth.uid())
with check (id = auth.uid());

create policy organization_memberships_select_own_or_manager
on public.organization_memberships
for select
to authenticated
using (
  user_id = auth.uid()
  or private.is_organization_manager(organization_id)
);

create policy branch_memberships_select_own_or_organization_manager
on public.branch_memberships
for select
to authenticated
using (
  user_id = auth.uid()
  or private.is_organization_manager(
    (select branch.organization_id from public.branches branch where branch.id = branch_id)
  )
);

revoke all on table public.organizations from public, anon, authenticated;
revoke all on table public.branches from public, anon, authenticated;
revoke all on table public.profiles from public, anon, authenticated;
revoke all on table public.organization_memberships from public, anon, authenticated;
revoke all on table public.branch_memberships from public, anon, authenticated;

grant select on table public.organizations to authenticated;
grant select on table public.branches to authenticated;
grant select on table public.profiles to authenticated;
grant update (full_name) on table public.profiles to authenticated;
grant select on table public.organization_memberships to authenticated;
grant select on table public.branch_memberships to authenticated;
