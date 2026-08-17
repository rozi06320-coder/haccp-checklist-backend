comment on table public.branch_shifts is
  'Deprecated compatibility data. Current operational teams and staff assignments are not scheduled by shift.';

do $$
begin
  if exists (
    select 1 from public.branch_supervisor_teams
    where active
    group by supervisor_user_id, branch_id
    having count(*) > 1
  ) then
    raise exception 'shift-free migration blocked: multiple active teams exist for one supervisor and branch'
      using errcode = '23514';
  end if;
end $$;

drop index public.branch_supervisor_teams_active_assignment_key;
drop index public.operational_staff_assignments_active_key;
alter table public.operational_staff_assignments
  drop constraint operational_staff_assignments_team_scope_fkey;
alter table public.branch_supervisor_teams
  drop constraint branch_supervisor_teams_shift_scope_fkey;
alter table public.branch_supervisor_teams alter column shift_id drop not null;
alter table public.operational_staff_assignments alter column shift_id drop not null;
alter table public.branch_supervisor_teams
  add constraint branch_supervisor_teams_id_branch_organization_key
  unique (id, branch_id, organization_id);
alter table public.operational_staff_assignments
  add constraint operational_staff_assignments_team_scope_fkey
  foreign key (supervisor_team_id, branch_id, organization_id)
  references public.branch_supervisor_teams(id, branch_id, organization_id) on delete restrict;
create unique index branch_supervisor_teams_active_supervisor_branch_key
  on public.branch_supervisor_teams(supervisor_user_id, branch_id) where active;
create unique index operational_staff_assignments_active_team_key
  on public.operational_staff_assignments(operational_staff_id, supervisor_team_id) where active;

comment on column public.branch_supervisor_teams.shift_id is
  'Deprecated historical reference. Null for current shift-free supervisor teams.';
comment on column public.operational_staff_assignments.shift_id is
  'Deprecated historical reference. Null for current shift-free staff assignments.';

create or replace function private.actor_owns_operational_team(actor uuid,target_branch uuid,target_team uuid default null)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles profile
    join public.branch_memberships membership on membership.user_id=profile.id
    join public.branches branch on branch.id=membership.branch_id
    join public.organizations organization on organization.id=branch.organization_id
    join public.branch_supervisor_teams team
      on team.branch_id=branch.id and team.supervisor_user_id=profile.id
    where profile.id=actor and profile.disabled_at is null and not profile.must_change_password
      and membership.branch_id=target_branch and membership.role='branch_manager' and membership.active
      and branch.active and organization.active and team.active
      and (target_team is null or team.id=target_team)
  );
$$;

create or replace function private.validate_operational_team()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.branch_memberships membership
    join public.profiles profile on profile.id=membership.user_id
    join public.branches branch on branch.id=membership.branch_id
    join public.organizations organization on organization.id=branch.organization_id
    where membership.branch_id=new.branch_id and membership.user_id=new.supervisor_user_id
      and membership.role='branch_manager'
      and branch.organization_id=new.organization_id
      and (not new.active or (
        membership.active and profile.disabled_at is null and branch.active and organization.active
      ))
  ) then raise exception 'invalid supervisor team scope' using errcode='23514'; end if;
  return new;
end $$;

create or replace function private.validate_operational_assignment()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if not private.operational_roles_are_valid(new.operational_roles)
    or not exists (
      select 1 from public.operational_staff staff
      join public.branch_supervisor_teams team on team.id=new.supervisor_team_id
      join public.branches branch on branch.id=new.branch_id
      join public.organizations organization on organization.id=new.organization_id
      where staff.id=new.operational_staff_id
        and staff.branch_id=new.branch_id and staff.organization_id=new.organization_id
        and team.branch_id=new.branch_id and team.organization_id=new.organization_id
        and (not new.active or (
          staff.employment_status='active' and team.active and branch.active and organization.active
        ))
    )
  then raise exception 'invalid operational assignment scope' using errcode='23514'; end if;
  return new;
end $$;

drop function public.get_supervisor_operational_team(uuid,uuid,date);
create function public.get_supervisor_operational_team(actor_user_id uuid,target_branch_id uuid,requested_date date)
returns table(team_id uuid,staff_id uuid,display_name text,employment_status text,
  assignment_id uuid,operational_roles text[],duty_status text)
language plpgsql security definer set search_path = ''
as $$
begin
  if requested_date is null or not private.actor_owns_operational_team(actor_user_id,target_branch_id,null)
  then raise exception 'team access denied' using errcode='42501'; end if;
  return query select team.id,staff.id,staff.display_name,staff.employment_status,
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
  new_display_name text,new_operational_roles text[])
