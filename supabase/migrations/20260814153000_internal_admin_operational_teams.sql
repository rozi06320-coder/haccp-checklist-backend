create or replace function private.sync_legacy_supervisor_operational_team()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  mapped public.branch_operational_teams%rowtype;
  ordinal bigint;
  chosen_role text;
  candidate_name text;
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(new.branch_id::text,17));
  select * into mapped from public.branch_operational_teams where legacy_supervisor_team_id=new.id for update;
  if mapped.id is null then
    select count(*) + 1 into ordinal from public.branch_operational_teams where branch_id = new.branch_id;
    loop
      candidate_name := private.operational_team_default_name(ordinal);
      exit when not exists (
        select 1 from public.branch_operational_teams team
        where team.branch_id = new.branch_id
          and team.active
          and team.normalized_name = private.normalize_operational_team_name(candidate_name)
      );
      ordinal := ordinal + 1;
      if ordinal > 999 then
        raise exception 'operational team default name generation failed' using errcode = '54000';
      end if;
    end loop;
    insert into public.branch_operational_teams(organization_id,branch_id,name,active,legacy_supervisor_team_id,created_at,updated_at)
    values(new.organization_id,new.branch_id,candidate_name,true,new.id,new.created_at,new.updated_at)
    returning * into mapped;
  end if;
  if new.active then
    if not exists(select 1 from public.branch_operational_team_supervisors where operational_team_id=mapped.id and supervisor_user_id=new.supervisor_user_id and active) then
      chosen_role:=case when exists(select 1 from public.branch_operational_team_supervisors where operational_team_id=mapped.id and assignment_role='primary' and active) then 'backup' else 'primary' end;
      insert into public.branch_operational_team_supervisors(organization_id,branch_id,operational_team_id,supervisor_user_id,assignment_role,created_by)
      values(new.organization_id,new.branch_id,mapped.id,new.supervisor_user_id,chosen_role,new.supervisor_user_id);
    end if;
  else
    update public.branch_operational_team_supervisors set active=false,valid_to=greatest(valid_from,current_date)
    where operational_team_id=mapped.id and supervisor_user_id=new.supervisor_user_id and active;
  end if;
  return new;
end $$;

create or replace function private.internal_admin_operational_team_row(target_operational_team_id uuid)
returns table(
  team_id uuid,
  organization_id uuid,
  team_name text,
  company_name text,
  branch_id uuid,
  branch_name text,
  branch_name_ar text,
  branch_code text,
  supervisor_user_id uuid,
  supervisor_name text,
  supervisor_name_ar text,
  supervisor_email text,
  supervisor_role text,
  backup_supervisors jsonb,
  active boolean,
  operational_staff_count bigint,
  staff jsonb
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    team.id,
    team.organization_id,
    team.name,
    coalesce(legacy.company_name, team.name),
    branch.id,
    branch.name,
    branch.name_ar,
    branch.code,
    primary_assignment.supervisor_user_id,
    primary_profile.full_name,
    primary_profile.full_name_ar,
    primary_auth.email::text,
    'branch_manager'::text,
    coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'supervisor_user_id', backup_assignment.supervisor_user_id,
        'supervisor_name', backup_profile.full_name,
        'supervisor_name_ar', backup_profile.full_name_ar,
        'supervisor_email', backup_auth.email::text,
        'assignment_role', backup_assignment.assignment_role
      ) order by pg_catalog.lower(coalesce(backup_profile.full_name, backup_auth.email::text)), backup_assignment.supervisor_user_id)
      from public.branch_operational_team_supervisors backup_assignment
      join public.profiles backup_profile on backup_profile.id = backup_assignment.supervisor_user_id
      join auth.users backup_auth on backup_auth.id = backup_assignment.supervisor_user_id
      where backup_assignment.operational_team_id = team.id
        and backup_assignment.active
        and backup_assignment.assignment_role = 'backup'
    ), '[]'::jsonb),
    team.active,
    (
      select count(*)
      from public.operational_staff_assignments assignment
      where assignment.operational_team_id = team.id
        and assignment.active
    ),
    coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'staff_id', staff.id,
        'display_name', staff.display_name,
        'company_name', staff.company_name,
        'staff_code', staff.staff_code,
        'country_code', staff.country_code,
        'employment_status', staff.employment_status,
        'assignment_id', assignment.id,
        'operational_team_id', assignment.operational_team_id,
        'operational_roles', assignment.operational_roles
      ) order by pg_catalog.lower(staff.display_name), staff.id)
      from public.operational_staff_assignments assignment
      join public.operational_staff staff on staff.id = assignment.operational_staff_id
      where assignment.operational_team_id = team.id
        and assignment.active
    ), '[]'::jsonb)
  from public.branch_operational_teams team
  join public.branches branch on branch.id = team.branch_id and branch.organization_id = team.organization_id
  left join public.branch_supervisor_teams legacy on legacy.id = team.legacy_supervisor_team_id
  join public.branch_operational_team_supervisors primary_assignment
    on primary_assignment.operational_team_id = team.id
    and primary_assignment.active
    and primary_assignment.assignment_role = 'primary'
  join public.profiles primary_profile on primary_profile.id = primary_assignment.supervisor_user_id
  join auth.users primary_auth on primary_auth.id = primary_assignment.supervisor_user_id
  where team.id = target_operational_team_id
