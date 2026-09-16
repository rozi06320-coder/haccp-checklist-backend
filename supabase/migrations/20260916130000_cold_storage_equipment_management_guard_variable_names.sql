-- Fix ambiguous PL/pgSQL variable names in the Cold Storage equipment
-- management trigger guard. Keep the current management lock behavior intact.

create or replace function private.cold_storage_equipment_management_guard()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_business_date date;
  v_current_slot text;
  v_submission_id uuid;
  v_organization_id uuid;
  v_branch_id uuid;
begin
  v_organization_id := coalesce(new.organization_id, old.organization_id);
  v_branch_id := coalesce(new.branch_id, old.branch_id);

  select private.phase4a_business_date(branch.timezone),
         private.cold_storage_current_eligible_slot(branch.id)
  into strict v_business_date, v_current_slot
  from public.branches branch
  where branch.id = v_branch_id
    and branch.organization_id = v_organization_id
    and branch.active;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_organization_id::text || ':' || v_branch_id::text || ':' ||
      v_business_date::text || ':cold_storage', 0
    )
  );

  select submission.id
  into v_submission_id
  from public.cold_storage_submissions submission
  where submission.organization_id = v_organization_id
    and submission.branch_id = v_branch_id
    and submission.business_date = v_business_date
  for update;

  if v_current_slot is not null and exists (
    select 1
    from public.cold_storage_readings reading
    where reading.submission_id = v_submission_id
      and reading.slot = v_current_slot
      and reading.submitted_at is not null
  ) then
    raise exception 'cold storage equipment management locked' using errcode = '55000';
  end if;

  if (
    tg_op = 'DELETE'
    or (tg_op = 'UPDATE' and not coalesce(new.active, false))
  )
  and v_current_slot is not null
  and exists (
    select 1
    from public.cold_storage_equipment snapshot
    join public.cold_storage_readings reading
      on reading.submission_id = snapshot.submission_id
     and reading.equipment_id = snapshot.equipment_id
    where snapshot.submission_id = v_submission_id
      and snapshot.master_equipment_id = old.id
      and reading.slot = v_current_slot
      and reading.submitted_at is null
      and (
        reading.temperature_c is not null
        or pg_catalog.length(pg_catalog.btrim(coalesce(reading.corrective_action, ''))) > 0
      )
  ) then
    raise exception 'cold storage equipment has current draft' using errcode = '55000';
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;
