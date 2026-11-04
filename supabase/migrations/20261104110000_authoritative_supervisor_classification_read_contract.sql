-- Additive read contracts for authoritative Supervisor classification.
-- The existing RPCs remain available for older clients.

create function public.list_managed_people_directory_v2(
  actor_user_id uuid,
  target_organization_id uuid,
  branch_filter uuid default null,
  requested_month date default null,
  search_term text default null,
  code_filter text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  result jsonb;
  normalized_people jsonb;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id)
     or (branch_filter is not null and not exists (
       select 1
       from public.branches branch
       where branch.id = branch_filter
         and branch.organization_id = target_organization_id
     )) then
    raise exception 'people directory access denied' using errcode = '42501';
  end if;

  result := public.list_managed_people_directory(
    actor_user_id,
    target_organization_id,
    branch_filter,
    requested_month,
    search_term,
    code_filter
  );

  select coalesce(pg_catalog.jsonb_agg(
    case
      when person.value->>'person_type' = 'supervisor'
       and exists (
         select 1
         from public.branch_memberships membership
         join public.branches branch on branch.id = membership.branch_id
         where membership.user_id = (person.value->>'person_id')::uuid
           and membership.role = 'branch_manager'
           and membership.active
           and branch.organization_id = target_organization_id
       ) then person.value || pg_catalog.jsonb_build_object(
         'supervisor_role', coalesce((
           select classification.classification
           from public.supervisor_access_classifications classification
           where classification.organization_id = target_organization_id
             and classification.user_id = (person.value->>'person_id')::uuid
             and classification.active
         ), 'supervisor'))
      when person.value->>'person_type' = 'supervisor'
       and person.value->>'supervisor_role' = 'training_supervisor'
      then person.value || pg_catalog.jsonb_build_object(
        'person_type', 'training_supervisor',
        'supervisor_role', 'training_supervisor'
      )
      else person.value
    end order by person.ordinality
  ), '[]'::jsonb)
  into normalized_people
  from pg_catalog.jsonb_array_elements(coalesce(result->'people', '[]'::jsonb))
    with ordinality as person(value, ordinality);

  return result || pg_catalog.jsonb_build_object('people', normalized_people);
end;
$$;

revoke all on function public.list_managed_people_directory_v2(uuid, uuid, uuid, date, text, text)
  from public, anon, authenticated;
grant execute on function public.list_managed_people_directory_v2(uuid, uuid, uuid, date, text, text)
  to service_role;

create function public.list_internal_admin_supervisors_v2(
  actor_user_id uuid,
  target_organization_id uuid
)
returns table(
  id uuid,
  full_name text,
  full_name_ar text,
  person_code text,
  phone_number text,
  country_code text,
  iqama_number text,
  iqama_expiry_date date,
  email text,
  branches jsonb,
  team_assignments jsonb,
  active boolean,
  classification text,
  disabled boolean,
  must_change_password boolean,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_internal_admin(actor_user_id)
     or not exists (
       select 1
       from public.organizations organization
       where organization.id = target_organization_id
         and organization.active
     ) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  return query
    select profile.id,
      profile.full_name,
      profile.full_name_ar,
      profile.person_code,
      profile.phone_number,
      profile.country_code,
      profile.iqama_number,
      profile.iqama_expiry_date,
      auth_user.email::text,
      coalesce(pg_catalog.jsonb_agg(distinct pg_catalog.jsonb_build_object(
        'id', branch.id,
        'name', branch.name,
        'name_ar', branch.name_ar,
        'code', branch.code,
        'active', membership.active
      )) filter (where branch.id is not null), '[]'::jsonb),
      coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'team_id', team.id,
          'team_name', team.name,
          'branch_id', team.branch_id,
          'branch_name', team_branch.name,
          'branch_name_ar', team_branch.name_ar,
          'assignment_role', assignment.assignment_role,
          'active', assignment.active
        ) order by pg_catalog.lower(team_branch.name), pg_catalog.lower(team.name), assignment.assignment_role)
        from public.branch_operational_team_supervisors assignment
        join public.branch_operational_teams team on team.id = assignment.operational_team_id
        join public.branches team_branch on team_branch.id = assignment.branch_id
        where assignment.organization_id = target_organization_id
          and assignment.supervisor_user_id = profile.id
          and assignment.active
      ), '[]'::jsonb),
      coalesce(pg_catalog.bool_or(membership.active), false),
      coalesce((
        select classification.classification
        from public.supervisor_access_classifications classification
        where classification.organization_id = target_organization_id
          and classification.user_id = profile.id
          and classification.active
      ), 'supervisor')::text,
      profile.disabled_at is not null,
      profile.must_change_password,
      profile.created_at
    from public.branch_memberships membership
    join public.branches branch on branch.id = membership.branch_id
    join public.profiles profile on profile.id = membership.user_id
    join auth.users auth_user on auth_user.id = membership.user_id
    where branch.organization_id = target_organization_id
      and membership.role = 'branch_manager'
    group by profile.id, profile.full_name, profile.full_name_ar, profile.person_code,
      profile.phone_number, profile.country_code, profile.iqama_number,
      profile.iqama_expiry_date, auth_user.email, profile.disabled_at,
      profile.must_change_password, profile.created_at
    order by coalesce(pg_catalog.bool_or(membership.active), false) desc,
      profile.disabled_at is not null,
      pg_catalog.lower(coalesce(profile.full_name, auth_user.email::text)), profile.id
    limit 500;
end;
$$;

revoke all on function public.list_internal_admin_supervisors_v2(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.list_internal_admin_supervisors_v2(uuid, uuid)
  to service_role;
