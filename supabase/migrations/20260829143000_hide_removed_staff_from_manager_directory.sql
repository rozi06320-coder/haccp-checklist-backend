-- Hide soft-removed duplicate/mistaken operational staff from the Manager
-- current Employee Directory while preserving Left Company and historical records.

create or replace function public.list_managed_employee_team(
  actor_user_id uuid,target_organization_id uuid,branch_filter uuid default null,requested_month date default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare result jsonb;
begin
  if requested_month is null or requested_month<>pg_catalog.date_trunc('month',requested_month)::date
    or not private.actor_manages_active_organization(actor_user_id,target_organization_id)
    or (branch_filter is not null and not exists(select 1 from public.branches
      where id=branch_filter and organization_id=target_organization_id))
  then raise exception 'employee team access denied' using errcode='42501'; end if;
  select pg_catalog.jsonb_build_object(
    'employees',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'staff_id',staff.id,'display_name',staff.display_name,'staff_code',staff.staff_code,'country_code',staff.country_code,
      'employment_status',staff.employment_status,'company_name',staff.company_name,
      'iqama_number',staff.iqama_number,'phone_number',staff.phone_number,'email',staff.email,
      'branch_id',branch.id,'branch_name',branch.name,'branch_name_ar',branch.name_ar,
      'supervisor_name',profile.full_name,'supervisor_name_ar',profile.full_name_ar,
      'assignment_id',assignment.id,'operational_team_id',operational_team.id,
      'operational_team_name',operational_team.name,'operational_roles',assignment.operational_roles,
      'duty_status',case when staff.employment_status='active' and assignment.id is not null
        then coalesce(duty.duty_status,'on_duty') else null end,
      'supervisor_training_status',case when exists(
        select 1 from public.operational_staff_supervisor_training training
        where training.operational_staff_id=staff.id and training.status='training'
      ) then 'training' else null end
    ) order by staff.normalized_name,staff.id)
    from public.operational_staff staff
    join public.branches branch on branch.id=staff.branch_id
    left join public.operational_staff_assignments assignment
      on assignment.operational_staff_id=staff.id and assignment.active
    left join public.branch_operational_teams operational_team on operational_team.id=assignment.operational_team_id
    left join public.branch_supervisor_teams team on team.id=assignment.supervisor_team_id
    left join public.profiles profile on profile.id=team.supervisor_user_id
    left join public.operational_staff_duty_statuses duty on duty.assignment_id=assignment.id
      and duty.duty_date=private.phase4a_business_date(branch.timezone)
    where staff.organization_id=target_organization_id
      and (branch_filter is null or staff.branch_id=branch_filter)
      and (
        staff.employment_status='active'
        or not exists (
          select 1
          from public.operational_staff_removal_audits removal
          where removal.organization_id=target_organization_id
            and removal.operational_staff_id=staff.id
            and removal.reason_code in('duplicate','added_by_mistake','wrong_employee_data','other')
        )
      )),'[]'::jsonb),
    'operational_teams',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',team.id,'branch_id',branch.id,'branch_name',branch.name,'branch_name_ar',branch.name_ar,
      'name',team.name,'active',team.active
    ) order by pg_catalog.lower(branch.name),team.normalized_name,team.id)
    from public.branch_operational_teams team join public.branches branch on branch.id=team.branch_id
    where team.organization_id=target_organization_id and team.active),'[]'::jsonb),
    'health_cards',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',card.id,'operational_staff_id',staff.id,'display_name',staff.display_name,
      'branch_id',branch.id,'branch_name',branch.name,'branch_name_ar',branch.name_ar,
      'certificate_number',card.certificate_number,'status',card.status,'place_of_issue',card.place_of_issue,
      'expiry_date',card.expiry_date,'date_issue',card.date_issue,'occupation',card.occupation,
      'company',card.company,'branch_name_snapshot',card.branch_name_snapshot,'notes',card.notes,'updated_at',card.updated_at
    ) order by pg_catalog.lower(staff.display_name),staff.id)
    from public.operational_staff_health_cards card
    join public.operational_staff staff on staff.id=card.operational_staff_id and staff.organization_id=target_organization_id
    join public.branches branch on branch.id=staff.branch_id
    where branch_filter is null or staff.branch_id=branch_filter),'[]'::jsonb),
    'monthly_evaluations',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',evaluation.id,'operational_staff_id',staff.id,'display_name',staff.display_name,
      'branch_id',branch.id,'branch_name',branch.name,'branch_name_ar',branch.name_ar,
      'evaluation_month',evaluation.evaluation_month,'evaluator_name',evaluation.evaluator_name,
      'status',evaluation.status,'average_score',evaluation.average_score,
      'scores',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'section',score.section,'factor_key',score.factor_key,'factor_label',score.factor_label,
        'rating',score.rating,'comment',score.comment) order by score.section,score.factor_key)
        from public.operational_staff_monthly_evaluation_scores score
        where score.evaluation_id=evaluation.id),'[]'::jsonb),'updated_at',evaluation.updated_at
    ) order by pg_catalog.lower(staff.display_name),staff.id)
    from public.operational_staff_monthly_evaluations evaluation
    join public.operational_staff staff on staff.id=evaluation.operational_staff_id
      and staff.organization_id=target_organization_id
    join public.branches branch on branch.id=staff.branch_id
    where evaluation.evaluation_month=requested_month
      and (branch_filter is null or staff.branch_id=branch_filter)),'[]'::jsonb)
  ) into result;
  return result;
end $$;

revoke all on function public.list_managed_employee_team(uuid,uuid,uuid,date) from public,anon,authenticated;
grant execute on function public.list_managed_employee_team(uuid,uuid,uuid,date) to service_role;
