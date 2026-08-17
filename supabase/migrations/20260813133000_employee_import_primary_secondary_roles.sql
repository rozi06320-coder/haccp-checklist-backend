alter table public.operational_staff_import_preview_rows
  add column if not exists operational_roles text[];

update public.operational_staff_import_preview_rows
set operational_roles = array[operational_role]
where operational_roles is null
  and operational_role is not null;

alter table public.operational_staff_import_preview_rows
  alter column operational_roles set not null;

alter table public.operational_staff_import_preview_rows
  drop constraint if exists operational_staff_import_preview_rows_roles_check;

alter table public.operational_staff_import_preview_rows
  add constraint operational_staff_import_preview_rows_roles_check check (
    cardinality(operational_roles) between 1 and 2
    and operational_roles <@ array['kitchen','dispatcher','production','front_of_house','cleaner','cashier']::text[]
    and (cardinality(operational_roles) = 1 or operational_roles[1] <> operational_roles[2])
  );

create or replace function public.create_operational_team_staff_import_preview(
  actor_user_id uuid,
  target_branch_id uuid,
  target_operational_team_id uuid,
  import_rows jsonb
)
returns table(preview_token uuid, row_number integer, error_code text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_team public.branch_operational_teams%rowtype;
  token uuid;
begin
  select * into strict target_team
  from public.branch_operational_teams team
  where team.id = target_operational_team_id
    and team.branch_id = target_branch_id
    and team.active
  for update;

  if not private.actor_can_write_operational_team(actor_user_id, target_branch_id, target_team.id)
    or target_team.legacy_supervisor_team_id is null
    or jsonb_typeof(import_rows) is distinct from 'array'
    or jsonb_array_length(import_rows) > 250
  then
    raise exception 'staff import denied' using errcode = '42501';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(import_rows) as row(
      row_number integer,
      staff_code text,
      display_name text,
      primary_role text,
      secondary_role text,
      country_code text,
      company_name text,
      iqama_number text,
      iqama_expiry_date date,
      phone_number text,
      email text
    )
    where row.row_number is null
      or row.row_number < 2
      or length(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(row.display_name, '')), '[[:space:]]+', ' ', 'g')) not between 1 and 120
      or (private.clean_operational_staff_company_name(row.company_name) is not null and length(private.clean_operational_staff_company_name(row.company_name)) not between 1 and 160)
      or (private.clean_operational_staff_code(row.staff_code) is not null and length(private.clean_operational_staff_code(row.staff_code)) not between 1 and 80)
      or (private.clean_operational_staff_country_code(row.country_code) is not null and not private.operational_staff_country_code_is_valid(private.clean_operational_staff_country_code(row.country_code)))
      or row.primary_role not in ('kitchen','dispatcher','production','front_of_house','cleaner','cashier')
      or (row.secondary_role is not null and row.secondary_role not in ('kitchen','dispatcher','production','front_of_house','cleaner','cashier'))
      or row.secondary_role = row.primary_role
  ) then
    raise exception 'invalid staff import rows' using errcode = '22023';
  end if;

  insert into public.operational_staff_import_previews(organization_id, branch_id, operational_team_id, actor_user_id)
  values(target_team.organization_id, target_branch_id, target_team.id, actor_user_id)
  returning operational_staff_import_previews.preview_token into token;

  insert into public.operational_staff_import_preview_rows(
    preview_token, organization_id, branch_id, operational_team_id, row_number, display_name,
    company_name, staff_code, country_code, iqama_number, iqama_expiry_date, phone_number, email, operational_role, operational_roles
  )
  select token, target_team.organization_id, target_branch_id, target_team.id, row.row_number,
    pg_catalog.regexp_replace(pg_catalog.btrim(row.display_name), '[[:space:]]+', ' ', 'g'),
    private.clean_operational_staff_company_name(row.company_name),
    private.clean_operational_staff_code(row.staff_code),
    private.clean_operational_staff_country_code(row.country_code),
    private.clean_operational_staff_optional_text(row.iqama_number, 80),
    row.iqama_expiry_date,
    private.clean_operational_staff_optional_text(row.phone_number, 40),
    private.clean_operational_staff_email(row.email),
    row.primary_role,
    array_remove(array[row.primary_role, row.secondary_role], null)::text[]
  from jsonb_to_recordset(import_rows) as row(
    row_number integer,
    staff_code text,
    display_name text,
    primary_role text,
    secondary_role text,
    country_code text,
    company_name text,
    iqama_number text,
    iqama_expiry_date date,
    phone_number text,
    email text
  )
  where private.clean_operational_staff_code(row.staff_code) is null
    or not exists (
      select 1
      from public.operational_staff staff
      where staff.organization_id = target_team.organization_id
        and staff.employment_status = 'active'
        and staff.staff_code is not null
        and pg_catalog.lower(pg_catalog.btrim(staff.staff_code)) = pg_catalog.lower(pg_catalog.btrim(private.clean_operational_staff_code(row.staff_code)))
    );

  return query
  select token, duplicate.row_number, 'duplicate_employee_code'::text
  from jsonb_to_recordset(import_rows) as duplicate(row_number integer, staff_code text)
  where private.clean_operational_staff_code(duplicate.staff_code) is not null
    and exists (
      select 1
      from public.operational_staff staff
      where staff.organization_id = target_team.organization_id
        and staff.employment_status = 'active'
        and staff.staff_code is not null
        and pg_catalog.lower(pg_catalog.btrim(staff.staff_code)) = pg_catalog.lower(pg_catalog.btrim(private.clean_operational_staff_code(duplicate.staff_code)))
    );

  if not found then
    return query select token, null::integer, null::text;
  end if;
exception
  when unique_violation then raise exception 'duplicate employee code in import' using errcode = '23505';
  when no_data_found or too_many_rows then raise exception 'staff import denied' using errcode = '42501';
end $$;

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
        'assignment_id', created_assignment, 'operational_roles', row_data.operational_roles,
        'import_preview_token', import_preview_token, 'import_row_number', row_data.row_number));

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
