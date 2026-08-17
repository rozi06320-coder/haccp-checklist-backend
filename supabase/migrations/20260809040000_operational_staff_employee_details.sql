alter table public.operational_staff
  add column if not exists iqama_number text,
  add column if not exists iqama_expiry_date date,
  add column if not exists phone_number text,
  add column if not exists email text;

alter table public.operational_staff
  drop constraint if exists operational_staff_iqama_number_format,
  drop constraint if exists operational_staff_phone_number_format,
  drop constraint if exists operational_staff_email_format;

alter table public.operational_staff
  add constraint operational_staff_iqama_number_format
  check (iqama_number is null or (iqama_number = pg_catalog.btrim(iqama_number) and length(iqama_number) between 1 and 80)),
  add constraint operational_staff_phone_number_format
  check (phone_number is null or (phone_number = pg_catalog.btrim(phone_number) and length(phone_number) between 1 and 40)),
  add constraint operational_staff_email_format
  check (email is null or (email = pg_catalog.btrim(email) and length(email) between 3 and 254 and email ~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'));

create or replace function private.clean_operational_staff_optional_text(value text, max_length integer)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare cleaned text := nullif(pg_catalog.btrim(value), '');
begin
  if cleaned is not null and length(cleaned) > max_length then
    raise exception 'invalid staff text' using errcode = '22023';
  end if;
  return cleaned;
end;
$$;

create or replace function private.clean_operational_staff_email(value text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare cleaned text := nullif(pg_catalog.btrim(value), '');
begin
  if cleaned is not null and (length(cleaned) > 254 or cleaned !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') then
    raise exception 'invalid staff email' using errcode = '22023';
  end if;
  return cleaned;
end;
$$;

drop function if exists public.get_supervisor_operational_team(uuid, uuid, date);
create function public.get_supervisor_operational_team(actor_user_id uuid,target_branch_id uuid,requested_date date)
returns table(team_id uuid,company_name text,staff_id uuid,display_name text,staff_company_name text,staff_code text,
  iqama_number text,iqama_expiry_date date,phone_number text,email text,employment_status text,
  assignment_id uuid,operational_roles text[],duty_status text)
language plpgsql security definer set search_path = ''
as $$
begin
  if requested_date is null or not private.actor_owns_operational_team(actor_user_id,target_branch_id,null)
  then raise exception 'team access denied' using errcode='42501'; end if;
  return query select team.id,team.company_name,staff.id,staff.display_name,staff.company_name,staff.staff_code,
    staff.iqama_number,staff.iqama_expiry_date,staff.phone_number,staff.email,staff.employment_status,
    assignment.id,assignment.operational_roles,coalesce(duty.duty_status,'on_duty')
  from public.branch_supervisor_teams team
  left join public.operational_staff_assignments assignment
    on assignment.supervisor_team_id=team.id and assignment.active
  left join public.operational_staff staff on staff.id=assignment.operational_staff_id
  left join public.operational_staff_duty_statuses duty
    on duty.assignment_id=assignment.id and duty.duty_date=requested_date
  where team.supervisor_user_id=actor_user_id and team.branch_id=target_branch_id and team.active
  order by lower(staff.display_name),staff.id;
end $$;

create function public.create_supervisor_operational_staff(actor_user_id uuid,target_branch_id uuid,
  new_display_name text,new_operational_roles text[],new_staff_code text,new_company_name text,
  new_iqama_number text,new_iqama_expiry_date date,new_phone_number text,new_email text)
returns table(staff_id uuid,assignment_id uuid,duplicate_name_warning boolean,iqama_number text,iqama_expiry_date date,phone_number text,email text)
language plpgsql security definer set search_path = ''
as $$
declare target_team public.branch_supervisor_teams%rowtype; created_staff uuid; created_assignment uuid;
 clean_name text := pg_catalog.regexp_replace(pg_catalog.btrim(new_display_name),'[[:space:]]+',' ','g');
 clean_code text := private.clean_operational_staff_code(new_staff_code);
 clean_company_name text := private.clean_operational_staff_company_name(new_company_name);
 clean_iqama_number text := private.clean_operational_staff_optional_text(new_iqama_number,80);
 clean_phone_number text := private.clean_operational_staff_optional_text(new_phone_number,40);
 clean_email text := private.clean_operational_staff_email(new_email);
begin
 select team.* into strict target_team from public.branch_supervisor_teams team
  where team.supervisor_user_id=actor_user_id and team.branch_id=target_branch_id and team.active;
 if not private.actor_owns_operational_team(actor_user_id,target_branch_id,target_team.id)
  or length(clean_name) not between 1 and 120
  or length(coalesce(clean_company_name,'')) not between 1 and 160
  or (clean_code is not null and length(clean_code) not between 1 and 80)
  or not private.operational_roles_are_valid(new_operational_roles)
 then raise exception 'staff operation denied' using errcode='42501'; end if;
 insert into public.operational_staff(organization_id,branch_id,display_name,company_name,staff_code,iqama_number,iqama_expiry_date,phone_number,email,created_by)
  values(target_team.organization_id,target_branch_id,clean_name,clean_company_name,clean_code,clean_iqama_number,new_iqama_expiry_date,clean_phone_number,clean_email,actor_user_id)
  returning id into created_staff;
 insert into public.operational_staff_assignments(
  organization_id,branch_id,operational_staff_id,supervisor_team_id,operational_roles
 ) values (
  target_team.organization_id,target_branch_id,created_staff,target_team.id,new_operational_roles
 ) returning id into created_assignment;
 insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
 values(target_team.organization_id,actor_user_id,target_branch_id,'operational_staff_created',
  jsonb_build_object('operational_staff_id',created_staff,'assignment_id',created_assignment,
    'operational_roles',new_operational_roles));
 return query select created_staff,created_assignment,exists(
  select 1 from public.operational_staff staff where staff.organization_id=target_team.organization_id
   and staff.branch_id=target_branch_id and staff.id<>created_staff and staff.employment_status='active'
   and staff.normalized_name=private.normalize_operational_staff_name(clean_name)),
   clean_iqama_number,new_iqama_expiry_date,clean_phone_number,clean_email;
exception when no_data_found or too_many_rows then
 raise exception 'staff operation denied' using errcode='42501';
end $$;

create function public.update_supervisor_operational_staff(actor_user_id uuid,target_branch_id uuid,
 target_staff_id uuid,new_display_name text,new_employment_status text,new_operational_roles text[],new_staff_code text,new_company_name text,
 new_iqama_number text,new_iqama_expiry_date date,new_phone_number text,new_email text)
returns table(staff_id uuid,assignment_id uuid,duplicate_name_warning boolean,iqama_number text,iqama_expiry_date date,phone_number text,email text)
language plpgsql security definer set search_path = ''
as $$
declare staff_row public.operational_staff%rowtype; assignment_row public.operational_staff_assignments%rowtype;
 clean_name text := pg_catalog.regexp_replace(pg_catalog.btrim(new_display_name),'[[:space:]]+',' ','g');
 clean_code text := private.clean_operational_staff_code(new_staff_code);
 clean_company_name text := private.clean_operational_staff_company_name(new_company_name);
 clean_iqama_number text := private.clean_operational_staff_optional_text(new_iqama_number,80);
 clean_phone_number text := private.clean_operational_staff_optional_text(new_phone_number,40);
 clean_email text := private.clean_operational_staff_email(new_email);
begin
 select staff.* into strict staff_row from public.operational_staff staff
  where staff.id=target_staff_id and staff.branch_id=target_branch_id;
 select assignment.* into strict assignment_row from public.operational_staff_assignments assignment
  where assignment.operational_staff_id=target_staff_id and assignment.active;
 if not private.actor_owns_operational_team(actor_user_id,target_branch_id,assignment_row.supervisor_team_id)
  or new_employment_status not in ('active','inactive') or length(clean_name) not between 1 and 120
  or length(coalesce(clean_company_name,'')) not between 1 and 160
  or (clean_code is not null and length(clean_code) not between 1 and 80)
  or not private.operational_roles_are_valid(new_operational_roles)
 then raise exception 'staff operation denied' using errcode='42501'; end if;
 update public.operational_staff set display_name=clean_name,company_name=clean_company_name,staff_code=clean_code,
  iqama_number=clean_iqama_number,iqama_expiry_date=new_iqama_expiry_date,phone_number=clean_phone_number,email=clean_email,
  employment_status=new_employment_status,
  deactivated_at=case when new_employment_status='inactive' then coalesce(deactivated_at,now()) else null end,
  deactivated_by=case when new_employment_status='inactive' then coalesce(deactivated_by,actor_user_id) else null end
  where id=target_staff_id;
 update public.operational_staff_assignments set operational_roles=new_operational_roles,
  active=(new_employment_status='active'),
  valid_to=case when new_employment_status='inactive' then current_date else null end
  where id=assignment_row.id returning * into assignment_row;
 insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
 values(staff_row.organization_id,actor_user_id,target_branch_id,
  case when new_employment_status='inactive' then 'operational_staff_deactivated' else 'operational_staff_updated' end,
  jsonb_build_object('operational_staff_id',target_staff_id,'assignment_id',assignment_row.id,
   'previous_status',staff_row.employment_status,'new_status',new_employment_status,
   'operational_roles',new_operational_roles));
 return query select target_staff_id,assignment_row.id,exists(
  select 1 from public.operational_staff staff where staff.organization_id=staff_row.organization_id
   and staff.branch_id=target_branch_id and staff.id<>target_staff_id and staff.employment_status='active'
   and staff.normalized_name=private.normalize_operational_staff_name(clean_name)),
   clean_iqama_number,new_iqama_expiry_date,clean_phone_number,clean_email;
exception when no_data_found or too_many_rows then
 raise exception 'staff operation denied' using errcode='42501';
end $$;

revoke all on function public.get_supervisor_operational_team(uuid,uuid,date),
 public.create_supervisor_operational_staff(uuid,uuid,text,text[],text,text,text,date,text,text),
 public.update_supervisor_operational_staff(uuid,uuid,uuid,text,text,text[],text,text,text,date,text,text)
 from public,anon,authenticated;
grant execute on function public.get_supervisor_operational_team(uuid,uuid,date),
 public.create_supervisor_operational_staff(uuid,uuid,text,text[],text,text,text,date,text,text),
 public.update_supervisor_operational_staff(uuid,uuid,uuid,text,text,text[],text,text,text,date,text,text)
 to service_role;
