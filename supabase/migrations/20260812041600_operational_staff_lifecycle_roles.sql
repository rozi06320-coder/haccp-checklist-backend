-- Operational Staff role, vacation, leave-company, and cross-branch transfer hardening.
-- Historical checklist snapshots are intentionally not rewritten.

do $$
begin
  if exists (
    select 1
    from public.operational_staff_assignments assignment,
      pg_catalog.unnest(assignment.operational_roles) role
    where role not in ('kitchen','packaging','front_of_house','cleaner')
  ) then
    raise exception 'operational staff role migration blocked: unsupported assignment role exists'
      using errcode='23514';
  end if;

  if exists (
    select 1 from public.operational_staff staff
    where staff.employment_status='active'
      and (select pg_catalog.count(*) from public.operational_staff_assignments assignment
        where assignment.operational_staff_id=staff.id and assignment.active)<>1
  ) then
    raise exception 'operational staff lifecycle migration blocked: active assignment is ambiguous'
      using errcode='23514';
  end if;
end $$;

-- Temporarily accept the legacy role while current assignment rows are renamed.
create or replace function private.operational_roles_are_valid(candidate text[])
returns boolean language sql immutable security invoker set search_path = ''
as $$
  select candidate is not null
    and pg_catalog.cardinality(candidate) between 1 and 2
    and not candidate @> array[null]::text[]
    and (select pg_catalog.count(*)=pg_catalog.count(distinct value)
      from pg_catalog.unnest(candidate) value)
    and candidate <@ array['kitchen','packaging','dispatcher','production','front_of_house','cleaner']::text[]
$$;

update public.operational_staff_assignments assignment
set operational_roles=array(
  select case role when 'packaging' then 'dispatcher' else role end
  from pg_catalog.unnest(assignment.operational_roles) role
)
where assignment.operational_roles @> array['packaging']::text[];

-- This is the canonical role contract for all current staff assignment writes.
create or replace function private.operational_roles_are_valid(candidate text[])
returns boolean language sql immutable security invoker set search_path = ''
as $$
  select candidate is not null
    and pg_catalog.cardinality(candidate) between 1 and 2
    and not candidate @> array[null]::text[]
    and (select pg_catalog.count(*)=pg_catalog.count(distinct value)
      from pg_catalog.unnest(candidate) value)
    and candidate <@ array['kitchen','dispatcher','production','front_of_house','cleaner']::text[]
$$;

alter table public.operational_staff_duty_statuses
  drop constraint operational_staff_duty_status_check;
alter table public.operational_staff_duty_statuses
  add constraint operational_staff_duty_status_check
  check(duty_status in('on_duty','day_off','on_vacation'));

alter table public.operational_staff_assignments
  add column created_by_user_id uuid references auth.users(id) on delete restrict,
  add column closed_at timestamptz,
  add column closed_by_user_id uuid references auth.users(id) on delete restrict,
  add column closure_reason text,
  add constraint operational_staff_assignments_closure_reason_check
    check(closure_reason is null or closure_reason in('team_move','branch_transfer','left_company')),
  add constraint operational_staff_assignments_closure_metadata_check
    check((active and closed_at is null and closed_by_user_id is null and closure_reason is null)
      or not active);

alter table public.operational_staff
  add constraint operational_staff_id_organization_key unique(id,organization_id);
alter table public.operational_staff_assignments
  drop constraint operational_staff_assignments_staff_scope_fkey;
alter table public.operational_staff_assignments
  add constraint operational_staff_assignments_staff_organization_fkey
  foreign key(operational_staff_id,organization_id)
  references public.operational_staff(id,organization_id) on delete restrict;

create or replace function private.validate_operational_assignment()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not private.operational_roles_are_valid(new.operational_roles) or not exists (
    select 1
    from public.operational_staff staff
    join public.branch_operational_teams operational_team on operational_team.id=new.operational_team_id
    join public.branch_supervisor_teams legacy_team on legacy_team.id=new.supervisor_team_id
    join public.branches branch on branch.id=new.branch_id
    join public.organizations organization on organization.id=new.organization_id
    where staff.id=new.operational_staff_id and staff.organization_id=new.organization_id
      and operational_team.branch_id=new.branch_id and operational_team.organization_id=new.organization_id
      and operational_team.legacy_supervisor_team_id=legacy_team.id
      and legacy_team.branch_id=new.branch_id and legacy_team.organization_id=new.organization_id
      and (not new.active or (staff.branch_id=new.branch_id and staff.employment_status='active'
        and operational_team.active and branch.active and organization.active))
  ) then
    raise exception 'invalid operational assignment scope' using errcode='23514';
  end if;
  return new;
