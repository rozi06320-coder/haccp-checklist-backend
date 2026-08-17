create function private.normalize_operational_staff_name(candidate text)
returns text language sql immutable security invoker set search_path = ''
as $$
  select pg_catalog.lower(
    pg_catalog.regexp_replace(pg_catalog.btrim(candidate), '[[:space:]]+', ' ', 'g')
  );
$$;
revoke all on function private.normalize_operational_staff_name(text) from public, anon, authenticated;

create function private.operational_roles_are_valid(candidate text[])
returns boolean language sql immutable security invoker set search_path = ''
as $$
  select candidate is not null
    and pg_catalog.cardinality(candidate) between 1 and 2
    and not candidate @> array[null]::text[]
    and (select pg_catalog.count(*) = pg_catalog.count(distinct value)
         from pg_catalog.unnest(candidate) value)
    and candidate <@ array['kitchen','packaging','front_of_house','cleaner']::text[];
$$;
revoke all on function private.operational_roles_are_valid(text[]) from public, anon, authenticated;

create table public.branch_shifts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  name text not null,
  start_time time not null,
  end_time time not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branch_shifts_id_scope_key unique (id, branch_id, organization_id),
  constraint branch_shifts_branch_scope_fkey foreign key (branch_id, organization_id)
    references public.branches(id, organization_id) on delete restrict,
  constraint branch_shifts_name_check check (name = pg_catalog.btrim(name) and length(name) between 1 and 120),
  constraint branch_shifts_time_check check (start_time <> end_time)
);
create unique index branch_shifts_name_ci_key
  on public.branch_shifts(branch_id, pg_catalog.lower(name));

create table public.branch_supervisor_teams (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  supervisor_user_id uuid not null references auth.users(id) on delete restrict,
  shift_id uuid not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branch_supervisor_teams_id_scope_key unique (id, branch_id, organization_id, shift_id),
  constraint branch_supervisor_teams_branch_scope_fkey foreign key (branch_id, organization_id)
    references public.branches(id, organization_id) on delete restrict,
  constraint branch_supervisor_teams_shift_scope_fkey foreign key (shift_id, branch_id, organization_id)
    references public.branch_shifts(id, branch_id, organization_id) on delete restrict
);
create unique index branch_supervisor_teams_active_assignment_key
  on public.branch_supervisor_teams(supervisor_user_id, branch_id, shift_id) where active;
create index branch_supervisor_teams_supervisor_idx on public.branch_supervisor_teams(supervisor_user_id);

create table public.operational_staff (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  display_name text not null,
  normalized_name text generated always as (private.normalize_operational_staff_name(display_name)) stored,
  employment_status text not null default 'active',
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deactivated_at timestamptz,
  deactivated_by uuid references auth.users(id) on delete restrict,
  constraint operational_staff_id_scope_key unique (id, branch_id, organization_id),
  constraint operational_staff_branch_scope_fkey foreign key (branch_id, organization_id)
    references public.branches(id, organization_id) on delete restrict,
  constraint operational_staff_display_name_check check (
    display_name = pg_catalog.regexp_replace(pg_catalog.btrim(display_name), '[[:space:]]+', ' ', 'g')
    and length(display_name) between 1 and 120
  ),
  constraint operational_staff_employment_status_check check (employment_status in ('active','inactive')),
  constraint operational_staff_deactivation_check check (
    (employment_status = 'active' and deactivated_at is null and deactivated_by is null)
    or (employment_status = 'inactive' and deactivated_at is not null and deactivated_by is not null)
  )
);
create index operational_staff_scope_name_idx on public.operational_staff(organization_id, branch_id, normalized_name);

create table public.operational_staff_assignments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  operational_staff_id uuid not null,
  supervisor_team_id uuid not null,
  shift_id uuid not null,
  operational_roles text[] not null,
  active boolean not null default true,
  valid_from date not null default current_date,
  valid_to date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint operational_staff_assignments_id_scope_key unique (id, operational_staff_id, branch_id, organization_id),
  constraint operational_staff_assignments_staff_scope_fkey foreign key (operational_staff_id, branch_id, organization_id)
    references public.operational_staff(id, branch_id, organization_id) on delete restrict,
  constraint operational_staff_assignments_team_scope_fkey foreign key (supervisor_team_id, branch_id, organization_id, shift_id)
    references public.branch_supervisor_teams(id, branch_id, organization_id, shift_id) on delete restrict,
  constraint operational_staff_assignments_roles_check check (private.operational_roles_are_valid(operational_roles)),
  constraint operational_staff_assignments_dates_check check (valid_to is null or valid_to >= valid_from),
  constraint operational_staff_assignments_active_dates_check check (not active or valid_to is null)
);
create unique index operational_staff_assignments_active_key
  on public.operational_staff_assignments(operational_staff_id, supervisor_team_id, shift_id) where active;