returns table(staff_id uuid,assignment_id uuid,duplicate_name_warning boolean)
language plpgsql security definer set search_path = ''
as $$
declare target_team public.branch_supervisor_teams%rowtype; created_staff uuid; created_assignment uuid;
 clean_name text := pg_catalog.regexp_replace(pg_catalog.btrim(new_display_name),'[[:space:]]+',' ','g');
begin
 select team.* into strict target_team from public.branch_supervisor_teams team
  where team.supervisor_user_id=actor_user_id and team.branch_id=target_branch_id and team.active;
 if not private.actor_owns_operational_team(actor_user_id,target_branch_id,target_team.id)
  or length(clean_name) not between 1 and 120
  or not private.operational_roles_are_valid(new_operational_roles)
 then raise exception 'staff operation denied' using errcode='42501'; end if;
 insert into public.operational_staff(organization_id,branch_id,display_name,created_by)
  values(target_team.organization_id,target_branch_id,clean_name,actor_user_id) returning id into created_staff;
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
   and staff.normalized_name=private.normalize_operational_staff_name(clean_name));
exception when no_data_found or too_many_rows then
 raise exception 'staff operation denied' using errcode='42501';
end $$;

create function public.update_supervisor_operational_staff(actor_user_id uuid,target_branch_id uuid,
 target_staff_id uuid,new_display_name text,new_employment_status text,new_operational_roles text[])
returns table(staff_id uuid,assignment_id uuid,duplicate_name_warning boolean)
language plpgsql security definer set search_path = ''
as $$
declare staff_row public.operational_staff%rowtype; assignment_row public.operational_staff_assignments%rowtype;
 clean_name text := pg_catalog.regexp_replace(pg_catalog.btrim(new_display_name),'[[:space:]]+',' ','g');
begin
 select staff.* into strict staff_row from public.operational_staff staff
  where staff.id=target_staff_id and staff.branch_id=target_branch_id;
 select assignment.* into strict assignment_row from public.operational_staff_assignments assignment
  where assignment.operational_staff_id=target_staff_id and assignment.active;
 if not private.actor_owns_operational_team(actor_user_id,target_branch_id,assignment_row.supervisor_team_id)
  or new_employment_status not in ('active','inactive') or length(clean_name) not between 1 and 120
  or not private.operational_roles_are_valid(new_operational_roles)
 then raise exception 'staff operation denied' using errcode='42501'; end if;
 update public.operational_staff set display_name=clean_name,employment_status=new_employment_status,
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
   and staff.normalized_name=private.normalize_operational_staff_name(clean_name));
exception when no_data_found or too_many_rows then
 raise exception 'staff operation denied' using errcode='42501';
end $$;

drop function public.list_managed_operational_staff(uuid,uuid,integer,integer,text,uuid,uuid,uuid,text,text,date);
create function public.list_managed_operational_staff(actor_user_id uuid,target_organization_id uuid,
 requested_page integer default 1,requested_page_size integer default 20,search_term text default null,
 branch_filter uuid default null,supervisor_filter uuid default null,role_filter text default null,
 employment_filter text default null,requested_date date default null)
returns table(staff_id uuid,display_name text,employment_status text,branch_id uuid,branch_name text,
 supervisor_user_id uuid,supervisor_name text,team_id uuid,assignment_id uuid,
 operational_roles text[],duty_status text,total_count bigint)
language plpgsql security definer set search_path = ''
as $$
begin
 if requested_page<1 or requested_page_size not between 1 and 50 or length(coalesce(search_term,''))>120
  or (role_filter is not null and role_filter not in ('kitchen','packaging','front_of_house','cleaner'))
  or (employment_filter is not null and employment_filter not in ('active','inactive'))
  or not private.actor_manages_active_organization(actor_user_id,target_organization_id)
 then raise exception 'listing denied' using errcode='42501'; end if;
 return query select staff.id,staff.display_name,staff.employment_status,branch.id,branch.name,
  team.supervisor_user_id,profile.full_name,team.id,assignment.id,assignment.operational_roles,
  coalesce(duty.duty_status,'on_duty'),count(*) over()
 from public.operational_staff staff join public.branches branch on branch.id=staff.branch_id
 left join public.operational_staff_assignments assignment
  on assignment.operational_staff_id=staff.id and assignment.active
 left join public.branch_supervisor_teams team on team.id=assignment.supervisor_team_id
 left join public.profiles profile on profile.id=team.supervisor_user_id
 left join public.operational_staff_duty_statuses duty
  on duty.assignment_id=assignment.id and duty.duty_date=requested_date
 where staff.organization_id=target_organization_id
  and (nullif(btrim(search_term),'') is null
    or staff.normalized_name like '%'||private.normalize_operational_staff_name(search_term)||'%')
  and (branch_filter is null or staff.branch_id=branch_filter)
  and (supervisor_filter is null or team.supervisor_user_id=supervisor_filter)
  and (role_filter is null or assignment.operational_roles @> array[role_filter])
  and (employment_filter is null or staff.employment_status=employment_filter)
 order by staff.normalized_name,staff.id limit requested_page_size
 offset ((requested_page-1)::bigint*requested_page_size);
