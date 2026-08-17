create or replace function public.get_managed_annual_evaluation_workspace(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_evaluation_year integer,
  p_branch_id uuid default null,
  p_subject_type text default null,
  p_subject_id uuid default null,
  p_state text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_id uuid;
begin
  if not private.actor_manages_active_organization(p_actor_user_id, p_organization_id)
    or p_evaluation_year not between 2000 and 2200
    or (p_subject_type is not null and p_subject_type not in ('supervisor', 'training_supervisor', 'employee'))
    or (p_state is not null and p_state not in ('draft', 'submitted'))
    or ((p_subject_type is null) <> (p_subject_id is null))
    or (p_branch_id is not null and not exists (
      select 1
      from public.branches branch
      where branch.id = p_branch_id
        and branch.organization_id = p_organization_id
        and branch.active
    ))
  then
    raise exception 'annual evaluation access denied' using errcode = '42501';
  end if;

  if p_subject_id is not null then
    select evaluation.id
      into current_id
    from public.annual_evaluations evaluation
    where evaluation.organization_id = p_organization_id
      and evaluation.evaluation_year = p_evaluation_year
      and (
        p_branch_id is null
        or evaluation.branch_id = p_branch_id
        or (p_subject_type = 'training_supervisor' and evaluation.subject_type = 'training_supervisor')
      )
      and (
        (p_subject_type = 'supervisor' and evaluation.subject_type = 'supervisor' and evaluation.supervisor_user_id = p_subject_id)
        or (p_subject_type = 'training_supervisor' and evaluation.subject_type = 'training_supervisor' and evaluation.operational_staff_id = p_subject_id)
        or (p_subject_type = 'employee' and evaluation.subject_type = 'employee' and evaluation.operational_staff_id = p_subject_id)
      )
    order by evaluation.updated_at desc
    limit 1;
  end if;

  return pg_catalog.jsonb_build_object(
    'subjects',
    coalesce((
      select pg_catalog.jsonb_agg(subject order by subject ->> 'subject_type', subject ->> 'branch_name', subject ->> 'subject_name')
      from (
        with supervisor_subjects as (
          select distinct on (membership.user_id)
            membership.user_id,
            branch.id as branch_id,
            branch.name as branch_name,
            profile.full_name,
            profile.person_code,
            profile.phone_number,
            profile.country_code,
            profile.iqama_number,
            profile.iqama_expiry_date
          from public.branch_memberships membership
          join public.branches branch on branch.id = membership.branch_id
          join public.organizations organization on organization.id = branch.organization_id
          join public.profiles profile on profile.id = membership.user_id
          where branch.organization_id = p_organization_id
            and branch.active
            and organization.active
            and membership.role = 'branch_manager'
            and membership.active
            and profile.disabled_at is null
            and (p_branch_id is null or branch.id = p_branch_id)
          order by membership.user_id, branch.name, branch.id
        ),
        training_subjects as (
          select distinct on (staff.id)
            staff.id,
            staff.display_name,
            staff.staff_code,
            staff.phone_number,
            staff.country_code,
            staff.iqama_number,
            staff.iqama_expiry_date,
            branch.id as branch_id,
            branch.name as branch_name,
            assignment.operational_roles
          from public.operational_staff_supervisor_training training
          join public.operational_staff staff
            on staff.id = training.operational_staff_id
           and staff.organization_id = training.organization_id
          join public.branches branch
            on branch.id = staff.branch_id
           and branch.organization_id = staff.organization_id
          join public.organizations organization on organization.id = staff.organization_id
          join public.operational_staff_assignments assignment
            on assignment.operational_staff_id = staff.id
           and assignment.active
          where training.organization_id = p_organization_id
            and training.status = 'training'
            and staff.employment_status = 'active'
            and branch.active
            and organization.active
            and (p_branch_id is null or branch.id = p_branch_id)
          order by staff.id, assignment.created_at desc, assignment.id
        )
        select pg_catalog.jsonb_build_object(
          'subject_type', 'supervisor',
          'subject_id', supervisor.user_id,
          'supervisor_user_id', supervisor.user_id,
          'operational_staff_id', null,
          'subject_name', coalesce(supervisor.full_name, 'Supervisor'),
          'staff_code', supervisor.person_code,
          'role', 'Supervisor',
          'branch_id', supervisor.branch_id,
          'branch_name', supervisor.branch_name,
          'person_code', supervisor.person_code,
          'phone_number', supervisor.phone_number,
          'country_code', supervisor.country_code,
          'iqama_number', supervisor.iqama_number,
          'iqama_expiry_date', supervisor.iqama_expiry_date
        ) as subject
        from supervisor_subjects supervisor
        union all
        select pg_catalog.jsonb_build_object(
          'subject_type', 'training_supervisor',
          'subject_id', training.id,
          'supervisor_user_id', null,
          'operational_staff_id', training.id,
          'subject_name', training.display_name,
          'staff_code', training.staff_code,
          'role', private.annual_operational_roles_snapshot(training.operational_roles),
          'branch_id', training.branch_id,
          'branch_name', training.branch_name,
          'person_code', null,
          'phone_number', training.phone_number,
          'country_code', training.country_code,
          'iqama_number', training.iqama_number,
          'iqama_expiry_date', training.iqama_expiry_date
        ) as subject
        from training_subjects training
      ) subjects
    ), '[]'::jsonb),
    'evaluations',
    coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', evaluation.id,
        'branch_id', evaluation.branch_id,
        'evaluation_year', evaluation.evaluation_year,
        'subject_type', evaluation.subject_type,
        'subject_id', coalesce(evaluation.supervisor_user_id, evaluation.operational_staff_id),
        'subject_name_snapshot', evaluation.subject_name_snapshot,
        'subject_role_snapshot', evaluation.subject_role_snapshot,
        'subject_staff_code_snapshot', evaluation.subject_staff_code_snapshot,
        'branch_name_snapshot', evaluation.branch_name_snapshot,
        'state', evaluation.state,
        'revision', evaluation.revision,
        'total_score', evaluation.total_score,
        'evaluator_name_snapshot', evaluation.evaluator_name_snapshot,
        'updated_at', evaluation.updated_at,
        'submitted_at', evaluation.submitted_at
      ) order by evaluation.evaluation_year desc, evaluation.updated_at desc)
      from public.annual_evaluations evaluation
      where evaluation.organization_id = p_organization_id
        and evaluation.evaluation_year = p_evaluation_year
        and (p_branch_id is null or evaluation.branch_id = p_branch_id)
        and (p_subject_type is null or evaluation.subject_type = p_subject_type)
        and (p_subject_id is null or coalesce(evaluation.supervisor_user_id, evaluation.operational_staff_id) = p_subject_id)
        and (p_state is null or evaluation.state = p_state)
    ), '[]'::jsonb),
    'current',
    case when current_id is null then null else private.annual_evaluation_json(current_id) end
  );
end;
$$;

revoke all on function public.get_managed_annual_evaluation_workspace(uuid, uuid, integer, uuid, text, uuid, text)
  from public, anon, authenticated;
grant execute on function public.get_managed_annual_evaluation_workspace(uuid, uuid, integer, uuid, text, uuid, text)
  to service_role;
