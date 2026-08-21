-- Cold Storage equipment management: update name/type and archive master rows.
-- Submitted history remains protected because daily reports read submission
-- snapshots from public.cold_storage_equipment, not the mutable branch master.

create function public.update_supervisor_cold_storage_equipment(
  actor_user_id uuid,
  target_branch_id uuid,
  target_equipment_id uuid,
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
  updated_equipment public.branch_cold_storage_equipment%rowtype;
begin
  if equipment_type not in ('refrigerator', 'freezer') then
    raise exception 'invalid cold storage equipment type' using errcode = '22023';
  end if;

  select * into strict actor_context
  from private.phase4a_actor_context(actor_user_id, target_branch_id);

  update public.branch_cold_storage_equipment equipment
  set name = clean_name,
    equipment_type = update_supervisor_cold_storage_equipment.equipment_type,
    updated_by = actor_user_id
  where equipment.id = target_equipment_id
    and equipment.organization_id = actor_context.organization_id
    and equipment.branch_id = actor_context.branch_id
    and equipment.active
  returning equipment.* into strict updated_equipment;

  return query
  select
    updated_equipment.id,
    updated_equipment.branch_id,
    updated_equipment.name,
    updated_equipment.equipment_type,
    updated_equipment.active,
    updated_equipment.updated_at;
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage equipment access denied' using errcode = '42501';
end;
$$;

create or replace function public.rename_supervisor_cold_storage_equipment(
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
    and equipment.active
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

create function public.archive_supervisor_cold_storage_equipment(
  actor_user_id uuid,
  target_branch_id uuid,
  target_equipment_id uuid
)
returns setof public.supervisor_cold_storage_equipment_dto
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor_context record;
  archived_equipment public.branch_cold_storage_equipment%rowtype;
begin
  select * into strict actor_context
  from private.phase4a_actor_context(actor_user_id, target_branch_id);

  update public.branch_cold_storage_equipment equipment
  set active = false,
    updated_by = actor_user_id
  where equipment.id = target_equipment_id
    and equipment.organization_id = actor_context.organization_id
    and equipment.branch_id = actor_context.branch_id
    and equipment.active
  returning equipment.* into strict archived_equipment;

  return query
  select
    archived_equipment.id,
    archived_equipment.branch_id,
    archived_equipment.name,
    archived_equipment.equipment_type,
    archived_equipment.active,
    archived_equipment.updated_at;
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage equipment access denied' using errcode = '42501';
end;
$$;

revoke all on function public.update_supervisor_cold_storage_equipment(uuid, uuid, uuid, text, text)
  from public, anon, authenticated;
revoke all on function public.rename_supervisor_cold_storage_equipment(uuid, uuid, uuid, text)
  from public, anon, authenticated;
revoke all on function public.archive_supervisor_cold_storage_equipment(uuid, uuid, uuid)
  from public, anon, authenticated;

grant execute on function public.update_supervisor_cold_storage_equipment(uuid, uuid, uuid, text, text)
  to service_role;
grant execute on function public.rename_supervisor_cold_storage_equipment(uuid, uuid, uuid, text)
  to service_role;
grant execute on function public.archive_supervisor_cold_storage_equipment(uuid, uuid, uuid)
  to service_role;
