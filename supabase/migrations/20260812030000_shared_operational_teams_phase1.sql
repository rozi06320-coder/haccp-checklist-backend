-- Phase 1: durable branch operational teams for Employee Team and Daily Hygiene only.
-- Legacy branch_supervisor_teams remains authoritative for modules not migrated in this phase.

do $$
begin
  if exists (
    select 1 from public.operational_staff staff
    where staff.employment_status='active'
      and (select count(*) from public.operational_staff_assignments assignment
        where assignment.operational_staff_id=staff.id and assignment.active) <> 1
  ) then raise exception 'operational team migration blocked: active employee assignment is ambiguous' using errcode='23514'; end if;

  if exists (
    select 1 from public.operational_staff
    where employment_status='active'
    group by organization_id,branch_id,normalized_name having count(*)>1
  ) then raise exception 'operational team migration blocked: duplicate active employee names exist' using errcode='23514'; end if;

  if exists (
    select 1 from public.operational_staff
    where employment_status='active' and staff_code is not null
    group by organization_id,branch_id,pg_catalog.lower(staff_code) having count(*)>1
  ) then raise exception 'operational team migration blocked: duplicate active employee codes exist' using errcode='23514'; end if;

  if exists (
    select 1 from public.branch_supervisor_teams team
    where team.active and not exists (
      select 1 from public.branch_memberships membership
      join public.branches branch on branch.id=membership.branch_id
      join public.organizations organization on organization.id=branch.organization_id
      join public.profiles profile on profile.id=membership.user_id
      where membership.branch_id=team.branch_id and membership.user_id=team.supervisor_user_id
        and membership.role='branch_manager' and membership.active
        and branch.organization_id=team.organization_id and branch.active and organization.active
        and profile.disabled_at is null and not profile.must_change_password
    )
  ) then raise exception 'operational team migration blocked: active supervisor scope conflict exists' using errcode='23514'; end if;

  if exists (
    select 1 from public.operational_staff_health_cards
    group by operational_staff_id having count(*)>1
  ) then raise exception 'operational team migration blocked: duplicate employee health cards exist' using errcode='23514'; end if;

  if exists (
    select 1 from public.operational_staff_monthly_evaluations
    group by operational_staff_id,evaluation_month having count(*)>1
  ) then raise exception 'operational team migration blocked: duplicate employee monthly evaluations exist' using errcode='23514'; end if;
end $$;

create function private.normalize_operational_team_name(value text)
returns text language sql immutable set search_path = ''
as $$ select pg_catalog.lower(pg_catalog.regexp_replace(pg_catalog.btrim(value),'[[:space:]]+',' ','g')) $$;

create function private.operational_team_default_name(ordinal bigint)
returns text language sql immutable set search_path = ''
as $$
  select case when ordinal between 1 and 26 then 'Team '||pg_catalog.chr(64+ordinal::integer)
    else 'Team '||ordinal::text end
$$;

