alter table public.account_management_audit_logs
  drop constraint if exists account_management_audit_logs_action_check;

alter table public.account_management_audit_logs
  add constraint account_management_audit_logs_action_check check (
    action in (
      'user_created',
      'user_disabled',
      'user_enabled',
      'temporary_password_reset',
      'password_changed',
      'branch_created',
      'branch_assignment_added',
      'branch_assignment_removed',
      'branch_role_changed',
      'daily_audit_pin_configured',
      'daily_audit_pin_replaced',
      'daily_audit_access_granted',
      'daily_audit_user_access_granted',
      'daily_audit_user_access_revoked',
      'daily_audit_access_user_created',
      'daily_audit_access_user_revoked',
      'maintenance_access_user_created',
      'maintenance_access_user_deactivated',
      'maintenance_user_created',
      'maintenance_user_deactivated',
      'training_account_created',
      'training_account_updated',
      'training_account_deactivated',
      'training_account_reactivated',
      'training_account_password_reset',
      'branch_shift_created',
      'branch_shift_updated',
      'supervisor_team_assigned',
      'supervisor_team_deactivated',
      'supervisor_profile_updated',
      'operational_staff_created',
      'operational_staff_updated',
      'operational_staff_deactivated',
      'operational_staff_assignment_created',
      'operational_staff_assignment_updated',
      'operational_staff_assignment_deactivated',
      'operational_staff_duty_changed',
      'organization_logo_updated',
      'branch_logo_updated',
      'operational_staff_supervisor_training_started',
      'operational_staff_supervisor_training_cancelled',
      'operational_staff_supervisor_training_promoted'
    )
  );

do $migration$
begin
  if not exists (
    select 1
    from pg_constraint constraint_row
    join pg_class table_row on table_row.oid = constraint_row.conrelid
    join pg_namespace schema_row on schema_row.oid = table_row.relnamespace
    where schema_row.nspname = 'public'
      and table_row.relname = 'branches'
      and constraint_row.conname = 'branches_organization_id_id_key'
  ) then
    alter table public.branches
      add constraint branches_organization_id_id_key unique (organization_id, id);
  end if;
end
$migration$;

create table public.training_memberships (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  account_name text not null check (length(btrim(account_name)) between 1 and 120),
  active boolean not null default true,
  created_by uuid not null references auth.users(id) on delete restrict,
  updated_by uuid null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (organization_id, user_id)
);

create table public.training_membership_branches (
  organization_id uuid not null,
  user_id uuid not null,
  branch_id uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (organization_id, user_id, branch_id),
  constraint training_membership_branches_membership_fk
    foreign key (organization_id, user_id)
    references public.training_memberships(organization_id, user_id)
    on delete cascade,
  constraint training_membership_branches_branch_fk
    foreign key (organization_id, branch_id)
    references public.branches(organization_id, id)
    on delete cascade
);

alter table public.training_memberships enable row level security;
alter table public.training_membership_branches enable row level security;

revoke all on table public.training_memberships from public, anon, authenticated, service_role;
revoke all on table public.training_membership_branches from public, anon, authenticated, service_role;
grant select on table public.training_memberships to authenticated;
grant select on table public.training_membership_branches to authenticated;

create index training_memberships_user_active_idx
  on public.training_memberships(user_id, organization_id)
  where active;

create index training_membership_branches_user_idx
  on public.training_membership_branches(user_id, organization_id);

create index training_membership_branches_branch_idx
  on public.training_membership_branches(branch_id);

create trigger training_memberships_set_updated_at
before update on public.training_memberships
for each row execute function private.set_updated_at();

create trigger training_membership_branches_set_updated_at
before update on public.training_membership_branches
for each row execute function private.set_updated_at();

create function private.actor_has_active_training_membership(actor uuid, target_organization uuid default null)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles profile
    join public.training_memberships membership on membership.user_id = profile.id
    join public.organizations organization on organization.id = membership.organization_id
    where profile.id = actor
      and profile.disabled_at is null
      and not profile.must_change_password
      and membership.active
      and organization.active
      and (target_organization is null or membership.organization_id = target_organization)
      and exists (
        select 1
        from public.training_membership_branches assignment
        join public.branches branch
          on branch.id = assignment.branch_id
         and branch.organization_id = assignment.organization_id
        where assignment.organization_id = membership.organization_id
          and assignment.user_id = membership.user_id
          and branch.active
      )
  );
