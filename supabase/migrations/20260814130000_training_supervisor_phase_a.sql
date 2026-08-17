-- Manager-controlled Training Supervisor designation for operational employees.

alter table public.account_management_audit_logs
  drop constraint if exists account_management_audit_logs_action_check;

alter table public.account_management_audit_logs
  add constraint account_management_audit_logs_action_check check (
    action in (
      'user_created',
      'user_disabled',
      'user_enabled',
      'temporary_password_reset',
      'password_changed',
      'branch_created',
      'branch_assignment_added',
      'branch_assignment_removed',
      'branch_role_changed',
      'daily_audit_pin_configured',
      'daily_audit_pin_replaced',
      'daily_audit_access_granted',
      'daily_audit_user_access_granted',
      'daily_audit_user_access_revoked',
      'daily_audit_access_user_created',
      'daily_audit_access_user_revoked',
      'maintenance_access_user_created',
      'maintenance_access_user_deactivated',
      'maintenance_user_created',
      'maintenance_user_deactivated',
      'branch_shift_created',
      'branch_shift_updated',
      'supervisor_team_assigned',
      'supervisor_team_deactivated',
      'operational_staff_created',
      'operational_staff_updated',
      'operational_staff_deactivated',
      'operational_staff_assignment_created',
      'operational_staff_assignment_updated',
      'operational_staff_assignment_deactivated',
      'operational_staff_duty_changed',
      'organization_logo_updated',
      'branch_logo_updated',
      'operational_staff_supervisor_training_started',
      'operational_staff_supervisor_training_cancelled'
    )
  );

create table public.operational_staff_supervisor_training (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  operational_staff_id uuid not null references public.operational_staff(id) on delete restrict,
  branch_id_at_start uuid not null,
  status text not null default 'training',
  started_at timestamptz not null default now(),
  started_by_user_id uuid not null references auth.users(id) on delete restrict,
  cancelled_at timestamptz,
  cancelled_by_user_id uuid references auth.users(id) on delete restrict,
  cancellation_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint operational_staff_supervisor_training_branch_scope_fkey foreign key(branch_id_at_start,organization_id)
    references public.branches(id,organization_id) on delete restrict,
  constraint operational_staff_supervisor_training_status_check check(status in('training','cancelled')),
  constraint operational_staff_supervisor_training_cancel_check check(
    (status='training' and cancelled_at is null and cancelled_by_user_id is null and cancellation_reason is null)
    or (status='cancelled' and cancelled_at is not null and cancelled_by_user_id is not null)
  ),
  constraint operational_staff_supervisor_training_reason_check check(
    cancellation_reason is null or (cancellation_reason=pg_catalog.btrim(cancellation_reason) and pg_catalog.length(cancellation_reason) between 1 and 500)
  )
);

create unique index operational_staff_supervisor_training_active_key
  on public.operational_staff_supervisor_training(operational_staff_id)
  where status='training';
create index operational_staff_supervisor_training_org_staff_idx
  on public.operational_staff_supervisor_training(organization_id,operational_staff_id,started_at desc);

alter table public.operational_staff_supervisor_training enable row level security;
revoke all on public.operational_staff_supervisor_training from public,anon,authenticated,service_role;

create trigger operational_staff_supervisor_training_set_updated_at before update on public.operational_staff_supervisor_training
for each row execute function private.set_updated_at();

create function private.operational_staff_supervisor_training_json(target_id uuid)
returns jsonb language sql stable security invoker set search_path='' as $$
select pg_catalog.jsonb_build_object(
  'id',training.id,'organization_id',training.organization_id,'operational_staff_id',training.operational_staff_id,
  'branch_id_at_start',training.branch_id_at_start,'status',training.status,'started_at',training.started_at,
  'started_by_user_id',training.started_by_user_id,'cancelled_at',training.cancelled_at,
  'cancelled_by_user_id',training.cancelled_by_user_id,'cancellation_reason',training.cancellation_reason,
  'created_at',training.created_at,'updated_at',training.updated_at
) from public.operational_staff_supervisor_training training where training.id=target_id
$$;

