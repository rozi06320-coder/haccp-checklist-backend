alter table public.profiles
  add column if not exists person_code text,
  add column if not exists phone_number text,
  add column if not exists country_code text,
  add column if not exists iqama_number text,
  add column if not exists iqama_expiry_date date;

alter table public.profiles
  drop constraint if exists profiles_person_code_format,
  drop constraint if exists profiles_phone_number_format,
  drop constraint if exists profiles_country_code_format,
  drop constraint if exists profiles_iqama_number_format;

alter table public.profiles
  add constraint profiles_person_code_format
  check (
    person_code is null
    or (
      person_code = pg_catalog.regexp_replace(pg_catalog.btrim(person_code), '[[:space:]]+', ' ', 'g')
      and length(person_code) between 1 and 80
    )
  ),
  add constraint profiles_phone_number_format
  check (
    phone_number is null
    or (
      phone_number = pg_catalog.btrim(phone_number)
      and length(phone_number) between 1 and 40
    )
  ),
  add constraint profiles_country_code_format
  check (
    country_code is null
    or country_code ~ '^[A-Z]{2}$'
  ),
  add constraint profiles_iqama_number_format
  check (
    iqama_number is null
    or (
      iqama_number = pg_catalog.btrim(iqama_number)
      and length(iqama_number) between 1 and 80
    )
  );

create unique index if not exists profiles_person_code_unique_idx
  on public.profiles (pg_catalog.lower(pg_catalog.btrim(person_code)))
  where person_code is not null;

create or replace function public.finalize_provisioned_supervisor(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_new_user_id uuid,
  p_full_name text,
  p_branch_ids uuid[],
  p_full_name_ar text,
  p_team_assignments jsonb,
  p_person_code text,
  p_phone_number text,
  p_country_code text,
  p_iqama_number text,
  p_iqama_expiry_date date
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_person_code text := nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p_person_code, '')), '[[:space:]]+', ' ', 'g'), '');
  normalized_phone_number text := nullif(pg_catalog.btrim(coalesce(p_phone_number, '')), '');
  normalized_country_code text := nullif(pg_catalog.upper(pg_catalog.btrim(coalesce(p_country_code, ''))), '');
  normalized_iqama_number text := nullif(pg_catalog.btrim(coalesce(p_iqama_number, '')), '');
  changed_rows integer;
begin
  if (normalized_person_code is not null and length(normalized_person_code) > 80)
    or (normalized_phone_number is not null and length(normalized_phone_number) > 40)
    or (normalized_country_code is not null and normalized_country_code !~ '^[A-Z]{2}$')
    or (normalized_iqama_number is not null and length(normalized_iqama_number) > 80)
  then
    raise exception using errcode = '22023', message = 'invalid profile input';
  end if;

  perform public.finalize_provisioned_supervisor(
    p_actor_user_id,
    p_organization_id,
    p_new_user_id,
    p_full_name,
    p_branch_ids,
    p_full_name_ar,
    p_team_assignments
  );

  update public.profiles
  set person_code = normalized_person_code,
      phone_number = normalized_phone_number,
      country_code = normalized_country_code,
      iqama_number = normalized_iqama_number,
      iqama_expiry_date = p_iqama_expiry_date
  where id = p_new_user_id;
  get diagnostics changed_rows = row_count;
  if changed_rows <> 1 then
    raise exception using errcode = '23503', message = 'target profile missing';
  end if;

  return pg_catalog.jsonb_build_object('success', true);
end;
$$;

revoke all on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[], text, jsonb, text, text, text, text, date)
  from public, anon, authenticated;
grant execute on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[], text, jsonb, text, text, text, text, date)
  to service_role;

drop function if exists public.list_internal_admin_supervisors(uuid, uuid);