$$;

revoke all on function private.actor_has_active_training_membership(uuid, uuid) from public, anon, authenticated;

create policy training_memberships_select_own_or_internal_admin
on public.training_memberships
for select
to authenticated
using (
  user_id = auth.uid()
  or private.is_internal_admin(auth.uid())
);

create policy training_membership_branches_select_own_or_internal_admin
on public.training_membership_branches
for select
to authenticated
using (
  user_id = auth.uid()
  or private.is_internal_admin(auth.uid())
);

create function private.validate_training_branch_scope(target_organization_id uuid, target_branch_ids uuid[])
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  requested_count integer;
  matched_count integer;
begin
  select count(*) into requested_count from unnest(coalesce(target_branch_ids, '{}'::uuid[])) as branch_id;

  if requested_count < 1 or requested_count > 50 then
    raise exception using errcode = '22023', message = 'invalid branch assignment';
  end if;

  if requested_count <> (select count(distinct branch_id) from unnest(target_branch_ids) as branch_id) then
    raise exception using errcode = '22023', message = 'duplicate branch assignment';
  end if;

  select count(*) into matched_count
  from public.branches branch
  where branch.organization_id = target_organization_id
    and branch.active
    and branch.id = any(target_branch_ids);

  if matched_count <> requested_count then
    raise exception using errcode = '42501', message = 'branch assignment denied';
  end if;
end;
$$;

revoke all on function private.validate_training_branch_scope(uuid, uuid[]) from public, anon, authenticated;

create function private.training_account_target_is_dedicated(target_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not exists (
    select 1
    from public.internal_admin_memberships membership
    where membership.user_id = target_user_id
  )
  and not exists (
    select 1
    from public.organization_memberships membership
    where membership.user_id = target_user_id
  )
  and not exists (
    select 1
    from public.branch_memberships membership
    where membership.user_id = target_user_id
  )
  and not exists (
    select 1
    from public.maintenance_memberships membership
    where membership.user_id = target_user_id
  );
$$;

revoke all on function private.training_account_target_is_dedicated(uuid) from public, anon, authenticated;

create function public.finalize_provisioned_training_account(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_new_user_id uuid,
  p_account_name text,
  p_branch_ids uuid[],
  p_active boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed_rows integer;
  normalized_account_name text := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p_account_name, '')), '\s+', ' ', 'g');
begin
  if pg_catalog.length(normalized_account_name) = 0 or pg_catalog.length(normalized_account_name) > 120 then
    raise exception using errcode = '22023', message = 'invalid provisioning input';
  end if;

  if not private.is_internal_admin(p_actor_user_id) then
    raise exception using errcode = '42501', message = 'provisioning denied';
  end if;

  if not exists(select 1 from public.organizations organization where organization.id = p_organization_id and organization.active) then
    raise exception using errcode = '42501', message = 'provisioning denied';
  end if;

  perform private.validate_training_branch_scope(p_organization_id, p_branch_ids);

  if not private.training_account_target_is_dedicated(p_new_user_id) then
    raise exception using errcode = '42501', message = 'provisioning denied';
  end if;

  update public.profiles
  set full_name = normalized_account_name,
      must_change_password = true,
      disabled_at = null,
      updated_at = now()
  where id = p_new_user_id;
  get diagnostics changed_rows = row_count;
  if changed_rows <> 1 then
    raise exception using errcode = '23503', message = 'target profile missing';
  end if;

  insert into public.training_memberships(organization_id, user_id, account_name, active, created_by, updated_by)
  values(p_organization_id, p_new_user_id, normalized_account_name, coalesce(p_active, true), p_actor_user_id, p_actor_user_id);

  insert into public.training_membership_branches(organization_id, user_id, branch_id)
  select p_organization_id, p_new_user_id, branch_id
  from unnest(p_branch_ids) as branch_id;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, action, details)
  values(
    p_organization_id,
    p_actor_user_id,
    p_new_user_id,
    'training_account_created',
    pg_catalog.jsonb_build_object(
      'new_status', case when coalesce(p_active, true) then 'active' else 'disabled' end,
      'branch_count', pg_catalog.array_length(p_branch_ids, 1)
    )
  );

  return pg_catalog.jsonb_build_object('success', true);
end;
$$;