$$;

drop function if exists public.list_internal_admin_branch_teams(uuid, uuid);
create function public.list_internal_admin_branch_teams(
  actor_user_id uuid,
  target_organization_id uuid
)
returns table(
  team_id uuid,
  organization_id uuid,
  team_name text,
  company_name text,
  branch_id uuid,
  branch_name text,
  branch_name_ar text,
  branch_code text,
  supervisor_user_id uuid,
  supervisor_name text,
  supervisor_name_ar text,
  supervisor_email text,
  supervisor_role text,
  backup_supervisors jsonb,
  active boolean,
  operational_staff_count bigint,
  staff jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_internal_admin(actor_user_id)
    or not exists(select 1 from public.organizations organization where organization.id = target_organization_id and organization.active)
  then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  return query
    select row.*
    from public.branch_operational_teams team
    cross join lateral private.internal_admin_operational_team_row(team.id) row
    where team.organization_id = target_organization_id
    order by row.branch_name, row.team_name, row.team_id
    limit 500;
end;
$$;

create function public.create_internal_admin_operational_team(
  actor_user_id uuid,
  target_organization_id uuid,
  target_branch_id uuid,
  new_team_name text,
  new_company_name text,
  target_primary_supervisor_user_id uuid,
  target_backup_supervisor_user_id uuid default null,
  initial_staff jsonb default '[]'::jsonb
)
returns table(
  team_id uuid,
  organization_id uuid,
  team_name text,
  company_name text,
  branch_id uuid,
  branch_name text,
  branch_name_ar text,
  branch_code text,
  supervisor_user_id uuid,
  supervisor_name text,
  supervisor_name_ar text,
  supervisor_email text,
  supervisor_role text,
  backup_supervisors jsonb,
  active boolean,
  operational_staff_count bigint,
  staff jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  clean_team_name text := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(new_team_name, '')), '[[:space:]]+', ' ', 'g');
  clean_company_name text := private.clean_operational_staff_company_name(new_company_name);
  created_legacy_id uuid;
  created_team public.branch_operational_teams%rowtype;
  staff_entry jsonb;
  staff_roles text[];
  staff_name text;
  staff_company text;
  staff_code text;
  staff_country text;
  created_staff uuid;
  created_assignment uuid;
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;
  if length(clean_team_name) not between 1 and 80
    or length(coalesce(clean_company_name, '')) not between 1 and 160
    or pg_catalog.jsonb_typeof(coalesce(initial_staff, '[]'::jsonb)) <> 'array'
    or pg_catalog.jsonb_array_length(coalesce(initial_staff, '[]'::jsonb)) > 50
  then
    raise exception 'invalid branch team request' using errcode = '22023';
  end if;
  if target_backup_supervisor_user_id is not null
    and target_backup_supervisor_user_id = target_primary_supervisor_user_id
  then
    raise exception 'invalid branch team request' using errcode = '22023';
  end if;
  if not exists (
    select 1
    from public.branches branch
    join public.organizations organization on organization.id = branch.organization_id
    where branch.id = target_branch_id
      and branch.organization_id = target_organization_id
      and branch.active
      and organization.active
  ) then
    raise exception 'invalid branch team request' using errcode = '22023';
  end if;
  if not exists (
    select 1
    from public.branch_memberships membership
    join public.profiles profile on profile.id = membership.user_id
    where membership.branch_id = target_branch_id
      and membership.user_id = target_primary_supervisor_user_id
      and membership.role = 'branch_manager'
      and membership.active
      and profile.disabled_at is null
      and not profile.must_change_password
  ) then
    raise exception 'invalid supervisor assignment' using errcode = '23514';
  end if;
  if target_backup_supervisor_user_id is not null and not exists (
    select 1
    from public.branch_memberships membership
    join public.profiles profile on profile.id = membership.user_id
    where membership.branch_id = target_branch_id
      and membership.user_id = target_backup_supervisor_user_id
      and membership.role = 'branch_manager'
      and membership.active
      and profile.disabled_at is null
      and not profile.must_change_password
  ) then
    raise exception 'invalid supervisor assignment' using errcode = '23514';
  end if;
  if exists (
    select 1
    from public.branch_operational_teams team
    where team.branch_id = target_branch_id
      and team.active
      and team.normalized_name = private.normalize_operational_team_name(clean_team_name)
  ) then
    raise exception 'branch team already exists' using errcode = '23505';
  end if;

  insert into public.branch_supervisor_teams(organization_id, branch_id, supervisor_user_id, active, company_name)
  values(target_organization_id, target_branch_id, target_primary_supervisor_user_id, false, clean_company_name)
  returning id into created_legacy_id;

  select * into strict created_team
  from public.branch_operational_teams team
  where team.legacy_supervisor_team_id = created_legacy_id
  for update;

  update public.branch_operational_teams
  set name = clean_team_name,
      active = true,
      updated_at = now()
  where id = created_team.id
  returning * into created_team;

  insert into public.branch_operational_team_supervisors(
    organization_id, branch_id, operational_team_id, supervisor_user_id, assignment_role, created_by
  )
  values(target_organization_id, target_branch_id, created_team.id, target_primary_supervisor_user_id, 'primary', actor_user_id);

  if target_backup_supervisor_user_id is not null then
    insert into public.branch_operational_team_supervisors(
      organization_id, branch_id, operational_team_id, supervisor_user_id, assignment_role, created_by
    )
    values(target_organization_id, target_branch_id, created_team.id, target_backup_supervisor_user_id, 'backup', actor_user_id);
  end if;

  for staff_entry in select value from pg_catalog.jsonb_array_elements(coalesce(initial_staff, '[]'::jsonb)) loop
    if pg_catalog.jsonb_typeof(staff_entry->'operational_roles') is distinct from 'array' then
      raise exception 'invalid branch team staff request' using errcode = '22023';
    end if;
    select array_agg(parsed.value::text order by parsed.ordinality)
    into staff_roles
    from pg_catalog.jsonb_array_elements_text(staff_entry->'operational_roles') with ordinality as parsed(value, ordinality);
    staff_name := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(staff_entry->>'display_name', '')), '[[:space:]]+', ' ', 'g');
    staff_company := private.clean_operational_staff_company_name(staff_entry->>'company_name');
    staff_code := private.clean_operational_staff_code(staff_entry->>'staff_code');
    staff_country := private.clean_operational_staff_country_code(staff_entry->>'country_code');
    if length(staff_name) not between 1 and 120
      or length(coalesce(staff_company, '')) not between 1 and 160
      or (staff_code is not null and length(staff_code) not between 1 and 80)
      or (staff_country is not null and not private.operational_staff_country_code_is_valid(staff_country))
      or not private.operational_roles_are_valid(staff_roles)
    then
      raise exception 'invalid branch team staff request' using errcode = '22023';
    end if;
    insert into public.operational_staff(organization_id, branch_id, display_name, company_name, staff_code, country_code, created_by)
    values(target_organization_id, target_branch_id, staff_name, staff_company, staff_code, staff_country, actor_user_id)
    returning id into created_staff;
    insert into public.operational_staff_assignments(
      organization_id, branch_id, operational_staff_id, supervisor_team_id, operational_team_id, operational_roles
    )
    values(target_organization_id, target_branch_id, created_staff, created_legacy_id, created_team.id, staff_roles)
    returning id into created_assignment;
    insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, branch_id, action, details)
    values(target_organization_id, actor_user_id, target_primary_supervisor_user_id, target_branch_id, 'operational_staff_created',
      pg_catalog.jsonb_build_object('team_id', created_team.id,
        'operational_staff_id', created_staff, 'assignment_id', created_assignment, 'operational_roles', staff_roles));
  end loop;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, branch_id, action, details)
  values(target_organization_id, actor_user_id, target_primary_supervisor_user_id, target_branch_id, 'supervisor_team_assigned',
    pg_catalog.jsonb_build_object('team_id', created_team.id));

  return query select * from private.internal_admin_operational_team_row(created_team.id);
