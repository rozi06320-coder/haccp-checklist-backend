-- Cold Storage equipment code P0.
-- Existing master and historical snapshot rows remain nullable for rollout.

alter table public.branch_cold_storage_equipment
  add column equipment_code text null,
  add constraint branch_cold_storage_equipment_code_check check (
    equipment_code is null
    or (
      equipment_code = pg_catalog.upper(pg_catalog.btrim(equipment_code))
      and pg_catalog.length(equipment_code) between 1 and 24
      and equipment_code ~ '^[A-Z0-9-]+$'
    )
  );

alter table public.cold_storage_equipment
  add column equipment_code text null,
  add constraint cold_storage_equipment_code_check check (
    equipment_code is null
    or (
      equipment_code = pg_catalog.upper(pg_catalog.btrim(equipment_code))
      and pg_catalog.length(equipment_code) between 1 and 24
      and equipment_code ~ '^[A-Z0-9-]+$'
    )
  );

create unique index branch_cold_storage_equipment_active_equipment_code_key
  on public.branch_cold_storage_equipment (
    organization_id,
    branch_id,
    equipment_code
  )
  where active and equipment_code is not null;

create function private.clean_cold_storage_equipment_code(candidate text)
returns text
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  cleaned text := pg_catalog.upper(pg_catalog.btrim(coalesce(candidate, '')));
begin
  if cleaned = ''
    or pg_catalog.length(cleaned) > 24
    or cleaned !~ '^[A-Z0-9-]+$'
  then
    raise exception 'invalid cold storage equipment code' using errcode = '22023';
  end if;
  return cleaned;
end;
$$;

revoke all on function private.clean_cold_storage_equipment_code(text)
  from public, anon, authenticated, service_role;

alter type public.supervisor_cold_storage_equipment_dto
  add attribute equipment_code text;

drop function public.create_supervisor_cold_storage_equipment(uuid, uuid, text, text);
drop function public.update_supervisor_cold_storage_equipment(uuid, uuid, uuid, text, text);