create function public.list_internal_admin_supervisors(
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
  disabled boolean,
  must_change_password boolean,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if not exists(select 1 from public.organizations organization where organization.id = target_organization_id and organization.active) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  return query
    select profile.id, profile.full_name, profile.full_name_ar,
      profile.person_code, profile.phone_number, profile.country_code, profile.iqama_number, profile.iqama_expiry_date,
      auth_user.email::text,
      coalesce(pg_catalog.jsonb_agg(distinct pg_catalog.jsonb_build_object(
        'id', branch.id,
        'name', branch.name,
        'name_ar', branch.name_ar,
        'code', branch.code,
        'active', membership.active
      )) filter (where branch.id is not null), '[]'::jsonb) as branches,
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
      ), '[]'::jsonb) as team_assignments,
      coalesce(pg_catalog.bool_or(membership.active), false) as active,
      profile.disabled_at is not null as disabled,
      profile.must_change_password,
      profile.created_at
    from public.branch_memberships membership
    join public.branches branch on branch.id = membership.branch_id
    join public.profiles profile on profile.id = membership.user_id
    join auth.users auth_user on auth_user.id = membership.user_id
    where branch.organization_id = target_organization_id
      and membership.role = 'branch_manager'
    group by profile.id, profile.full_name, profile.full_name_ar, profile.person_code, profile.phone_number,
      profile.country_code, profile.iqama_number, profile.iqama_expiry_date, auth_user.email, profile.disabled_at,
      profile.must_change_password, profile.created_at
    order by coalesce(pg_catalog.bool_or(membership.active), false) desc,
      profile.disabled_at is not null,
      pg_catalog.lower(coalesce(profile.full_name, auth_user.email::text)), profile.id
    limit 500;
end;
$$;

revoke all on function public.list_internal_admin_supervisors(uuid, uuid) from public, anon, authenticated;
grant execute on function public.list_internal_admin_supervisors(uuid, uuid) to service_role;

drop function if exists public.list_managed_organization_users(uuid, uuid, integer, integer, text, text, uuid, text);

create function public.list_managed_organization_users(
  actor_user_id uuid,
  target_organization_id uuid,
  requested_page integer default 1,
  requested_page_size integer default 20,
  search_term text default null,
  role_filter text default null,
  branch_filter uuid default null,
  lifecycle_filter text default null
)
returns table (
  id uuid,
  full_name text,
  full_name_ar text,
  person_code text,
  phone_number text,
  country_code text,
  iqama_number text,
  iqama_expiry_date date,
  email text,
  role text,
  branches jsonb,
  disabled boolean,
  must_change_password boolean,
  created_at timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_search text := nullif(pg_catalog.btrim(search_term), '');
begin
  if actor_user_id is null
    or target_organization_id is null
    or requested_page < 1
    or requested_page_size < 1
    or requested_page_size > 50
    or pg_catalog.length(coalesce(search_term, '')) > 120
    or (role_filter is not null and role_filter not in ('staff', 'branch_manager'))
    or (lifecycle_filter is not null and lifecycle_filter not in ('active', 'password_change_required', 'disabled'))
  then
    raise exception 'invalid listing input' using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.organization_memberships membership
    join public.profiles actor_profile on actor_profile.id = membership.user_id
    where membership.organization_id = target_organization_id
      and membership.user_id = actor_user_id
      and membership.role = 'organization_manager'
      and actor_profile.disabled_at is null
      and not actor_profile.must_change_password
  ) then
    raise exception 'listing denied' using errcode = '42501';
  end if;

  if branch_filter is not null and not exists (
    select 1
    from public.branches branch
    where branch.id = branch_filter
      and branch.organization_id = target_organization_id
  ) then
    raise exception 'invalid listing input' using errcode = '22023';
  end if;

  return query
  with organization_accounts as (
    select
      profile.id,
      profile.full_name,
      profile.full_name_ar,
      profile.person_code,
      profile.phone_number,
      profile.country_code,
      profile.iqama_number,
      profile.iqama_expiry_date,
      auth_user.email::text as email,
      membership.role,
      profile.disabled_at is not null as disabled,
      profile.must_change_password,
      profile.created_at,
      pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', branch.id,
          'name', branch.name,
          'name_ar', branch.name_ar,
          'code', branch.code
        )
        order by branch.name, branch.id
      ) as branches
    from public.branch_memberships membership
    join public.branches branch
      on branch.id = membership.branch_id
      and branch.organization_id = target_organization_id
    join public.profiles profile on profile.id = membership.user_id
    join auth.users auth_user on auth_user.id = profile.id
    where (role_filter is null or membership.role = role_filter)
      and (branch_filter is null or exists (
        select 1
        from public.branch_memberships filtered_membership
        join public.branches filtered_branch
          on filtered_branch.id = filtered_membership.branch_id
        where filtered_membership.user_id = membership.user_id
          and filtered_membership.role = membership.role
          and filtered_branch.organization_id = target_organization_id
          and filtered_branch.id = branch_filter
      ))
      and (
        lifecycle_filter is null
        or (lifecycle_filter = 'active' and profile.disabled_at is null and not profile.must_change_password)
        or (lifecycle_filter = 'password_change_required' and profile.disabled_at is null and profile.must_change_password)
        or (lifecycle_filter = 'disabled' and profile.disabled_at is not null)
      )
      and (
        normalized_search is null
        or profile.full_name ilike '%' || normalized_search || '%'
        or profile.full_name_ar ilike '%' || normalized_search || '%'
        or profile.person_code ilike '%' || normalized_search || '%'
        or profile.phone_number ilike '%' || normalized_search || '%'
        or profile.iqama_number ilike '%' || normalized_search || '%'
        or auth_user.email ilike '%' || normalized_search || '%'
      )
    group by profile.id, profile.full_name, profile.full_name_ar, profile.person_code, profile.phone_number,
      profile.country_code, profile.iqama_number, profile.iqama_expiry_date, auth_user.email, membership.role,
      profile.disabled_at, profile.must_change_password, profile.created_at
  ),
  counted as (
    select account.*, pg_catalog.count(*) over () as matching_count
    from organization_accounts account
  )
  select
    account.id,
    account.full_name,
    account.full_name_ar,
    account.person_code,
    account.phone_number,
    account.country_code,
    account.iqama_number,
    account.iqama_expiry_date,
    account.email,
    account.role,
    account.branches,
    account.disabled,
    account.must_change_password,
    account.created_at,
    account.matching_count
  from counted account
  order by pg_catalog.lower(coalesce(account.full_name, '')), account.id
  limit requested_page_size
  offset ((requested_page - 1)::bigint * requested_page_size::bigint);