end $$;

create or replace function public.create_operational_team_staff(actor_user_id uuid,target_branch_id uuid,target_operational_team_id uuid,
  new_display_name text,new_operational_roles text[],new_staff_code text,new_company_name text,
  new_iqama_number text,new_iqama_expiry_date date,new_phone_number text,new_email text)
returns table(staff_id uuid,assignment_id uuid,duplicate_name_warning boolean,iqama_number text,iqama_expiry_date date,phone_number text,email text)
language plpgsql security definer set search_path = '' as $$
declare target_team public.branch_operational_teams%rowtype; created_staff uuid; created_assignment uuid;
 clean_name text:=pg_catalog.regexp_replace(pg_catalog.btrim(new_display_name),'[[:space:]]+',' ','g');
 clean_code text:=private.clean_operational_staff_code(new_staff_code);
 clean_company text:=private.clean_operational_staff_company_name(new_company_name);
 clean_iqama text:=private.clean_operational_staff_optional_text(new_iqama_number,80);
 clean_phone text:=private.clean_operational_staff_optional_text(new_phone_number,40);
 clean_email text:=private.clean_operational_staff_email(new_email);
begin
  select * into strict target_team from public.branch_operational_teams
  where id=target_operational_team_id and branch_id=target_branch_id and active for update;
  if not private.actor_can_write_operational_team(actor_user_id,target_branch_id,target_team.id)
    or target_team.legacy_supervisor_team_id is null or length(clean_name) not between 1 and 120
    or length(coalesce(clean_company,'')) not between 1 and 160
    or (clean_code is not null and length(clean_code) not between 1 and 80)
    or not private.operational_roles_are_valid(new_operational_roles)
  then raise exception 'staff operation denied' using errcode='42501'; end if;
  insert into public.operational_staff(organization_id,branch_id,display_name,company_name,staff_code,iqama_number,iqama_expiry_date,phone_number,email,created_by)
  values(target_team.organization_id,target_branch_id,clean_name,clean_company,clean_code,clean_iqama,new_iqama_expiry_date,clean_phone,clean_email,actor_user_id)
  returning id into created_staff;
  insert into public.operational_staff_assignments(organization_id,branch_id,operational_staff_id,supervisor_team_id,
    operational_team_id,operational_roles,created_by_user_id)
  values(target_team.organization_id,target_branch_id,created_staff,target_team.legacy_supervisor_team_id,
    target_team.id,new_operational_roles,actor_user_id)
  returning id into created_assignment;
  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
  values(target_team.organization_id,actor_user_id,target_branch_id,'operational_staff_created',
    pg_catalog.jsonb_build_object('team_id',target_team.id,'operational_staff_id',created_staff,
      'assignment_id',created_assignment,'operational_roles',new_operational_roles));
  return query select created_staff,created_assignment,false,clean_iqama,new_iqama_expiry_date,clean_phone,clean_email;
exception when unique_violation then raise exception 'staff identity already exists' using errcode='23505';
when no_data_found or too_many_rows then raise exception 'staff operation denied' using errcode='42501';
end $$;

create or replace function public.update_operational_team_staff(actor_user_id uuid,target_branch_id uuid,target_staff_id uuid,
  new_display_name text,new_employment_status text,new_operational_roles text[],new_staff_code text,new_company_name text,
  new_iqama_number text,new_iqama_expiry_date date,new_phone_number text,new_email text)
returns table(staff_id uuid,assignment_id uuid,duplicate_name_warning boolean,iqama_number text,iqama_expiry_date date,phone_number text,email text)
language plpgsql security definer set search_path = '' as $$
declare assignment_row public.operational_staff_assignments%rowtype;
 clean_name text:=pg_catalog.regexp_replace(pg_catalog.btrim(new_display_name),'[[:space:]]+',' ','g');
 clean_code text:=private.clean_operational_staff_code(new_staff_code);
 clean_company text:=private.clean_operational_staff_company_name(new_company_name);
 clean_iqama text:=private.clean_operational_staff_optional_text(new_iqama_number,80);
 clean_phone text:=private.clean_operational_staff_optional_text(new_phone_number,40);
 clean_email text:=private.clean_operational_staff_email(new_email);