create function public.start_managed_operational_staff_supervisor_training(
  actor_user_id uuid,target_organization_id uuid,target_staff_id uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
declare staff_row public.operational_staff%rowtype; training_id uuid;
begin
  if not private.actor_manages_active_organization(actor_user_id,target_organization_id)
  then raise exception 'supervisor training access denied' using errcode='42501'; end if;
  select staff.* into strict staff_row
  from public.operational_staff staff
  join public.branches branch on branch.id=staff.branch_id and branch.organization_id=staff.organization_id
  join public.organizations organization on organization.id=staff.organization_id
  where staff.id=target_staff_id and staff.organization_id=target_organization_id
    and staff.employment_status='active' and branch.active and organization.active
    and exists(
      select 1 from public.operational_staff_assignments assignment
      join public.branch_operational_teams team on team.id=assignment.operational_team_id and team.active
      where assignment.operational_staff_id=staff.id and assignment.active
    )
  for update;
  insert into public.operational_staff_supervisor_training(
    organization_id,operational_staff_id,branch_id_at_start,started_by_user_id
  ) values(target_organization_id,target_staff_id,staff_row.branch_id,actor_user_id)
  returning id into training_id;
  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
  values(target_organization_id,actor_user_id,staff_row.branch_id,'operational_staff_supervisor_training_started',
    pg_catalog.jsonb_build_object('operational_staff_id',target_staff_id,'training_id',training_id));
  return private.operational_staff_supervisor_training_json(training_id);
exception
  when unique_violation then raise exception 'active supervisor training already exists' using errcode='23505';
  when no_data_found or too_many_rows then raise exception 'supervisor training access denied' using errcode='42501';
end $$;

create function public.cancel_managed_operational_staff_supervisor_training(
  actor_user_id uuid,target_organization_id uuid,target_staff_id uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
declare training_row public.operational_staff_supervisor_training%rowtype;
begin
  if not private.actor_manages_active_organization(actor_user_id,target_organization_id)
  then raise exception 'supervisor training access denied' using errcode='42501'; end if;
  select training.* into strict training_row
  from public.operational_staff_supervisor_training training
  join public.operational_staff staff on staff.id=training.operational_staff_id
  where training.operational_staff_id=target_staff_id and training.organization_id=target_organization_id
    and staff.organization_id=target_organization_id and training.status='training'
  for update;
  update public.operational_staff_supervisor_training
  set status='cancelled',cancelled_at=now(),cancelled_by_user_id=actor_user_id
  where id=training_row.id returning * into training_row;
  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
  values(target_organization_id,actor_user_id,training_row.branch_id_at_start,'operational_staff_supervisor_training_cancelled',
    pg_catalog.jsonb_build_object('operational_staff_id',target_staff_id,'training_id',training_row.id));
  return private.operational_staff_supervisor_training_json(training_row.id);
exception
  when no_data_found or too_many_rows then raise exception 'supervisor training access denied' using errcode='42501';
end $$;

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
      and (branch_filter is null or staff.branch_id=branch_filter)),'[]'::jsonb),
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

revoke all on function private.operational_staff_supervisor_training_json(uuid) from public,anon,authenticated,service_role;
revoke all on function public.start_managed_operational_staff_supervisor_training(uuid,uuid,uuid),
  public.cancel_managed_operational_staff_supervisor_training(uuid,uuid,uuid),
  public.list_managed_employee_team(uuid,uuid,uuid,date)
  from public,anon,authenticated;
grant execute on function public.start_managed_operational_staff_supervisor_training(uuid,uuid,uuid),
  public.cancel_managed_operational_staff_supervisor_training(uuid,uuid,uuid),
  public.list_managed_employee_team(uuid,uuid,uuid,date)
  to service_role;
