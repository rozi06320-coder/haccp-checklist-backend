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

revoke all on function public.store_internal_admin_branch_training_access(uuid, uuid, uuid, boolean, bytea, bytea, integer, integer, integer, integer) from public, anon, authenticated;
grant execute on function public.store_internal_admin_branch_training_access(uuid, uuid, uuid, boolean, bytea, bytea, integer, integer, integer, integer) to service_role;