create index operational_staff_assignments_team_idx on public.operational_staff_assignments(supervisor_team_id, active);

create table public.operational_staff_duty_statuses (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  operational_staff_id uuid not null,
  assignment_id uuid not null,
  duty_date date not null,
  duty_status text not null,
  set_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint operational_staff_duty_assignment_scope_fkey
    foreign key (assignment_id, operational_staff_id, branch_id, organization_id)
    references public.operational_staff_assignments(id, operational_staff_id, branch_id, organization_id) on delete restrict,
  constraint operational_staff_duty_status_check check (duty_status in ('on_duty','day_off')),
  constraint operational_staff_duty_unique unique (assignment_id, operational_staff_id, duty_date)
);
create index operational_staff_duty_scope_date_idx
  on public.operational_staff_duty_statuses(organization_id, branch_id, duty_date);

create function private.validate_operational_team()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.branch_memberships membership
    join public.profiles profile on profile.id = membership.user_id
    join public.branches branch on branch.id = membership.branch_id
    join public.branch_shifts shift on shift.id = new.shift_id
    where membership.branch_id = new.branch_id
      and membership.user_id = new.supervisor_user_id
      and membership.role = 'branch_manager'
      and profile.disabled_at is null and not profile.must_change_password
      and branch.organization_id = new.organization_id and branch.active
      and shift.branch_id = new.branch_id and shift.organization_id = new.organization_id
      and (not new.active or shift.active)
  ) then raise exception 'invalid supervisor team scope' using errcode='23514'; end if;
  return new;
end $$;
revoke all on function private.validate_operational_team() from public, anon, authenticated;
create trigger branch_supervisor_teams_validate before insert or update on public.branch_supervisor_teams
for each row execute function private.validate_operational_team();

create function private.validate_operational_assignment()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.active and not exists (
    select 1 from public.operational_staff staff
    join public.branch_supervisor_teams team on team.id = new.supervisor_team_id
    join public.branch_shifts shift on shift.id = new.shift_id
    join public.branches branch on branch.id = new.branch_id
    where staff.id = new.operational_staff_id and staff.branch_id = new.branch_id
      and staff.organization_id = new.organization_id and staff.employment_status = 'active'
      and team.branch_id = new.branch_id and team.organization_id = new.organization_id
      and team.shift_id = new.shift_id and team.active
      and shift.branch_id = new.branch_id and shift.organization_id = new.organization_id and shift.active
      and branch.active
  ) then raise exception 'invalid active assignment scope' using errcode='23514'; end if;
  return new;
end $$;
revoke all on function private.validate_operational_assignment() from public, anon, authenticated;
create trigger operational_staff_assignments_validate before insert or update on public.operational_staff_assignments
for each row execute function private.validate_operational_assignment();

create trigger branch_shifts_set_updated_at before update on public.branch_shifts
for each row execute function private.set_updated_at();
create trigger branch_supervisor_teams_set_updated_at before update on public.branch_supervisor_teams
for each row execute function private.set_updated_at();
create trigger operational_staff_set_updated_at before update on public.operational_staff
for each row execute function private.set_updated_at();
create trigger operational_staff_assignments_set_updated_at before update on public.operational_staff_assignments
for each row execute function private.set_updated_at();
create trigger operational_staff_duty_set_updated_at before update on public.operational_staff_duty_statuses
for each row execute function private.set_updated_at();

