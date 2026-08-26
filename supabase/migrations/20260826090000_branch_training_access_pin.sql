do $$
begin
  if not exists (
    select 1
    from pg_constraint constraint_row
    join pg_class table_row
      on table_row.oid = constraint_row.conrelid
    join pg_namespace schema_row
      on schema_row.oid = table_row.relnamespace
    where schema_row.nspname = 'public'
      and table_row.relname = 'branches'
      and constraint_row.conname = 'branches_organization_id_id_key'
  ) then
    alter table public.branches
      add constraint branches_organization_id_id_key unique (organization_id, id);
  end if;
end $$;

create table if not exists public.branch_training_access (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  branch_id uuid not null,
  enabled boolean not null default false,
  pin_hash bytea,
  salt bytea,
  kdf_version integer,
  cost integer,
  block_size integer,
  parallelization integer,
  credential_version uuid not null default gen_random_uuid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  primary key (organization_id, branch_id),
  constraint branch_training_access_branch_scope_fkey
    foreign key (organization_id, branch_id)
    references public.branches(organization_id, id)
    on delete cascade,
  constraint branch_training_access_pin_complete_check check (
    (
      pin_hash is null
      and salt is null
      and kdf_version is null
      and cost is null
      and block_size is null
      and parallelization is null
    )
    or (
      pin_hash is not null
      and length(pin_hash) = 32
      and salt is not null
      and length(salt) = 16
      and kdf_version = 1
      and cost = 16384
      and block_size = 8
      and parallelization = 1
    )
  ),
  constraint branch_training_access_enabled_requires_pin_check
    check (not enabled or pin_hash is not null)
);

create index if not exists branch_training_access_enabled_idx
  on public.branch_training_access (organization_id, enabled, branch_id)
  where enabled;

drop trigger if exists branch_training_access_set_updated_at on public.branch_training_access;
create trigger branch_training_access_set_updated_at
before update on public.branch_training_access
for each row execute function private.set_updated_at();

alter table public.branch_training_access enable row level security;

drop policy if exists branch_training_access_service_read on public.branch_training_access;
create policy branch_training_access_service_read
on public.branch_training_access
for select
to service_role
using (true);

drop policy if exists branch_training_access_service_write on public.branch_training_access;
create policy branch_training_access_service_write
on public.branch_training_access
for all
to service_role
using (true)
with check (true);

revoke all on table public.branch_training_access from public, anon, authenticated;
grant select, insert, update, delete on table public.branch_training_access to service_role;

create or replace function public.list_internal_admin_branch_training_access(
  actor_user_id uuid,
  target_organization_id uuid
)
returns table(
  branch_id uuid,
  enabled boolean,
  pin_configured boolean,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'Access denied' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.organizations organization
    where organization.id = target_organization_id
  ) then
    raise exception 'Organization not found' using errcode = 'P0002';
  end if;

  return query
  select
    branch.id,
    coalesce(access.enabled, false),
    access.pin_hash is not null,
    access.updated_at
  from public.branches branch
  left join public.branch_training_access access
    on access.organization_id = branch.organization_id
   and access.branch_id = branch.id
  where branch.organization_id = target_organization_id
  order by lower(branch.name), branch.id;
end;
$$;

