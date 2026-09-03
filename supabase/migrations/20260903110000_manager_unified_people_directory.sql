-- Additive Manager people directory reader. The existing employee-team reader
-- remains unchanged for staged backend/frontend rollout.

create function public.list_managed_people_directory(
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
  normalized_search text := nullif(pg_catalog.btrim(search_term), '');
  normalized_code_filter text := nullif(pg_catalog.btrim(code_filter), '');
  people_limit constant integer := 1000;
begin
  if requested_month is null
    or requested_month <> pg_catalog.date_trunc('month', requested_month)::date
    or pg_catalog.length(coalesce(search_term, '')) > 120
    or pg_catalog.length(coalesce(code_filter, '')) > 64
    or not private.actor_manages_active_organization(actor_user_id, target_organization_id)
    or (
      branch_filter is not null
      and not exists (
        select 1
        from public.branches branch
        where branch.id = branch_filter
          and branch.organization_id = target_organization_id
      )
    )
  then
    raise exception 'people directory access denied' using errcode = '42501';
  end if;

  with supervisor_organization_joins as materialized (
    select
      membership.user_id as person_id,
      pg_catalog.min(membership.created_at) as joined_at
    from public.branch_memberships membership
    join public.branches branch on branch.id = membership.branch_id
    where branch.organization_id = target_organization_id
    group by membership.user_id
  ),
  supervisor_people as materialized (
    select
      profile.id as person_id,
      coalesce(profile.full_name, auth_user.email::text) as display_name,
      profile.full_name_ar as display_name_ar,
      profile.person_code,
      profile.phone_number,
      auth_user.email::text as email,
      profile.country_code,
      profile.iqama_number,
      profile.iqama_expiry_date,
      organization_join.joined_at,
      organization_join.joined_at + interval '1 month' as new_until,
      case
        when profile.disabled_at is not null then 'disabled'
        when profile.must_change_password then 'password_change_required'
        else 'active'
      end as person_status,
      pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', branch.id,
          'name', branch.name,
          'name_ar', branch.name_ar,
          'code', branch.code
        )
        order by pg_catalog.lower(branch.name), branch.id
      ) as branches
    from public.branch_memberships membership
    join public.branches branch
      on branch.id = membership.branch_id
      and branch.organization_id = target_organization_id
      and branch.active
    join public.organizations organization
      on organization.id = branch.organization_id
      and organization.active
    join public.profiles profile on profile.id = membership.user_id
    join auth.users auth_user on auth_user.id = profile.id
    join supervisor_organization_joins organization_join on organization_join.person_id = profile.id
    where membership.role = 'branch_manager'
      and membership.active
      and (
        normalized_search is null
        or pg_catalog.strpos(pg_catalog.lower(coalesce(profile.full_name, '')), pg_catalog.lower(normalized_search)) > 0
        or pg_catalog.strpos(pg_catalog.lower(coalesce(profile.full_name_ar, '')), pg_catalog.lower(normalized_search)) > 0
        or pg_catalog.strpos(pg_catalog.lower(coalesce(profile.person_code, '')), pg_catalog.lower(normalized_search)) > 0
        or pg_catalog.strpos(pg_catalog.lower(coalesce(auth_user.email::text, '')), pg_catalog.lower(normalized_search)) > 0
      )
      and (
        normalized_code_filter is null
        or pg_catalog.strpos(pg_catalog.lower(coalesce(profile.person_code, '')), pg_catalog.lower(normalized_code_filter)) > 0
      )
    group by profile.id, auth_user.email, organization_join.joined_at
    having branch_filter is null or pg_catalog.bool_or(branch.id = branch_filter)
  ),
  people_rows as materialized (
    select
      'staff'::text as person_type,
      staff.id as person_id,
      staff.normalized_name as sort_name,
      pg_catalog.jsonb_build_object(
        'person_type', 'staff',
        'person_id', staff.id,
        'display_name', staff.display_name,
        'display_name_ar', null,
        'person_code', staff.staff_code,
        'phone_number', staff.phone_number,
        'email', staff.email,
        'country_code', staff.country_code,
        'iqama_number', staff.iqama_number,
        'iqama_expiry_date', staff.iqama_expiry_date,
        'branches', pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
          'id', branch.id,
          'name', branch.name,
          'name_ar', branch.name_ar,
          'code', branch.code
        )),
        'status', case
          when staff.employment_status = 'inactive' then 'left_company'
          when duty.duty_status = 'on_vacation' then 'on_vacation'
          else 'active'
        end,
        'joined_at', staff.created_at,
        'new_until', staff.created_at + interval '1 month',
        'is_new', staff.created_at <= pg_catalog.now() and pg_catalog.now() < staff.created_at + interval '1 month',
        'staff_id', staff.id,
        'employment_status', staff.employment_status,
        'company_name', staff.company_name,
        'supervisor_name', supervisor_profile.full_name,
        'supervisor_name_ar', supervisor_profile.full_name_ar,
        'assignment_id', assignment.id,
        'operational_team_id', operational_team.id,
        'operational_team_name', operational_team.name,
        'operational_roles', assignment.operational_roles,
        'duty_status', case
          when staff.employment_status = 'active' and assignment.id is not null
            then coalesce(duty.duty_status, 'on_duty')
          else null
        end,
        'supervisor_training_status', case
          when exists (
            select 1
            from public.operational_staff_supervisor_training training
            where training.operational_staff_id = staff.id
              and training.status = 'training'
          ) then 'training'
          else null
        end
      ) as person
    from public.operational_staff staff
    join public.branches branch on branch.id = staff.branch_id
    left join public.operational_staff_assignments assignment
      on assignment.operational_staff_id = staff.id
      and assignment.active
    left join public.branch_operational_teams operational_team
      on operational_team.id = assignment.operational_team_id
    left join public.branch_supervisor_teams supervisor_team
      on supervisor_team.id = assignment.supervisor_team_id
    left join public.profiles supervisor_profile
      on supervisor_profile.id = supervisor_team.supervisor_user_id
    left join public.operational_staff_duty_statuses duty
      on duty.assignment_id = assignment.id
      and duty.duty_date = private.phase4a_business_date(branch.timezone)
    where staff.organization_id = target_organization_id
      and (branch_filter is null or staff.branch_id = branch_filter)
      and (
        normalized_search is null
        or pg_catalog.strpos(pg_catalog.lower(coalesce(staff.display_name, '')), pg_catalog.lower(normalized_search)) > 0
        or pg_catalog.strpos(pg_catalog.lower(coalesce(staff.staff_code, '')), pg_catalog.lower(normalized_search)) > 0
        or pg_catalog.strpos(pg_catalog.lower(coalesce(staff.email, '')), pg_catalog.lower(normalized_search)) > 0
      )
      and (
        normalized_code_filter is null
        or pg_catalog.strpos(pg_catalog.lower(coalesce(staff.staff_code, '')), pg_catalog.lower(normalized_code_filter)) > 0
      )
      and (
        staff.employment_status = 'active'
        or not exists (
          select 1
          from public.operational_staff_removal_audits removal
          where removal.organization_id = target_organization_id
            and removal.operational_staff_id = staff.id
            and removal.reason_code in ('duplicate', 'added_by_mistake', 'wrong_employee_data', 'other')
        )
      )
      and not (
        staff.employment_status = 'inactive'
        and exists (
          select 1
          from public.operational_staff_supervisor_training promotion
          join supervisor_people promoted_supervisor
            on promoted_supervisor.person_id = promotion.promoted_supervisor_user_id
          where promotion.operational_staff_id = staff.id
            and promotion.organization_id = target_organization_id
            and promotion.status = 'promoted'
        )
      )

    union all

    select
      'supervisor'::text,
      supervisor.person_id,
      pg_catalog.lower(supervisor.display_name),
      pg_catalog.jsonb_build_object(
        'person_type', 'supervisor',
        'person_id', supervisor.person_id,
        'display_name', supervisor.display_name,
        'display_name_ar', supervisor.display_name_ar,
        'person_code', supervisor.person_code,
        'phone_number', supervisor.phone_number,
        'email', supervisor.email,
        'country_code', supervisor.country_code,
        'iqama_number', supervisor.iqama_number,
        'iqama_expiry_date', supervisor.iqama_expiry_date,
        'branches', supervisor.branches,
        'status', supervisor.person_status,
        'joined_at', supervisor.joined_at,
        'new_until', supervisor.new_until,
        'is_new', supervisor.joined_at <= pg_catalog.now() and pg_catalog.now() < supervisor.new_until
      )
    from supervisor_people supervisor
  ),
  limited_people as materialized (
    select person_type, person_id, sort_name, person
    from people_rows
    order by sort_name, person_type, person_id
    limit people_limit
  )
  select pg_catalog.jsonb_build_object(
    'people', coalesce((
      select pg_catalog.jsonb_agg(person order by sort_name, person_type, person_id)
      from limited_people
    ), '[]'::jsonb),
    'people_total', (select pg_catalog.count(*) from people_rows),
    'people_limit', people_limit,
    'people_truncated', (select pg_catalog.count(*) > people_limit from people_rows),
    'operational_teams', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', team.id,
        'branch_id', branch.id,
        'branch_name', branch.name,
        'branch_name_ar', branch.name_ar,
        'name', team.name,
        'active', team.active
      ) order by pg_catalog.lower(branch.name), team.normalized_name, team.id)
      from public.branch_operational_teams team
      join public.branches branch on branch.id = team.branch_id
      where team.organization_id = target_organization_id
        and team.active
    ), '[]'::jsonb),
    'health_cards', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', card.id,
        'operational_staff_id', staff.id,
        'display_name', staff.display_name,
        'branch_id', branch.id,
        'branch_name', branch.name,
        'branch_name_ar', branch.name_ar,
        'certificate_number', card.certificate_number,
        'status', card.status,
        'place_of_issue', card.place_of_issue,
        'expiry_date', card.expiry_date,
        'date_issue', card.date_issue,
        'occupation', card.occupation,
        'company', card.company,
        'branch_name_snapshot', card.branch_name_snapshot,
        'notes', card.notes,
        'updated_at', card.updated_at
      ) order by pg_catalog.lower(staff.display_name), staff.id)
      from public.operational_staff_health_cards card
      join public.operational_staff staff
        on staff.id = card.operational_staff_id
        and staff.organization_id = target_organization_id
      join public.branches branch on branch.id = staff.branch_id
      where branch_filter is null or staff.branch_id = branch_filter
    ), '[]'::jsonb),
    'monthly_evaluations', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', evaluation.id,
        'operational_staff_id', staff.id,
        'display_name', staff.display_name,
        'branch_id', branch.id,
        'branch_name', branch.name,
        'branch_name_ar', branch.name_ar,
        'evaluation_month', evaluation.evaluation_month,
        'evaluator_name', evaluation.evaluator_name,
        'status', evaluation.status,
        'average_score', evaluation.average_score,
        'scores', coalesce((
          select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'section', score.section,
            'factor_key', score.factor_key,
            'factor_label', score.factor_label,
            'rating', score.rating,
            'comment', score.comment
          ) order by score.section, score.factor_key)
          from public.operational_staff_monthly_evaluation_scores score
          where score.evaluation_id = evaluation.id
        ), '[]'::jsonb),
        'updated_at', evaluation.updated_at
      ) order by pg_catalog.lower(staff.display_name), staff.id)
      from public.operational_staff_monthly_evaluations evaluation
      join public.operational_staff staff
        on staff.id = evaluation.operational_staff_id
        and staff.organization_id = target_organization_id
      join public.branches branch on branch.id = staff.branch_id
      where evaluation.evaluation_month = requested_month
        and (branch_filter is null or staff.branch_id = branch_filter)
    ), '[]'::jsonb)
  ) into result;

  return result;
end;
$$;

comment on function public.list_managed_people_directory(uuid, uuid, uuid, date, text, text) is
  'Additive Manager directory reader. Supervisors are returned once with all active branches in the authorized organization; branch_filter controls person inclusion. Results are capped at 1000 with explicit total/truncation metadata.';

revoke all on function public.list_managed_people_directory(uuid, uuid, uuid, date, text, text)
  from public, anon, authenticated;
grant execute on function public.list_managed_people_directory(uuid, uuid, uuid, date, text, text)
  to service_role;
