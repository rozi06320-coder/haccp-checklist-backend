alter table public.organizations
  add column active boolean not null default true;
alter table public.branch_memberships
  add column active boolean not null default true;

comment on column public.organizations.active is
  'Defaults existing and new organizations to active; explicit deactivation is enforced by authorization helpers.';
comment on column public.branch_memberships.active is
  'Defaults existing and new branch memberships to active; explicit deactivation is enforced by authorization helpers.';

create or replace function private.is_organization_manager(target_organization_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.organization_memberships membership
    join public.organizations organization on organization.id=membership.organization_id
    where membership.organization_id=target_organization_id
      and membership.user_id=auth.uid()
      and membership.role='organization_manager'
      and organization.active
  );
$$;

create or replace function private.has_branch_access(target_branch_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from public.branch_memberships membership
    join public.branches branch on branch.id=membership.branch_id
    join public.organizations organization on organization.id=branch.organization_id
    where membership.branch_id=target_branch_id
      and membership.user_id=auth.uid()
      and membership.role in ('staff','branch_manager')
      and membership.active and branch.active and organization.active
  )
  or exists (
    select 1
    from public.branches branch
    join public.organizations organization on organization.id=branch.organization_id
    join public.organization_memberships membership on membership.organization_id=branch.organization_id
    where branch.id=target_branch_id and branch.active and organization.active
      and membership.user_id=auth.uid() and membership.role='organization_manager'
  );
$$;

create or replace function private.has_organization_access(target_organization_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select private.is_organization_manager(target_organization_id)
  or exists (
    select 1
    from public.branches branch
    join public.organizations organization on organization.id=branch.organization_id
    join public.branch_memberships membership on membership.branch_id=branch.id
    where branch.organization_id=target_organization_id
      and membership.user_id=auth.uid()
      and membership.role in ('staff','branch_manager')
      and membership.active and branch.active and organization.active
  );
$$;

create or replace function private.actor_can_manage_branch(actor uuid,target_branch uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles profile
    where profile.id=actor and profile.disabled_at is null and not profile.must_change_password
  ) and (
    exists (
      select 1 from public.branch_memberships membership
      join public.branches branch on branch.id=membership.branch_id
      join public.organizations organization on organization.id=branch.organization_id
      where membership.user_id=actor and membership.branch_id=target_branch
        and membership.role='branch_manager' and membership.active
        and branch.active and organization.active
    ) or exists (
      select 1 from public.branches branch
      join public.organizations organization on organization.id=branch.organization_id
      join public.organization_memberships membership on membership.organization_id=branch.organization_id
      where branch.id=target_branch and branch.active and organization.active
        and membership.user_id=actor and membership.role='organization_manager'
    )
  );
$$;

create or replace function private.actor_can_access_branch(actor uuid,target_branch uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles profile
    where profile.id=actor and profile.disabled_at is null and not profile.must_change_password
  ) and (
    exists (
      select 1 from public.branch_memberships membership
      join public.branches branch on branch.id=membership.branch_id
      join public.organizations organization on organization.id=branch.organization_id
      where membership.user_id=actor and membership.branch_id=target_branch
        and membership.active and branch.active and organization.active
    ) or exists (
      select 1 from public.branches branch
      join public.organizations organization on organization.id=branch.organization_id
      join public.organization_memberships membership on membership.organization_id=branch.organization_id
      where branch.id=target_branch and branch.active and organization.active
        and membership.user_id=actor and membership.role='organization_manager'
    )
  );
$$;

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
    join public.branch_shifts shift on shift.id=team.shift_id
    where profile.id=actor and profile.disabled_at is null and not profile.must_change_password
      and membership.branch_id=target_branch and membership.role='branch_manager' and membership.active
      and branch.active and organization.active and team.active and shift.active
      and (target_team is null or team.id=target_team)
  );
$$;
revoke all on function private.actor_owns_operational_team(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function private.actor_owns_operational_team(uuid,uuid,uuid) to authenticated;

create or replace function private.validate_operational_team()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.branch_memberships membership
    join public.profiles profile on profile.id=membership.user_id
    join public.branches branch on branch.id=membership.branch_id
    join public.organizations organization on organization.id=branch.organization_id
    join public.branch_shifts shift on shift.id=new.shift_id
    where membership.branch_id=new.branch_id and membership.user_id=new.supervisor_user_id
      and membership.role='branch_manager' and membership.active
      and profile.disabled_at is null and not profile.must_change_password
      and branch.organization_id=new.organization_id and branch.active and organization.active
      and shift.branch_id=new.branch_id and shift.organization_id=new.organization_id
      and (not new.active or shift.active)
  ) then raise exception 'invalid supervisor team scope' using errcode='23514'; end if;
  return new;