end $$;

drop function public.list_managed_supervisor_teams(uuid,uuid);
create function public.list_managed_supervisor_teams(actor_user_id uuid,target_organization_id uuid)
returns table(team_id uuid,branch_id uuid,branch_name text,supervisor_user_id uuid,
 supervisor_name text,active boolean,operational_staff_count bigint)
language plpgsql security definer set search_path = ''
as $$
begin
 if not private.actor_manages_active_organization(actor_user_id,target_organization_id)
 then raise exception 'listing denied' using errcode='42501'; end if;
 return query select team.id,branch.id,branch.name,team.supervisor_user_id,profile.full_name,team.active,
  count(assignment.id) filter(where assignment.active)
 from public.branch_supervisor_teams team join public.branches branch on branch.id=team.branch_id
 join public.profiles profile on profile.id=team.supervisor_user_id
 left join public.operational_staff_assignments assignment on assignment.supervisor_team_id=team.id
 where team.organization_id=target_organization_id
 group by team.id,branch.id,branch.name,profile.full_name
 order by branch.name,profile.full_name,team.id limit 500;
end $$;

create or replace function public.list_eligible_branch_supervisors(actor_user_id uuid,
 target_organization_id uuid,target_branch_id uuid)
returns table(user_id uuid,full_name text,assignments jsonb)
language plpgsql security definer set search_path = ''
as $$
begin
 if not private.managed_active_branch(actor_user_id,target_organization_id,target_branch_id)
 then raise exception 'supervisor listing denied' using errcode='42501'; end if;
 return query select profile.id,profile.full_name,
  coalesce((select jsonb_agg(jsonb_build_object('team_id',team.id,'active',team.active)
    order by team.id) from public.branch_supervisor_teams team
    where team.supervisor_user_id=profile.id and team.branch_id=target_branch_id),'[]'::jsonb)
 from public.branch_memberships membership join public.profiles profile on profile.id=membership.user_id
 where membership.branch_id=target_branch_id and membership.role='branch_manager'
  and membership.active and profile.disabled_at is null and not profile.must_change_password
 order by lower(coalesce(profile.full_name,'')),profile.id limit 200;
end $$;

create function public.create_managed_supervisor_team(actor_user_id uuid,target_organization_id uuid,
 target_branch_id uuid,target_supervisor_user_id uuid)
returns table(id uuid,supervisor_user_id uuid,active boolean)
language plpgsql security definer set search_path = ''
as $$
declare created public.branch_supervisor_teams%rowtype;
begin
 if not private.managed_active_branch(actor_user_id,target_organization_id,target_branch_id)
  or not exists(select 1 from public.profiles profile
   join public.branch_memberships membership on membership.user_id=profile.id
   where profile.id=target_supervisor_user_id and profile.disabled_at is null
    and not profile.must_change_password
    and membership.branch_id=target_branch_id and membership.role='branch_manager' and membership.active)
 then raise exception 'team operation denied' using errcode='42501'; end if;
 select team.* into created from public.branch_supervisor_teams team
  where team.supervisor_user_id=target_supervisor_user_id and team.branch_id=target_branch_id and team.active;
 if created.id is null then
  insert into public.branch_supervisor_teams(organization_id,branch_id,supervisor_user_id)
   values(target_organization_id,target_branch_id,target_supervisor_user_id) returning * into created;
  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
   values(target_organization_id,actor_user_id,target_branch_id,'supervisor_team_assigned',
    jsonb_build_object('team_id',created.id,'new_status','active'));
 end if;
 return query select created.id,created.supervisor_user_id,created.active;
end $$;

create function public.update_managed_supervisor_team(actor_user_id uuid,target_organization_id uuid,
 target_branch_id uuid,target_team_id uuid,new_active boolean)