create function public.list_internal_admin_training_accounts(
  actor_user_id uuid,
  target_organization_id uuid
)
returns table(
  id uuid,
  account_name text,
  email text,
  organization_id uuid,
  active boolean,
  must_change_password boolean,
  created_at timestamptz,
  updated_at timestamptz,
  updated_by_name text,
  branches jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'training account access denied' using errcode = '42501';
  end if;

  if not exists(select 1 from public.organizations organization where organization.id = target_organization_id and organization.active) then
    raise exception 'training account access denied' using errcode = '42501';
  end if;

  return query
    select membership.user_id,
      membership.account_name,
      auth_user.email::text,
      membership.organization_id,
      membership.active,
      profile.must_change_password,
      membership.created_at,
      membership.updated_at,
      updater.full_name,
      coalesce(
        (
          select pg_catalog.jsonb_agg(
            pg_catalog.jsonb_build_object(
              'id', branch.id,
              'name', branch.name,
              'name_ar', branch.name_ar,
              'code', branch.code,
              'active', branch.active
            )
            order by branch.name, branch.id
          )
          from public.training_membership_branches assignment
          join public.branches branch
            on branch.id = assignment.branch_id
           and branch.organization_id = assignment.organization_id
          where assignment.organization_id = membership.organization_id
            and assignment.user_id = membership.user_id
        ),
        '[]'::jsonb
      )
    from public.training_memberships membership
    join public.profiles profile on profile.id = membership.user_id
    join auth.users auth_user on auth_user.id = membership.user_id
    left join public.profiles updater on updater.id = membership.updated_by
    where membership.organization_id = target_organization_id
    order by membership.active desc, pg_catalog.lower(membership.account_name), membership.user_id
    limit 500;
end;
$$;

create function public.update_internal_admin_training_account(
  actor_user_id uuid,
  target_organization_id uuid,
  target_user_id uuid,
  new_account_name text,
  new_active boolean,
  target_branch_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_account_name text := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(new_account_name, '')), '\s+', ' ', 'g');
  previous_active boolean;
begin
  if pg_catalog.length(normalized_account_name) = 0 or pg_catalog.length(normalized_account_name) > 120 then
    raise exception using errcode = '22023', message = 'invalid account name';
  end if;

  if not private.is_internal_admin(actor_user_id) then
    raise exception 'training account update denied' using errcode = '42501';
  end if;

  if not exists(select 1 from public.organizations organization where organization.id = target_organization_id and organization.active) then
    raise exception 'training account update denied' using errcode = '42501';
  end if;

  select membership.active into previous_active
  from public.training_memberships membership
  where membership.organization_id = target_organization_id
    and membership.user_id = target_user_id;

  if previous_active is null then
    raise exception 'training account not found' using errcode = 'P0002';
  end if;

  if not private.training_account_target_is_dedicated(target_user_id) then
    raise exception 'training account update denied' using errcode = '42501';
  end if;

  perform private.validate_training_branch_scope(target_organization_id, target_branch_ids);

  update public.training_memberships
  set account_name = normalized_account_name,
      active = coalesce(new_active, true),
      updated_by = actor_user_id,
      updated_at = now()
  where organization_id = target_organization_id
    and user_id = target_user_id;

  update public.profiles
  set full_name = normalized_account_name,
      updated_at = now()
  where id = target_user_id;

  delete from public.training_membership_branches
  where organization_id = target_organization_id
    and user_id = target_user_id;

  insert into public.training_membership_branches(organization_id, user_id, branch_id)
  select target_organization_id, target_user_id, branch_id
  from unnest(target_branch_ids) as branch_id;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, action, details)
  values(
    target_organization_id,
    actor_user_id,
    target_user_id,
    case
      when previous_active and not coalesce(new_active, true) then 'training_account_deactivated'
      when not previous_active and coalesce(new_active, true) then 'training_account_reactivated'
      else 'training_account_updated'
    end,
    pg_catalog.jsonb_build_object(
      'new_status', case when coalesce(new_active, true) then 'active' else 'disabled' end,
      'branch_count', pg_catalog.array_length(target_branch_ids, 1)
    )
  );

  return pg_catalog.jsonb_build_object('success', true);
end;
$$;

