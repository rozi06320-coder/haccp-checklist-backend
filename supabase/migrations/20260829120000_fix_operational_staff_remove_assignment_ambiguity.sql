-- Fix PL/pgSQL ambiguity between the RETURNS TABLE assignment_id output
-- parameter and the removal audit assignment_id conflict target.
create or replace function public.remove_operational_team_staff(
  actor_user_id uuid,
  target_branch_id uuid,
  target_staff_id uuid,
  expected_assignment_id uuid,
  removal_reason text,
  removal_note text default null
)
returns table(staff_id uuid, assignment_id uuid, employment_status text, reason_code text)
language plpgsql security definer set search_path = '' as $$
declare
  staff_row public.operational_staff%rowtype;
  assignment_row public.operational_staff_assignments%rowtype;
  current_business_date date;
  clean_note text := nullif(pg_catalog.btrim(pg_catalog.regexp_replace(coalesce(removal_note,''),'[[:space:]]+',' ','g')), '');
  closure text;
  existing_reason text;
begin
  if removal_reason not in('duplicate','added_by_mistake','wrong_employee_data','left_company','other')
    or (removal_reason = 'other' and clean_note is null)
    or length(coalesce(clean_note,'')) > 1000
  then raise exception 'invalid staff removal reason' using errcode='22023'; end if;

  select * into strict staff_row from public.operational_staff staff
    where staff.id = target_staff_id and staff.branch_id = target_branch_id for update;
  select * into strict assignment_row from public.operational_staff_assignments assignment
    where assignment.id = expected_assignment_id
      and assignment.operational_staff_id = target_staff_id
      and assignment.branch_id = target_branch_id
      and assignment.organization_id = staff_row.organization_id
    for update;

  if not private.actor_can_write_operational_team(actor_user_id, target_branch_id, assignment_row.operational_team_id)
  then raise exception 'staff removal denied' using errcode='42501'; end if;

  if staff_row.employment_status = 'inactive' or not assignment_row.active then
    select audit.reason_code into existing_reason
    from public.operational_staff_removal_audits audit
    where audit.assignment_id = assignment_row.id
    order by audit.created_at desc
    limit 1;
    if existing_reason is null then
      raise exception 'staff removal conflicts with current state' using errcode='40001';
    end if;
    return query select target_staff_id, assignment_row.id, 'inactive'::text, existing_reason;
    return;
  end if;

  select private.phase4a_business_date(branch.timezone) into strict current_business_date
  from public.branches branch where branch.id = target_branch_id and branch.active;
  closure := case when removal_reason = 'left_company' then 'left_company' else 'employee_removed' end;

  update public.operational_staff_assignments
  set active = false,
      valid_to = current_business_date,
      closed_at = now(),
      closed_by_user_id = actor_user_id,
      closure_reason = closure
  where operational_staff_assignments.id = assignment_row.id;

  update public.operational_staff
  set employment_status = 'inactive',
      deactivated_at = now(),
      deactivated_by = actor_user_id
  where operational_staff.id = target_staff_id;

  insert into public.operational_staff_removal_audits(
    organization_id, branch_id, operational_team_id, assignment_id, operational_staff_id,
    reason_code, reason_note, actor_user_id
  )
  select
    staff_row.organization_id, target_branch_id, assignment_row.operational_team_id, assignment_row.id,
    target_staff_id, removal_reason, clean_note, actor_user_id
  where not exists (
    select 1
    from public.operational_staff_removal_audits audit
    where audit.assignment_id = assignment_row.id
  );

  insert into public.account_management_audit_logs(organization_id, actor_user_id, branch_id, action, details)
  values(staff_row.organization_id, actor_user_id, target_branch_id, 'operational_staff_deactivated',
    pg_catalog.jsonb_build_object('team_id', assignment_row.operational_team_id,
      'operational_staff_id', target_staff_id, 'assignment_id', assignment_row.id,
      'previous_status', 'active', 'new_status', 'inactive',
      'operational_roles', assignment_row.operational_roles, 'closure_reason', closure));

  return query select target_staff_id, assignment_row.id, 'inactive'::text, removal_reason;
exception when no_data_found or too_many_rows then
  raise exception 'staff removal denied' using errcode='42501';
end $$;