create table public.branch_operational_teams (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  name text not null,
  normalized_name text generated always as (private.normalize_operational_team_name(name)) stored,
  active boolean not null default true,
  legacy_supervisor_team_id uuid unique references public.branch_supervisor_teams(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branch_operational_teams_scope_key unique(id,branch_id,organization_id),
  constraint branch_operational_teams_branch_scope_fkey foreign key(branch_id,organization_id)
    references public.branches(id,organization_id) on delete restrict,
  constraint branch_operational_teams_name_check check(
    name=pg_catalog.regexp_replace(pg_catalog.btrim(name),'[[:space:]]+',' ','g') and length(name) between 1 and 80
  )
);
create unique index branch_operational_teams_active_name_key
  on public.branch_operational_teams(branch_id,normalized_name) where active;
create index branch_operational_teams_branch_idx
  on public.branch_operational_teams(organization_id,branch_id,active);
create trigger branch_operational_teams_set_updated_at before update on public.branch_operational_teams
for each row execute function private.set_updated_at();

create table public.branch_operational_team_supervisors (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  operational_team_id uuid not null,
  supervisor_user_id uuid not null references auth.users(id) on delete restrict,
  assignment_role text not null,
  active boolean not null default true,
  valid_from date not null default current_date,
  valid_to date,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branch_operational_team_supervisors_team_scope_fkey
    foreign key(operational_team_id,branch_id,organization_id)
    references public.branch_operational_teams(id,branch_id,organization_id) on delete restrict,
  constraint branch_operational_team_supervisors_role_check check(assignment_role in('primary','backup')),
  constraint branch_operational_team_supervisors_dates_check check(valid_to is null or valid_to>=valid_from),
  constraint branch_operational_team_supervisors_active_dates_check check(not active or valid_to is null)
);
create unique index branch_operational_team_supervisors_active_pair_key
  on public.branch_operational_team_supervisors(operational_team_id,supervisor_user_id) where active;
create unique index branch_operational_team_supervisors_active_primary_key
  on public.branch_operational_team_supervisors(operational_team_id) where active and assignment_role='primary';
create index branch_operational_team_supervisors_actor_idx
  on public.branch_operational_team_supervisors(supervisor_user_id,branch_id,active);
create trigger branch_operational_team_supervisors_set_updated_at before update on public.branch_operational_team_supervisors
for each row execute function private.set_updated_at();

create function private.validate_branch_operational_team_supervisor()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not exists (
    select 1 from public.branch_operational_teams team
    join public.branches branch on branch.id=team.branch_id
    join public.organizations organization on organization.id=team.organization_id
    join public.branch_memberships membership on membership.branch_id=team.branch_id
    join public.profiles profile on profile.id=membership.user_id
    where team.id=new.operational_team_id and team.branch_id=new.branch_id
      and team.organization_id=new.organization_id and membership.user_id=new.supervisor_user_id
      and membership.role='branch_manager'
      and (not new.active or (team.active and branch.active and organization.active and membership.active
        and profile.disabled_at is null and not profile.must_change_password))
  ) then raise exception 'invalid operational team supervisor scope' using errcode='23514'; end if;
  return new;
end $$;
create trigger branch_operational_team_supervisors_validate before insert or update
on public.branch_operational_team_supervisors for each row
execute function private.validate_branch_operational_team_supervisor();

with ranked as (
  select legacy.*,pg_catalog.row_number() over(partition by legacy.branch_id order by legacy.created_at,legacy.id) ordinal
  from public.branch_supervisor_teams legacy
)
insert into public.branch_operational_teams(organization_id,branch_id,name,active,legacy_supervisor_team_id,created_at,updated_at)
select ranked.organization_id,ranked.branch_id,private.operational_team_default_name(ranked.ordinal),
  ranked.active or exists(select 1 from public.operational_staff_assignments assignment
    where assignment.supervisor_team_id=ranked.id and assignment.active),
  ranked.id,ranked.created_at,ranked.updated_at
from ranked;

insert into public.branch_operational_team_supervisors(
  organization_id,branch_id,operational_team_id,supervisor_user_id,assignment_role,active,valid_from,valid_to,created_by,created_at,updated_at
)
select team.organization_id,team.branch_id,team.id,legacy.supervisor_user_id,'primary',legacy.active,
  legacy.created_at::date,case when legacy.active then null else legacy.updated_at::date end,
  legacy.supervisor_user_id,legacy.created_at,legacy.updated_at
from public.branch_operational_teams team
join public.branch_supervisor_teams legacy on legacy.id=team.legacy_supervisor_team_id;

alter table public.operational_staff_assignments add column operational_team_id uuid;
update public.operational_staff_assignments assignment
set operational_team_id=team.id
from public.branch_operational_teams team
where team.legacy_supervisor_team_id=assignment.supervisor_team_id;
do $$ begin
  if exists(select 1 from public.operational_staff_assignments where operational_team_id is null)
  then raise exception 'operational team migration blocked: legacy assignment cannot be mapped' using errcode='23514'; end if;
end $$;
alter table public.operational_staff_assignments alter column operational_team_id set not null;
alter table public.operational_staff_assignments add constraint operational_staff_assignments_operational_team_scope_fkey
  foreign key(operational_team_id,branch_id,organization_id)
  references public.branch_operational_teams(id,branch_id,organization_id) on delete restrict;
create unique index operational_staff_assignments_one_active_team_key
  on public.operational_staff_assignments(operational_staff_id) where active;
create index operational_staff_assignments_operational_team_idx
  on public.operational_staff_assignments(operational_team_id,active);

create function private.populate_operational_assignment_team()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.operational_team_id is null then
    select team.id into strict new.operational_team_id from public.branch_operational_teams team
    where team.legacy_supervisor_team_id=new.supervisor_team_id;
  end if;
  return new;
exception when no_data_found or too_many_rows then
  raise exception 'invalid operational assignment scope' using errcode='23514';
end $$;
create trigger operational_staff_assignments_00_populate_team before insert or update
on public.operational_staff_assignments for each row execute function private.populate_operational_assignment_team();

create or replace function private.validate_operational_assignment()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if not private.operational_roles_are_valid(new.operational_roles) or not exists (
    select 1 from public.operational_staff staff
    join public.branch_operational_teams operational_team on operational_team.id=new.operational_team_id
    join public.branch_supervisor_teams legacy_team on legacy_team.id=new.supervisor_team_id
    join public.branches branch on branch.id=new.branch_id
    join public.organizations organization on organization.id=new.organization_id
    where staff.id=new.operational_staff_id and staff.branch_id=new.branch_id and staff.organization_id=new.organization_id
      and operational_team.branch_id=new.branch_id and operational_team.organization_id=new.organization_id
      and operational_team.legacy_supervisor_team_id=legacy_team.id
      and legacy_team.branch_id=new.branch_id and legacy_team.organization_id=new.organization_id
      and (not new.active or (staff.employment_status='active' and operational_team.active and branch.active and organization.active))
  ) then raise exception 'invalid operational assignment scope' using errcode='23514'; end if;
  return new;
end $$;

create function private.actor_can_read_operational_branch(actor uuid,target_branch uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(
    select 1 from public.profiles profile
    join public.branch_memberships membership on membership.user_id=profile.id
    join public.branches branch on branch.id=membership.branch_id
    join public.organizations organization on organization.id=branch.organization_id
    where profile.id=actor and profile.disabled_at is null and not profile.must_change_password
      and membership.branch_id=target_branch and membership.role='branch_manager' and membership.active
      and branch.active and organization.active
  )
$$;

create function private.actor_can_write_operational_team(actor uuid,target_branch uuid,target_team uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select private.actor_can_read_operational_branch(actor,target_branch) and exists(
    select 1 from public.branch_operational_team_supervisors assignment
    join public.branch_operational_teams team on team.id=assignment.operational_team_id
    where assignment.supervisor_user_id=actor and assignment.branch_id=target_branch
      and assignment.operational_team_id=target_team and assignment.active and team.active
      and assignment.valid_from<=current_date and (assignment.valid_to is null or assignment.valid_to>=current_date)
  )
$$;

create function private.actor_default_operational_team(actor uuid,target_branch uuid)
returns uuid language sql stable security definer set search_path = '' as $$
  select team.id from public.branch_operational_teams team
  left join public.branch_operational_team_supervisors assignment
    on assignment.operational_team_id=team.id and assignment.supervisor_user_id=actor and assignment.active
  where team.branch_id=target_branch and team.active and private.actor_can_read_operational_branch(actor,target_branch)
  order by case assignment.assignment_role when 'primary' then 0 when 'backup' then 1 else 2 end,
    assignment.valid_from desc nulls last,team.normalized_name,team.id limit 1
$$;

alter table public.branch_operational_teams enable row level security;
alter table public.branch_operational_team_supervisors enable row level security;
create policy branch_operational_teams_read on public.branch_operational_teams for select to authenticated using(
  private.actor_can_read_operational_branch(auth.uid(),branch_id) or private.is_organization_manager(organization_id)
);
create policy branch_operational_team_supervisors_read on public.branch_operational_team_supervisors for select to authenticated using(
  private.actor_can_read_operational_branch(auth.uid(),branch_id) or private.is_organization_manager(organization_id)
);
drop policy operational_staff_read on public.operational_staff;
create policy operational_staff_read on public.operational_staff for select to authenticated using(
  private.actor_can_read_operational_branch(auth.uid(),branch_id) or private.is_organization_manager(organization_id)
);
drop policy operational_assignments_read on public.operational_staff_assignments;
create policy operational_assignments_read on public.operational_staff_assignments for select to authenticated using(
  private.actor_can_read_operational_branch(auth.uid(),branch_id) or private.is_organization_manager(organization_id)
);
drop policy operational_duty_read on public.operational_staff_duty_statuses;
create policy operational_duty_read on public.operational_staff_duty_statuses for select to authenticated using(
  private.actor_can_read_operational_branch(auth.uid(),branch_id) or private.is_organization_manager(organization_id)
);
revoke all on public.branch_operational_teams,public.branch_operational_team_supervisors from public,anon,authenticated,service_role;
grant select on public.branch_operational_teams,public.branch_operational_team_supervisors to authenticated;

create function private.sync_legacy_supervisor_operational_team()
returns trigger language plpgsql security definer set search_path = '' as $$
declare mapped public.branch_operational_teams%rowtype; ordinal bigint; chosen_role text;
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(new.branch_id::text,17));
  select * into mapped from public.branch_operational_teams where legacy_supervisor_team_id=new.id for update;
  if mapped.id is null then
    select count(*)+1 into ordinal from public.branch_operational_teams where branch_id=new.branch_id;
    insert into public.branch_operational_teams(organization_id,branch_id,name,active,legacy_supervisor_team_id,created_at,updated_at)
    values(new.organization_id,new.branch_id,private.operational_team_default_name(ordinal),true,new.id,new.created_at,new.updated_at)
    returning * into mapped;
  end if;
  if new.active then
    if not exists(select 1 from public.branch_operational_team_supervisors where operational_team_id=mapped.id and supervisor_user_id=new.supervisor_user_id and active) then
      chosen_role:=case when exists(select 1 from public.branch_operational_team_supervisors where operational_team_id=mapped.id and assignment_role='primary' and active) then 'backup' else 'primary' end;
      insert into public.branch_operational_team_supervisors(organization_id,branch_id,operational_team_id,supervisor_user_id,assignment_role,created_by)
      values(new.organization_id,new.branch_id,mapped.id,new.supervisor_user_id,chosen_role,new.supervisor_user_id);
    end if;
  else
    update public.branch_operational_team_supervisors set active=false,valid_to=greatest(valid_from,current_date)
    where operational_team_id=mapped.id and supervisor_user_id=new.supervisor_user_id and active;
  end if;
  return new;
end $$;
create trigger branch_supervisor_teams_sync_operational_team after insert or update of active
on public.branch_supervisor_teams for each row execute function private.sync_legacy_supervisor_operational_team();

drop function public.get_supervisor_operational_team(uuid,uuid,date);
create function public.get_supervisor_operational_team(actor_user_id uuid,target_branch_id uuid,requested_date date)
returns table(team_id uuid,team_name text,team_active boolean,can_write boolean,assignment_role text,
  company_name text,staff_id uuid,display_name text,staff_company_name text,staff_code text,
  iqama_number text,iqama_expiry_date date,phone_number text,email text,employment_status text,
  assignment_id uuid,operational_roles text[],duty_status text)
language plpgsql security definer set search_path = '' as $$
begin
  if requested_date is null or not private.actor_can_read_operational_branch(actor_user_id,target_branch_id)
  then raise exception 'team access denied' using errcode='42501'; end if;
  return query
  select team.id,team.name,team.active,private.actor_can_write_operational_team(actor_user_id,target_branch_id,team.id),
    actor_assignment.assignment_role,coalesce(legacy.company_name,organization.name),
    staff.id,staff.display_name,staff.company_name,staff.staff_code,staff.iqama_number,staff.iqama_expiry_date,
    staff.phone_number,staff.email,staff.employment_status,assignment.id,assignment.operational_roles,
    coalesce(duty.duty_status,'on_duty')
  from public.branch_operational_teams team
  join public.organizations organization on organization.id=team.organization_id
  left join public.branch_supervisor_teams legacy on legacy.id=team.legacy_supervisor_team_id
  left join public.branch_operational_team_supervisors actor_assignment
    on actor_assignment.operational_team_id=team.id and actor_assignment.supervisor_user_id=actor_user_id and actor_assignment.active
  left join public.operational_staff_assignments assignment
    on assignment.operational_team_id=team.id and assignment.active
  left join public.operational_staff staff on staff.id=assignment.operational_staff_id
  left join public.operational_staff_duty_statuses duty
    on duty.assignment_id=assignment.id and duty.duty_date=requested_date
  where team.branch_id=target_branch_id and team.active
  order by case actor_assignment.assignment_role when 'primary' then 0 when 'backup' then 1 else 2 end,
    team.normalized_name,pg_catalog.lower(staff.display_name),staff.id;
end $$;

create function public.create_operational_team_staff(actor_user_id uuid,target_branch_id uuid,target_operational_team_id uuid,
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
  insert into public.operational_staff_assignments(organization_id,branch_id,operational_staff_id,supervisor_team_id,operational_team_id,operational_roles)
  values(target_team.organization_id,target_branch_id,created_staff,target_team.legacy_supervisor_team_id,target_team.id,new_operational_roles)
  returning id into created_assignment;
  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
  values(target_team.organization_id,actor_user_id,target_branch_id,'operational_staff_created',
    pg_catalog.jsonb_build_object('team_id',target_team.id,'operational_staff_id',created_staff,'assignment_id',created_assignment,'operational_roles',new_operational_roles));
  return query select created_staff,created_assignment,false,clean_iqama,new_iqama_expiry_date,clean_phone,clean_email;
exception when unique_violation then raise exception 'staff identity already exists' using errcode='23505';
when no_data_found or too_many_rows then raise exception 'staff operation denied' using errcode='42501';
end $$;

create function public.update_operational_team_staff(actor_user_id uuid,target_branch_id uuid,target_staff_id uuid,
  new_display_name text,new_employment_status text,new_operational_roles text[],new_staff_code text,new_company_name text,
  new_iqama_number text,new_iqama_expiry_date date,new_phone_number text,new_email text)
returns table(staff_id uuid,assignment_id uuid,duplicate_name_warning boolean,iqama_number text,iqama_expiry_date date,phone_number text,email text)
language plpgsql security definer set search_path = '' as $$
declare staff_row public.operational_staff%rowtype; assignment_row public.operational_staff_assignments%rowtype;
 clean_name text:=pg_catalog.regexp_replace(pg_catalog.btrim(new_display_name),'[[:space:]]+',' ','g');
 clean_code text:=private.clean_operational_staff_code(new_staff_code);
 clean_company text:=private.clean_operational_staff_company_name(new_company_name);
 clean_iqama text:=private.clean_operational_staff_optional_text(new_iqama_number,80);
 clean_phone text:=private.clean_operational_staff_optional_text(new_phone_number,40);
 clean_email text:=private.clean_operational_staff_email(new_email);
begin
  select * into strict staff_row from public.operational_staff where id=target_staff_id and branch_id=target_branch_id for update;
  select * into strict assignment_row from public.operational_staff_assignments where operational_staff_id=target_staff_id and active for update;
  if not private.actor_can_write_operational_team(actor_user_id,target_branch_id,assignment_row.operational_team_id)
    or new_employment_status not in('active','inactive') or length(clean_name) not between 1 and 120
    or length(coalesce(clean_company,'')) not between 1 and 160
    or (clean_code is not null and length(clean_code) not between 1 and 80)
    or not private.operational_roles_are_valid(new_operational_roles)
  then raise exception 'staff operation denied' using errcode='42501'; end if;
  update public.operational_staff set display_name=clean_name,company_name=clean_company,staff_code=clean_code,
    iqama_number=clean_iqama,iqama_expiry_date=new_iqama_expiry_date,phone_number=clean_phone,email=clean_email,
    employment_status=new_employment_status,
    deactivated_at=case when new_employment_status='inactive' then coalesce(deactivated_at,now()) else null end,
    deactivated_by=case when new_employment_status='inactive' then coalesce(deactivated_by,actor_user_id) else null end
  where id=target_staff_id;
  update public.operational_staff_assignments set operational_roles=new_operational_roles,
    active=(new_employment_status='active'),valid_to=case when new_employment_status='inactive' then current_date else null end
  where id=assignment_row.id returning * into assignment_row;
  return query select target_staff_id,assignment_row.id,false,clean_iqama,new_iqama_expiry_date,clean_phone,clean_email;
exception when unique_violation then raise exception 'staff identity already exists' using errcode='23505';
when no_data_found or too_many_rows then raise exception 'staff operation denied' using errcode='42501';
end $$;

create function public.set_operational_team_staff_duty(actor_user_id uuid,target_branch_id uuid,target_staff_id uuid,
  requested_date date,new_duty_status text)
returns table(staff_id uuid,assignment_id uuid,duty_date date,duty_status text,eligible boolean)
language plpgsql security definer set search_path = '' as $$
declare staff_row public.operational_staff%rowtype; assignment_row public.operational_staff_assignments%rowtype;
begin
  select * into strict staff_row from public.operational_staff where id=target_staff_id and branch_id=target_branch_id;
  select * into strict assignment_row from public.operational_staff_assignments where operational_staff_id=target_staff_id and active for update;
  if requested_date is null or new_duty_status not in('on_duty','day_off')
    or not private.actor_can_write_operational_team(actor_user_id,target_branch_id,assignment_row.operational_team_id)
  then raise exception 'duty operation denied' using errcode='42501'; end if;
  insert into public.operational_staff_duty_statuses(organization_id,branch_id,operational_staff_id,assignment_id,duty_date,duty_status,set_by)
  values(staff_row.organization_id,target_branch_id,target_staff_id,assignment_row.id,requested_date,new_duty_status,actor_user_id)
  on conflict on constraint operational_staff_duty_unique do update set duty_status=excluded.duty_status,set_by=excluded.set_by;
  return query select target_staff_id,assignment_row.id,requested_date,new_duty_status,
    staff_row.employment_status='active' and new_duty_status='on_duty';
exception when no_data_found or too_many_rows then raise exception 'duty operation denied' using errcode='42501';
end $$;

create function public.move_operational_staff_team(actor_user_id uuid,target_branch_id uuid,target_staff_id uuid,
  expected_assignment_id uuid,target_operational_team_id uuid)
returns table(staff_id uuid,assignment_id uuid,operational_team_id uuid)
language plpgsql security definer set search_path = '' as $$
declare staff_row public.operational_staff%rowtype; old_assignment public.operational_staff_assignments%rowtype;
 target_team public.branch_operational_teams%rowtype; created_assignment uuid; business_date date; prior_duty text;
begin
  select * into strict staff_row from public.operational_staff where id=target_staff_id and branch_id=target_branch_id for update;
  select * into strict old_assignment from public.operational_staff_assignments
    where operational_staff_id=target_staff_id and active for update;
  select * into strict target_team from public.branch_operational_teams
    where id=target_operational_team_id and branch_id=target_branch_id and organization_id=staff_row.organization_id and active for update;
  if old_assignment.id<>expected_assignment_id
    or not private.actor_can_write_operational_team(actor_user_id,target_branch_id,old_assignment.operational_team_id)
    or not private.actor_can_write_operational_team(actor_user_id,target_branch_id,target_team.id)
    or target_team.legacy_supervisor_team_id is null or staff_row.employment_status<>'active'
  then raise exception 'staff move denied' using errcode='42501'; end if;
  if old_assignment.operational_team_id=target_team.id then raise exception 'staff already belongs to team' using errcode='23505'; end if;
  select private.phase4a_business_date(branch.timezone) into strict business_date
  from public.branches branch where branch.id=target_branch_id and branch.active;
  if exists(
    select 1 from public.hygiene_staff_snapshots snapshot
    join public.checklist_submissions submission on submission.id=snapshot.submission_id
    where snapshot.operational_staff_id=target_staff_id and submission.branch_id=target_branch_id
      and submission.business_date=business_date and submission.checklist_type='staff_hygiene' and submission.state='submitted'
  ) then raise exception 'staff move blocked by submitted hygiene' using errcode='23514'; end if;
  select duty_status into prior_duty from public.operational_staff_duty_statuses
    where assignment_id=old_assignment.id and duty_date=business_date;
  update public.operational_staff_assignments set active=false,valid_to=business_date where id=old_assignment.id;
  insert into public.operational_staff_assignments(organization_id,branch_id,operational_staff_id,supervisor_team_id,
    operational_team_id,operational_roles,valid_from)
  values(staff_row.organization_id,target_branch_id,target_staff_id,target_team.legacy_supervisor_team_id,
    target_team.id,old_assignment.operational_roles,business_date) returning id into created_assignment;
  if prior_duty is not null then
    insert into public.operational_staff_duty_statuses(organization_id,branch_id,operational_staff_id,assignment_id,duty_date,duty_status,set_by)
    values(staff_row.organization_id,target_branch_id,target_staff_id,created_assignment,business_date,prior_duty,actor_user_id);
  end if;
  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
  values(staff_row.organization_id,actor_user_id,target_branch_id,'operational_staff_assignment_updated',
    pg_catalog.jsonb_build_object('team_id',target_team.id,'operational_staff_id',target_staff_id,
      'assignment_id',created_assignment,'previous_status','active','new_status','active','operational_roles',old_assignment.operational_roles));
  return query select target_staff_id,created_assignment,target_team.id;
exception when no_data_found or too_many_rows then raise exception 'staff move denied' using errcode='42501';
end $$;

create function public.assign_operational_team_supervisor(actor_user_id uuid,target_organization_id uuid,
  target_operational_team_id uuid,target_supervisor_user_id uuid,new_assignment_role text)
returns table(id uuid,operational_team_id uuid,supervisor_user_id uuid,assignment_role text,active boolean)
language plpgsql security definer set search_path = '' as $$
declare team public.branch_operational_teams%rowtype; created public.branch_operational_team_supervisors%rowtype;
begin
  select * into strict team from public.branch_operational_teams
  where branch_operational_teams.id=target_operational_team_id and organization_id=target_organization_id and active for update;
  if not private.actor_manages_active_organization(actor_user_id,target_organization_id)
    or new_assignment_role not in('primary','backup')
  then raise exception 'operational team assignment denied' using errcode='42501'; end if;
  insert into public.branch_operational_team_supervisors(organization_id,branch_id,operational_team_id,
    supervisor_user_id,assignment_role,created_by)
  values(team.organization_id,team.branch_id,team.id,target_supervisor_user_id,new_assignment_role,actor_user_id)
  returning * into created;
  return query select created.id,created.operational_team_id,created.supervisor_user_id,created.assignment_role,created.active;
exception when no_data_found or too_many_rows then raise exception 'operational team assignment denied' using errcode='42501';
end $$;

-- Daily Hygiene gains durable team ownership while all other checklist types keep legacy ownership.
alter table public.checklist_submissions
  add column operational_team_id uuid,
  add column operational_team_name_snapshot text,
  add column submitted_by_user_id uuid references auth.users(id) on delete restrict,
  add column hygiene_revision bigint not null default 0;
alter table public.checklist_submissions disable trigger immutable_submitted_report;
update public.checklist_submissions submission
set operational_team_id=team.id,
    operational_team_name_snapshot=team.name,
    submitted_by_user_id=submission.supervisor_user_id,
    hygiene_revision=1
from public.branch_operational_teams team
where submission.checklist_type='staff_hygiene' and team.legacy_supervisor_team_id=submission.supervisor_team_id;
alter table public.checklist_submissions enable trigger immutable_submitted_report;
do $$ begin
  if exists(select 1 from public.checklist_submissions where checklist_type='staff_hygiene'
    and (operational_team_id is null or operational_team_name_snapshot is null or submitted_by_user_id is null))
  then raise exception 'operational team migration blocked: hygiene submission cannot be mapped' using errcode='23514'; end if;
end $$;
alter table public.checklist_submissions add constraint checklist_submissions_operational_team_scope_fkey
  foreign key(operational_team_id,branch_id,organization_id)
  references public.branch_operational_teams(id,branch_id,organization_id) on delete restrict;
alter table public.checklist_submissions add constraint checklist_submissions_hygiene_team_check check(
  checklist_type<>'staff_hygiene' or (operational_team_id is not null and operational_team_name_snapshot is not null
    and submitted_by_user_id is not null and hygiene_revision>=1)
);
create unique index checklist_submissions_hygiene_one_draft
  on public.checklist_submissions(organization_id,branch_id,operational_team_id,business_date)
  where checklist_type='staff_hygiene' and state='draft';
create unique index checklist_submissions_hygiene_one_final
  on public.checklist_submissions(organization_id,branch_id,operational_team_id,business_date)
  where checklist_type='staff_hygiene' and state='submitted';

create function private.lock_operational_team_hygiene(target_branch uuid,target_team uuid,target_date date)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    target_branch::text||':'||target_team::text||':'||target_date::text,31));
end $$;

create function private.operational_team_hygiene_context(actor uuid,target_branch uuid,target_team uuid,write_required boolean)
returns table(organization_id uuid,branch_id uuid,operational_team_id uuid,legacy_team_id uuid,business_date date,
  branch_name text,branch_code text,supervisor_name text,team_name text,can_write boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.actor_can_read_operational_branch(actor,target_branch)
    or (write_required and not private.actor_can_write_operational_team(actor,target_branch,target_team))
  then raise exception 'hygiene access denied' using errcode='42501'; end if;
  return query select branch.organization_id,branch.id,team.id,team.legacy_supervisor_team_id,
    private.phase4a_business_date(branch.timezone),branch.name,branch.code,profile.full_name,team.name,
    private.actor_can_write_operational_team(actor,target_branch,team.id)
  from public.branch_operational_teams team
  join public.branches branch on branch.id=team.branch_id and branch.organization_id=team.organization_id
  join public.profiles profile on profile.id=actor
  where team.id=target_team and team.branch_id=target_branch and team.active;
  if not found then raise exception 'hygiene access denied' using errcode='42501'; end if;
end $$;

create function public.get_operational_team_hygiene_current_state(actor_user_id uuid,target_branch_id uuid,target_operational_team_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c record; submission public.checklist_submissions%rowtype;
begin
  select * into strict c from private.operational_team_hygiene_context(actor_user_id,target_branch_id,target_operational_team_id,false);
  select * into submission from public.checklist_submissions existing
  where existing.organization_id=c.organization_id and existing.branch_id=c.branch_id
    and existing.operational_team_id=c.operational_team_id and existing.business_date=c.business_date
    and existing.checklist_type='staff_hygiene'
  order by case existing.state when 'submitted' then 0 else 1 end,existing.updated_at desc,existing.id limit 1;
  if submission.state='submitted' then
    return pg_catalog.jsonb_build_object('state','submitted','business_date',c.business_date,'checklist_type','staff_hygiene',
      'id',submission.id,'created_at',submission.created_at,'updated_at',submission.updated_at,
      'submitted_at',submission.submitted_at,'operational_team_id',c.operational_team_id,'team_name',c.team_name,
      'can_write',c.can_write,'revision',submission.hygiene_revision,
      'staff',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'staff_id',snapshot.operational_staff_id,'display_name',snapshot.display_name_snapshot,
        'operational_roles',snapshot.operational_roles_snapshot,'uniform',snapshot.uniform_result,
        'fingernails',snapshot.fingernails_result,'hair',snapshot.hair_result,'facial_hair',snapshot.facial_hair_result,
        'remark',snapshot.remark) order by pg_catalog.lower(snapshot.display_name_snapshot),snapshot.id)
        from public.hygiene_staff_snapshots snapshot where snapshot.submission_id=submission.id),'[]'::jsonb));
  end if;
  return pg_catalog.jsonb_build_object('state',coalesce(submission.state,'none'),'business_date',c.business_date,
    'checklist_type','staff_hygiene','id',submission.id,'created_at',submission.created_at,'updated_at',submission.updated_at,
    'submitted_at',submission.submitted_at,'operational_team_id',c.operational_team_id,'team_name',c.team_name,
    'can_write',c.can_write,'revision',coalesce(submission.hygiene_revision,0),
    'staff',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'staff_id',staff.id,'display_name',staff.display_name,'operational_roles',assignment.operational_roles,
      'uniform',coalesce(snapshot.uniform_result,'pending'),'fingernails',coalesce(snapshot.fingernails_result,'pending'),
      'hair',coalesce(snapshot.hair_result,'pending'),'facial_hair',coalesce(snapshot.facial_hair_result,'pending'),
      'remark',coalesce(snapshot.remark,'')) order by pg_catalog.lower(staff.display_name),staff.id)
      from public.operational_staff_assignments assignment
      join public.operational_staff staff on staff.id=assignment.operational_staff_id
      left join public.operational_staff_duty_statuses duty on duty.assignment_id=assignment.id and duty.duty_date=c.business_date
      left join public.hygiene_staff_snapshots snapshot on snapshot.submission_id=submission.id and snapshot.operational_staff_id=staff.id
      where assignment.operational_team_id=c.operational_team_id and assignment.active
        and assignment.valid_from<=c.business_date and (assignment.valid_to is null or assignment.valid_to>=c.business_date)
        and staff.employment_status='active' and coalesce(duty.duty_status,'on_duty')='on_duty'),'[]'::jsonb));
