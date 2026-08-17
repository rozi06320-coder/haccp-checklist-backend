alter table public.account_management_audit_logs
  drop constraint account_management_audit_logs_action_check;
alter table public.account_management_audit_logs
  add constraint account_management_audit_logs_action_check check (
    action in (
      'user_created','user_disabled','user_enabled','temporary_password_reset',
      'password_changed','branch_assignment_added','branch_assignment_removed',
      'branch_role_changed','daily_audit_pin_configured','daily_audit_pin_replaced'
    )
  );

create table private.daily_audit_pin_credentials (
  branch_id uuid primary key references public.branches(id) on delete cascade,
  pin_hash bytea not null check (octet_length(pin_hash) = 32),
  salt bytea not null check (octet_length(salt) = 16),
  kdf_version smallint not null check (kdf_version = 1),
  cost integer not null check (cost between 16384 and 1048576),
  block_size integer not null check (block_size between 1 and 32),
  parallelization integer not null check (parallelization between 1 and 16),
  credential_version uuid not null default gen_random_uuid(),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);
create index daily_audit_pin_credentials_updated_by_idx
  on private.daily_audit_pin_credentials(updated_by) where updated_by is not null;
revoke all on table private.daily_audit_pin_credentials from public, anon, authenticated, service_role;

create function private.actor_can_manage_branch(actor uuid, target_branch uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = actor and p.disabled_at is null and not p.must_change_password
  ) and (
    exists (
      select 1 from public.branch_memberships m
      join public.branches b on b.id=m.branch_id
      where m.user_id = actor and m.branch_id = target_branch
        and m.role = 'branch_manager' and b.active
    ) or exists (
      select 1 from public.branches b join public.organization_memberships m
        on m.organization_id = b.organization_id
      where b.id = target_branch and b.active
        and m.user_id = actor and m.role = 'organization_manager'
    )
  );
$$;
create function private.actor_can_access_branch(actor uuid, target_branch uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = actor and p.disabled_at is null and not p.must_change_password
  ) and (
    exists (
      select 1 from public.branch_memberships m join public.branches b on b.id=m.branch_id
      where m.user_id=actor and m.branch_id=target_branch and b.active
    )
    or exists (
      select 1 from public.branches b join public.organization_memberships m
        on m.organization_id=b.organization_id
      where b.id=target_branch and b.active and m.user_id=actor and m.role='organization_manager'
    )
  );
$$;
revoke all on function private.actor_can_manage_branch(uuid,uuid) from public,anon,authenticated;
revoke all on function private.actor_can_access_branch(uuid,uuid) from public,anon,authenticated;

create function public.list_supervised_branches(actor_user_id uuid)
returns table(id uuid, organization_id uuid, name text, code text, staff_count bigint)
language sql security definer set search_path = ''
as $$
  select b.id,b.organization_id,b.name,b.code,
    (select count(*) from public.branch_memberships sm where sm.branch_id=b.id and sm.role='staff')
  from public.branches b
  where b.active and private.actor_can_manage_branch(actor_user_id,b.id)
  order by b.name,b.id limit 200;
$$;
create function public.list_supervised_branch_staff(actor_user_id uuid,target_branch_id uuid)
returns table(id uuid,full_name text,role text,disabled boolean,must_change_password boolean)
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.actor_can_manage_branch(actor_user_id,target_branch_id) then
    raise exception 'branch access denied' using errcode='42501';
  end if;
  return query select p.id,p.full_name,m.role,p.disabled_at is not null,p.must_change_password
  from public.branch_memberships m join public.profiles p on p.id=m.user_id
  where m.branch_id=target_branch_id order by lower(coalesce(p.full_name,'')),p.id limit 500;