end;
$$;

revoke all on function public.list_managed_organization_users(uuid, uuid, integer, integer, text, text, uuid, text)
  from public, anon, authenticated;
grant execute on function public.list_managed_organization_users(uuid, uuid, integer, integer, text, text, uuid, text)
  to service_role;

create or replace function public.get_managed_annual_evaluation_workspace(
  p_actor_user_id uuid,p_organization_id uuid,p_evaluation_year integer,p_branch_id uuid default null,
  p_subject_type text default null,p_subject_id uuid default null,p_state text default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare current_id uuid;
begin
  if not private.actor_manages_active_organization(p_actor_user_id,p_organization_id)
    or p_evaluation_year not between 2000 and 2200
    or (p_subject_type is not null and p_subject_type not in('supervisor','training_supervisor','employee'))
    or (p_state is not null and p_state not in('draft','submitted'))
    or ((p_subject_type is null)<>(p_subject_id is null))
    or (p_branch_id is not null and not exists(select 1 from public.branches branch where branch.id=p_branch_id and branch.organization_id=p_organization_id and branch.active))
  then raise exception 'annual evaluation access denied' using errcode='42501'; end if;
  if p_subject_id is not null then
    select evaluation.id into current_id from public.annual_evaluations evaluation
    where evaluation.organization_id=p_organization_id and evaluation.evaluation_year=p_evaluation_year
      and (p_branch_id is null or evaluation.branch_id=p_branch_id or (p_subject_type='training_supervisor' and evaluation.subject_type='training_supervisor'))
      and ((p_subject_type='supervisor' and evaluation.subject_type='supervisor' and evaluation.supervisor_user_id=p_subject_id)
        or (p_subject_type='training_supervisor' and evaluation.subject_type='training_supervisor' and evaluation.operational_staff_id=p_subject_id)
        or (p_subject_type='employee' and evaluation.subject_type='employee' and evaluation.operational_staff_id=p_subject_id))
    order by evaluation.updated_at desc
    limit 1;
  end if;
  return pg_catalog.jsonb_build_object(
    'subjects',coalesce((
      select pg_catalog.jsonb_agg(subject order by subject->>'branch_name',subject->>'subject_name') from(
        select pg_catalog.jsonb_build_object('subject_type','supervisor','subject_id',membership.user_id,
          'supervisor_user_id',membership.user_id,'operational_staff_id',null,'subject_name',coalesce(profile.full_name,'Supervisor'),
          'staff_code',profile.person_code,'role','Supervisor','branch_id',branch.id,'branch_name',branch.name,
          'person_code',profile.person_code,'phone_number',profile.phone_number,'country_code',profile.country_code,
          'iqama_number',profile.iqama_number,'iqama_expiry_date',profile.iqama_expiry_date)subject
        from public.branch_memberships membership join public.branches branch on branch.id=membership.branch_id
        join public.organizations organization on organization.id=branch.organization_id
        join public.profiles profile on profile.id=membership.user_id
        where branch.organization_id=p_organization_id and branch.active and organization.active
          and membership.role='branch_manager' and membership.active
          and profile.disabled_at is null and (p_branch_id is null or branch.id=p_branch_id)
        union all
        select pg_catalog.jsonb_build_object('subject_type','training_supervisor','subject_id',staff.id,
          'supervisor_user_id',null,'operational_staff_id',staff.id,'subject_name',staff.display_name,
          'staff_code',staff.staff_code,'role',private.annual_operational_roles_snapshot(assignment.operational_roles),
          'branch_id',branch.id,'branch_name',branch.name,
          'person_code',null,'phone_number',staff.phone_number,'country_code',staff.country_code,
          'iqama_number',staff.iqama_number,'iqama_expiry_date',staff.iqama_expiry_date)subject
        from public.operational_staff_supervisor_training training
        join public.operational_staff staff on staff.id=training.operational_staff_id and staff.organization_id=training.organization_id
        join public.branches branch on branch.id=staff.branch_id and branch.organization_id=staff.organization_id
        join public.organizations organization on organization.id=staff.organization_id
        join public.operational_staff_assignments assignment on assignment.operational_staff_id=staff.id and assignment.active
        where training.organization_id=p_organization_id and training.status='training'
          and staff.employment_status='active' and branch.active and organization.active
          and (p_branch_id is null or branch.id=p_branch_id)
      )subjects
    ),'[]'::jsonb),
    'evaluations',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',evaluation.id,'branch_id',evaluation.branch_id,'evaluation_year',evaluation.evaluation_year,
      'subject_type',evaluation.subject_type,'subject_id',coalesce(evaluation.supervisor_user_id,evaluation.operational_staff_id),
      'subject_name_snapshot',evaluation.subject_name_snapshot,'subject_role_snapshot',evaluation.subject_role_snapshot,
      'subject_staff_code_snapshot',evaluation.subject_staff_code_snapshot,'branch_name_snapshot',evaluation.branch_name_snapshot,
      'state',evaluation.state,'revision',evaluation.revision,'total_score',evaluation.total_score,
      'evaluator_name_snapshot',evaluation.evaluator_name_snapshot,'updated_at',evaluation.updated_at,'submitted_at',evaluation.submitted_at
    )order by evaluation.evaluation_year desc,evaluation.updated_at desc)from public.annual_evaluations evaluation
      where evaluation.organization_id=p_organization_id and evaluation.evaluation_year=p_evaluation_year
        and (p_branch_id is null or evaluation.branch_id=p_branch_id)
        and (p_subject_type is null or evaluation.subject_type=p_subject_type)
        and (p_subject_id is null or coalesce(evaluation.supervisor_user_id,evaluation.operational_staff_id)=p_subject_id)
        and (p_state is null or evaluation.state=p_state)),'[]'::jsonb),
    'current',case when current_id is null then null else private.annual_evaluation_json(current_id)end
  );
end $$;

revoke all on function public.get_managed_annual_evaluation_workspace(uuid, uuid, integer, uuid, text, uuid, text)
  from public, anon, authenticated;
grant execute on function public.get_managed_annual_evaluation_workspace(uuid, uuid, integer, uuid, text, uuid, text)
  to service_role;