create or replace function public.list_supervisor_cold_storage_equipment(
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
    equipment.updated_at,
    equipment.equipment_code
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
  equipment_code text,
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
  clean_code text := private.clean_cold_storage_equipment_code(equipment_code);
  clean_name text := private.clean_cold_storage_equipment_name(equipment_name);
  created_equipment public.branch_cold_storage_equipment%rowtype;
begin
  if equipment_type not in ('refrigerator', 'freezer') then
    raise exception 'invalid cold storage equipment type' using errcode = '22023';
  end if;

  select * into strict actor_context
  from private.phase4a_actor_context(actor_user_id, target_branch_id);

  if exists (
    select 1
    from public.branch_cold_storage_equipment existing
    where existing.organization_id = actor_context.organization_id
      and existing.branch_id = actor_context.branch_id
      and existing.active
      and existing.equipment_code = clean_code
  ) then
    raise exception 'equipment code already exists' using errcode = '23505';
  end if;

  insert into public.branch_cold_storage_equipment (
    organization_id,
    branch_id,
    equipment_code,
    name,
    equipment_type,
    active,
    created_by
  ) values (
    actor_context.organization_id,
    actor_context.branch_id,
    clean_code,
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
    created_equipment.updated_at,
    created_equipment.equipment_code;
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage equipment access denied' using errcode = '42501';
end;
$$;

create function public.update_supervisor_cold_storage_equipment(
  actor_user_id uuid,
  target_branch_id uuid,
  target_equipment_id uuid,
  equipment_code text,
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
  clean_code text := private.clean_cold_storage_equipment_code(equipment_code);
  clean_name text := private.clean_cold_storage_equipment_name(equipment_name);
  updated_equipment public.branch_cold_storage_equipment%rowtype;
begin
  if equipment_type not in ('refrigerator', 'freezer') then
    raise exception 'invalid cold storage equipment type' using errcode = '22023';
  end if;

  select * into strict actor_context
  from private.phase4a_actor_context(actor_user_id, target_branch_id);

  if exists (
    select 1
    from public.branch_cold_storage_equipment existing
    where existing.organization_id = actor_context.organization_id
      and existing.branch_id = actor_context.branch_id
      and existing.id <> target_equipment_id
      and existing.active
      and existing.equipment_code = clean_code
  ) then
    raise exception 'equipment code already exists' using errcode = '23505';
  end if;

  update public.branch_cold_storage_equipment equipment
  set equipment_code = clean_code,
    name = clean_name,
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
    updated_equipment.updated_at,
    updated_equipment.equipment_code;
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
    renamed_equipment.updated_at,
    renamed_equipment.equipment_code;
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage equipment access denied' using errcode = '42501';
end;
$$;

create or replace function public.archive_supervisor_cold_storage_equipment(
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
    archived_equipment.updated_at,
    archived_equipment.equipment_code;
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage equipment access denied' using errcode = '42501';
end;
$$;

create or replace function private.resolve_cold_storage_equipment_roster(
  target_organization_id uuid,
  target_branch_id uuid,
  supplied_equipment jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  entry jsonb;
  equipment_key text;
  explicit_master boolean;
  master_id uuid;
  master_row public.branch_cold_storage_equipment%rowtype;
  legacy_equipment jsonb := '[]'::jsonb;
  resolved_equipment jsonb;
begin
  if supplied_equipment is null
    or pg_catalog.jsonb_typeof(supplied_equipment) <> 'array'
    or pg_catalog.jsonb_array_length(supplied_equipment) > 100
  then
    raise exception 'invalid cold storage equipment' using errcode = '22023';
  end if;

  if (
    select pg_catalog.count(*) <> pg_catalog.count(distinct pg_catalog.btrim(value ->> 'equipment_id'))
    from pg_catalog.jsonb_array_elements(supplied_equipment)
  ) then
    raise exception 'duplicate cold storage equipment' using errcode = '22023';
  end if;

  for entry in
    select value from pg_catalog.jsonb_array_elements(supplied_equipment)
  loop
    if not (entry ? 'equipment_id')
      or pg_catalog.jsonb_typeof(entry -> 'equipment_id') <> 'string'
      or pg_catalog.length(pg_catalog.btrim(entry ->> 'equipment_id')) not between 1 and 80
    then
      raise exception 'invalid cold storage equipment row' using errcode = '22023';
    end if;

    equipment_key := pg_catalog.btrim(entry ->> 'equipment_id');
    explicit_master := entry ? 'master_equipment_id';

    if explicit_master then
      if pg_catalog.jsonb_typeof(entry -> 'master_equipment_id') <> 'string' then
        raise exception 'invalid cold storage master equipment' using errcode = '22023';
      end if;
      master_id := private.cold_storage_try_uuid(pg_catalog.btrim(entry ->> 'master_equipment_id'));
      if master_id is null or equipment_key <> master_id::text then
        raise exception 'invalid cold storage master equipment' using errcode = '22023';
      end if;
    else
      master_id := private.cold_storage_try_uuid(equipment_key);
    end if;

    master_row := null;
    if master_id is not null then
      select master.* into master_row
      from public.branch_cold_storage_equipment master
      where master.id = master_id;
    end if;

    if master_row.id is not null then
      if master_row.organization_id <> target_organization_id
        or master_row.branch_id <> target_branch_id
        or not master_row.active
      then
        raise exception 'cold storage master equipment denied' using errcode = '42501';
      end if;
      continue;
    elsif explicit_master then
      raise exception 'cold storage master equipment denied' using errcode = '42501';
    end if;

    if not (entry ? 'equipment_name' and entry ? 'equipment_type')
      or pg_catalog.jsonb_typeof(entry -> 'equipment_name') <> 'string'
      or pg_catalog.length(pg_catalog.btrim(entry ->> 'equipment_name')) not between 1 and 120
      or entry ->> 'equipment_type' not in ('refrigerator', 'freezer')
      or (entry ? 'active' and pg_catalog.jsonb_typeof(entry -> 'active') <> 'boolean')
    then
      raise exception 'invalid cold storage equipment row' using errcode = '22023';
    end if;

    legacy_equipment := legacy_equipment || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'equipment_id', equipment_key,
        'equipment_code', case
          when nullif(pg_catalog.btrim(coalesce(entry ->> 'equipment_code', '')), '') is null then null
          else private.clean_cold_storage_equipment_code(entry ->> 'equipment_code')
        end,
        'equipment_name', pg_catalog.btrim(entry ->> 'equipment_name'),
        'equipment_type', entry ->> 'equipment_type',
        'active', coalesce((entry ->> 'active')::boolean, true)
      ))
    );
  end loop;

  select coalesce(
    pg_catalog.jsonb_agg(roster.item order by roster.sort_name, roster.equipment_id),
    '[]'::jsonb
  ) into resolved_equipment
  from (
    select
      master.id::text as equipment_id,
      pg_catalog.lower(master.name) as sort_name,
      pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'equipment_id', master.id::text,
        'master_equipment_id', master.id,
        'organization_id', master.organization_id,
        'branch_id', master.branch_id,
        'equipment_code', master.equipment_code,
        'equipment_name', master.name,
        'equipment_type', master.equipment_type,
        'active', true
      )) as item
    from public.branch_cold_storage_equipment master
    where master.organization_id = target_organization_id
      and master.branch_id = target_branch_id
      and master.active

    union all

    select
      legacy.value ->> 'equipment_id',
      pg_catalog.lower(legacy.value ->> 'equipment_name'),
      legacy.value
    from pg_catalog.jsonb_array_elements(legacy_equipment) legacy(value)
  ) roster;

  if pg_catalog.jsonb_array_length(resolved_equipment) > 100 then
    raise exception 'invalid cold storage equipment' using errcode = '22023';
  end if;

  return resolved_equipment;