create function public.authorize_training_account_password_reset(
  actor_user_id uuid,
  target_organization_id uuid,
  target_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_internal_admin(actor_user_id)
    or not exists(select 1 from public.organizations organization where organization.id = target_organization_id and organization.active)
    or not exists(
      select 1
      from public.training_memberships membership
      where membership.organization_id = target_organization_id
        and membership.user_id = target_user_id
    )
    or not private.training_account_target_is_dedicated(target_user_id)
  then
    raise exception 'training account password reset denied' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object('success', true);
end;
$$;

create function public.finalize_training_account_password_reset(
  actor_user_id uuid,
  target_organization_id uuid,
  target_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_internal_admin(actor_user_id)
    or not exists(select 1 from public.organizations organization where organization.id = target_organization_id and organization.active)
    or not exists(
      select 1
      from public.training_memberships membership
      where membership.organization_id = target_organization_id
        and membership.user_id = target_user_id
    )
    or not private.training_account_target_is_dedicated(target_user_id)
  then
    raise exception 'training account password reset denied' using errcode = '42501';
  end if;

  update public.profiles
  set must_change_password = true,
      updated_at = now()
  where id = target_user_id;

  update public.training_memberships
  set updated_by = actor_user_id,
      updated_at = now()
  where organization_id = target_organization_id
    and user_id = target_user_id;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, action, details)
  values(
    target_organization_id,
    actor_user_id,
    target_user_id,
    'training_account_password_reset',
    pg_catalog.jsonb_build_object('must_change_password', true)
  );

  return pg_catalog.jsonb_build_object('success', true);
end;
$$;

create function public.get_training_account_context(actor_user_id uuid)
returns table(
  user_id uuid,
  account_name text,
  email text,
  organization_id uuid,
  organization_name text,
  organization_name_ar text,
  active boolean,
  branches jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.actor_has_active_training_membership(actor_user_id, null) then
    raise exception 'training access denied' using errcode = '42501';
  end if;

  return query
    select membership.user_id,
      membership.account_name,
      auth_user.email::text,
      organization.id,
      organization.name,
      organization.name_ar,
      membership.active,
      coalesce(
        (
          select pg_catalog.jsonb_agg(
            pg_catalog.jsonb_build_object(
              'id', branch.id,
              'name', branch.name,
              'name_ar', branch.name_ar,
              'code', branch.code,
              'active', branch.active
            )
            order by branch.name, branch.id
          )
          from public.training_membership_branches assignment
          join public.branches branch
            on branch.id = assignment.branch_id
           and branch.organization_id = assignment.organization_id
          where assignment.organization_id = membership.organization_id
            and assignment.user_id = membership.user_id
            and branch.active
        ),
        '[]'::jsonb
      )
    from public.training_memberships membership
    join public.organizations organization on organization.id = membership.organization_id
    join auth.users auth_user on auth_user.id = membership.user_id
    where membership.user_id = actor_user_id
      and membership.active
      and organization.active
    order by membership.created_at, membership.organization_id
    limit 1;
end;
$$;

revoke all on function public.finalize_provisioned_training_account(uuid, uuid, uuid, text, uuid[], boolean) from public, anon, authenticated;
revoke all on function public.list_internal_admin_training_accounts(uuid, uuid) from public, anon, authenticated;
revoke all on function public.update_internal_admin_training_account(uuid, uuid, uuid, text, boolean, uuid[]) from public, anon, authenticated;
revoke all on function public.authorize_training_account_password_reset(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.finalize_training_account_password_reset(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.get_training_account_context(uuid) from public, anon, authenticated;

grant execute on function public.finalize_provisioned_training_account(uuid, uuid, uuid, text, uuid[], boolean) to service_role;
grant execute on function public.list_internal_admin_training_accounts(uuid, uuid) to service_role;
grant execute on function public.update_internal_admin_training_account(uuid, uuid, uuid, text, boolean, uuid[]) to service_role;
grant execute on function public.authorize_training_account_password_reset(uuid, uuid, uuid) to service_role;
grant execute on function public.finalize_training_account_password_reset(uuid, uuid, uuid) to service_role;
grant execute on function public.get_training_account_context(uuid) to service_role;

comment on table public.training_memberships is
  'Phase 2A Training account membership. Supabase Auth remains the identity source; this table grants standalone learner portal access.';
comment on table public.training_membership_branches is
  'Phase 2A Training branch assignments keyed by branch UUID, never branch code.';