create or replace function public.store_internal_admin_branch_training_access(
  actor_user_id uuid,
  target_organization_id uuid,
  target_branch_id uuid,
  new_enabled boolean,
  new_pin_hash bytea default null,
  new_salt bytea default null,
  new_kdf_version integer default null,
  new_cost integer default null,
  new_block_size integer default null,
  new_parallelization integer default null
)
returns table(
  branch_id uuid,
  enabled boolean,
  pin_configured boolean,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  branch_row public.branches%rowtype;
  saved public.branch_training_access%rowtype;
  has_new_pin boolean;
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'Access denied' using errcode = '42501';
  end if;

  select *
  into branch_row
  from public.branches branch
  where branch.organization_id = target_organization_id
    and branch.id = target_branch_id;

  if branch_row.id is null then
    raise exception 'Branch not found' using errcode = 'P0002';
  end if;

  if new_enabled and not exists (
    select 1
    from public.organizations organization
    where organization.id = target_organization_id
      and organization.active
  ) then
    raise exception 'Organization is inactive' using errcode = '22023';
  end if;

  if new_enabled and not branch_row.active then
    raise exception 'Branch is inactive' using errcode = '22023';
  end if;

  has_new_pin :=
    new_pin_hash is not null
    or new_salt is not null
    or new_kdf_version is not null
    or new_cost is not null
    or new_block_size is not null
    or new_parallelization is not null;

  if has_new_pin and not (
    new_pin_hash is not null
    and length(new_pin_hash) = 32
    and new_salt is not null
    and length(new_salt) = 16
    and new_kdf_version = 1
    and new_cost = 16384
    and new_block_size = 8
    and new_parallelization = 1
  ) then
    raise exception 'Invalid PIN credential' using errcode = '22023';
  end if;

  if new_enabled and not has_new_pin and not exists (
    select 1
    from public.branch_training_access access
    where access.organization_id = target_organization_id
      and access.branch_id = target_branch_id
      and access.pin_hash is not null
  ) then
    raise exception 'PIN is required' using errcode = '22023';
  end if;

  insert into public.branch_training_access as bta (
    organization_id,
    branch_id,
    enabled,
    pin_hash,
    salt,
    kdf_version,
    cost,
    block_size,
    parallelization,
    credential_version,
    updated_by
  )
  values (
    target_organization_id,
    target_branch_id,
    new_enabled,
    new_pin_hash,
    new_salt,
    new_kdf_version,
    new_cost,
    new_block_size,
    new_parallelization,
    case when has_new_pin then gen_random_uuid() else gen_random_uuid() end,
    actor_user_id
  )
  on conflict on constraint branch_training_access_pkey
  do update set
    enabled = excluded.enabled,
    pin_hash = case when has_new_pin then excluded.pin_hash else bta.pin_hash end,
    salt = case when has_new_pin then excluded.salt else bta.salt end,
    kdf_version = case when has_new_pin then excluded.kdf_version else bta.kdf_version end,
    cost = case when has_new_pin then excluded.cost else bta.cost end,
    block_size = case when has_new_pin then excluded.block_size else bta.block_size end,
    parallelization = case when has_new_pin then excluded.parallelization else bta.parallelization end,
    credential_version = case when has_new_pin or bta.enabled <> excluded.enabled then gen_random_uuid() else bta.credential_version end,
    updated_by = excluded.updated_by,
    updated_at = now()
  returning *
  into saved;

  return query select saved.branch_id, saved.enabled, saved.pin_hash is not null, saved.updated_at;
end;
$$;

create or replace function public.list_public_training_branches(
  organization_slug text
)
returns table(
  organization_id uuid,
  organization_name text,
  organization_name_ar text,
  branch_id uuid,
  branch_name text,
  branch_name_ar text
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    organization.id,
    organization.name,
    organization.name_ar,
    branch.id,
    branch.name,
    branch.name_ar
  from public.organizations organization
  join public.branches branch
    on branch.organization_id = organization.id
  join public.branch_training_access access
    on access.organization_id = branch.organization_id
   and access.branch_id = branch.id
  where organization.slug = btrim(lower(organization_slug))
    and organization.active
    and branch.active
    and access.enabled
    and access.pin_hash is not null
  order by lower(branch.name), branch.id;
$$;

create or replace function public.get_training_branch_access_credential(
  organization_slug text,
  target_branch_id uuid
)
returns table(
  organization_id uuid,
  organization_name text,
  organization_name_ar text,
  branch_id uuid,
  branch_name text,
  branch_name_ar text,
  credential_version uuid,
  pin_hash bytea,
  salt bytea,
  kdf_version integer,
  cost integer,
  block_size integer,
  parallelization integer
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    organization.id,
    organization.name,
    organization.name_ar,
    branch.id,
    branch.name,
    branch.name_ar,
    access.credential_version,
    access.pin_hash,
    access.salt,
    access.kdf_version,
    access.cost,
    access.block_size,
    access.parallelization
  from public.organizations organization
  join public.branches branch
    on branch.organization_id = organization.id
  join public.branch_training_access access
    on access.organization_id = branch.organization_id
   and access.branch_id = branch.id
  where organization.slug = btrim(lower(organization_slug))
    and organization.active
    and branch.id = target_branch_id
    and branch.active
    and access.enabled
    and access.pin_hash is not null;
$$;

create or replace function public.validate_training_branch_session(
  target_organization_id uuid,
  target_branch_id uuid,
  target_credential_version uuid
)
returns table(
  organization_id uuid,
  organization_name text,
  organization_name_ar text,
  branch_id uuid,
  branch_name text,
  branch_name_ar text
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    organization.id,
    organization.name,
    organization.name_ar,
    branch.id,
    branch.name,
    branch.name_ar
  from public.organizations organization
  join public.branches branch
    on branch.organization_id = organization.id
  join public.branch_training_access access
    on access.organization_id = branch.organization_id
   and access.branch_id = branch.id
  where organization.id = target_organization_id
    and organization.active
    and branch.id = target_branch_id
    and branch.active
    and access.enabled
    and access.pin_hash is not null
    and access.credential_version = target_credential_version;
$$;

revoke all on function public.list_internal_admin_branch_training_access(uuid, uuid) from public, anon, authenticated;
revoke all on function public.store_internal_admin_branch_training_access(uuid, uuid, uuid, boolean, bytea, bytea, integer, integer, integer, integer) from public, anon, authenticated;
revoke all on function public.list_public_training_branches(text) from public, anon, authenticated;
revoke all on function public.get_training_branch_access_credential(text, uuid) from public, anon, authenticated;
revoke all on function public.validate_training_branch_session(uuid, uuid, uuid) from public, anon, authenticated;

grant execute on function public.list_internal_admin_branch_training_access(uuid, uuid) to service_role;
grant execute on function public.store_internal_admin_branch_training_access(uuid, uuid, uuid, boolean, bytea, bytea, integer, integer, integer, integer) to service_role;
grant execute on function public.list_public_training_branches(text) to service_role;
grant execute on function public.get_training_branch_access_credential(text, uuid) to service_role;
grant execute on function public.validate_training_branch_session(uuid, uuid, uuid) to service_role;