exception when no_data_found or too_many_rows then raise exception 'hygiene access denied' using errcode='42501';
end $$;

create function public.save_operational_team_hygiene_draft(actor_user_id uuid,target_branch_id uuid,
  target_operational_team_id uuid,expected_revision bigint,staff_answers jsonb)
returns table(id uuid,business_date date,checklist_type text,state text,created_at timestamptz,updated_at timestamptz,revision bigint)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare c record; report public.checklist_submissions%rowtype; entry jsonb; eligible_count int;
begin
  select * into strict c from private.operational_team_hygiene_context(actor_user_id,target_branch_id,target_operational_team_id,true);
  perform private.lock_operational_team_hygiene(c.branch_id,c.operational_team_id,c.business_date);
  if pg_catalog.jsonb_typeof(staff_answers)<>'array' or pg_catalog.jsonb_array_length(staff_answers)>500
  then raise exception 'invalid hygiene draft' using errcode='22023'; end if;
  if exists(select 1 from public.checklist_submissions where organization_id=c.organization_id and branch_id=c.branch_id
    and operational_team_id=c.operational_team_id and business_date=c.business_date and checklist_type='staff_hygiene' and state='submitted')
  then raise exception 'final submission already exists' using errcode='23505'; end if;
  select * into report from public.checklist_submissions existing
  where existing.organization_id=c.organization_id and existing.branch_id=c.branch_id
    and existing.operational_team_id=c.operational_team_id and existing.business_date=c.business_date
    and existing.checklist_type='staff_hygiene' and existing.state='draft' for update;
  if (report.id is null and coalesce(expected_revision,0)<>0)
    or (report.id is not null and coalesce(expected_revision,-1)<>report.hygiene_revision)
  then raise exception 'hygiene draft changed' using errcode='40001'; end if;
  select count(*) into eligible_count from public.operational_staff_assignments assignment
  join public.operational_staff staff on staff.id=assignment.operational_staff_id
  left join public.operational_staff_duty_statuses duty on duty.assignment_id=assignment.id and duty.duty_date=c.business_date
  where assignment.operational_team_id=c.operational_team_id and assignment.active
    and assignment.valid_from<=c.business_date and (assignment.valid_to is null or assignment.valid_to>=c.business_date)
    and staff.employment_status='active' and coalesce(duty.duty_status,'on_duty')='on_duty';
  if pg_catalog.jsonb_array_length(staff_answers)<>eligible_count
    or (select count(distinct value->>'staff_id') from pg_catalog.jsonb_array_elements(staff_answers))<>eligible_count
  then raise exception 'staff set changed' using errcode='22023'; end if;
  for entry in select value from pg_catalog.jsonb_array_elements(staff_answers) loop
    if (select count(*) from pg_catalog.jsonb_object_keys(entry))<>6
      or not(entry?'staff_id' and entry?'uniform' and entry?'fingernails' and entry?'hair' and entry?'facial_hair' and entry?'remark')
      or entry->>'uniform' not in('pending','pass','issue') or entry->>'fingernails' not in('pending','pass','issue')
      or entry->>'hair' not in('pending','pass','issue') or entry->>'facial_hair' not in('pending','pass','issue')
      or length(entry->>'remark')>2000
      or not exists(select 1 from public.operational_staff_assignments assignment
        join public.operational_staff staff on staff.id=assignment.operational_staff_id
        left join public.operational_staff_duty_statuses duty on duty.assignment_id=assignment.id and duty.duty_date=c.business_date
        where staff.id=(entry->>'staff_id')::uuid and assignment.operational_team_id=c.operational_team_id
          and assignment.active and staff.employment_status='active' and coalesce(duty.duty_status,'on_duty')='on_duty')
    then raise exception 'invalid hygiene draft' using errcode='22023'; end if;
  end loop;
  if report.id is null then
    insert into public.checklist_submissions(organization_id,branch_id,supervisor_user_id,supervisor_team_id,
      operational_team_id,operational_team_name_snapshot,submitted_by_user_id,hygiene_revision,business_date,
      checklist_type,definition_id,state,branch_name_snapshot,branch_code_snapshot,supervisor_name_snapshot)
    values(c.organization_id,c.branch_id,actor_user_id,c.legacy_team_id,c.operational_team_id,c.team_name,
      actor_user_id,1,c.business_date,'staff_hygiene','staff_hygiene_v1','draft',c.branch_name,c.branch_code,c.supervisor_name)
    returning * into report;
  else
    update public.checklist_submissions set supervisor_user_id=actor_user_id,submitted_by_user_id=actor_user_id,
      supervisor_name_snapshot=c.supervisor_name,operational_team_name_snapshot=c.team_name,
      hygiene_revision=report.hygiene_revision+1,updated_at=now()
    where checklist_submissions.id=report.id returning * into report;
  end if;
  delete from public.hygiene_staff_snapshots where submission_id=report.id;
  insert into public.hygiene_staff_snapshots(submission_id,operational_staff_id,display_name_snapshot,operational_roles_snapshot,
    remark,uniform_result,fingernails_result,hair_result,facial_hair_result)
  select report.id,staff.id,staff.display_name,assignment.operational_roles,entry.value->>'remark',entry.value->>'uniform',
    entry.value->>'fingernails',entry.value->>'hair',entry.value->>'facial_hair'
  from pg_catalog.jsonb_array_elements(staff_answers) entry(value)
  join public.operational_staff staff on staff.id=(entry.value->>'staff_id')::uuid
  join public.operational_staff_assignments assignment on assignment.operational_staff_id=staff.id
    and assignment.operational_team_id=c.operational_team_id and assignment.active;
  return query select report.id,report.business_date,report.checklist_type,report.state,
    report.created_at,report.updated_at,report.hygiene_revision;
