-- Cold Storage equipment master Phase 2: Supervisor list/create/rename RPCs.
-- Daily submission snapshots and their persistence RPCs are intentionally unchanged.

create function private.clean_cold_storage_equipment_name(candidate text)
returns text
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  cleaned text := nullif(
    pg_catalog.regexp_replace(
      pg_catalog.btrim(coalesce(candidate, '')),
      '[[:space:]]+',
      ' ',
      'g'
    ),
    ''
  );
begin
  if cleaned is null or pg_catalog.length(cleaned) > 120 then
    raise exception 'invalid cold storage equipment name' using errcode = '22023';
  end if;
  return cleaned;
end;
$$;

revoke all on function private.clean_cold_storage_equipment_name(text)
  from public, anon, authenticated, service_role;

create type public.supervisor_cold_storage_equipment_dto as (
  id uuid,
  branch_id uuid,
  name text,
  equipment_type text,
  active boolean,
  updated_at timestamptz
);

revoke all on type public.supervisor_cold_storage_equipment_dto
  from public, anon, authenticated;
grant usage on type public.supervisor_cold_storage_equipment_dto
  to service_role;

create function public.list_supervisor_cold_storage_equipment(
  actor_user_id uuid,
  target_branch_id uuid
)
returns setof public.supervisor_cold_storage_equipment_dto
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  actor_context record;
begin
  select * into strict actor_context
  from private.phase4a_actor_context(actor_user_id, target_branch_id);

  return query
  select
    equipment.id,
    equipment.branch_id,
    equipment.name,
    equipment.equipment_type,
    equipment.active,
    equipment.updated_at
  from public.branch_cold_storage_equipment equipment
  where equipment.organization_id = actor_context.organization_id
    and equipment.branch_id = actor_context.branch_id
    and equipment.active
  order by pg_catalog.lower(equipment.name), equipment.id;
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage equipment access denied' using errcode = '42501';
end;
$$;

create function public.create_supervisor_cold_storage_equipment(
  actor_user_id uuid,
  target_branch_id uuid,
  equipment_name text,
  equipment_type text
)
returns setof public.supervisor_cold_storage_equipment_dto
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_context record;
  clean_name text := private.clean_cold_storage_equipment_name(equipment_name);
  created_equipment public.branch_cold_storage_equipment%rowtype;
begin
  if equipment_type not in ('refrigerator', 'freezer') then
    raise exception 'invalid cold storage equipment type' using errcode = '22023';
  end if;

  select * into strict actor_context
  from private.phase4a_actor_context(actor_user_id, target_branch_id);

  insert into public.branch_cold_storage_equipment (
    organization_id,
    branch_id,
    name,
    equipment_type,
    active,
    created_by
  ) values (
    actor_context.organization_id,
    actor_context.branch_id,
    clean_name,
    equipment_type,
    true,
    actor_user_id
  )
  returning * into created_equipment;

  return query
  select
    created_equipment.id,
    created_equipment.branch_id,
    created_equipment.name,
    created_equipment.equipment_type,
    created_equipment.active,
    created_equipment.updated_at;
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage equipment access denied' using errcode = '42501';
end;
$$;

create function public.rename_supervisor_cold_storage_equipment(
  actor_user_id uuid,
  target_branch_id uuid,
  target_equipment_id uuid,
  equipment_name text
)
returns setof public.supervisor_cold_storage_equipment_dto
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_context record;
  clean_name text := private.clean_cold_storage_equipment_name(equipment_name);
  renamed_equipment public.branch_cold_storage_equipment%rowtype;
begin
  select * into strict actor_context
  from private.phase4a_actor_context(actor_user_id, target_branch_id);

  update public.branch_cold_storage_equipment equipment
  set name = clean_name,
    updated_by = actor_user_id
  where equipment.id = target_equipment_id
    and equipment.organization_id = actor_context.organization_id
    and equipment.branch_id = actor_context.branch_id
  returning equipment.* into strict renamed_equipment;

  return query
  select
    renamed_equipment.id,
    renamed_equipment.branch_id,
    renamed_equipment.name,
    renamed_equipment.equipment_type,
    renamed_equipment.active,
    renamed_equipment.updated_at;
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage equipment access denied' using errcode = '42501';
end;
$$;

revoke all on function public.list_supervisor_cold_storage_equipment(uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.create_supervisor_cold_storage_equipment(uuid, uuid, text, text)
  from public, anon, authenticated;
revoke all on function public.rename_supervisor_cold_storage_equipment(uuid, uuid, uuid, text)
  from public, anon, authenticated;

grant execute on function public.list_supervisor_cold_storage_equipment(uuid, uuid)
  to service_role;
grant execute on function public.create_supervisor_cold_storage_equipment(uuid, uuid, text, text)
  to service_role;
grant execute on function public.rename_supervisor_cold_storage_equipment(uuid, uuid, uuid, text)
  to service_role;
