-- Allow 'promoted_to_supervisor' as canonical closure reason on operational staff assignments.

alter table public.operational_staff_assignments
  drop constraint if exists operational_staff_assignments_closure_reason_check;

alter table public.operational_staff_assignments
  add constraint operational_staff_assignments_closure_reason_check
  check (
    closure_reason is null
    or closure_reason = any (
      array[
        'team_move'::text,
        'branch_transfer'::text,
        'left_company'::text,
        'employee_removed'::text,
        'promoted_to_supervisor'::text
      ]
    )
  );

notify pgrst, 'reload schema';