alter table public.account_management_audit_logs drop constraint account_management_audit_logs_action_check;
alter table public.account_management_audit_logs add constraint account_management_audit_logs_action_check check (
  action in (
    'user_created','user_disabled','user_enabled','temporary_password_reset','password_changed',
    'branch_assignment_added','branch_assignment_removed','branch_role_changed',
    'daily_audit_pin_configured','daily_audit_pin_replaced',
    'branch_shift_created','branch_shift_updated','supervisor_team_assigned','supervisor_team_deactivated',
    'operational_staff_created','operational_staff_updated','operational_staff_deactivated',
    'operational_staff_assignment_created','operational_staff_assignment_updated',
    'operational_staff_assignment_deactivated','operational_staff_duty_changed'
  )
);
create function private.operational_audit_details_are_allowlisted(action_name text,candidate jsonb)
returns boolean language sql immutable security invoker set search_path = ''
as $$
  select action_name not in (
    'branch_shift_created','branch_shift_updated','supervisor_team_assigned','supervisor_team_deactivated',
    'operational_staff_created','operational_staff_updated','operational_staff_deactivated',
    'operational_staff_assignment_created','operational_staff_assignment_updated',
    'operational_staff_assignment_deactivated','operational_staff_duty_changed'
  ) or not exists (
    select 1 from pg_catalog.jsonb_object_keys(candidate) key
    where key not in ('shift_id','team_id','operational_staff_id','assignment_id',
      'previous_status','new_status','operational_roles')
  );
$$;
revoke all on function private.operational_audit_details_are_allowlisted(text,jsonb) from public,anon,authenticated;
grant execute on function private.operational_audit_details_are_allowlisted(text,jsonb) to service_role;
alter table public.account_management_audit_logs
  add constraint account_audit_operational_details_allowlist_check
  check (private.operational_audit_details_are_allowlisted(action,details));

create function private.actor_owns_operational_team(actor uuid, target_branch uuid, target_team uuid default null)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    join public.branch_memberships m on m.user_id=p.id
    join public.branches b on b.id=m.branch_id
    join public.branch_supervisor_teams t on t.branch_id=b.id and t.supervisor_user_id=p.id
    join public.branch_shifts s on s.id=t.shift_id
    where p.id=actor and p.disabled_at is null and not p.must_change_password
      and m.branch_id=target_branch and m.role='branch_manager' and b.active and t.active and s.active
      and (target_team is null or t.id=target_team)
  );
