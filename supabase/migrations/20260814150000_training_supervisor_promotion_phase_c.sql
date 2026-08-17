-- Promote active Training Supervisors into real branch Supervisor accounts.

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
      'operational_staff_supervisor_training_cancelled',
      'operational_staff_supervisor_training_promoted'
    )
  );

alter table public.operational_staff_assignments
  drop constraint if exists operational_staff_assignments_closure_reason_check;

alter table public.operational_staff_assignments
  add constraint operational_staff_assignments_closure_reason_check
    check(closure_reason is null or closure_reason in('team_move','branch_transfer','left_company','promoted_to_supervisor'));

alter table public.operational_staff_supervisor_training
  add column if not exists promoted_at timestamptz,
  add column if not exists promoted_by_user_id uuid references auth.users(id) on delete restrict,
  add column if not exists promoted_supervisor_user_id uuid references auth.users(id) on delete restrict;

alter table public.operational_staff_supervisor_training
  drop constraint if exists operational_staff_supervisor_training_status_check,
  drop constraint if exists operational_staff_supervisor_training_cancel_check;

alter table public.operational_staff_supervisor_training
  add constraint operational_staff_supervisor_training_status_check check(status in('training','cancelled','promoted')),
  add constraint operational_staff_supervisor_training_lifecycle_check check(
    (status='training'
      and cancelled_at is null and cancelled_by_user_id is null and cancellation_reason is null
      and promoted_at is null and promoted_by_user_id is null and promoted_supervisor_user_id is null)
    or (status='cancelled'
      and cancelled_at is not null and cancelled_by_user_id is not null
      and promoted_at is null and promoted_by_user_id is null and promoted_supervisor_user_id is null)
    or (status='promoted'
      and cancelled_at is null and cancelled_by_user_id is null and cancellation_reason is null
      and promoted_at is not null and promoted_by_user_id is not null and promoted_supervisor_user_id is not null)
  );

create or replace function private.operational_staff_supervisor_training_json(target_id uuid)
returns jsonb language sql stable security invoker set search_path='' as $$
select pg_catalog.jsonb_build_object(
  'id',training.id,'organization_id',training.organization_id,'operational_staff_id',training.operational_staff_id,
  'branch_id_at_start',training.branch_id_at_start,'status',training.status,'started_at',training.started_at,
  'started_by_user_id',training.started_by_user_id,'cancelled_at',training.cancelled_at,
  'cancelled_by_user_id',training.cancelled_by_user_id,'cancellation_reason',training.cancellation_reason,
  'promoted_at',training.promoted_at,'promoted_by_user_id',training.promoted_by_user_id,
  'promoted_supervisor_user_id',training.promoted_supervisor_user_id,
  'created_at',training.created_at,'updated_at',training.updated_at
) from public.operational_staff_supervisor_training training where training.id=target_id
$$;

create function public.get_managed_supervisor_training_promotion_state(
  actor_user_id uuid,
  target_organization_id uuid,
  target_staff_id uuid
) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  training_row public.operational_staff_supervisor_training%rowtype;
begin
  if not private.actor_manages_active_organization(actor_user_id,target_organization_id)
  then raise exception 'supervisor promotion access denied' using errcode='42501'; end if;

  select training.* into training_row
  from public.operational_staff_supervisor_training training
  join public.operational_staff staff on staff.id=training.operational_staff_id
  where training.operational_staff_id=target_staff_id
    and training.organization_id=target_organization_id
    and staff.organization_id=target_organization_id
    and training.status='promoted'
  order by training.promoted_at desc nulls last,training.started_at desc
  limit 1;
  if training_row.id is not null then
    return private.operational_staff_supervisor_training_json(training_row.id);
  end if;

  select training.* into strict training_row
  from public.operational_staff_supervisor_training training
  join public.operational_staff staff on staff.id=training.operational_staff_id
  join public.branches branch on branch.id=staff.branch_id and branch.organization_id=staff.organization_id
  join public.organizations organization on organization.id=staff.organization_id
  join public.operational_staff_assignments assignment on assignment.operational_staff_id=staff.id and assignment.active
  join public.branch_operational_teams team on team.id=assignment.operational_team_id and team.active
  where training.operational_staff_id=target_staff_id
    and training.organization_id=target_organization_id
    and staff.organization_id=target_organization_id
    and training.status='training'
    and staff.employment_status='active'
    and branch.active
    and organization.active
  for update of training;
  return private.operational_staff_supervisor_training_json(training_row.id);
