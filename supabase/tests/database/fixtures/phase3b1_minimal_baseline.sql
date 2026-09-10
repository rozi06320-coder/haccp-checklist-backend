-- Phase 3B1 Minimal Test Baseline Fixture
-- Creates ONLY the prerequisite schema objects required by Phase 3A & Phase 3B1 tests.
-- Does NOT include unrelated production modules (checklists, oil, cold storage, maintenance, etc.).

-- 1. Required extensions
create extension if not exists pgtap;
create extension if not exists pgcrypto;

-- 2. Ensure standard Supabase roles exist
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin;
  end if;
end $$;

-- 3. Ensure auth schema, helpers, and auth.users exist
create schema if not exists auth;
grant usage on schema auth to anon, authenticated, service_role;

create or replace function auth.uid()
returns uuid
language sql stable
as $$
  select
  coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

create or replace function auth.role()
returns text
language sql stable
as $$
  select
  coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$$;

grant execute on function auth.uid() to anon, authenticated, service_role;
grant execute on function auth.role() to anon, authenticated, service_role;

create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  instance_id uuid,
  aud text,
  role text,
  email text,
  raw_app_meta_data jsonb default '{}'::jsonb,
  raw_user_meta_data jsonb default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- 4. Schema private
create schema if not exists private;
revoke all on schema private from public;
revoke all on schema private from anon;
revoke all on schema private from authenticated;
grant usage on schema private to service_role;

-- 5. Helper function: set_updated_at
create or replace function private.set_updated_at()
returns trigger language plpgsql security invoker set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
revoke all on function private.set_updated_at() from public;