$$;
revoke all on function private.actor_owns_operational_team(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function private.actor_owns_operational_team(uuid,uuid,uuid) to authenticated;

create function private.actor_can_access_operational_staff(actor uuid,target_staff uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.operational_staff_assignments a
    where a.operational_staff_id=target_staff and a.active
      and private.actor_owns_operational_team(actor,a.branch_id,a.supervisor_team_id)
  );
$$;
revoke all on function private.actor_can_access_operational_staff(uuid,uuid) from public,anon,authenticated;
grant execute on function private.actor_can_access_operational_staff(uuid,uuid) to authenticated;

alter table public.branch_shifts enable row level security;
alter table public.branch_supervisor_teams enable row level security;
alter table public.operational_staff enable row level security;
alter table public.operational_staff_assignments enable row level security;
alter table public.operational_staff_duty_statuses enable row level security;

create policy branch_shifts_read on public.branch_shifts for select to authenticated using (
  private.is_organization_manager(organization_id)
  or exists (select 1 from public.branch_supervisor_teams t where t.shift_id=id and t.supervisor_user_id=auth.uid() and t.active)
);
create policy supervisor_teams_read on public.branch_supervisor_teams for select to authenticated using (
  private.is_organization_manager(organization_id)
  or (supervisor_user_id=auth.uid() and private.actor_owns_operational_team(auth.uid(),branch_id,id))
);
create policy operational_staff_read on public.operational_staff for select to authenticated using (
  private.is_organization_manager(organization_id)
  or private.actor_can_access_operational_staff(auth.uid(),id)
);
create policy operational_assignments_read on public.operational_staff_assignments for select to authenticated using (
  private.is_organization_manager(organization_id)
  or private.actor_owns_operational_team(auth.uid(),branch_id,supervisor_team_id)
);
create policy operational_duty_read on public.operational_staff_duty_statuses for select to authenticated using (
  private.is_organization_manager(organization_id)
  or exists (select 1 from public.operational_staff_assignments a where a.id=assignment_id
    and private.actor_owns_operational_team(auth.uid(),branch_id,a.supervisor_team_id))
);

revoke all on table public.branch_shifts, public.branch_supervisor_teams, public.operational_staff,
  public.operational_staff_assignments, public.operational_staff_duty_statuses from public,anon,authenticated,service_role;
grant select on table public.branch_shifts, public.branch_supervisor_teams, public.operational_staff,
  public.operational_staff_assignments, public.operational_staff_duty_statuses to authenticated;

create function public.get_supervisor_operational_team(actor_user_id uuid,target_branch_id uuid,requested_date date)
returns table(team_id uuid,shift_id uuid,shift_name text,shift_start_time time,shift_end_time time,
  staff_id uuid,display_name text,employment_status text,assignment_id uuid,operational_roles text[],duty_status text)
language plpgsql security definer set search_path = ''
as $$
begin
  if requested_date is null or not private.actor_owns_operational_team(actor_user_id,target_branch_id,null)
  then raise exception 'team access denied' using errcode='42501'; end if;
  return query select t.id,s.id,s.name,s.start_time,s.end_time,os.id,os.display_name,os.employment_status,
    a.id,a.operational_roles,coalesce(d.duty_status,'on_duty')
  from public.branch_supervisor_teams t join public.branch_shifts s on s.id=t.shift_id
  left join public.operational_staff_assignments a on a.supervisor_team_id=t.id and a.active
  left join public.operational_staff os on os.id=a.operational_staff_id
  left join public.operational_staff_duty_statuses d on d.assignment_id=a.id and d.duty_date=requested_date
  where t.supervisor_user_id=actor_user_id and t.branch_id=target_branch_id and t.active
  order by lower(os.display_name),os.id;
end $$;

create function public.create_supervisor_operational_staff(actor_user_id uuid,target_branch_id uuid,
  new_display_name text,new_shift_id uuid,new_operational_roles text[])
returns table(staff_id uuid,assignment_id uuid,duplicate_name_warning boolean)
language plpgsql security definer set search_path = ''
as $$
declare target_team public.branch_supervisor_teams%rowtype; target_org uuid; created_staff uuid; created_assignment uuid;
  clean_name text := pg_catalog.regexp_replace(pg_catalog.btrim(new_display_name),'[[:space:]]+',' ','g');
begin
  select t.* into strict target_team from public.branch_supervisor_teams t
  where t.supervisor_user_id=actor_user_id and t.branch_id=target_branch_id and t.shift_id=new_shift_id and t.active;
  if not private.actor_owns_operational_team(actor_user_id,target_branch_id,target_team.id)
    or length(clean_name) not between 1 and 120 or not private.operational_roles_are_valid(new_operational_roles)
  then raise exception 'staff operation denied' using errcode='42501'; end if;
  target_org := target_team.organization_id;
  insert into public.operational_staff(organization_id,branch_id,display_name,created_by)
    values(target_org,target_branch_id,clean_name,actor_user_id) returning id into created_staff;
  insert into public.operational_staff_assignments(organization_id,branch_id,operational_staff_id,supervisor_team_id,shift_id,operational_roles)
    values(target_org,target_branch_id,created_staff,target_team.id,new_shift_id,new_operational_roles) returning id into created_assignment;
  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
    values(target_org,actor_user_id,target_branch_id,'operational_staff_created',
      jsonb_build_object('operational_staff_id',created_staff,'assignment_id',created_assignment,'operational_roles',new_operational_roles));
  return query select created_staff,created_assignment,exists(select 1 from public.operational_staff os
    where os.organization_id=target_org and os.branch_id=target_branch_id and os.id<>created_staff
      and os.employment_status='active' and os.normalized_name=private.normalize_operational_staff_name(clean_name));
exception when no_data_found or too_many_rows then
  raise exception 'staff operation denied' using errcode='42501';
end $$;

create function public.update_supervisor_operational_staff(actor_user_id uuid,target_branch_id uuid,target_staff_id uuid,
  new_display_name text,new_employment_status text,new_shift_id uuid,new_operational_roles text[])
returns table(staff_id uuid,assignment_id uuid,duplicate_name_warning boolean)
language plpgsql security definer set search_path = ''
as $$
declare old_staff public.operational_staff%rowtype; old_assignment public.operational_staff_assignments%rowtype;
 target_team public.branch_supervisor_teams%rowtype; clean_name text := pg_catalog.regexp_replace(pg_catalog.btrim(new_display_name),'[[:space:]]+',' ','g');
begin
  select os.* into strict old_staff from public.operational_staff os where os.id=target_staff_id and os.branch_id=target_branch_id;
  select a.* into strict old_assignment from public.operational_staff_assignments a
    where a.operational_staff_id=target_staff_id and a.active;
  if not private.actor_owns_operational_team(actor_user_id,target_branch_id,old_assignment.supervisor_team_id)
    or new_employment_status not in ('active','inactive') or length(clean_name) not between 1 and 120
    or not private.operational_roles_are_valid(new_operational_roles)
  then raise exception 'staff operation denied' using errcode='42501'; end if;
  select t.* into strict target_team from public.branch_supervisor_teams t
    where t.supervisor_user_id=actor_user_id and t.branch_id=target_branch_id and t.shift_id=new_shift_id and t.active;
  update public.operational_staff set display_name=clean_name,employment_status=new_employment_status,
    deactivated_at=case when new_employment_status='inactive' then coalesce(deactivated_at,now()) else null end,
    deactivated_by=case when new_employment_status='inactive' then coalesce(deactivated_by,actor_user_id) else null end
    where id=target_staff_id;
  if old_assignment.supervisor_team_id<>target_team.id or old_assignment.shift_id<>new_shift_id then
    update public.operational_staff_assignments set active=false,valid_to=current_date where id=old_assignment.id;
    insert into public.operational_staff_assignments(organization_id,branch_id,operational_staff_id,supervisor_team_id,shift_id,operational_roles,active)
      values(old_staff.organization_id,target_branch_id,target_staff_id,target_team.id,new_shift_id,new_operational_roles,new_employment_status='active')
      returning * into old_assignment;
  else update public.operational_staff_assignments set operational_roles=new_operational_roles,
    active=(new_employment_status='active'),valid_to=case when new_employment_status='inactive' then current_date else null end
    where id=old_assignment.id returning * into old_assignment; end if;
  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
    values(old_staff.organization_id,actor_user_id,target_branch_id,
      case when new_employment_status='inactive' then 'operational_staff_deactivated' else 'operational_staff_updated' end,
      jsonb_build_object('operational_staff_id',target_staff_id,'assignment_id',old_assignment.id,
        'previous_status',old_staff.employment_status,'new_status',new_employment_status,'operational_roles',new_operational_roles));
  return query select target_staff_id,old_assignment.id,exists(select 1 from public.operational_staff os
    where os.organization_id=old_staff.organization_id and os.branch_id=target_branch_id and os.id<>target_staff_id
      and os.employment_status='active' and os.normalized_name=private.normalize_operational_staff_name(clean_name));
exception when no_data_found or too_many_rows then raise exception 'staff operation denied' using errcode='42501';
end $$;

create function public.set_supervisor_operational_duty(actor_user_id uuid,target_branch_id uuid,target_staff_id uuid,
  requested_date date,new_duty_status text)
returns table(staff_id uuid,assignment_id uuid,duty_date date,duty_status text,eligible boolean)
language plpgsql security definer set search_path = ''
as $$
declare staff_row public.operational_staff%rowtype; assignment_row public.operational_staff_assignments%rowtype;
begin
  select os.* into strict staff_row from public.operational_staff os where os.id=target_staff_id and os.branch_id=target_branch_id;
  select a.* into strict assignment_row from public.operational_staff_assignments a
    where a.operational_staff_id=target_staff_id and a.active;
  if requested_date is null or new_duty_status not in ('on_duty','day_off')
    or not private.actor_owns_operational_team(actor_user_id,target_branch_id,assignment_row.supervisor_team_id)
  then raise exception 'duty operation denied' using errcode='42501'; end if;
  insert into public.operational_staff_duty_statuses(organization_id,branch_id,operational_staff_id,assignment_id,duty_date,duty_status,set_by)
    values(staff_row.organization_id,target_branch_id,target_staff_id,assignment_row.id,requested_date,new_duty_status,actor_user_id)
    on conflict on constraint operational_staff_duty_unique
    do update set duty_status=excluded.duty_status,set_by=excluded.set_by;
  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
    values(staff_row.organization_id,actor_user_id,target_branch_id,'operational_staff_duty_changed',
      jsonb_build_object('operational_staff_id',target_staff_id,'assignment_id',assignment_row.id,'new_status',new_duty_status));
  return query select target_staff_id,assignment_row.id,requested_date,new_duty_status,
    (staff_row.employment_status='active' and new_duty_status='on_duty');
exception when no_data_found or too_many_rows then raise exception 'duty operation denied' using errcode='42501';
end $$;

create function public.list_managed_operational_staff(actor_user_id uuid,target_organization_id uuid,
  requested_page integer default 1,requested_page_size integer default 20,search_term text default null,
  branch_filter uuid default null,supervisor_filter uuid default null,shift_filter uuid default null,
  role_filter text default null,employment_filter text default null,requested_date date default null)
returns table(staff_id uuid,display_name text,employment_status text,branch_id uuid,branch_name text,
  supervisor_user_id uuid,supervisor_name text,team_id uuid,shift_id uuid,shift_name text,
  assignment_id uuid,operational_roles text[],duty_status text,total_count bigint)
language plpgsql security definer set search_path = ''
as $$
begin
 if requested_page<1 or requested_page_size not between 1 and 50 or length(coalesce(search_term,''))>120
  or (role_filter is not null and role_filter not in ('kitchen','packaging','front_of_house','cleaner'))
  or (employment_filter is not null and employment_filter not in ('active','inactive'))
  or not exists(select 1 from public.organization_memberships m join public.profiles p on p.id=m.user_id
    where m.user_id=actor_user_id and m.organization_id=target_organization_id and m.role='organization_manager'
      and p.disabled_at is null and not p.must_change_password)
 then raise exception 'listing denied' using errcode='42501'; end if;
 return query select os.id,os.display_name,os.employment_status,b.id,b.name,t.supervisor_user_id,p.full_name,
  t.id,s.id,s.name,a.id,a.operational_roles,coalesce(d.duty_status,'on_duty'),count(*) over()
 from public.operational_staff os join public.branches b on b.id=os.branch_id
 left join public.operational_staff_assignments a on a.operational_staff_id=os.id and a.active
 left join public.branch_supervisor_teams t on t.id=a.supervisor_team_id
 left join public.branch_shifts s on s.id=a.shift_id
 left join public.profiles p on p.id=t.supervisor_user_id
 left join public.operational_staff_duty_statuses d on d.assignment_id=a.id and d.duty_date=requested_date
 where os.organization_id=target_organization_id
  and (nullif(btrim(search_term),'') is null or os.normalized_name like '%'||private.normalize_operational_staff_name(search_term)||'%')
  and (branch_filter is null or os.branch_id=branch_filter)
  and (supervisor_filter is null or t.supervisor_user_id=supervisor_filter)
  and (shift_filter is null or s.id=shift_filter)
  and (role_filter is null or a.operational_roles @> array[role_filter])
  and (employment_filter is null or os.employment_status=employment_filter)
 order by os.normalized_name,os.id limit requested_page_size
 offset ((requested_page-1)::bigint*requested_page_size);
end $$;

create function public.list_managed_supervisor_teams(actor_user_id uuid,target_organization_id uuid)
returns table(team_id uuid,branch_id uuid,branch_name text,shift_id uuid,shift_name text,
 supervisor_user_id uuid,supervisor_name text,active boolean)
language plpgsql security definer set search_path = ''
as $$
begin
 if not exists(select 1 from public.organization_memberships m join public.profiles p on p.id=m.user_id
  where m.user_id=actor_user_id and m.organization_id=target_organization_id and m.role='organization_manager'
    and p.disabled_at is null and not p.must_change_password)
 then raise exception 'listing denied' using errcode='42501'; end if;
 return query select t.id,b.id,b.name,s.id,s.name,t.supervisor_user_id,p.full_name,t.active
 from public.branch_supervisor_teams t join public.branches b on b.id=t.branch_id
 join public.branch_shifts s on s.id=t.shift_id join public.profiles p on p.id=t.supervisor_user_id
 where t.organization_id=target_organization_id order by b.name,s.name,p.full_name,t.id limit 500;
end $$;

revoke all on function public.get_supervisor_operational_team(uuid,uuid,date) from public,anon,authenticated;
revoke all on function public.create_supervisor_operational_staff(uuid,uuid,text,uuid,text[]) from public,anon,authenticated;
revoke all on function public.update_supervisor_operational_staff(uuid,uuid,uuid,text,text,uuid,text[]) from public,anon,authenticated;
revoke all on function public.set_supervisor_operational_duty(uuid,uuid,uuid,date,text) from public,anon,authenticated;
revoke all on function public.list_managed_operational_staff(uuid,uuid,integer,integer,text,uuid,uuid,uuid,text,text,date) from public,anon,authenticated;
revoke all on function public.list_managed_supervisor_teams(uuid,uuid) from public,anon,authenticated;
grant execute on function public.get_supervisor_operational_team(uuid,uuid,date),
 public.create_supervisor_operational_staff(uuid,uuid,text,uuid,text[]),
 public.update_supervisor_operational_staff(uuid,uuid,uuid,text,text,uuid,text[]),
 public.set_supervisor_operational_duty(uuid,uuid,uuid,date,text),
 public.list_managed_operational_staff(uuid,uuid,integer,integer,text,uuid,uuid,uuid,text,text,date),
 public.list_managed_supervisor_teams(uuid,uuid) to service_role;