exception when no_data_found or too_many_rows then raise exception 'hygiene draft denied' using errcode='42501';
end $$;

create function public.submit_operational_team_hygiene(actor_user_id uuid,target_branch_id uuid,target_operational_team_id uuid,
  idempotency_key uuid,request_hash text,staff_answers jsonb)
returns table(id uuid,business_date date,checklist_type text,state text,submitted_at timestamptz,issue_count bigint)
language plpgsql security definer set search_path = '' as $$
declare c record; report public.checklist_submissions%rowtype; prior record; entry jsonb; eligible_count int;
begin
  select * into strict c from private.operational_team_hygiene_context(actor_user_id,target_branch_id,target_operational_team_id,true);
  perform private.lock_operational_team_hygiene(c.branch_id,c.operational_team_id,c.business_date);
  if length(request_hash)<>64 or pg_catalog.jsonb_typeof(staff_answers)<>'array'
  then raise exception 'invalid submission' using errcode='22023'; end if;
  select count(*) into eligible_count from public.operational_staff_assignments assignment
  join public.operational_staff staff on staff.id=assignment.operational_staff_id
  left join public.operational_staff_duty_statuses duty on duty.assignment_id=assignment.id and duty.duty_date=c.business_date
  where assignment.operational_team_id=c.operational_team_id and assignment.active
    and assignment.valid_from<=c.business_date and (assignment.valid_to is null or assignment.valid_to>=c.business_date)
    and staff.employment_status='active' and coalesce(duty.duty_status,'on_duty')='on_duty';
  if pg_catalog.jsonb_array_length(staff_answers)<>eligible_count
    or (select count(distinct value->>'staff_id') from pg_catalog.jsonb_array_elements(staff_answers))<>eligible_count
  then raise exception 'staff set changed' using errcode='22023'; end if;
  for entry in select value from pg_catalog.jsonb_array_elements(staff_answers) loop
    if (select count(*) from pg_catalog.jsonb_object_keys(entry))<>6
      or entry->>'uniform' not in('pass','issue') or entry->>'fingernails' not in('pass','issue')
      or entry->>'hair' not in('pass','issue') or entry->>'facial_hair' not in('pass','issue')
      or ('issue'=any(array[entry->>'uniform',entry->>'fingernails',entry->>'hair',entry->>'facial_hair'])
        and length(pg_catalog.btrim(entry->>'remark'))=0)
      or not exists(select 1 from public.operational_staff_assignments assignment
        join public.operational_staff staff on staff.id=assignment.operational_staff_id
        left join public.operational_staff_duty_statuses duty on duty.assignment_id=assignment.id and duty.duty_date=c.business_date
        where staff.id=(entry->>'staff_id')::uuid and assignment.operational_team_id=c.operational_team_id
          and assignment.active and staff.employment_status='active' and coalesce(duty.duty_status,'on_duty')='on_duty')
    then raise exception 'invalid hygiene answer' using errcode='22023'; end if;
  end loop;
  insert into public.checklist_submission_idempotency(actor_user_id,idempotency_key,request_hash)
  values(actor_user_id,idempotency_key,request_hash) on conflict do nothing;
  select * into prior from public.checklist_submission_idempotency where
    checklist_submission_idempotency.actor_user_id=submit_operational_team_hygiene.actor_user_id
    and checklist_submission_idempotency.idempotency_key=submit_operational_team_hygiene.idempotency_key for update;
  if prior.request_hash<>request_hash then raise exception 'idempotency conflict' using errcode='23505'; end if;
  if prior.submission_id is not null then
    return query select existing.id,existing.business_date,existing.checklist_type,existing.state,existing.submitted_at,
      (select count(*) from public.checklist_issues issue where issue.source_submission_id=existing.id)
    from public.checklist_submissions existing where existing.id=prior.submission_id
      and existing.operational_team_id=c.operational_team_id;
    if found then return; end if;
    raise exception 'idempotency conflict' using errcode='23505';
  end if;
  if exists(select 1 from public.checklist_submissions existing where existing.organization_id=c.organization_id
    and existing.branch_id=c.branch_id and existing.operational_team_id=c.operational_team_id
    and existing.business_date=c.business_date and existing.checklist_type='staff_hygiene' and existing.state='submitted')
  then raise exception 'hygiene already submitted' using errcode='23505'; end if;
  insert into public.checklist_submissions(organization_id,branch_id,supervisor_user_id,supervisor_team_id,
    operational_team_id,operational_team_name_snapshot,submitted_by_user_id,hygiene_revision,business_date,
    checklist_type,definition_id,state,branch_name_snapshot,branch_code_snapshot,supervisor_name_snapshot,submitted_at)
  values(c.organization_id,c.branch_id,actor_user_id,c.legacy_team_id,c.operational_team_id,c.team_name,actor_user_id,1,
    c.business_date,'staff_hygiene','staff_hygiene_v1','submitted',c.branch_name,c.branch_code,c.supervisor_name,now())
  returning * into report;
  insert into public.hygiene_staff_snapshots(submission_id,operational_staff_id,display_name_snapshot,operational_roles_snapshot,
    remark,uniform_result,fingernails_result,hair_result,facial_hair_result)
  select report.id,staff.id,staff.display_name,assignment.operational_roles,entry.value->>'remark',entry.value->>'uniform',
    entry.value->>'fingernails',entry.value->>'hair',entry.value->>'facial_hair'
  from pg_catalog.jsonb_array_elements(staff_answers) entry(value)
  join public.operational_staff staff on staff.id=(entry.value->>'staff_id')::uuid
  join public.operational_staff_assignments assignment on assignment.operational_staff_id=staff.id
    and assignment.operational_team_id=c.operational_team_id and assignment.active;
  insert into public.checklist_issues(organization_id,branch_id,source_submission_id,hygiene_staff_snapshot_id,status,
    checklist_type,affected_staff_id,affected_staff_name_snapshot,remark)
  select report.organization_id,report.branch_id,report.id,snapshot.id,'new','staff_hygiene',snapshot.operational_staff_id,
    snapshot.display_name_snapshot,snapshot.remark from public.hygiene_staff_snapshots snapshot
  where snapshot.submission_id=report.id and 'issue'=any(array[snapshot.uniform_result,snapshot.fingernails_result,snapshot.hair_result,snapshot.facial_hair_result]);
  update public.checklist_submission_idempotency set submission_id=report.id where
    checklist_submission_idempotency.actor_user_id=submit_operational_team_hygiene.actor_user_id
    and checklist_submission_idempotency.idempotency_key=submit_operational_team_hygiene.idempotency_key;
  return query select report.id,report.business_date,report.checklist_type,report.state,report.submitted_at,
    (select count(*) from public.checklist_issues issue where issue.source_submission_id=report.id);
