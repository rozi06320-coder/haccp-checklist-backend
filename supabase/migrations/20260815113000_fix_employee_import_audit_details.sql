create or replace function public.confirm_operational_team_staff_import(
  actor_user_id uuid,
  target_branch_id uuid,
  target_operational_team_id uuid,
  import_preview_token uuid
)
returns table(imported_count integer)
language plpgsql
security definer
set search_path = ''
as $$
declare
  preview public.operational_staff_import_previews%rowtype;
  target_team public.branch_operational_teams%rowtype;
  row_data public.operational_staff_import_preview_rows%rowtype;
  created_staff uuid;
  created_assignment uuid;
  count_imported integer := 0;
begin
  select * into strict target_team
  from public.branch_operational_teams team
  where team.id = target_operational_team_id
    and team.branch_id = target_branch_id
    and team.active
  for update;

  select * into strict preview
  from public.operational_staff_import_previews stored
  where stored.preview_token = import_preview_token
    and stored.branch_id = target_branch_id
    and stored.operational_team_id = target_operational_team_id
    and stored.actor_user_id = confirm_operational_team_staff_import.actor_user_id
    and stored.consumed_at is null
    and stored.expires_at > now()
  for update;

  if preview.organization_id <> target_team.organization_id
    or target_team.legacy_supervisor_team_id is null
    or not private.actor_can_write_operational_team(actor_user_id, target_branch_id, target_team.id)
  then
    raise exception 'staff import denied' using errcode = '42501';
  end if;

  if exists (
    select 1
    from public.operational_staff_import_preview_rows import_row
    join public.operational_staff staff
      on staff.organization_id = preview.organization_id
      and staff.employment_status = 'active'
      and staff.staff_code is not null
      and import_row.staff_code is not null
      and pg_catalog.lower(pg_catalog.btrim(staff.staff_code)) = import_row.normalized_staff_code
    where import_row.preview_token = import_preview_token
  ) then
    raise exception 'employee code already exists' using errcode = '23505';
  end if;

  for row_data in
    select * from public.operational_staff_import_preview_rows import_row
    where import_row.preview_token = import_preview_token
    order by import_row.row_number
  loop
    insert into public.operational_staff(
      organization_id, branch_id, display_name, company_name, staff_code, country_code,
      iqama_number, iqama_expiry_date, phone_number, email, created_by
    )
    values(
      preview.organization_id, preview.branch_id, row_data.display_name, row_data.company_name, row_data.staff_code,
      row_data.country_code, row_data.iqama_number, row_data.iqama_expiry_date, row_data.phone_number, row_data.email,
      actor_user_id
    )
    returning id into created_staff;

    insert into public.operational_staff_assignments(
      organization_id, branch_id, operational_staff_id, supervisor_team_id, operational_team_id,
      operational_roles, created_by_user_id
    )
    values(
      preview.organization_id, preview.branch_id, created_staff, target_team.legacy_supervisor_team_id,
      preview.operational_team_id, row_data.operational_roles, actor_user_id
    )
    returning id into created_assignment;

    insert into public.account_management_audit_logs(organization_id, actor_user_id, branch_id, action, details)
    values(preview.organization_id, actor_user_id, preview.branch_id, 'operational_staff_created',
      jsonb_build_object('team_id', preview.operational_team_id, 'operational_staff_id', created_staff,
        'assignment_id', created_assignment, 'operational_roles', row_data.operational_roles));

    count_imported := count_imported + 1;
  end loop;

  update public.operational_staff_import_previews
  set consumed_at = now()
  where preview_token = import_preview_token;

  return query select count_imported;
exception
  when unique_violation then raise exception 'employee code already exists' using errcode = '23505';
  when no_data_found or too_many_rows then raise exception 'staff import denied' using errcode = '42501';
end $$;
