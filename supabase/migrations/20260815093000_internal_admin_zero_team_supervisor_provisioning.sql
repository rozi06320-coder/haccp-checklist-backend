create or replace function private.apply_internal_admin_supervisor_team_assignments(
  actor_user_id uuid,
  target_organization_id uuid,
  target_supervisor_user_id uuid,
  target_branch_ids uuid[],
  target_team_assignments jsonb
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  entry jsonb;
  team_id_text text;
  team_id uuid;
  assignment_role text;
  team_ids uuid[] := array[]::uuid[];
  team_roles text[] := array[]::text[];
  valid_team_count integer;
  inserted_count integer := 0;
  last_row_count integer;
begin
  if pg_catalog.jsonb_typeof(coalesce(target_team_assignments, '[]'::jsonb)) is distinct from 'array' then
    raise exception 'invalid supervisor team assignment' using errcode = '22023';
  end if;

  for entry in select value from pg_catalog.jsonb_array_elements(coalesce(target_team_assignments, '[]'::jsonb)) loop
    if pg_catalog.jsonb_typeof(entry) is distinct from 'object' then
      raise exception 'invalid supervisor team assignment' using errcode = '22023';
    end if;

    team_id_text := entry->>'operational_team_id';
    assignment_role := entry->>'assignment_role';

    if team_id_text is null
      or team_id_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      or assignment_role not in ('primary', 'backup')
    then
      raise exception 'invalid supervisor team assignment' using errcode = '22023';
    end if;

    team_id := team_id_text::uuid;
    if array_position(team_ids, team_id) is not null then
      raise exception 'invalid supervisor team assignment' using errcode = '22023';
    end if;

    team_ids := array_append(team_ids, team_id);
    team_roles := array_append(team_roles, assignment_role);
  end loop;

  if pg_catalog.array_length(team_ids, 1) > 50 then
    raise exception 'invalid supervisor team assignment' using errcode = '22023';
  end if;

  if coalesce(pg_catalog.array_length(team_ids, 1), 0) = 0 then
    return 0;
  end if;

  select count(*) into valid_team_count
  from public.branch_operational_teams team
  where team.id = any(team_ids)
    and team.organization_id = target_organization_id
    and team.branch_id = any(target_branch_ids)
    and team.active;

  if valid_team_count <> pg_catalog.array_length(team_ids, 1) then
    raise exception 'invalid supervisor team assignment' using errcode = '23514';
  end if;

  for index_value in 1..pg_catalog.array_length(team_ids, 1) loop
    if team_roles[index_value] = 'primary'
      and exists (
        select 1
        from public.branch_operational_team_supervisors assignment
        where assignment.operational_team_id = team_ids[index_value]
          and assignment.assignment_role = 'primary'
          and assignment.active
          and assignment.supervisor_user_id <> target_supervisor_user_id
      )
    then
      raise exception 'primary supervisor already assigned' using errcode = '23505';
    end if;

    if exists (
      select 1
      from public.branch_operational_team_supervisors assignment
      where assignment.operational_team_id = team_ids[index_value]
        and assignment.supervisor_user_id = target_supervisor_user_id
        and assignment.active
        and assignment.assignment_role <> team_roles[index_value]
    ) then
      raise exception 'supervisor team assignment already exists' using errcode = '23505';
    end if;

    insert into public.branch_operational_team_supervisors(
      organization_id,
      branch_id,
      operational_team_id,
      supervisor_user_id,
      assignment_role,
      created_by
    )
    select
      team.organization_id,
      team.branch_id,
      team.id,
      target_supervisor_user_id,
      team_roles[index_value],
      actor_user_id
    from public.branch_operational_teams team
    where team.id = team_ids[index_value]
      and not exists (
        select 1
        from public.branch_operational_team_supervisors existing
        where existing.operational_team_id = team.id
          and existing.supervisor_user_id = target_supervisor_user_id
          and existing.active
          and existing.assignment_role = team_roles[index_value]
      );

    get diagnostics last_row_count = row_count;
    inserted_count := inserted_count + last_row_count;
  end loop;

  return inserted_count;
end;
$$;

revoke all on function private.apply_internal_admin_supervisor_team_assignments(uuid, uuid, uuid, uuid[], jsonb) from public, anon, authenticated;
grant execute on function private.apply_internal_admin_supervisor_team_assignments(uuid, uuid, uuid, uuid[], jsonb) to service_role;