end;
$$;

create or replace function private.cold_storage_snapshot_equipment(target_submission_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'id', equipment.id,
        'equipment_id', equipment.equipment_id,
        'master_equipment_id', equipment.master_equipment_id,
        'organization_id', equipment.organization_id,
        'branch_id', equipment.branch_id,
        'equipment_code', equipment.equipment_code,
        'equipment_name', equipment.equipment_name,
        'equipment_type', equipment.equipment_type,
        'active', equipment.active
      ))
      order by pg_catalog.lower(equipment.equipment_name), equipment.equipment_id
    ),
    '[]'::jsonb
  )
  from public.cold_storage_equipment equipment
  where equipment.submission_id = target_submission_id;
$$;

create or replace function private.replace_cold_storage_equipment(
  submission_id uuid,
  equipment jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.cold_storage_equipment snapshot
  where snapshot.submission_id = replace_cold_storage_equipment.submission_id;

  insert into public.cold_storage_equipment(
    submission_id,
    equipment_id,
    equipment_code,
    equipment_name,
    equipment_type,
    active,
    master_equipment_id,
    organization_id,
    branch_id
  )
  select
    submission_id,
    pg_catalog.btrim(row_value ->> 'equipment_id'),
    case
      when nullif(pg_catalog.btrim(coalesce(row_value ->> 'equipment_code', '')), '') is null then null
      else private.clean_cold_storage_equipment_code(row_value ->> 'equipment_code')
    end,
    pg_catalog.btrim(row_value ->> 'equipment_name'),
    row_value ->> 'equipment_type',
    coalesce((row_value ->> 'active')::boolean, true),
    case when row_value ? 'master_equipment_id'
      then (row_value ->> 'master_equipment_id')::uuid else null end,
    case when row_value ? 'organization_id'
      then (row_value ->> 'organization_id')::uuid else null end,
    case when row_value ? 'branch_id'
      then (row_value ->> 'branch_id')::uuid else null end
  from pg_catalog.jsonb_array_elements(equipment) entry(row_value);
end;
$$;

create or replace function public.get_cold_storage_current_state(actor_user_id uuid,target_branch_id uuid)
returns jsonb language plpgsql security definer set search_path=''as $$declare c record;s public.cold_storage_submissions%rowtype;equipment_result jsonb;readings_result jsonb;has_submitted boolean:=false;begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 select*into s from public.cold_storage_submissions x where x.organization_id=c.organization_id and x.branch_id=c.branch_id and x.business_date=c.business_date;
 if s.id is not null then select exists(select 1 from public.cold_storage_readings r where r.submission_id=s.id and r.submitted_at is not null)into has_submitted;end if;
 if has_submitted then
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object('id',e.id,'equipment_id',e.equipment_id,'equipment_code',e.equipment_code,'equipment_name',e.equipment_name,'equipment_type',e.equipment_type,'active',e.active))order by lower(e.equipment_name),e.equipment_id),'[]'::jsonb)into equipment_result from public.cold_storage_equipment e where e.submission_id=s.id;
 else
  select coalesce(pg_catalog.jsonb_agg(q.item order by q.sort_name,q.equipment_id),'[]'::jsonb)into equipment_result from(
   select m.id::text equipment_id,lower(m.name)sort_name,pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object('id',e.id,'equipment_id',m.id::text,'equipment_code',m.equipment_code,'equipment_name',m.name,'equipment_type',m.equipment_type,'active',true))item
   from public.branch_cold_storage_equipment m left join lateral(select x.id from public.cold_storage_equipment x where x.submission_id=s.id and x.master_equipment_id=m.id limit 1)e on true
   where m.organization_id=c.organization_id and m.branch_id=c.branch_id and m.active
   union all select e.equipment_id,lower(e.equipment_name),pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object('id',e.id,'equipment_id',e.equipment_id,'equipment_code',e.equipment_code,'equipment_name',e.equipment_name,'equipment_type',e.equipment_type,'active',e.active))from public.cold_storage_equipment e where e.submission_id=s.id and e.master_equipment_id is null
  )q;
 end if;
 select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id',r.id,'equipment_id',coalesce(e.master_equipment_id::text,r.equipment_id),'slot',r.slot,'temperature_c',r.temperature_c,'status',r.status,'corrective_action',r.corrective_action,'submitted_at',r.submitted_at)order by coalesce(e.master_equipment_id::text,r.equipment_id),case r.slot when'12:00'then 1 when'20:00'then 2 when'02:00'then 3 when'3:00'then 4 else 5 end),'[]'::jsonb)into readings_result
 from public.cold_storage_readings r join public.cold_storage_equipment e on e.submission_id=r.submission_id and e.equipment_id=r.equipment_id left join public.branch_cold_storage_equipment m on m.id=e.master_equipment_id and m.organization_id=c.organization_id and m.branch_id=c.branch_id where r.submission_id=s.id and(has_submitted or e.master_equipment_id is null or m.active);
 return pg_catalog.jsonb_build_object('submission_id',s.id,'business_date',c.business_date,'state',coalesce(s.state,'none'),'revision',coalesce(s.branch_revision,0),'equipment',equipment_result,'readings',readings_result);
