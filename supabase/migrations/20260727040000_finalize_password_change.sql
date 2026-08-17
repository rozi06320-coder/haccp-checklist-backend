create function public.finalize_password_change(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed_rows integer;
begin
  if not exists (
    select 1
    from public.profiles
    where id = p_user_id
      and disabled_at is null
      and must_change_password
  ) then
    raise exception using errcode = '42501', message = 'password change finalization denied';
  end if;

  if not exists (
    select 1
    from public.organization_memberships
    where user_id = p_user_id
      and role = 'organization_manager'
    union all
    select 1
    from public.branch_memberships membership
    join public.branches branch on branch.id = membership.branch_id
    where membership.user_id = p_user_id
  ) then
    raise exception using errcode = '42501', message = 'password change finalization denied';
  end if;

  update public.profiles
  set must_change_password = false
  where id = p_user_id
    and disabled_at is null
    and must_change_password;
  get diagnostics changed_rows = row_count;
  if changed_rows <> 1 then
    raise exception using errcode = '42501', message = 'password change finalization denied';
  end if;

  insert into public.account_management_audit_logs (
    organization_id,
    actor_user_id,
    target_user_id,
    action,
    details
  )
  select attribution.organization_id,
         p_user_id,
         p_user_id,
         'password_changed',
         '{}'::jsonb
  from (
    select membership.organization_id
    from public.organization_memberships membership
    where membership.user_id = p_user_id
      and membership.role = 'organization_manager'
    union
    select branch.organization_id
    from public.branch_memberships membership
    join public.branches branch on branch.id = membership.branch_id
    where membership.user_id = p_user_id
  ) attribution;

  return pg_catalog.jsonb_build_object('success', true);
end;
$$;

revoke all on function public.finalize_password_change(uuid)
  from public, anon, authenticated;
grant execute on function public.finalize_password_change(uuid)
  to service_role;

comment on function public.finalize_password_change(uuid) is
  'Atomically clears the forced-password lifecycle flag and writes one allowlisted audit row per affected organization after Auth password update. Service-role only.';
