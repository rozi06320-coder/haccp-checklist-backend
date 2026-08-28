-- Supervisor Employee Team soft removal with durable reason audit.
-- This intentionally preserves operational_staff and all historical references.

alter table public.operational_staff_assignments
  drop constraint if exists operational_staff_assignments_closure_reason_check;

alter table public.operational_staff_assignments
  add constraint operational_staff_assignments_closure_reason_check
  check(closure_reason is null or closure_reason in('team_move','branch_transfer','left_company','employee_removed'));

create table if not exists public.operational_staff_removal_audits (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  operational_team_id uuid not null,
  assignment_id uuid not null references public.operational_staff_assignments(id) on delete restrict,
  operational_staff_id uuid not null,
  reason_code text not null,
  reason_note text,
  actor_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint operational_staff_removal_audits_branch_fkey
    foreign key(branch_id, organization_id) references public.branches(id, organization_id) on delete restrict,
  constraint operational_staff_removal_audits_staff_fkey
    foreign key(operational_staff_id, organization_id) references public.operational_staff(id, organization_id) on delete restrict,
  constraint operational_staff_removal_audits_reason_code_check
    check(reason_code in('duplicate','added_by_mistake','wrong_employee_data','left_company','other')),
  constraint operational_staff_removal_audits_reason_note_check
    check(reason_note is null or (reason_note = pg_catalog.btrim(reason_note) and length(reason_note) between 1 and 1000)),
  constraint operational_staff_removal_audits_other_note_check
    check(reason_code <> 'other' or reason_note is not null)
);

create unique index if not exists operational_staff_removal_audits_assignment_key
  on public.operational_staff_removal_audits(assignment_id);
create index if not exists operational_staff_removal_audits_org_created_idx
  on public.operational_staff_removal_audits(organization_id, created_at desc);
create index if not exists operational_staff_removal_audits_staff_idx
  on public.operational_staff_removal_audits(operational_staff_id, created_at desc);

alter table public.operational_staff_removal_audits enable row level security;
revoke all on public.operational_staff_removal_audits from public, anon, authenticated;

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
  ) values (
    staff_row.organization_id, target_branch_id, assignment_row.operational_team_id, assignment_row.id,
    target_staff_id, removal_reason, clean_note, actor_user_id
  ) on conflict (assignment_id) do nothing;

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

revoke all on function public.remove_operational_team_staff(uuid,uuid,uuid,uuid,text,text) from public, anon, authenticated;
grant execute on function public.remove_operational_team_staff(uuid,uuid,uuid,uuid,text,text) to service_role;

comment on table public.operational_staff_removal_audits is
  'Durable audit trail for Supervisor Employee Team soft removals. Staff rows and historical references are preserved.';
comment on function public.remove_operational_team_staff(uuid,uuid,uuid,uuid,text,text) is
  'Soft-removes active Operational Staff from a Supervisor Employee Team, records the removal reason, and preserves history.';