-- 6. Table: public.organizations
create table if not exists public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) > 0),
  slug text not null unique check (slug = lower(slug) and slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
drop trigger if exists organizations_set_updated_at on public.organizations;
create trigger organizations_set_updated_at
before update on public.organizations
for each row execute function private.set_updated_at();

-- 7. Table: public.branches
create table if not exists public.branches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (length(btrim(name)) > 0),
  code text not null check (length(btrim(code)) > 0),
  timezone text not null default 'Asia/Riyadh' check (length(btrim(timezone)) > 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branches_id_organization_id_key unique (id, organization_id),
  constraint branches_organization_code_key unique (organization_id, code)
);
drop trigger if exists branches_set_updated_at on public.branches;
create trigger branches_set_updated_at
before update on public.branches
for each row execute function private.set_updated_at();

-- 8. Table: public.profiles
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text check (full_name is null or length(btrim(full_name)) > 0),
  must_change_password boolean not null default false,
  disabled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function private.set_updated_at();

-- 9. Trigger: profile creation on auth.users insert
create or replace function private.create_profile_for_new_user()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$$;
revoke all on function private.create_profile_for_new_user() from public;
drop trigger if exists create_profile_after_user_insert on auth.users;
create trigger create_profile_after_user_insert
after insert on auth.users
for each row execute function private.create_profile_for_new_user();

-- 10. Table: public.organization_memberships
create table if not exists public.organization_memberships (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role = 'organization_manager'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (organization_id, user_id)
);
drop trigger if exists organization_memberships_set_updated_at on public.organization_memberships;
create trigger organization_memberships_set_updated_at
before update on public.organization_memberships
for each row execute function private.set_updated_at();

-- 11. Table: public.branch_memberships
create table if not exists public.branch_memberships (
  branch_id uuid not null references public.branches(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('staff', 'branch_manager')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (branch_id, user_id)
);
drop trigger if exists branch_memberships_set_updated_at on public.branch_memberships;
create trigger branch_memberships_set_updated_at
before update on public.branch_memberships
for each row execute function private.set_updated_at();

-- 12. Table: public.branch_supervisor_teams
create table if not exists public.branch_supervisor_teams (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  supervisor_user_id uuid not null references auth.users(id) on delete restrict,
  shift_id uuid,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branch_supervisor_teams_branch_scope_fkey foreign key (branch_id, organization_id)
    references public.branches(id, organization_id) on delete restrict,
  constraint branch_supervisor_teams_id_branch_organization_key unique (id, branch_id, organization_id)
);
drop trigger if exists branch_supervisor_teams_set_updated_at on public.branch_supervisor_teams;
create trigger branch_supervisor_teams_set_updated_at
before update on public.branch_supervisor_teams
for each row execute function private.set_updated_at();

-- 13. Authorization helpers
create or replace function private.is_organization_manager(target_organization_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.organization_memberships membership
    join public.organizations organization on organization.id = membership.organization_id
    where membership.organization_id = target_organization_id
      and membership.user_id = auth.uid()
      and membership.role = 'organization_manager'
      and organization.active
  );
$$;
revoke all on function private.is_organization_manager(uuid) from public;
grant execute on function private.is_organization_manager(uuid) to authenticated;

create or replace function private.has_branch_access(target_branch_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.branch_memberships membership
    join public.branches branch on branch.id = membership.branch_id
    join public.organizations organization on organization.id = branch.organization_id
    where membership.branch_id = target_branch_id
      and membership.user_id = auth.uid()
      and membership.role in ('staff', 'branch_manager')
      and membership.active and branch.active and organization.active
  )
  or exists (
    select 1
    from public.branches branch
    join public.organizations organization on organization.id = branch.organization_id
    join public.organization_memberships membership on membership.organization_id = branch.organization_id
    where branch.id = target_branch_id and branch.active and organization.active
      and membership.user_id = auth.uid() and membership.role = 'organization_manager'
  );
$$;
revoke all on function private.has_branch_access(uuid) from public;
grant execute on function private.has_branch_access(uuid) to authenticated;

-- 14. Canonical 04:00 AM business-date helpers
create or replace function private.phase4a_business_date_at(tz text, as_of timestamptz)
returns date language sql stable strict security definer set search_path = ''
as $$
  select ((as_of at time zone tz) - interval '4 hours')::date
$$;
revoke all on function private.phase4a_business_date_at(text, timestamptz) from public, anon, authenticated;
grant execute on function private.phase4a_business_date_at(text, timestamptz) to service_role;

create or replace function private.phase4a_business_date(tz text)
returns date language sql stable strict security definer set search_path = ''
as $$
  select private.phase4a_business_date_at(tz, pg_catalog.statement_timestamp())
$$;
revoke all on function private.phase4a_business_date(text) from public, anon, authenticated;
grant execute on function private.phase4a_business_date(text) to service_role;

-- 15. Context helper: phase2_branch_context
create or replace function private.phase2_branch_context(actor uuid, target_branch uuid)
returns table(
  organization_id uuid,
  branch_id uuid,
  legacy_team_id uuid,
  business_date date,
  branch_name text,
  branch_code text,
  actor_name text
)
language sql stable security definer set search_path = '' as $$
  select
    b.organization_id,
    b.id,
    t.id,
    private.phase4a_business_date(b.timezone),
    b.name,
    b.code,
    p.full_name
  from public.profiles p
  join public.branch_memberships m
    on m.user_id = p.id
   and m.branch_id = target_branch
   and m.role = 'branch_manager'
   and m.active
  join public.branches b
    on b.id = m.branch_id
   and b.active
  join public.organizations o
    on o.id = b.organization_id
   and o.active
  join lateral (
    select legacy.id
    from public.branch_supervisor_teams legacy
    where legacy.branch_id = b.id
      and legacy.organization_id = b.organization_id
      and legacy.supervisor_user_id = p.id
    order by legacy.active desc, legacy.created_at, legacy.id
    limit 1
  ) t on true
  where p.id = actor
    and p.disabled_at is null
    and not p.must_change_password
$$;
revoke all on function private.phase2_branch_context(uuid, uuid) from public, anon, authenticated;
grant execute on function private.phase2_branch_context(uuid, uuid) to service_role;

-- 16. Baseline RLS policies and table grants
alter table public.organizations enable row level security;
alter table public.branches enable row level security;
alter table public.profiles enable row level security;
alter table public.organization_memberships enable row level security;
alter table public.branch_memberships enable row level security;
alter table public.branch_supervisor_teams enable row level security;

create policy organizations_select_authorized on public.organizations
  for select to authenticated using (private.is_organization_manager(id));

create policy branches_select_authorized on public.branches
  for select to authenticated using (private.has_branch_access(id));

create policy profiles_select_own on public.profiles
  for select to authenticated using (id = auth.uid());

create policy profiles_update_own on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

grant usage on schema public to anon, authenticated, service_role;
grant usage on schema private to service_role;

grant select on table public.organizations to authenticated;
grant select on table public.branches to authenticated;
grant select on table public.profiles to authenticated;
grant update (full_name) on table public.profiles to authenticated;
grant update (must_change_password, disabled_at) on table public.profiles to service_role;
grant select on table public.branch_memberships to authenticated;
grant select on table public.organization_memberships to authenticated;
grant select on table public.branch_supervisor_teams to authenticated;
