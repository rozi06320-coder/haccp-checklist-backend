-- Use a Supabase RPC-safe name below PostgreSQL's 63-byte identifier limit.

drop function if exists public.get_managed_operational_staff_supervisor_training_promotion_sta(uuid,uuid,uuid);

create or replace function public.get_managed_supervisor_training_promotion_state(
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

revoke all on function public.get_managed_supervisor_training_promotion_state(uuid,uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.get_managed_supervisor_training_promotion_state(uuid,uuid,uuid)
  to service_role;