exception when no_data_found or too_many_rows then raise exception 'hygiene submission denied' using errcode='42501';
end $$;

-- Legacy Hygiene RPCs remain as compatibility wrappers, but resolve the durable default team.
create or replace function public.save_phase4a_hygiene_draft(actor_user_id uuid,target_branch_id uuid,staff_answers jsonb)
returns table(id uuid,business_date date,checklist_type text,state text,created_at timestamptz,updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare target_team uuid; current_revision bigint;
begin
  target_team:=private.actor_default_operational_team(actor_user_id,target_branch_id);
  select coalesce((public.get_operational_team_hygiene_current_state(actor_user_id,target_branch_id,target_team)->>'revision')::bigint,0)
    into current_revision;
  return query select result.id,result.business_date,result.checklist_type,result.state,result.created_at,result.updated_at
  from public.save_operational_team_hygiene_draft(actor_user_id,target_branch_id,target_team,current_revision,staff_answers) result;
exception when no_data_found or too_many_rows then raise exception 'draft denied' using errcode='42501';
end $$;

create or replace function public.submit_phase4a_hygiene(actor_user_id uuid,target_branch_id uuid,idempotency_key uuid,
  request_hash text,staff_answers jsonb)
returns table(id uuid,business_date date,checklist_type text,state text,submitted_at timestamptz,issue_count bigint)
language plpgsql security definer set search_path = '' as $$
declare target_team uuid;
begin
  target_team:=private.actor_default_operational_team(actor_user_id,target_branch_id);
  return query select * from public.submit_operational_team_hygiene(actor_user_id,target_branch_id,target_team,
    idempotency_key,request_hash,staff_answers);
exception when no_data_found or too_many_rows then raise exception 'submission denied' using errcode='42501';
end $$;

drop policy report_read on public.checklist_submissions;
create policy report_read on public.checklist_submissions for select to authenticated using(
  (checklist_type='staff_hygiene' and private.actor_can_read_operational_branch(auth.uid(),branch_id))
  or (supervisor_user_id=auth.uid() and private.actor_owns_operational_team(auth.uid(),branch_id,supervisor_team_id))
  or private.actor_manages_active_organization(auth.uid(),organization_id)
);

-- Employee-owned supporting records retain legacy columns only for compatibility/audit.
alter table public.operational_staff_health_cards drop constraint operational_staff_health_cards_team_staff_key;
alter table public.operational_staff_health_cards add constraint operational_staff_health_cards_staff_key unique(operational_staff_id);
alter table public.operational_staff_monthly_evaluations
  add column evaluated_by_user_id uuid references auth.users(id) on delete restrict;
update public.operational_staff_monthly_evaluations evaluation
set evaluated_by_user_id=team.supervisor_user_id from public.branch_supervisor_teams team
where team.id=evaluation.supervisor_team_id;
alter table public.operational_staff_monthly_evaluations alter column evaluated_by_user_id set not null;
alter table public.operational_staff_monthly_evaluations
  drop constraint operational_staff_monthly_evaluations_team_staff_month_key;
alter table public.operational_staff_monthly_evaluations
  add constraint operational_staff_monthly_evaluations_staff_month_key unique(operational_staff_id,evaluation_month);

create or replace function public.list_operational_staff_health_cards(actor_user_id uuid,target_branch_id uuid)
returns table(id uuid,operational_staff_id uuid,certificate_number text,status text,place_of_issue text,expiry_date date,
  date_issue date,occupation text,company text,branch_name_snapshot text,notes text,updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  if not private.actor_can_read_operational_branch(actor_user_id,target_branch_id)
  then raise exception 'health card access denied' using errcode='42501'; end if;
  return query select card.id,card.operational_staff_id,card.certificate_number,card.status,card.place_of_issue,
    card.expiry_date,card.date_issue,card.occupation,card.company,card.branch_name_snapshot,card.notes,card.updated_at
  from public.operational_staff_health_cards card join public.operational_staff staff on staff.id=card.operational_staff_id
  where staff.branch_id=target_branch_id order by pg_catalog.lower(staff.display_name),staff.id;
end $$;

create or replace function public.upsert_operational_staff_health_card(actor_user_id uuid,target_branch_id uuid,payload jsonb)
returns table(id uuid,operational_staff_id uuid,certificate_number text,status text,place_of_issue text,expiry_date date,
  date_issue date,occupation text,company text,branch_name_snapshot text,notes text,updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare target_staff_id uuid; assignment public.operational_staff_assignments%rowtype;
 new_status text:=coalesce(nullif(pg_catalog.btrim(payload->>'status'),''),'not_done');
 new_certificate text:=private.clean_health_card_optional_text(payload->>'certificate_number',120);
 new_place text:=private.clean_health_card_optional_text(payload->>'place_of_issue',120);
 new_expiry date:=private.health_card_payload_date(payload,'expiry_date'); new_issue date:=private.health_card_payload_date(payload,'date_issue');
 new_occupation text:=private.clean_health_card_optional_text(payload->>'occupation',120);
 new_company text:=private.clean_health_card_optional_text(payload->>'company',160);
 new_notes text:=private.clean_health_card_optional_text(payload->>'notes',2000); snapshot_branch text; staff_org uuid;
begin
  target_staff_id:=(payload->>'operational_staff_id')::uuid;
  select a.* into strict assignment from public.operational_staff_assignments a join public.operational_staff staff
    on staff.id=a.operational_staff_id where a.operational_staff_id=target_staff_id and a.active
      and staff.branch_id=target_branch_id and staff.employment_status='active' for update;
  if new_status not in('not_done','pending','passed','done_waiting_id')
    or not private.actor_can_write_operational_team(actor_user_id,target_branch_id,assignment.operational_team_id)
  then raise exception 'health card access denied' using errcode='42501'; end if;
  select branch.organization_id,branch.name into strict staff_org,snapshot_branch from public.branches branch
    where branch.id=target_branch_id and branch.active;
  return query insert into public.operational_staff_health_cards(organization_id,branch_id,supervisor_team_id,operational_staff_id,
    certificate_number,status,place_of_issue,expiry_date,date_issue,occupation,company,branch_name_snapshot,notes)
  values(staff_org,target_branch_id,assignment.supervisor_team_id,target_staff_id,new_certificate,new_status,new_place,new_expiry,
    new_issue,new_occupation,new_company,snapshot_branch,new_notes)
  on conflict on constraint operational_staff_health_cards_staff_key do update set
    supervisor_team_id=excluded.supervisor_team_id,certificate_number=excluded.certificate_number,status=excluded.status,
    place_of_issue=excluded.place_of_issue,expiry_date=excluded.expiry_date,date_issue=excluded.date_issue,
    occupation=excluded.occupation,company=excluded.company,branch_name_snapshot=excluded.branch_name_snapshot,
    notes=excluded.notes,updated_at=now()
  returning operational_staff_health_cards.id,operational_staff_health_cards.operational_staff_id,
    operational_staff_health_cards.certificate_number,operational_staff_health_cards.status,
    operational_staff_health_cards.place_of_issue,operational_staff_health_cards.expiry_date,
    operational_staff_health_cards.date_issue,operational_staff_health_cards.occupation,operational_staff_health_cards.company,
    operational_staff_health_cards.branch_name_snapshot,operational_staff_health_cards.notes,operational_staff_health_cards.updated_at;
exception when invalid_text_representation then raise exception 'invalid health card staff' using errcode='22023';
when no_data_found or too_many_rows then raise exception 'health card access denied' using errcode='42501';
end $$;

create or replace function public.list_operational_staff_monthly_evaluations(actor_user_id uuid,target_branch_id uuid,requested_month date)
returns table(id uuid,operational_staff_id uuid,evaluation_month date,evaluator_name text,status text,average_score numeric,scores jsonb,updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  if requested_month is null or requested_month<>pg_catalog.date_trunc('month',requested_month)::date
    or not private.actor_can_read_operational_branch(actor_user_id,target_branch_id)
  then raise exception 'monthly evaluation access denied' using errcode='42501'; end if;
  return query select evaluation.id,evaluation.operational_staff_id,evaluation.evaluation_month,evaluation.evaluator_name,
    evaluation.status,evaluation.average_score,coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'section',score.section,'factor_key',score.factor_key,'factor_label',score.factor_label,'rating',score.rating,
      'comment',score.comment) order by score.section,score.factor_key) filter(where score.id is not null),'[]'::jsonb),evaluation.updated_at
  from public.operational_staff_monthly_evaluations evaluation
  join public.operational_staff staff on staff.id=evaluation.operational_staff_id
  left join public.operational_staff_monthly_evaluation_scores score on score.evaluation_id=evaluation.id
  where staff.branch_id=target_branch_id and evaluation.evaluation_month=requested_month
  group by evaluation.id order by evaluation.updated_at desc,evaluation.id;
end $$;

create or replace function public.save_operational_staff_monthly_evaluation(actor_user_id uuid,target_branch_id uuid,
  target_staff_id uuid,requested_month date,new_evaluator_name text,score_payload jsonb,new_status text)
returns table(id uuid,operational_staff_id uuid,evaluation_month date,evaluator_name text,status text,average_score numeric,scores jsonb,updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare assignment public.operational_staff_assignments%rowtype; saved_id uuid; computed_average numeric;
 clean_evaluator text:=private.clean_monthly_evaluation_text(new_evaluator_name,120); completed boolean:=new_status='completed';
begin
  if requested_month is null or requested_month<>pg_catalog.date_trunc('month',requested_month)::date
    or new_status not in('draft','completed') then raise exception 'invalid monthly evaluation' using errcode='22023'; end if;
  if pg_catalog.to_regclass('pg_temp.monthly_score_payload') is not null then drop table monthly_score_payload; end if;
  create temporary table monthly_score_payload(section text,factor_key text,factor_label text,rating integer,comment text) on commit drop;
  insert into monthly_score_payload select parsed.section,parsed.factor_key,parsed.factor_label,parsed.rating,parsed.comment
    from private.monthly_evaluation_scores(score_payload,completed) parsed;
  select case when count(rating)=0 then null else pg_catalog.round(avg(rating)::numeric,2) end into computed_average
    from monthly_score_payload;
  select a.* into strict assignment from public.operational_staff_assignments a join public.operational_staff staff
    on staff.id=a.operational_staff_id where a.operational_staff_id=target_staff_id and a.active
      and staff.branch_id=target_branch_id and staff.employment_status='active' for update;
  if not private.actor_can_write_operational_team(actor_user_id,target_branch_id,assignment.operational_team_id)
  then raise exception 'monthly evaluation access denied' using errcode='42501'; end if;
  insert into public.operational_staff_monthly_evaluations(organization_id,branch_id,supervisor_team_id,operational_staff_id,
    evaluation_month,evaluator_name,status,average_score,evaluated_by_user_id)
  select staff.organization_id,target_branch_id,assignment.supervisor_team_id,target_staff_id,requested_month,clean_evaluator,
    new_status,computed_average,actor_user_id from public.operational_staff staff where staff.id=target_staff_id
  on conflict on constraint operational_staff_monthly_evaluations_staff_month_key do update set
    supervisor_team_id=excluded.supervisor_team_id,evaluator_name=excluded.evaluator_name,status=excluded.status,
    average_score=excluded.average_score,evaluated_by_user_id=excluded.evaluated_by_user_id,updated_at=now()
  returning operational_staff_monthly_evaluations.id into saved_id;
  delete from public.operational_staff_monthly_evaluation_scores where evaluation_id=saved_id;
  insert into public.operational_staff_monthly_evaluation_scores(evaluation_id,section,factor_key,factor_label,rating,comment)
    select saved_id,payload.section,payload.factor_key,payload.factor_label,payload.rating,payload.comment from monthly_score_payload payload;
  return query select evaluation.id,evaluation.operational_staff_id,evaluation.evaluation_month,evaluation.evaluator_name,
    evaluation.status,evaluation.average_score,coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'section',score.section,'factor_key',score.factor_key,'factor_label',score.factor_label,'rating',score.rating,
      'comment',score.comment) order by score.section,score.factor_key) filter(where score.id is not null),'[]'::jsonb),evaluation.updated_at
  from public.operational_staff_monthly_evaluations evaluation
  left join public.operational_staff_monthly_evaluation_scores score on score.evaluation_id=evaluation.id
  where evaluation.id=saved_id group by evaluation.id;