begin
  select assignment.* into strict assignment_row
  from public.operational_staff_assignments assignment
  join public.operational_staff staff on staff.id=assignment.operational_staff_id
  where assignment.operational_staff_id=target_staff_id and assignment.active and staff.branch_id=target_branch_id
  for update of assignment,staff;
  if not private.actor_can_write_operational_team(actor_user_id,target_branch_id,assignment_row.operational_team_id)
    or new_employment_status<>'active' or length(clean_name) not between 1 and 120
    or length(coalesce(clean_company,'')) not between 1 and 160
    or (clean_code is not null and length(clean_code) not between 1 and 80)
    or not private.operational_roles_are_valid(new_operational_roles)
  then raise exception 'staff operation denied' using errcode='42501'; end if;
  update public.operational_staff set display_name=clean_name,company_name=clean_company,staff_code=clean_code,
    iqama_number=clean_iqama,iqama_expiry_date=new_iqama_expiry_date,phone_number=clean_phone,email=clean_email
  where id=target_staff_id;
  update public.operational_staff_assignments set operational_roles=new_operational_roles
  where id=assignment_row.id returning * into assignment_row;
  return query select target_staff_id,assignment_row.id,false,clean_iqama,new_iqama_expiry_date,clean_phone,clean_email;
exception when unique_violation then raise exception 'staff identity already exists' using errcode='23505';
when no_data_found or too_many_rows then raise exception 'staff operation denied' using errcode='42501';
end $$;

create or replace function public.set_operational_team_staff_duty(actor_user_id uuid,target_branch_id uuid,target_staff_id uuid,
  requested_date date,new_duty_status text)
returns table(staff_id uuid,assignment_id uuid,duty_date date,duty_status text,eligible boolean)
language plpgsql security definer set search_path = '' as $$
declare staff_row public.operational_staff%rowtype; assignment_row public.operational_staff_assignments%rowtype;
begin
  select * into strict staff_row from public.operational_staff where id=target_staff_id and branch_id=target_branch_id;
  select * into strict assignment_row from public.operational_staff_assignments
    where operational_staff_id=target_staff_id and active for update;
  if requested_date is null or new_duty_status not in('on_duty','day_off','on_vacation')
    or staff_row.employment_status<>'active'
    or not private.actor_can_write_operational_team(actor_user_id,target_branch_id,assignment_row.operational_team_id)
  then raise exception 'duty operation denied' using errcode='42501'; end if;
  insert into public.operational_staff_duty_statuses(organization_id,branch_id,operational_staff_id,assignment_id,duty_date,duty_status,set_by)
  values(staff_row.organization_id,target_branch_id,target_staff_id,assignment_row.id,requested_date,new_duty_status,actor_user_id)
  on conflict on constraint operational_staff_duty_unique do update
    set duty_status=excluded.duty_status,set_by=excluded.set_by;
  return query select target_staff_id,assignment_row.id,requested_date,new_duty_status,new_duty_status='on_duty';
exception when no_data_found or too_many_rows then raise exception 'duty operation denied' using errcode='42501';
end $$;

create or replace function public.move_operational_staff_team(actor_user_id uuid,target_branch_id uuid,target_staff_id uuid,
  expected_assignment_id uuid,target_operational_team_id uuid)
returns table(staff_id uuid,assignment_id uuid,operational_team_id uuid)
language plpgsql security definer set search_path = '' as $$
declare staff_row public.operational_staff%rowtype; old_assignment public.operational_staff_assignments%rowtype;
 target_team public.branch_operational_teams%rowtype; created_assignment uuid; current_business_date date; prior_duty text;
