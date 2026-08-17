create function public.finalize_provisioned_supervisor(
  p_actor_user_id uuid,p_organization_id uuid,p_new_user_id uuid,
  p_full_name text,p_branch_ids uuid[]
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  return public.finalize_provisioned_user(
    p_actor_user_id,p_organization_id,p_new_user_id,p_full_name,'branch_manager',p_branch_ids
  );
end $$;
revoke all on function public.finalize_provisioned_supervisor(uuid,uuid,uuid,text,uuid[])
  from public,anon,authenticated;
grant execute on function public.finalize_provisioned_supervisor(uuid,uuid,uuid,text,uuid[])
  to service_role;

create or replace function public.get_daily_audit_pin_metadata(actor_user_id uuid,target_branch_id uuid)
returns table(configured boolean,updated_at timestamptz,updated_by_name text)
language plpgsql security definer set search_path = ''
as $$
declare target_organization uuid;
begin
  select branch.organization_id into strict target_organization
    from public.branches branch where branch.id=target_branch_id and branch.active;
  if not private.actor_manages_active_organization(actor_user_id,target_organization)
  then raise exception 'branch access denied' using errcode='42501'; end if;
  return query select credential.branch_id is not null,credential.updated_at,profile.full_name
  from (select target_branch_id as id) requested
  left join private.daily_audit_pin_credentials credential on credential.branch_id=requested.id
  left join public.profiles profile on profile.id=credential.updated_by;
exception when no_data_found then raise exception 'branch access denied' using errcode='42501';
end $$;

create or replace function public.store_daily_audit_pin(
  actor_user_id uuid,target_branch_id uuid,new_pin_hash bytea,new_salt bytea,
  new_kdf_version smallint,new_cost integer,new_block_size integer,new_parallelization integer
)
returns table(configured boolean,updated_at timestamptz,updated_by_name text)
language plpgsql security definer set search_path = ''
as $$
declare was_configured boolean; target_organization uuid;
begin
  select branch.organization_id into strict target_organization
    from public.branches branch where branch.id=target_branch_id and branch.active;
  if not private.actor_manages_active_organization(actor_user_id,target_organization)
  then raise exception 'branch access denied' using errcode='42501'; end if;
  if pg_catalog.octet_length(new_pin_hash)<>32 or pg_catalog.octet_length(new_salt)<>16
    or new_kdf_version<>1 or new_cost<>16384 or new_block_size<>8 or new_parallelization<>1
  then raise exception 'invalid credential input' using errcode='22023'; end if;
  select exists(select 1 from private.daily_audit_pin_credentials credential
    where credential.branch_id=target_branch_id) into was_configured;
  insert into private.daily_audit_pin_credentials(
    branch_id,pin_hash,salt,kdf_version,cost,block_size,parallelization,updated_by
  ) values (
    target_branch_id,new_pin_hash,new_salt,new_kdf_version,new_cost,new_block_size,new_parallelization,actor_user_id
  ) on conflict(branch_id) do update set
    pin_hash=excluded.pin_hash,salt=excluded.salt,kdf_version=excluded.kdf_version,
    cost=excluded.cost,block_size=excluded.block_size,parallelization=excluded.parallelization,
    credential_version=gen_random_uuid(),updated_at=now(),updated_by=excluded.updated_by;
  insert into public.account_management_audit_logs(
    organization_id,actor_user_id,branch_id,action,details
  ) values (
    target_organization,actor_user_id,target_branch_id,
    case when was_configured then 'daily_audit_pin_replaced' else 'daily_audit_pin_configured' end,'{}'
  );
  return query select true,credential.updated_at,profile.full_name
    from private.daily_audit_pin_credentials credential
    left join public.profiles profile on profile.id=credential.updated_by
    where credential.branch_id=target_branch_id;
exception when no_data_found then raise exception 'branch access denied' using errcode='42501';
end $$;

create or replace function public.get_daily_audit_pin_credential(actor_user_id uuid,target_branch_id uuid)
returns table(pin_hash bytea,salt bytea,kdf_version smallint,cost integer,
  block_size integer,parallelization integer,credential_version uuid)
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.actor_owns_operational_team(actor_user_id,target_branch_id,null)
  then raise exception 'branch access denied' using errcode='42501'; end if;
  return query select credential.pin_hash,credential.salt,credential.kdf_version,
    credential.cost,credential.block_size,credential.parallelization,credential.credential_version
  from private.daily_audit_pin_credentials credential where credential.branch_id=target_branch_id;
end $$;

revoke all on function public.get_daily_audit_pin_metadata(uuid,uuid) from public,anon,authenticated;
revoke all on function public.store_daily_audit_pin(uuid,uuid,bytea,bytea,smallint,integer,integer,integer)
  from public,anon,authenticated;
revoke all on function public.get_daily_audit_pin_credential(uuid,uuid) from public,anon,authenticated;
grant execute on function public.get_daily_audit_pin_metadata(uuid,uuid),
  public.store_daily_audit_pin(uuid,uuid,bytea,bytea,smallint,integer,integer,integer),
  public.get_daily_audit_pin_credential(uuid,uuid) to service_role;