end $$;
revoke all on function private.validate_operational_team() from public,anon,authenticated;

drop index public.branch_shifts_name_ci_key;
alter table public.branch_shifts drop constraint branch_shifts_name_check;
alter table public.branch_shifts add constraint branch_shifts_name_check check (
  name = pg_catalog.regexp_replace(pg_catalog.btrim(name), '[[:space:]]+', ' ', 'g')
  and pg_catalog.length(name) between 1 and 80
);
create unique index branch_shifts_active_name_ci_key
  on public.branch_shifts(branch_id,pg_catalog.lower(name)) where active;

create function private.actor_manages_active_organization(actor uuid,target_organization uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles profile
    join public.organization_memberships membership on membership.user_id=profile.id
    join public.organizations organization on organization.id=membership.organization_id
    where profile.id=actor and profile.disabled_at is null and not profile.must_change_password
      and membership.organization_id=target_organization
      and membership.role='organization_manager' and organization.active
  );
$$;
revoke all on function private.actor_manages_active_organization(uuid,uuid) from public,anon,authenticated;

create function private.managed_active_branch(actor uuid,target_organization uuid,target_branch uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select private.actor_manages_active_organization(actor,target_organization)
    and exists (
      select 1 from public.branches branch
      where branch.id=target_branch and branch.organization_id=target_organization and branch.active
    );
$$;
revoke all on function private.managed_active_branch(uuid,uuid,uuid) from public,anon,authenticated;

create function public.list_managed_branch_shifts(actor_user_id uuid,target_organization_id uuid,target_branch_id uuid)
returns table(id uuid,name text,start_time time,end_time time,active boolean,
  active_supervisor_team_count bigint,active_staff_assignment_count bigint)
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.managed_active_branch(actor_user_id,target_organization_id,target_branch_id)
  then raise exception 'shift access denied' using errcode='42501'; end if;
  return query select shift.id,shift.name,shift.start_time,shift.end_time,shift.active,
    (select pg_catalog.count(*) from public.branch_supervisor_teams team
      where team.shift_id=shift.id and team.active),
    (select pg_catalog.count(*) from public.operational_staff_assignments assignment
      where assignment.shift_id=shift.id and assignment.active)
  from public.branch_shifts shift
  where shift.organization_id=target_organization_id and shift.branch_id=target_branch_id
  order by shift.start_time,pg_catalog.lower(shift.name),shift.id limit 200;
end $$;

create function public.create_managed_branch_shift(actor_user_id uuid,target_organization_id uuid,
  target_branch_id uuid,new_name text,new_start_time time,new_end_time time)
returns table(id uuid,name text,start_time time,end_time time,active boolean)
language plpgsql security definer set search_path = ''
as $$
declare clean_name text := pg_catalog.regexp_replace(pg_catalog.btrim(new_name),'[[:space:]]+',' ','g');
 created public.branch_shifts%rowtype;
begin
  if not private.managed_active_branch(actor_user_id,target_organization_id,target_branch_id)
    or pg_catalog.length(clean_name) not between 1 and 80
    or new_start_time is null or new_end_time is null or new_start_time=new_end_time
  then raise exception 'shift operation denied' using errcode='42501'; end if;
  insert into public.branch_shifts(organization_id,branch_id,name,start_time,end_time)
    values(target_organization_id,target_branch_id,clean_name,new_start_time,new_end_time)
    returning * into created;
  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
    values(target_organization_id,actor_user_id,target_branch_id,'branch_shift_created',
      pg_catalog.jsonb_build_object('shift_id',created.id,'new_status','active'));
  return query select created.id,created.name,created.start_time,created.end_time,created.active;
end $$;

create function public.update_managed_branch_shift(actor_user_id uuid,target_organization_id uuid,
  target_branch_id uuid,target_shift_id uuid,new_name text,new_start_time time,new_end_time time,new_active boolean)
returns table(id uuid,name text,start_time time,end_time time,active boolean)
language plpgsql security definer set search_path = ''
as $$
declare current_shift public.branch_shifts%rowtype;
 clean_name text; previous_active boolean;
begin
  if not private.managed_active_branch(actor_user_id,target_organization_id,target_branch_id)
  then raise exception 'shift operation denied' using errcode='42501'; end if;
  select shift.* into strict current_shift from public.branch_shifts shift
    where shift.id=target_shift_id and shift.organization_id=target_organization_id
      and shift.branch_id=target_branch_id for update;
  previous_active := current_shift.active;
  clean_name := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(new_name,current_shift.name)),'[[:space:]]+',' ','g');
  new_start_time := coalesce(new_start_time,current_shift.start_time);
  new_end_time := coalesce(new_end_time,current_shift.end_time);
  new_active := coalesce(new_active,current_shift.active);
  if pg_catalog.length(clean_name) not between 1 and 80
    or new_start_time is null or new_end_time is null or new_start_time=new_end_time
  then raise exception 'invalid shift input' using errcode='22023'; end if;
  if current_shift.active and not new_active and (
    exists(select 1 from public.branch_supervisor_teams team where team.shift_id=target_shift_id and team.active)
    or exists(select 1 from public.operational_staff_assignments assignment where assignment.shift_id=target_shift_id and assignment.active)
  ) then raise exception 'shift has active dependencies' using errcode='23514'; end if;
  update public.branch_shifts shift set name=clean_name,start_time=new_start_time,
    end_time=new_end_time,active=new_active where shift.id=target_shift_id returning * into current_shift;
  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
    values(target_organization_id,actor_user_id,target_branch_id,'branch_shift_updated',
      pg_catalog.jsonb_build_object('shift_id',target_shift_id,
        'previous_status',case when previous_active then 'active' else 'inactive' end,
        'new_status',case when new_active then 'active' else 'inactive' end));
  return query select current_shift.id,current_shift.name,current_shift.start_time,current_shift.end_time,current_shift.active;
