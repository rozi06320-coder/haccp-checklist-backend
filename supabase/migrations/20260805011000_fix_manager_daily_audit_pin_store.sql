create or replace function public.store_organization_manager_daily_audit_pin(
  actor_user_id uuid,target_organization_id uuid,target_manager_user_id uuid,
  new_pin_hash bytea,new_salt bytea,new_pin_fingerprint bytea,
  new_kdf_version smallint,new_cost integer,new_block_size integer,new_parallelization integer
)
returns table(manager_user_id uuid,configured boolean,updated_at timestamptz,updated_by_name text)
language plpgsql security definer set search_path=''
as $$
declare was_configured boolean; old_version uuid; saved_version uuid;
begin
  if not exists(
    select 1 from public.organization_memberships membership
    join public.organizations organization on organization.id=membership.organization_id
    join public.profiles profile on profile.id=membership.user_id
    where membership.organization_id=target_organization_id and membership.user_id=actor_user_id
      and membership.role='organization_manager' and organization.active
      and profile.disabled_at is null and not profile.must_change_password
  ) or not exists(
    select 1 from public.organization_memberships membership
    join public.profiles profile on profile.id=membership.user_id
    where membership.organization_id=target_organization_id and membership.user_id=target_manager_user_id
      and membership.role='organization_manager' and profile.disabled_at is null
  ) then raise exception 'access denied' using errcode='42501'; end if;
  if octet_length(new_pin_hash)<>32 or octet_length(new_salt)<>16 or octet_length(new_pin_fingerprint)<>32
    or new_kdf_version<>1 or new_cost<>16384 or new_block_size<>8 or new_parallelization<>1
  then raise exception 'invalid credential input' using errcode='22023'; end if;
  select credential.credential_version into old_version
    from private.organization_manager_daily_audit_pins credential
    where credential.organization_id=target_organization_id
      and credential.manager_user_id=target_manager_user_id;
  was_configured := found;
  insert into private.organization_manager_daily_audit_pins(
    organization_id,manager_user_id,pin_hash,salt,pin_fingerprint,kdf_version,cost,block_size,
    parallelization,configured_by,updated_by
  ) values(
    target_organization_id,target_manager_user_id,new_pin_hash,new_salt,new_pin_fingerprint,
    new_kdf_version,new_cost,new_block_size,new_parallelization,actor_user_id,actor_user_id
  ) on conflict(organization_id,manager_user_id) do update set
    pin_hash=excluded.pin_hash,salt=excluded.salt,pin_fingerprint=excluded.pin_fingerprint,
    kdf_version=excluded.kdf_version,cost=excluded.cost,block_size=excluded.block_size,
    parallelization=excluded.parallelization,credential_version=gen_random_uuid(),
    updated_at=now(),updated_by=excluded.updated_by
  returning organization_manager_daily_audit_pins.credential_version into saved_version;
  insert into public.account_management_audit_logs(
    organization_id,actor_user_id,target_user_id,action,details
  ) values(
    target_organization_id,actor_user_id,target_manager_user_id,
    case when was_configured then 'daily_audit_pin_replaced' else 'daily_audit_pin_configured' end,
    jsonb_build_object('previous_configured',was_configured,'new_configured',true,
      'previous_credential_version',old_version,'new_credential_version',saved_version)
  );
  return query select credential.manager_user_id,true,credential.updated_at,updater.full_name
    from private.organization_manager_daily_audit_pins credential
    left join public.profiles updater on updater.id=credential.updated_by
    where credential.organization_id=target_organization_id
      and credential.manager_user_id=target_manager_user_id;
end $$;

revoke all on function public.store_organization_manager_daily_audit_pin(uuid,uuid,uuid,bytea,bytea,bytea,smallint,integer,integer,integer) from public,anon,authenticated;
grant execute on function public.store_organization_manager_daily_audit_pin(uuid,uuid,uuid,bytea,bytea,bytea,smallint,integer,integer,integer) to service_role;