exception
  when unique_violation then
    if sqlerrm ilike '%staff_code%' or sqlerrm ilike '%employee code%' then
      raise exception 'employee code already exists' using errcode = '23505';
    end if;
    raise exception 'branch team already exists' using errcode = '23505';
  when no_data_found or too_many_rows then
    raise exception 'invalid branch team request' using errcode = '22023';
end;
$$;

drop function if exists public.create_internal_admin_branch_team(uuid, uuid, uuid, uuid, text);
create function public.create_internal_admin_branch_team(
  actor_user_id uuid,
  target_organization_id uuid,
  target_branch_id uuid,
  target_supervisor_user_id uuid,
  new_company_name text
)
returns table(
  team_id uuid,
  organization_id uuid,
  company_name text,
  branch_id uuid,
  branch_name text,
  branch_name_ar text,
  branch_code text,
  supervisor_user_id uuid,
  supervisor_name text,
  supervisor_name_ar text,
  supervisor_email text,
  supervisor_role text,
  active boolean,
  operational_staff_count bigint,
  staff jsonb
)
language sql
security definer
set search_path = ''
as $$
  select
    created.team_id,
    created.organization_id,
    created.company_name,
    created.branch_id,
    created.branch_name,
    created.branch_name_ar,
    created.branch_code,
    created.supervisor_user_id,
    created.supervisor_name,
    created.supervisor_name_ar,
    created.supervisor_email,
    created.supervisor_role,
    created.active,
    created.operational_staff_count,
    created.staff
  from public.create_internal_admin_operational_team(
    actor_user_id,
    target_organization_id,
    target_branch_id,
    new_company_name,
    new_company_name,
    target_supervisor_user_id,
    null,
    '[]'::jsonb
  ) created