exception when no_data_found or too_many_rows then raise exception 'monthly evaluation access denied' using errcode='42501';
end $$;

-- Harden all Phase 4A persistence ACLs: RLS is not a TRUNCATE boundary.
revoke all on public.checklist_submissions,public.hygiene_staff_snapshots,public.opening_item_results,
  public.checklist_issues,public.checklist_submission_idempotency from public,anon,authenticated,service_role;
grant select on public.checklist_submissions,public.hygiene_staff_snapshots,public.opening_item_results,public.checklist_issues to authenticated;

revoke all on function private.normalize_operational_team_name(text),private.operational_team_default_name(bigint),
  private.validate_branch_operational_team_supervisor(),private.populate_operational_assignment_team(),
  private.actor_can_read_operational_branch(uuid,uuid),private.actor_can_write_operational_team(uuid,uuid,uuid),
  private.actor_default_operational_team(uuid,uuid),private.sync_legacy_supervisor_operational_team(),
  private.lock_operational_team_hygiene(uuid,uuid,date),private.operational_team_hygiene_context(uuid,uuid,uuid,boolean)
  from public,anon,authenticated;
grant execute on function private.actor_can_read_operational_branch(uuid,uuid) to authenticated;
revoke all on function public.get_supervisor_operational_team(uuid,uuid,date),
  public.create_operational_team_staff(uuid,uuid,uuid,text,text[],text,text,text,date,text,text),
  public.update_operational_team_staff(uuid,uuid,uuid,text,text,text[],text,text,text,date,text,text),
  public.set_operational_team_staff_duty(uuid,uuid,uuid,date,text),
  public.move_operational_staff_team(uuid,uuid,uuid,uuid,uuid),
  public.assign_operational_team_supervisor(uuid,uuid,uuid,uuid,text),
  public.get_operational_team_hygiene_current_state(uuid,uuid,uuid),
  public.save_operational_team_hygiene_draft(uuid,uuid,uuid,bigint,jsonb),
  public.submit_operational_team_hygiene(uuid,uuid,uuid,uuid,text,jsonb),
  public.save_phase4a_hygiene_draft(uuid,uuid,jsonb),public.submit_phase4a_hygiene(uuid,uuid,uuid,text,jsonb),
  public.list_operational_staff_health_cards(uuid,uuid),public.upsert_operational_staff_health_card(uuid,uuid,jsonb),
  public.list_operational_staff_monthly_evaluations(uuid,uuid,date),
  public.save_operational_staff_monthly_evaluation(uuid,uuid,uuid,date,text,jsonb,text)
  from public,anon,authenticated;