exception when no_data_found or too_many_rows then raise exception'cold storage state denied'using errcode='42501';end$$;

create or replace function public.get_cold_storage_report_detail(
  actor_user_id uuid,
  target_report_id uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.cold_storage_submissions%rowtype; submitted_time timestamptz; issue_total bigint; slot_total bigint;
begin
  select * into strict s from public.cold_storage_submissions x
  where x.id = target_report_id
    and exists (
      select 1
      from public.cold_storage_equipment e
      join public.cold_storage_readings r on r.submission_id = e.submission_id
        and r.equipment_id = e.equipment_id
        and r.submitted_at is not null
      where e.submission_id = x.id
        and e.active
    );
  if not (s.supervisor_user_id = actor_user_id and private.actor_owns_operational_team(actor_user_id, s.branch_id, s.supervisor_team_id)) then
    raise exception 'cold storage report access denied' using errcode = '42501';
  end if;
  select max(r.submitted_at), count(distinct r.slot) into submitted_time, slot_total
  from public.cold_storage_readings r
  join public.cold_storage_equipment e on e.submission_id = r.submission_id
    and e.equipment_id = r.equipment_id
    and e.active
  where r.submission_id = s.id
    and r.submitted_at is not null;
  select count(*) into issue_total from public.cold_storage_issues i where i.submission_id = s.id;
  return pg_catalog.jsonb_build_object(
    'id', s.id,
    'organization_id', s.organization_id,
    'branch_id', s.branch_id,
    'branch_name', s.branch_name_snapshot,
    'supervisor_team_id', s.supervisor_team_id,
    'business_date', s.business_date,
    'checklist_type', 'cold_storage',
    'definition_id', 'cold_storage_v1',
    'submitted_at', submitted_time,
    'submitted_by', s.supervisor_name_snapshot,
    'completion', pg_catalog.round((slot_total::numeric * 100) / 3),
    'issue_count', issue_total,
    'status',
      case
        when issue_total > 0 then 'issues_found'
        when slot_total < 3 then 'in_progress'
        else 'compliant'
      end,
    'submitted_slots', coalesce((
      select pg_catalog.jsonb_agg(distinct r.slot)
      from public.cold_storage_readings r
      join public.cold_storage_equipment e on e.submission_id = r.submission_id
        and e.equipment_id = r.equipment_id
        and e.active
      where r.submission_id = s.id
        and r.submitted_at is not null
    ), '[]'::jsonb),
    'rows', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'equipment_id', e.equipment_id,
        'equipment_code', e.equipment_code,
        'equipment_name', e.equipment_name,
        'equipment_type', e.equipment_type,
        'active', e.active,
        'slot', r.slot,
        'temperature_c', r.temperature_c,
        'status', r.status,
        'corrective_action', r.corrective_action,
        'submitted_at', r.submitted_at
      )) order by r.slot, e.equipment_id)
      from public.cold_storage_readings r
      join public.cold_storage_equipment e on e.submission_id = r.submission_id
        and e.equipment_id = r.equipment_id
      where r.submission_id = s.id
        and r.submitted_at is not null
    ), '[]'::jsonb),
    'issues', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
        'id', i.id,
        'equipment_id', i.equipment_id,
        'equipment_code', e.equipment_code,
        'equipment_name', coalesce(e.equipment_name, i.equipment_id),
        'slot', i.slot,
        'temperature_c', i.temperature_c,
        'title', 'Cold Storage temperature issue',
        'remark', i.corrective_action
      )) order by i.slot, i.equipment_id)
      from public.cold_storage_issues i
      left join public.cold_storage_equipment e on e.submission_id = i.submission_id
        and e.equipment_id = i.equipment_id
      where i.submission_id = s.id
    ), '[]'::jsonb)
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage report access denied' using errcode = '42501';
end $$;