exception when no_data_found then raise exception 'shift operation denied' using errcode='42501';
end $$;

create function public.list_eligible_branch_supervisors(actor_user_id uuid,target_organization_id uuid,target_branch_id uuid)
returns table(user_id uuid,full_name text,assignments jsonb)
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.managed_active_branch(actor_user_id,target_organization_id,target_branch_id)
  then raise exception 'supervisor listing denied' using errcode='42501'; end if;
  return query select profile.id,profile.full_name,
    coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'team_id',team.id,'shift_id',shift.id,'shift_name',shift.name,'active',team.active
    ) order by shift.name,team.id)
    from public.branch_supervisor_teams team join public.branch_shifts shift on shift.id=team.shift_id
    where team.supervisor_user_id=profile.id and team.branch_id=target_branch_id),'[]'::jsonb)
  from public.branch_memberships membership join public.profiles profile on profile.id=membership.user_id
  where membership.branch_id=target_branch_id and membership.role='branch_manager' and membership.active
    and profile.disabled_at is null and not profile.must_change_password
  order by pg_catalog.lower(coalesce(profile.full_name,'')),profile.id limit 200;
end $$;

create function public.create_managed_supervisor_team(actor_user_id uuid,target_organization_id uuid,
  target_branch_id uuid,target_supervisor_user_id uuid,target_shift_id uuid)
returns table(id uuid,supervisor_user_id uuid,shift_id uuid,active boolean)
language plpgsql security definer set search_path = ''
as $$
declare created public.branch_supervisor_teams%rowtype;
begin
  if not private.managed_active_branch(actor_user_id,target_organization_id,target_branch_id)
    or not exists(select 1 from public.profiles profile join public.branch_memberships membership on membership.user_id=profile.id
      where profile.id=target_supervisor_user_id and profile.disabled_at is null and not profile.must_change_password
        and membership.branch_id=target_branch_id and membership.role='branch_manager' and membership.active)
    or not exists(select 1 from public.branch_shifts shift where shift.id=target_shift_id
      and shift.organization_id=target_organization_id and shift.branch_id=target_branch_id and shift.active)
  then raise exception 'team operation denied' using errcode='42501'; end if;
  insert into public.branch_supervisor_teams(organization_id,branch_id,supervisor_user_id,shift_id)
    values(target_organization_id,target_branch_id,target_supervisor_user_id,target_shift_id)
    returning * into created;
  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
    values(target_organization_id,actor_user_id,target_branch_id,'supervisor_team_assigned',
      pg_catalog.jsonb_build_object('team_id',created.id,'shift_id',created.shift_id,'new_status','active'));
  return query select created.id,created.supervisor_user_id,created.shift_id,created.active;