returns table(id uuid,supervisor_user_id uuid,active boolean)
language plpgsql security definer set search_path = ''
as $$
declare current_team public.branch_supervisor_teams%rowtype; previous_active boolean;
begin
 if not private.managed_active_branch(actor_user_id,target_organization_id,target_branch_id)
 then raise exception 'team operation denied' using errcode='42501'; end if;
 select team.* into strict current_team from public.branch_supervisor_teams team
  where team.id=target_team_id and team.organization_id=target_organization_id
   and team.branch_id=target_branch_id for update;
 previous_active:=current_team.active; new_active:=coalesce(new_active,current_team.active);
 if current_team.active and not new_active and exists(
  select 1 from public.operational_staff_assignments assignment
  where assignment.supervisor_team_id=target_team_id and assignment.active)
 then raise exception 'team has active dependencies' using errcode='23514'; end if;
 update public.branch_supervisor_teams team set active=new_active
  where team.id=target_team_id returning team.* into current_team;
 insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
 values(target_organization_id,actor_user_id,target_branch_id,
  case when previous_active and not new_active then 'supervisor_team_deactivated' else 'supervisor_team_assigned' end,
  jsonb_build_object('team_id',target_team_id,
   'previous_status',case when previous_active then 'active' else 'inactive' end,
   'new_status',case when new_active then 'active' else 'inactive' end));
 return query select current_team.id,current_team.supervisor_user_id,current_team.active;
exception when no_data_found then raise exception 'team operation denied' using errcode='42501';
end $$;

create or replace function public.finalize_provisioned_supervisor(
 p_actor_user_id uuid,p_organization_id uuid,p_new_user_id uuid,p_full_name text,p_branch_ids uuid[])
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare result jsonb;
begin
 result:=public.finalize_provisioned_user(
  p_actor_user_id,p_organization_id,p_new_user_id,p_full_name,'branch_manager',p_branch_ids);
 insert into public.branch_supervisor_teams(organization_id,branch_id,supervisor_user_id)
 select p_organization_id,branch_id,p_new_user_id from unnest(p_branch_ids) branch_id
 where not exists(select 1 from public.branch_supervisor_teams team
  where team.supervisor_user_id=p_new_user_id and team.branch_id=branch_id and team.active);
 return result;
end $$;

revoke all on function public.list_managed_branch_shifts(uuid,uuid,uuid),
 public.create_managed_branch_shift(uuid,uuid,uuid,text,time,time),
 public.update_managed_branch_shift(uuid,uuid,uuid,uuid,text,time,time,boolean),
 public.create_managed_supervisor_team(uuid,uuid,uuid,uuid,uuid),
 public.update_managed_supervisor_team(uuid,uuid,uuid,uuid,uuid,boolean),
 public.create_supervisor_operational_staff(uuid,uuid,text,uuid,text[]),
 public.update_supervisor_operational_staff(uuid,uuid,uuid,text,text,uuid,text[])
 from service_role;
comment on function public.create_supervisor_operational_staff(uuid,uuid,text,uuid,text[]) is
 'Deprecated service-role compatibility overload. Current API uses the shift-free overload.';
comment on function public.update_supervisor_operational_staff(uuid,uuid,uuid,text,text,uuid,text[]) is
 'Deprecated service-role compatibility overload. Current API uses the shift-free overload.';
grant execute on function public.create_supervisor_operational_staff(uuid,uuid,text,uuid,text[]),
 public.update_supervisor_operational_staff(uuid,uuid,uuid,text,text,uuid,text[]) to service_role;
revoke all on function public.get_supervisor_operational_team(uuid,uuid,date),
 public.create_supervisor_operational_staff(uuid,uuid,text,text[]),
 public.update_supervisor_operational_staff(uuid,uuid,uuid,text,text,text[]),
 public.list_managed_operational_staff(uuid,uuid,integer,integer,text,uuid,uuid,text,text,date),
 public.list_managed_supervisor_teams(uuid,uuid),
 public.list_eligible_branch_supervisors(uuid,uuid,uuid),
 public.create_managed_supervisor_team(uuid,uuid,uuid,uuid),
 public.update_managed_supervisor_team(uuid,uuid,uuid,uuid,boolean)
 from public,anon,authenticated;
grant execute on function public.get_supervisor_operational_team(uuid,uuid,date),
 public.create_supervisor_operational_staff(uuid,uuid,text,text[]),
 public.update_supervisor_operational_staff(uuid,uuid,uuid,text,text,text[]),
 public.list_managed_operational_staff(uuid,uuid,integer,integer,text,uuid,uuid,text,text,date),
 public.list_managed_supervisor_teams(uuid,uuid),
 public.list_eligible_branch_supervisors(uuid,uuid,uuid),
 public.create_managed_supervisor_team(uuid,uuid,uuid,uuid),
 public.update_managed_supervisor_team(uuid,uuid,uuid,uuid,boolean)
 to service_role;