begin
  select * into strict staff_row from public.operational_staff
    where id=target_staff_id and branch_id=target_branch_id for update;
  select * into strict old_assignment from public.operational_staff_assignments
    where operational_staff_id=target_staff_id and active for update;
  if old_assignment.id<>expected_assignment_id then
    raise exception 'staff assignment changed' using errcode='40001';
  end if;
  select * into strict target_team from public.branch_operational_teams
    where id=target_operational_team_id and branch_id=target_branch_id
      and organization_id=staff_row.organization_id and active for update;
  if not private.actor_can_write_operational_team(actor_user_id,target_branch_id,old_assignment.operational_team_id)
    or not private.actor_can_write_operational_team(actor_user_id,target_branch_id,target_team.id)
    or target_team.legacy_supervisor_team_id is null or staff_row.employment_status<>'active'
  then raise exception 'staff move denied' using errcode='42501'; end if;
  if old_assignment.operational_team_id=target_team.id
  then raise exception 'staff already belongs to team' using errcode='23505'; end if;
  select private.phase4a_business_date(branch.timezone) into strict current_business_date
  from public.branches branch where branch.id=target_branch_id and branch.active;
  if exists(
    select 1 from public.hygiene_staff_snapshots snapshot
    join public.checklist_submissions submission on submission.id=snapshot.submission_id
    where snapshot.operational_staff_id=target_staff_id and submission.branch_id=target_branch_id
      and submission.business_date=current_business_date and submission.checklist_type='staff_hygiene'
      and submission.state='submitted'
  ) then raise exception 'staff move blocked by submitted hygiene' using errcode='23514'; end if;
  select duty.duty_status into prior_duty from public.operational_staff_duty_statuses duty
    where duty.assignment_id=old_assignment.id and duty.duty_date=current_business_date;
  update public.operational_staff_assignments
  set active=false,valid_to=current_business_date,closed_at=now(),closed_by_user_id=actor_user_id,
    closure_reason='team_move'
  where id=old_assignment.id;
  insert into public.operational_staff_assignments(organization_id,branch_id,operational_staff_id,supervisor_team_id,
    operational_team_id,operational_roles,valid_from,created_by_user_id)
  values(staff_row.organization_id,target_branch_id,target_staff_id,target_team.legacy_supervisor_team_id,
    target_team.id,old_assignment.operational_roles,current_business_date,actor_user_id)
  returning id into created_assignment;
  if prior_duty is not null then
    insert into public.operational_staff_duty_statuses(organization_id,branch_id,operational_staff_id,assignment_id,duty_date,duty_status,set_by)
    values(staff_row.organization_id,target_branch_id,target_staff_id,created_assignment,current_business_date,prior_duty,actor_user_id);
  end if;
  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
  values(staff_row.organization_id,actor_user_id,target_branch_id,'operational_staff_assignment_updated',
    pg_catalog.jsonb_build_object('team_id',target_team.id,'operational_staff_id',target_staff_id,
      'assignment_id',created_assignment,'previous_status','active','new_status','active',
      'operational_roles',old_assignment.operational_roles));
  return query select target_staff_id,created_assignment,target_team.id;
exception when no_data_found or too_many_rows then raise exception 'staff move denied' using errcode='42501';
end $$;

create function public.leave_operational_staff_company(actor_user_id uuid,target_branch_id uuid,target_staff_id uuid,
  expected_assignment_id uuid)
returns table(staff_id uuid,assignment_id uuid,employment_status text)
language plpgsql security definer set search_path = '' as $$
declare staff_row public.operational_staff%rowtype; assignment_row public.operational_staff_assignments%rowtype;
 current_business_date date;
begin
  select * into strict staff_row from public.operational_staff
    where id=target_staff_id and branch_id=target_branch_id for update;
  select * into strict assignment_row from public.operational_staff_assignments
    where operational_staff_id=target_staff_id and active for update;
  if assignment_row.id<>expected_assignment_id then
    raise exception 'staff assignment changed' using errcode='40001';
  end if;
  if staff_row.employment_status<>'active'
    or not private.actor_can_write_operational_team(actor_user_id,target_branch_id,assignment_row.operational_team_id)
  then raise exception 'staff leave denied' using errcode='42501'; end if;
  select private.phase4a_business_date(branch.timezone) into strict current_business_date
  from public.branches branch where branch.id=target_branch_id and branch.active;
  update public.operational_staff_assignments
  set active=false,valid_to=current_business_date,closed_at=now(),closed_by_user_id=actor_user_id,
    closure_reason='left_company'
  where id=assignment_row.id;
  update public.operational_staff
  set employment_status='inactive',deactivated_at=now(),deactivated_by=actor_user_id
  where id=target_staff_id;
  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
  values(staff_row.organization_id,actor_user_id,target_branch_id,'operational_staff_deactivated',
    pg_catalog.jsonb_build_object('team_id',assignment_row.operational_team_id,
      'operational_staff_id',target_staff_id,'assignment_id',assignment_row.id,
      'previous_status','active','new_status','inactive','operational_roles',assignment_row.operational_roles));
  return query select target_staff_id,assignment_row.id,'inactive'::text;
exception when no_data_found or too_many_rows then raise exception 'staff leave denied' using errcode='42501';
end $$;