$$;

drop function if exists public.create_internal_admin_branch_team_staff(uuid, uuid, uuid, text, text, text, text, text[]);
create function public.create_internal_admin_branch_team_staff(
  actor_user_id uuid,
  target_organization_id uuid,
  target_team_id uuid,
  new_display_name text,
  new_company_name text,
  new_staff_code text,
  new_country_code text,
  new_operational_roles text[]
)
returns table(staff_id uuid, assignment_id uuid, duplicate_name_warning boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_team public.branch_operational_teams%rowtype;
  created_staff uuid;
  created_assignment uuid;
  clean_name text := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(new_display_name, '')), '[[:space:]]+', ' ', 'g');
  clean_company_name text := private.clean_operational_staff_company_name(new_company_name);
  clean_code text := private.clean_operational_staff_code(new_staff_code);
  clean_country text := private.clean_operational_staff_country_code(new_country_code);
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  select team.*
    into strict target_team
  from public.branch_operational_teams team
  join public.branches branch on branch.id = team.branch_id and branch.organization_id = team.organization_id
  join public.organizations organization on organization.id = team.organization_id
  where team.id = target_team_id
    and team.organization_id = target_organization_id
    and team.active
    and team.legacy_supervisor_team_id is not null
    and branch.active
    and organization.active
  for update;

  if length(clean_name) not between 1 and 120
    or length(coalesce(clean_company_name, '')) not between 1 and 160
    or (clean_code is not null and length(clean_code) not between 1 and 80)
    or (clean_country is not null and not private.operational_staff_country_code_is_valid(clean_country))
    or not private.operational_roles_are_valid(new_operational_roles)
  then
    raise exception 'invalid branch team staff request' using errcode = '22023';
  end if;

  insert into public.operational_staff(organization_id, branch_id, display_name, company_name, staff_code, country_code, created_by)
  values(target_team.organization_id, target_team.branch_id, clean_name, clean_company_name, clean_code, clean_country, actor_user_id)
  returning id into created_staff;

  insert into public.operational_staff_assignments(
    organization_id,
    branch_id,
    operational_staff_id,
    supervisor_team_id,
    operational_team_id,
    operational_roles
  )
  values(
    target_team.organization_id,
    target_team.branch_id,
    created_staff,
    target_team.legacy_supervisor_team_id,
    target_team.id,
    new_operational_roles
  )
  returning id into created_assignment;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, branch_id, action, details)
  values(
    target_team.organization_id,
    actor_user_id,
    target_team.branch_id,
    'operational_staff_created',
    jsonb_build_object(
      'team_id', target_team.id,
      'operational_staff_id', created_staff,
      'assignment_id', created_assignment,
      'operational_roles', new_operational_roles
    )
  );

  return query select created_staff, created_assignment, exists(
    select 1
    from public.operational_staff staff
    where staff.organization_id = target_team.organization_id
      and staff.branch_id = target_team.branch_id
      and staff.id <> created_staff
      and staff.employment_status = 'active'
      and staff.normalized_name = private.normalize_operational_staff_name(clean_name)
  );
exception when unique_violation then
  raise exception 'employee code already exists' using errcode = '23505';
when no_data_found or too_many_rows then
  raise exception 'invalid branch team staff request' using errcode = '22023';
end;
$$;

revoke all on function private.internal_admin_operational_team_row(uuid) from public, anon, authenticated;
revoke all on function public.list_internal_admin_branch_teams(uuid, uuid) from public, anon, authenticated;
revoke all on function public.create_internal_admin_operational_team(uuid, uuid, uuid, text, text, uuid, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.create_internal_admin_branch_team(uuid, uuid, uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.create_internal_admin_branch_team_staff(uuid, uuid, uuid, text, text, text, text, text[]) from public, anon, authenticated;
grant execute on function public.list_internal_admin_branch_teams(uuid, uuid) to service_role;
grant execute on function public.create_internal_admin_operational_team(uuid, uuid, uuid, text, text, uuid, uuid, jsonb) to service_role;
grant execute on function public.create_internal_admin_branch_team(uuid, uuid, uuid, uuid, text) to service_role;
grant execute on function public.create_internal_admin_branch_team_staff(uuid, uuid, uuid, text, text, text, text, text[]) to service_role;
