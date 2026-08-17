create function public.finalize_provisioned_user(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_new_user_id uuid,
  p_full_name text,
  p_role text,
  p_branch_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  branch_id uuid;
  changed_rows integer;
begin
  if p_role not in ('staff', 'branch_manager') then
    raise exception using errcode = '22023', message = 'invalid provisioning input';
  end if;
  if p_full_name is null or pg_catalog.btrim(p_full_name) = '' then
    raise exception using errcode = '22023', message = 'invalid provisioning input';
  end if;
  if p_branch_ids is null or pg_catalog.cardinality(p_branch_ids) = 0 then
    raise exception using errcode = '22023', message = 'invalid provisioning input';
  end if;
  if (
    select pg_catalog.count(*) <> pg_catalog.count(distinct item)
    from pg_catalog.unnest(p_branch_ids) as item
  ) then
    raise exception using errcode = '22023', message = 'invalid provisioning input';
  end if;
  if not exists (
    select 1
    from public.organization_memberships
    where organization_id = p_organization_id
      and user_id = p_actor_user_id
      and role = 'organization_manager'
  ) then
    raise exception using errcode = '42501', message = 'provisioning denied';
  end if;
  if (
    select pg_catalog.count(*) <> pg_catalog.cardinality(p_branch_ids)
    from public.branches
    where id = any(p_branch_ids)
      and organization_id = p_organization_id
      and active
  ) then
    raise exception using errcode = '22023', message = 'invalid provisioning input';
  end if;

  update public.profiles
  set full_name = p_full_name,
      must_change_password = true,
      disabled_at = null
  where id = p_new_user_id;
  get diagnostics changed_rows = row_count;
  if changed_rows <> 1 then
    raise exception using errcode = '23503', message = 'target profile missing';
  end if;

  insert into public.branch_memberships (branch_id, user_id, role)
  select item, p_new_user_id, p_role
  from pg_catalog.unnest(p_branch_ids) as item;

  insert into public.account_management_audit_logs (
    organization_id, actor_user_id, target_user_id, action, details
  ) values (
    p_organization_id,
    p_actor_user_id,
    p_new_user_id,
    'user_created',
    pg_catalog.jsonb_build_object(
      'role', p_role,
      'branch_count', pg_catalog.cardinality(p_branch_ids)
    )
  );

  foreach branch_id in array p_branch_ids loop
    insert into public.account_management_audit_logs (
      organization_id, actor_user_id, target_user_id, branch_id, action, details
    ) values (
      p_organization_id,
      p_actor_user_id,
      p_new_user_id,
      branch_id,
      'branch_assignment_added',
      pg_catalog.jsonb_build_object('role', p_role)
    );
  end loop;

  return pg_catalog.jsonb_build_object('success', true);
end;
$$;

revoke all on function public.finalize_provisioned_user(uuid, uuid, uuid, text, text, uuid[])
  from public, anon, authenticated;
grant execute on function public.finalize_provisioned_user(uuid, uuid, uuid, text, text, uuid[])
  to service_role;

comment on function public.finalize_provisioned_user(uuid, uuid, uuid, text, text, uuid[]) is
  'Finalizes a manager-provisioned Auth user atomically. Service-role only; revalidates actor, role, and active tenant branches.';