create function public.transfer_operational_staff_branch(actor_user_id uuid,target_organization_id uuid,
  target_staff_id uuid,expected_assignment_id uuid,target_operational_team_id uuid)
returns table(staff_id uuid,assignment_id uuid,branch_id uuid,operational_team_id uuid)
language plpgsql security definer set search_path = '' as $$
declare staff_row public.operational_staff%rowtype; old_assignment public.operational_staff_assignments%rowtype;
 target_team public.branch_operational_teams%rowtype; created_assignment uuid; source_business_date date;
begin
  select * into strict staff_row from public.operational_staff
    where id=target_staff_id and organization_id=target_organization_id for update;
  select * into strict old_assignment from public.operational_staff_assignments
    where operational_staff_id=target_staff_id and active for update;
  if old_assignment.id<>expected_assignment_id then
    raise exception 'staff assignment changed' using errcode='40001';
  end if;
  select * into strict target_team from public.branch_operational_teams
    where id=target_operational_team_id and organization_id=target_organization_id and active for update;
  if not private.actor_manages_active_organization(actor_user_id,target_organization_id)
    or staff_row.employment_status<>'active' or target_team.branch_id=staff_row.branch_id
    or target_team.legacy_supervisor_team_id is null
  then raise exception 'staff transfer denied' using errcode='42501'; end if;
  if exists(select 1 from public.operational_staff other
    where other.organization_id=target_organization_id and other.branch_id=target_team.branch_id
      and other.id<>staff_row.id and other.employment_status='active'
      and (other.normalized_name=staff_row.normalized_name
        or (staff_row.staff_code is not null and pg_catalog.lower(other.staff_code)=pg_catalog.lower(staff_row.staff_code))))
  then raise exception 'staff identity already exists' using errcode='23505'; end if;
  select private.phase4a_business_date(branch.timezone) into strict source_business_date
  from public.branches branch where branch.id=staff_row.branch_id and branch.active;
  if exists(
    select 1 from public.hygiene_staff_snapshots snapshot
    join public.checklist_submissions submission on submission.id=snapshot.submission_id
    where snapshot.operational_staff_id=target_staff_id and submission.branch_id=staff_row.branch_id
      and submission.business_date=source_business_date and submission.checklist_type='staff_hygiene'
      and submission.state='submitted'
  ) then raise exception 'staff transfer blocked by submitted hygiene' using errcode='23514'; end if;
  update public.operational_staff_assignments
  set active=false,valid_to=source_business_date,closed_at=now(),closed_by_user_id=actor_user_id,
    closure_reason='branch_transfer'
  where id=old_assignment.id;
  update public.operational_staff set branch_id=target_team.branch_id where id=target_staff_id;
  insert into public.operational_staff_assignments(organization_id,branch_id,operational_staff_id,supervisor_team_id,
    operational_team_id,operational_roles,valid_from,created_by_user_id)
  values(target_organization_id,target_team.branch_id,target_staff_id,target_team.legacy_supervisor_team_id,
    target_team.id,old_assignment.operational_roles,
    (select private.phase4a_business_date(branch.timezone) from public.branches branch where branch.id=target_team.branch_id),
    actor_user_id)
  returning id into created_assignment;
  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
  values(target_organization_id,actor_user_id,target_team.branch_id,'operational_staff_assignment_updated',
    pg_catalog.jsonb_build_object('team_id',target_team.id,'operational_staff_id',target_staff_id,
      'assignment_id',created_assignment,'previous_status','active','new_status','active',
      'operational_roles',old_assignment.operational_roles));
  return query select target_staff_id,created_assignment,target_team.branch_id,target_team.id;
exception when no_data_found or too_many_rows then raise exception 'staff transfer denied' using errcode='42501';
end $$;