end $$;
create function public.get_daily_audit_pin_metadata(actor_user_id uuid,target_branch_id uuid)
returns table(configured boolean,updated_at timestamptz,updated_by_name text)
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.actor_can_manage_branch(actor_user_id,target_branch_id) then
    raise exception 'branch access denied' using errcode='42501';
  end if;
  return query select c.branch_id is not null,c.updated_at,p.full_name
  from (select target_branch_id as id) requested
  left join private.daily_audit_pin_credentials c on c.branch_id=requested.id
  left join public.profiles p on p.id=c.updated_by;
end $$;
create function public.store_daily_audit_pin(
  actor_user_id uuid,target_branch_id uuid,new_pin_hash bytea,new_salt bytea,
  new_kdf_version smallint,new_cost integer,new_block_size integer,new_parallelization integer
)
returns table(configured boolean,updated_at timestamptz,updated_by_name text)
language plpgsql security definer set search_path = ''
as $$
declare was_configured boolean; target_org uuid;
begin
  if not private.actor_can_manage_branch(actor_user_id,target_branch_id) then
    raise exception 'branch access denied' using errcode='42501';
  end if;
  if octet_length(new_pin_hash)<>32 or octet_length(new_salt)<>16 or new_kdf_version<>1
    or new_cost<>16384 or new_block_size<>8 or new_parallelization<>1 then
    raise exception 'invalid credential input' using errcode='22023';
  end if;
  select organization_id into strict target_org from public.branches where id=target_branch_id and active;
  select exists(select 1 from private.daily_audit_pin_credentials where branch_id=target_branch_id) into was_configured;
  insert into private.daily_audit_pin_credentials(branch_id,pin_hash,salt,kdf_version,cost,block_size,parallelization,updated_by)
  values(target_branch_id,new_pin_hash,new_salt,new_kdf_version,new_cost,new_block_size,new_parallelization,actor_user_id)
  on conflict(branch_id) do update set pin_hash=excluded.pin_hash,salt=excluded.salt,
    kdf_version=excluded.kdf_version,cost=excluded.cost,block_size=excluded.block_size,
    parallelization=excluded.parallelization,credential_version=gen_random_uuid(),
    updated_at=now(),updated_by=excluded.updated_by;
  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
  values(target_org,actor_user_id,target_branch_id,
    case when was_configured then 'daily_audit_pin_replaced' else 'daily_audit_pin_configured' end,'{}');
  return query select true,c.updated_at,p.full_name from private.daily_audit_pin_credentials c
    left join public.profiles p on p.id=c.updated_by where c.branch_id=target_branch_id;
end $$;
create function public.get_daily_audit_pin_credential(actor_user_id uuid,target_branch_id uuid)
returns table(pin_hash bytea,salt bytea,kdf_version smallint,cost integer,block_size integer,parallelization integer,credential_version uuid)
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.actor_can_access_branch(actor_user_id,target_branch_id) then
    raise exception 'branch access denied' using errcode='42501';
  end if;
  return query select c.pin_hash,c.salt,c.kdf_version,c.cost,c.block_size,c.parallelization,c.credential_version
  from private.daily_audit_pin_credentials c where c.branch_id=target_branch_id;
end $$;

revoke all on function public.list_supervised_branches(uuid) from public,anon,authenticated;
revoke all on function public.list_supervised_branch_staff(uuid,uuid) from public,anon,authenticated;
revoke all on function public.get_daily_audit_pin_metadata(uuid,uuid) from public,anon,authenticated;
revoke all on function public.store_daily_audit_pin(uuid,uuid,bytea,bytea,smallint,integer,integer,integer) from public,anon,authenticated;
revoke all on function public.get_daily_audit_pin_credential(uuid,uuid) from public,anon,authenticated;
grant execute on function public.list_supervised_branches(uuid) to service_role;
grant execute on function public.list_supervised_branch_staff(uuid,uuid) to service_role;
grant execute on function public.get_daily_audit_pin_metadata(uuid,uuid) to service_role;
grant execute on function public.store_daily_audit_pin(uuid,uuid,bytea,bytea,smallint,integer,integer,integer) to service_role;
grant execute on function public.get_daily_audit_pin_credential(uuid,uuid) to service_role;