grant execute on function public.get_supervisor_operational_team(uuid,uuid,date),
  public.create_operational_team_staff(uuid,uuid,uuid,text,text[],text,text,text,date,text,text),
  public.update_operational_team_staff(uuid,uuid,uuid,text,text,text[],text,text,text,date,text,text),
  public.set_operational_team_staff_duty(uuid,uuid,uuid,date,text),
  public.move_operational_staff_team(uuid,uuid,uuid,uuid,uuid),
  public.assign_operational_team_supervisor(uuid,uuid,uuid,uuid,text),
  public.get_operational_team_hygiene_current_state(uuid,uuid,uuid),
  public.save_operational_team_hygiene_draft(uuid,uuid,uuid,bigint,jsonb),
  public.submit_operational_team_hygiene(uuid,uuid,uuid,uuid,text,jsonb),
  public.save_phase4a_hygiene_draft(uuid,uuid,jsonb),public.submit_phase4a_hygiene(uuid,uuid,uuid,text,jsonb),
  public.list_operational_staff_health_cards(uuid,uuid),public.upsert_operational_staff_health_card(uuid,uuid,jsonb),
  public.list_operational_staff_monthly_evaluations(uuid,uuid,date),
  public.save_operational_staff_monthly_evaluation(uuid,uuid,uuid,date,text,jsonb,text)
  to service_role;