create or replace function public.list_managed_employee_team(
  actor_user_id uuid,target_organization_id uuid,branch_filter uuid default null,requested_month date default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare result jsonb;
begin
  if requested_month is null or requested_month<>pg_catalog.date_trunc('month',requested_month)::date
    or not private.actor_manages_active_organization(actor_user_id,target_organization_id)
    or (branch_filter is not null and not exists(select 1 from public.branches
      where id=branch_filter and organization_id=target_organization_id))
  then raise exception 'employee team access denied' using errcode='42501'; end if;
  select pg_catalog.jsonb_build_object(
    'employees',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'staff_id',staff.id,'display_name',staff.display_name,'staff_code',staff.staff_code,
      'employment_status',staff.employment_status,'company_name',staff.company_name,
      'iqama_number',staff.iqama_number,'phone_number',staff.phone_number,'email',staff.email,
      'branch_id',branch.id,'branch_name',branch.name,'branch_name_ar',branch.name_ar,
      'supervisor_name',profile.full_name,'supervisor_name_ar',profile.full_name_ar,
      'assignment_id',assignment.id,'operational_team_id',operational_team.id,
      'operational_team_name',operational_team.name,'operational_roles',assignment.operational_roles,
      'duty_status',case when staff.employment_status='active' and assignment.id is not null
        then coalesce(duty.duty_status,'on_duty') else null end
    ) order by staff.normalized_name,staff.id)
    from public.operational_staff staff
    join public.branches branch on branch.id=staff.branch_id
    left join public.operational_staff_assignments assignment
      on assignment.operational_staff_id=staff.id and assignment.active
    left join public.branch_operational_teams operational_team on operational_team.id=assignment.operational_team_id
    left join public.branch_supervisor_teams team on team.id=assignment.supervisor_team_id
    left join public.profiles profile on profile.id=team.supervisor_user_id
    left join public.operational_staff_duty_statuses duty on duty.assignment_id=assignment.id
      and duty.duty_date=private.phase4a_business_date(branch.timezone)
    where staff.organization_id=target_organization_id
      and (branch_filter is null or staff.branch_id=branch_filter)),'[]'::jsonb),
    'operational_teams',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',team.id,'branch_id',branch.id,'branch_name',branch.name,'branch_name_ar',branch.name_ar,
      'name',team.name,'active',team.active
    ) order by pg_catalog.lower(branch.name),team.normalized_name,team.id)
    from public.branch_operational_teams team join public.branches branch on branch.id=team.branch_id
    where team.organization_id=target_organization_id and team.active),'[]'::jsonb),
    'health_cards',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',card.id,'operational_staff_id',staff.id,'display_name',staff.display_name,
      'branch_id',branch.id,'branch_name',branch.name,'branch_name_ar',branch.name_ar,
      'certificate_number',card.certificate_number,'status',card.status,'place_of_issue',card.place_of_issue,
      'expiry_date',card.expiry_date,'date_issue',card.date_issue,'occupation',card.occupation,
      'company',card.company,'branch_name_snapshot',card.branch_name_snapshot,'notes',card.notes,'updated_at',card.updated_at
    ) order by pg_catalog.lower(staff.display_name),staff.id)
    from public.operational_staff_health_cards card
    join public.operational_staff staff on staff.id=card.operational_staff_id and staff.organization_id=target_organization_id
    join public.branches branch on branch.id=staff.branch_id
    where branch_filter is null or staff.branch_id=branch_filter),'[]'::jsonb),
    'monthly_evaluations',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',evaluation.id,'operational_staff_id',staff.id,'display_name',staff.display_name,
      'branch_id',branch.id,'branch_name',branch.name,'branch_name_ar',branch.name_ar,
      'evaluation_month',evaluation.evaluation_month,'evaluator_name',evaluation.evaluator_name,
      'status',evaluation.status,'average_score',evaluation.average_score,
      'scores',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'section',score.section,'factor_key',score.factor_key,'factor_label',score.factor_label,
        'rating',score.rating,'comment',score.comment) order by score.section,score.factor_key)
        from public.operational_staff_monthly_evaluation_scores score
        where score.evaluation_id=evaluation.id),'[]'::jsonb),'updated_at',evaluation.updated_at
    ) order by pg_catalog.lower(staff.display_name),staff.id)
    from public.operational_staff_monthly_evaluations evaluation
    join public.operational_staff staff on staff.id=evaluation.operational_staff_id
      and staff.organization_id=target_organization_id
    join public.branches branch on branch.id=staff.branch_id
    where evaluation.evaluation_month=requested_month
      and (branch_filter is null or staff.branch_id=branch_filter)),'[]'::jsonb)
  ) into result;
  return result;
end $$;

revoke all on function public.leave_operational_staff_company(uuid,uuid,uuid,uuid),
  public.transfer_operational_staff_branch(uuid,uuid,uuid,uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.leave_operational_staff_company(uuid,uuid,uuid,uuid),
  public.transfer_operational_staff_branch(uuid,uuid,uuid,uuid,uuid)
  to service_role;

revoke all on function private.operational_roles_are_valid(text[]),private.validate_operational_assignment()
  from public,anon,authenticated;