end $$;

create function public.update_managed_supervisor_team(actor_user_id uuid,target_organization_id uuid,
  target_branch_id uuid,target_team_id uuid,new_shift_id uuid,new_active boolean)
returns table(id uuid,supervisor_user_id uuid,shift_id uuid,active boolean)
language plpgsql security definer set search_path = ''
as $$
declare current_team public.branch_supervisor_teams%rowtype; previous_active boolean;
begin
  if not private.managed_active_branch(actor_user_id,target_organization_id,target_branch_id)
  then raise exception 'team operation denied' using errcode='42501'; end if;
  select team.* into strict current_team from public.branch_supervisor_teams team
    where team.id=target_team_id and team.organization_id=target_organization_id
      and team.branch_id=target_branch_id for update;
  previous_active := current_team.active;
  new_shift_id := coalesce(new_shift_id,current_team.shift_id);
  new_active := coalesce(new_active,current_team.active);
  if not exists(select 1 from public.branch_shifts shift where shift.id=new_shift_id
    and shift.organization_id=target_organization_id and shift.branch_id=target_branch_id
    and (not new_active or shift.active))
  then raise exception 'team operation denied' using errcode='42501'; end if;
  if current_team.active and (not new_active or current_team.shift_id<>new_shift_id)
    and exists(select 1 from public.operational_staff_assignments assignment
      where assignment.supervisor_team_id=target_team_id and assignment.active)
  then raise exception 'team has active dependencies' using errcode='23514'; end if;
  if current_team.shift_id<>new_shift_id then
    update public.branch_supervisor_teams team set active=false where team.id=target_team_id;
    insert into public.branch_supervisor_teams(organization_id,branch_id,supervisor_user_id,shift_id,active)
      values(target_organization_id,target_branch_id,current_team.supervisor_user_id,new_shift_id,new_active)
      returning * into current_team;
  else
    update public.branch_supervisor_teams team set active=new_active
      where team.id=target_team_id returning * into current_team;
  end if;
  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
    values(target_organization_id,actor_user_id,target_branch_id,
      case when previous_active and not new_active then 'supervisor_team_deactivated' else 'supervisor_team_assigned' end,
      pg_catalog.jsonb_build_object('team_id',target_team_id,'shift_id',new_shift_id,
        'previous_status',case when previous_active then 'active' else 'inactive' end,
        'new_status',case when new_active then 'active' else 'inactive' end));
  return query select current_team.id,current_team.supervisor_user_id,current_team.shift_id,current_team.active;
exception when no_data_found then raise exception 'team operation denied' using errcode='42501';
end $$;

create function public.get_supervisor_branch_timezone(actor_user_id uuid,target_branch_id uuid)
returns table(timezone text)
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.actor_owns_operational_team(actor_user_id,target_branch_id,null)
  then raise exception 'branch access denied' using errcode='42501'; end if;
  return query select branch.timezone from public.branches branch
    join public.organizations organization on organization.id=branch.organization_id
    where branch.id=target_branch_id and branch.active and organization.active;
end $$;

revoke all on function public.list_managed_branch_shifts(uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.create_managed_branch_shift(uuid,uuid,uuid,text,time,time) from public,anon,authenticated;
revoke all on function public.update_managed_branch_shift(uuid,uuid,uuid,uuid,text,time,time,boolean) from public,anon,authenticated;
revoke all on function public.list_eligible_branch_supervisors(uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.create_managed_supervisor_team(uuid,uuid,uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.update_managed_supervisor_team(uuid,uuid,uuid,uuid,uuid,boolean) from public,anon,authenticated;
revoke all on function public.get_supervisor_branch_timezone(uuid,uuid) from public,anon,authenticated;
grant execute on function public.list_managed_branch_shifts(uuid,uuid,uuid),
  public.create_managed_branch_shift(uuid,uuid,uuid,text,time,time),
  public.update_managed_branch_shift(uuid,uuid,uuid,uuid,text,time,time,boolean),
  public.list_eligible_branch_supervisors(uuid,uuid,uuid),
  public.create_managed_supervisor_team(uuid,uuid,uuid,uuid,uuid),
  public.update_managed_supervisor_team(uuid,uuid,uuid,uuid,uuid,boolean),
  public.get_supervisor_branch_timezone(uuid,uuid) to service_role;
