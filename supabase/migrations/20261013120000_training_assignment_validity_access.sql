-- Keep Training learner eligibility aligned with branch-local assignment dates.
-- Employee validation delegates to this function, and employee-bound Training
-- sessions revalidate through employee validation on every session load.

create or replace function public.list_training_branch_employees(
  target_organization_id uuid,
  target_branch_id uuid
)
returns table(
  employee_id uuid,
  display_name text,
  employee_code text
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    staff.id,
    staff.display_name,
    staff.staff_code
  from public.operational_staff staff
  join public.organizations organization
    on organization.id = staff.organization_id
   and organization.active
  join public.branches branch
    on branch.id = staff.branch_id
   and branch.organization_id = staff.organization_id
   and branch.active
  join public.branch_training_access access
    on access.organization_id = staff.organization_id
   and access.branch_id = staff.branch_id
   and access.enabled
   and access.pin_hash is not null
  where staff.organization_id = target_organization_id
    and staff.branch_id = target_branch_id
    and staff.employment_status = 'active'
    and exists (
      select 1
      from public.operational_staff_assignments assignment
      join public.branch_operational_teams operational_team
        on operational_team.id = assignment.operational_team_id
       and operational_team.organization_id = assignment.organization_id
       and operational_team.branch_id = assignment.branch_id
       and operational_team.active
      where assignment.operational_staff_id = staff.id
        and assignment.organization_id = staff.organization_id
        and assignment.branch_id = staff.branch_id
        and assignment.active
        and assignment.valid_from <= private.phase4a_business_date(branch.timezone)
        and (
          assignment.valid_to is null
          or assignment.valid_to >= private.phase4a_business_date(branch.timezone)
        )
    )
  order by pg_catalog.lower(staff.display_name), pg_catalog.lower(coalesce(staff.staff_code, '')), staff.id
  limit 500;
$$;

revoke all on function public.list_training_branch_employees(uuid, uuid) from public, anon, authenticated;
grant execute on function public.list_training_branch_employees(uuid, uuid) to service_role;