exception
  when no_data_found or too_many_rows then raise exception 'supervisor promotion access denied' using errcode='42501';
end $$;

create function public.promote_managed_operational_staff_supervisor_training(
  actor_user_id uuid,
  target_organization_id uuid,
  target_staff_id uuid,
  new_supervisor_user_id uuid,
  new_supervisor_full_name text,
  new_supervisor_full_name_ar text,
  target_operational_team_ids uuid[],
  target_assignment_role text
) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  training_row public.operational_staff_supervisor_training%rowtype;
  staff_row public.operational_staff%rowtype;
  assignment_row public.operational_staff_assignments%rowtype;
  clean_name text:=pg_catalog.regexp_replace(pg_catalog.btrim(new_supervisor_full_name),'[[:space:]]+',' ','g');
  clean_name_ar text:=private.clean_optional_master_name(new_supervisor_full_name_ar);
  changed_rows integer;
  team_id uuid;
  created_legacy_team_id uuid;
  inserted_assignment_ids uuid[]:='{}'::uuid[];
  inserted_assignment_id uuid;
begin
  if target_assignment_role not in('primary','backup')
    or clean_name is null or pg_catalog.length(clean_name) not between 1 and 120
    or target_operational_team_ids is null or pg_catalog.cardinality(target_operational_team_ids)=0
    or (select pg_catalog.count(*)<>pg_catalog.count(distinct item) from pg_catalog.unnest(target_operational_team_ids) item)
    or not private.actor_manages_active_organization(actor_user_id,target_organization_id)
  then raise exception 'supervisor promotion denied' using errcode='42501'; end if;

  select training.* into training_row
  from public.operational_staff_supervisor_training training
  where training.operational_staff_id=target_staff_id
    and training.organization_id=target_organization_id
    and training.status='promoted'
  order by training.promoted_at desc nulls last,training.started_at desc
  limit 1
  for update;
  if training_row.id is not null then
    if training_row.promoted_supervisor_user_id<>new_supervisor_user_id then
      raise exception 'supervisor promotion already completed' using errcode='23505';
    end if;
    return private.operational_staff_supervisor_training_json(training_row.id);
  end if;

  select training.* into strict training_row
  from public.operational_staff_supervisor_training training
  where training.operational_staff_id=target_staff_id
    and training.organization_id=target_organization_id
    and training.status='training'
  for update;

  select staff.* into strict staff_row
  from public.operational_staff staff
  join public.branches branch on branch.id=staff.branch_id and branch.organization_id=staff.organization_id
  join public.organizations organization on organization.id=staff.organization_id
  where staff.id=target_staff_id and staff.organization_id=target_organization_id
    and staff.employment_status='active' and branch.active and organization.active
  for update;

  select assignment.* into strict assignment_row
  from public.operational_staff_assignments assignment
  join public.branch_operational_teams team on team.id=assignment.operational_team_id and team.active
  where assignment.operational_staff_id=target_staff_id
    and assignment.organization_id=target_organization_id
    and assignment.branch_id=staff_row.branch_id
    and assignment.active
  for update;

  if (
    select pg_catalog.count(*)<>pg_catalog.cardinality(target_operational_team_ids)
    from public.branch_operational_teams team
    where team.id=any(target_operational_team_ids)
      and team.organization_id=target_organization_id
      and team.branch_id=staff_row.branch_id
      and team.active
  ) then
    raise exception 'supervisor promotion denied' using errcode='42501';
  end if;

  if exists(
    select 1 from public.branch_memberships membership
    join public.branches branch on branch.id=membership.branch_id
    where membership.user_id=new_supervisor_user_id
      and membership.role='branch_manager'
      and membership.active
      and branch.organization_id=target_organization_id
  ) then
    raise exception 'supervisor promotion already exists' using errcode='23505';
  end if;

  if target_assignment_role='primary' and exists(
    select 1 from public.branch_operational_team_supervisors supervisor_assignment
    where supervisor_assignment.operational_team_id=any(target_operational_team_ids)
      and supervisor_assignment.active
      and supervisor_assignment.assignment_role='primary'
      and supervisor_assignment.supervisor_user_id<>new_supervisor_user_id
  ) then
    raise exception 'primary supervisor assignment already exists' using errcode='23505';
  end if;

  update public.profiles
  set full_name=clean_name,
      full_name_ar=clean_name_ar,
      must_change_password=false,
      disabled_at=null
  where id=new_supervisor_user_id;
  get diagnostics changed_rows=row_count;
  if changed_rows<>1 then
    raise exception 'target profile missing' using errcode='23503';
  end if;

  insert into public.branch_memberships(branch_id,user_id,role,active)
  values(staff_row.branch_id,new_supervisor_user_id,'branch_manager',true)
  on conflict(branch_id,user_id) do update
    set role='branch_manager',active=true,updated_at=now();

  insert into public.branch_supervisor_teams(organization_id,branch_id,supervisor_user_id,active)
  select target_organization_id,staff_row.branch_id,new_supervisor_user_id,true
  where not exists(
    select 1 from public.branch_supervisor_teams team
    where team.organization_id=target_organization_id
      and team.branch_id=staff_row.branch_id
      and team.supervisor_user_id=new_supervisor_user_id
      and team.active
  )
  returning id into created_legacy_team_id;

  foreach team_id in array target_operational_team_ids loop
    insert into public.branch_operational_team_supervisors(
      organization_id,branch_id,operational_team_id,supervisor_user_id,assignment_role,created_by
    )
    select target_organization_id,staff_row.branch_id,team_id,new_supervisor_user_id,target_assignment_role,actor_user_id
    where not exists(
      select 1 from public.branch_operational_team_supervisors existing
      where existing.operational_team_id=team_id
        and existing.supervisor_user_id=new_supervisor_user_id
        and existing.active
    )
    returning id into inserted_assignment_id;
    if inserted_assignment_id is not null then
      inserted_assignment_ids:=array_append(inserted_assignment_ids,inserted_assignment_id);
    end if;
    inserted_assignment_id:=null;
  end loop;

  update public.operational_staff_assignments
  set active=false,
      valid_to=greatest(valid_from,current_date),
      closed_at=now(),
      closed_by_user_id=actor_user_id,
      closure_reason='promoted_to_supervisor'
  where id=assignment_row.id;

  update public.operational_staff
  set employment_status='inactive',
      deactivated_at=now(),
      deactivated_by=actor_user_id
  where id=staff_row.id;

  update public.operational_staff_supervisor_training
  set status='promoted',
      promoted_at=now(),
      promoted_by_user_id=actor_user_id,
      promoted_supervisor_user_id=new_supervisor_user_id
  where id=training_row.id
  returning * into training_row;

  update public.profiles
  set must_change_password=true
  where id=new_supervisor_user_id;

  insert into public.account_management_audit_logs(organization_id,actor_user_id,target_user_id,branch_id,action,details)
  values(target_organization_id,actor_user_id,new_supervisor_user_id,staff_row.branch_id,
    'operational_staff_supervisor_training_promoted',
    pg_catalog.jsonb_build_object(
      'operational_staff_id',target_staff_id,
      'training_id',training_row.id,
      'closed_assignment_id',assignment_row.id,
      'legacy_supervisor_team_id',created_legacy_team_id,
      'operational_team_ids',target_operational_team_ids,
      'assignment_role',target_assignment_role,
      'team_supervisor_assignment_ids',inserted_assignment_ids
    ));

  return private.operational_staff_supervisor_training_json(training_row.id);
exception
  when unique_violation then raise exception 'supervisor promotion conflict' using errcode='23505';
  when no_data_found or too_many_rows then raise exception 'supervisor promotion denied' using errcode='42501';
end $$;

revoke all on function public.get_managed_supervisor_training_promotion_state(uuid,uuid,uuid),
  public.promote_managed_operational_staff_supervisor_training(uuid,uuid,uuid,uuid,text,text,uuid[],text)
  from public,anon,authenticated;
grant execute on function public.get_managed_supervisor_training_promotion_state(uuid,uuid,uuid),
  public.promote_managed_operational_staff_supervisor_training(uuid,uuid,uuid,uuid,text,text,uuid[],text)
  to service_role;
