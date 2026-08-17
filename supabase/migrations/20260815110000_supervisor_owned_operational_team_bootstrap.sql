create function public.create_supervisor_owned_operational_team(
  p_actor_user_id uuid,
  p_branch_id uuid,
  p_team_name text
)
returns table(
  team_id uuid,
  organization_id uuid,
  branch_id uuid,
  team_name text,
  active boolean,
  legacy_supervisor_team_id uuid,
  supervisor_user_id uuid,
  assignment_role text,
  can_write boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_branch public.branches%rowtype;
  clean_team_name text := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p_team_name, '')), '[[:space:]]+', ' ', 'g');
  legacy_team public.branch_supervisor_teams%rowtype;
  canonical_team public.branch_operational_teams%rowtype;
begin
  if length(clean_team_name) not between 1 and 80 then
    raise exception 'invalid employee team name' using errcode = '22023';
  end if;

  select branch.*
    into target_branch
  from public.branches branch
  join public.organizations organization on organization.id = branch.organization_id
  where branch.id = p_branch_id
    and branch.active
    and organization.active
  for update;

  if target_branch.id is null then
    raise exception 'branch unavailable' using errcode = '42501';
  end if;

  if not private.actor_can_read_operational_branch(p_actor_user_id, p_branch_id) then
    raise exception 'employee team bootstrap denied' using errcode = '42501';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_branch_id::text, 17));

  if exists (
    select 1
    from public.branch_operational_team_supervisors assignment
    join public.branch_operational_teams team on team.id = assignment.operational_team_id
    where assignment.supervisor_user_id = p_actor_user_id
      and assignment.branch_id = p_branch_id
      and assignment.active
      and team.active
  ) then
    raise exception 'employee team already assigned' using errcode = '23505';
  end if;

  if exists (
    select 1
    from public.branch_operational_teams team
    where team.branch_id = p_branch_id
      and team.active
      and team.normalized_name = private.normalize_operational_team_name(clean_team_name)
  ) then
    raise exception 'employee team already exists' using errcode = '23505';
  end if;

  select team.*
    into legacy_team
  from public.branch_supervisor_teams team
  where team.organization_id = target_branch.organization_id
    and team.branch_id = p_branch_id
    and team.supervisor_user_id = p_actor_user_id
    and team.active
  order by team.created_at desc, team.id
  limit 1
  for update;

  if legacy_team.id is null then
    insert into public.branch_supervisor_teams(organization_id, branch_id, supervisor_user_id, company_name)
    values(target_branch.organization_id, p_branch_id, p_actor_user_id, clean_team_name)
    returning * into legacy_team;
  elsif exists (
    select 1
    from public.branch_operational_teams team
    where team.legacy_supervisor_team_id = legacy_team.id
      and team.active
  ) then
    raise exception 'employee team already assigned' using errcode = '23505';
  end if;

  select team.*
    into canonical_team
  from public.branch_operational_teams team
  where team.legacy_supervisor_team_id = legacy_team.id
  for update;

  if canonical_team.id is null then
    insert into public.branch_operational_teams(organization_id, branch_id, name, active, legacy_supervisor_team_id)
    values(target_branch.organization_id, p_branch_id, clean_team_name, true, legacy_team.id)
    returning * into canonical_team;
  else
    update public.branch_operational_teams
    set name = clean_team_name,
        active = true
    where id = canonical_team.id
    returning * into canonical_team;
  end if;

  update public.branch_supervisor_teams
  set company_name = clean_team_name
  where id = legacy_team.id;

  if exists (
    select 1
    from public.branch_operational_team_supervisors assignment
    where assignment.operational_team_id = canonical_team.id
      and assignment.active
      and assignment.assignment_role = 'primary'
      and assignment.supervisor_user_id <> p_actor_user_id
  ) then
    raise exception 'employee team primary supervisor conflict' using errcode = '23505';
  end if;

  update public.branch_operational_team_supervisors assignment
  set assignment_role = 'primary',
      active = true,
      valid_to = null
  where assignment.operational_team_id = canonical_team.id
    and assignment.supervisor_user_id = p_actor_user_id
    and assignment.active;

  if not found then
    insert into public.branch_operational_team_supervisors(
      organization_id,
      branch_id,
      operational_team_id,
      supervisor_user_id,
      assignment_role,
      created_by
    )
    values(
      target_branch.organization_id,
      p_branch_id,
      canonical_team.id,
      p_actor_user_id,
      'primary',
      p_actor_user_id
    );
  end if;

  return query
    select
      canonical_team.id,
      canonical_team.organization_id,
      canonical_team.branch_id,
      canonical_team.name,
      canonical_team.active,
      canonical_team.legacy_supervisor_team_id,
      p_actor_user_id,
      'primary'::text,
      private.actor_can_write_operational_team(p_actor_user_id, p_branch_id, canonical_team.id);
end;
$$;

revoke all on function public.create_supervisor_owned_operational_team(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.create_supervisor_owned_operational_team(uuid, uuid, text) to service_role;