create or replace function public.get_cold_storage_managed_report_detail(
  actor_user_id uuid,
  target_organization_id uuid,
  target_report_id uuid
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare s public.cold_storage_submissions%rowtype; submitted_time timestamptz; temperature_issue_total bigint; submitted_slot_array text[]; due_slot_array text[]; missed_slot_array text[];
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id) then
    raise exception 'cold storage managed report access denied' using errcode = '42501';
  end if;

  select * into s from public.cold_storage_submissions x
  where x.id = target_report_id
    and x.organization_id = target_organization_id
    and exists (
      select 1
      from public.cold_storage_equipment e
      join public.cold_storage_readings r on r.submission_id = e.submission_id
        and r.equipment_id = e.equipment_id
        and r.submitted_at is not null
      where e.submission_id = x.id
        and e.active
    );

  if found then
    select max(r.submitted_at), coalesce(array_agg(distinct r.slot), array[]::text[]) into submitted_time, submitted_slot_array
    from public.cold_storage_readings r
    join public.cold_storage_equipment e on e.submission_id = r.submission_id
      and e.equipment_id = r.equipment_id
      and e.active
    where r.submission_id = s.id
      and r.submitted_at is not null;
    due_slot_array := private.cold_storage_due_slots_for(s.branch_id, s.business_date);
    missed_slot_array := private.cold_storage_missed_slots_for(s.branch_id, s.business_date, submitted_slot_array);
    select count(*) into temperature_issue_total from public.cold_storage_issues i where i.submission_id = s.id;
    return pg_catalog.jsonb_build_object(
      'id', s.id,
      'record_kind', 'submission',
      'source_submission_id', s.id,
      'organization_id', s.organization_id,
      'branch_id', s.branch_id,
      'branch_name', s.branch_name_snapshot,
      'supervisor_team_id', s.supervisor_team_id,
      'business_date', s.business_date,
      'checklist_type', 'cold_storage',
      'definition_id', 'cold_storage_v1',
      'submitted_at', submitted_time,
      'submitted_by', s.supervisor_name_snapshot,
      'completion', case when cardinality(due_slot_array) = 0 then 0 else pg_catalog.round((cardinality(submitted_slot_array)::numeric * 100) / cardinality(due_slot_array)) end,
      'issue_count', temperature_issue_total + cardinality(missed_slot_array),
      'missed_check_count', cardinality(missed_slot_array),
      'missed_slots', to_jsonb(missed_slot_array),
      'status',
        case
          when temperature_issue_total > 0 or cardinality(missed_slot_array) > 0 then 'issues_found'
          when cardinality(submitted_slot_array) < cardinality(due_slot_array) then 'in_progress'
          else 'compliant'
        end,
      'submitted_slots', to_jsonb(submitted_slot_array),
      'rows', coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
          'equipment_id', e.equipment_id,
          'equipment_code', e.equipment_code,
          'equipment_name', e.equipment_name,
          'equipment_type', e.equipment_type,
          'active', e.active,
          'slot', r.slot,
          'temperature_c', r.temperature_c,
          'status', r.status,
          'corrective_action', r.corrective_action,
          'submitted_at', r.submitted_at
        )) order by r.slot, e.equipment_id)
        from public.cold_storage_readings r
        join public.cold_storage_equipment e on e.submission_id = r.submission_id
          and e.equipment_id = r.equipment_id
        where r.submission_id = s.id
          and r.submitted_at is not null
      ), '[]'::jsonb),
      'issues', coalesce((
        select pg_catalog.jsonb_agg(issue.row_data order by issue.sort_slot, issue.equipment_id)
        from (
          select i.slot sort_slot, i.equipment_id, pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
            'id', i.id,
            'equipment_id', i.equipment_id,
            'equipment_code', e.equipment_code,
            'equipment_name', coalesce(e.equipment_name, i.equipment_id),
            'slot', i.slot,
            'temperature_c', i.temperature_c,
            'title', 'Cold Storage temperature issue',
            'remark', i.corrective_action
          )) row_data
          from public.cold_storage_issues i
          left join public.cold_storage_equipment e on e.submission_id = i.submission_id
            and e.equipment_id = i.equipment_id
          where i.submission_id = s.id
        ) issue
      ), '[]'::jsonb)
    );
  end if;

  select x.* into strict s
  from public.cold_storage_submissions x
  cross join lateral (
    select coalesce(array_agg(distinct r.slot) filter (where r.slot is not null), array[]::text[]) submitted_slots
    from public.cold_storage_equipment e
    left join public.cold_storage_readings r on r.submission_id = e.submission_id
      and r.equipment_id = e.equipment_id
      and r.submitted_at is not null
    where e.submission_id = x.id
      and e.active
  ) submitted
  where x.organization_id = target_organization_id
    and private.cold_storage_missed_report_id(x.id) = target_report_id
    and exists (select 1 from public.cold_storage_equipment e where e.submission_id = x.id and e.active)
    and cardinality(private.cold_storage_missed_slots_for(x.branch_id, x.business_date, submitted.submitted_slots)) > 0;

  select coalesce(array_agg(distinct r.slot) filter (where r.slot is not null), array[]::text[]) into submitted_slot_array
  from public.cold_storage_equipment e
  left join public.cold_storage_readings r on r.submission_id = e.submission_id
    and r.equipment_id = e.equipment_id
    and r.submitted_at is not null
  where e.submission_id = s.id
    and e.active;
  missed_slot_array := private.cold_storage_missed_slots_for(s.branch_id, s.business_date, submitted_slot_array);
  return pg_catalog.jsonb_build_object(
    'id', private.cold_storage_missed_report_id(s.id),
    'record_kind', 'derived_missing',
    'source_submission_id', s.id,
    'organization_id', s.organization_id,
    'branch_id', s.branch_id,
    'branch_name', s.branch_name_snapshot,
    'supervisor_team_id', s.supervisor_team_id,
    'business_date', s.business_date,
    'checklist_type', 'cold_storage',
    'definition_id', 'cold_storage_v1',
    'submitted_at', null,
    'submitted_by', null,
    'completion', 0,
    'issue_count', cardinality(missed_slot_array),
    'missed_check_count', cardinality(missed_slot_array),
    'missed_slots', to_jsonb(missed_slot_array),
    'status', 'not_checked',
    'submitted_slots', to_jsonb(submitted_slot_array),
    'items', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'item_id', 'missed:' || slot,
        'item_text', slot || ' scheduled Refrigerator & Freezer check',
        'answer', 'not_checked',
        'remark', 'Scheduled temperature check was not submitted.',
        'evidence', null
      ) order by case slot when '12:00' then 1 when '3:00' then 2 else 3 end)
      from unnest(missed_slot_array) slot
    ), '[]'::jsonb),
    'rows', '[]'::jsonb,
    'issues', '[]'::jsonb
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'cold storage managed report access denied' using errcode = '42501';
end $$;

revoke all on function public.create_supervisor_cold_storage_equipment(uuid, uuid, text, text, text),
  public.update_supervisor_cold_storage_equipment(uuid, uuid, uuid, text, text, text)
from public, anon, authenticated;
grant execute on function public.create_supervisor_cold_storage_equipment(uuid, uuid, text, text, text),
  public.update_supervisor_cold_storage_equipment(uuid, uuid, uuid, text, text, text)
to service_role;
