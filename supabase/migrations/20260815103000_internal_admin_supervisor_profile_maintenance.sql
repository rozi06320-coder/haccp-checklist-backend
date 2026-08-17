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

create function public.update_internal_admin_supervisor_profile(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_supervisor_user_id uuid,
  p_full_name text,
  p_full_name_ar text,
  p_person_code text,
  p_phone_number text,
  p_country_code text,
  p_iqama_number text,
  p_iqama_expiry_date date
) returns table(
  id uuid,
  full_name text,
  full_name_ar text,
  person_code text,
  phone_number text,
  country_code text,
  iqama_number text,
  iqama_expiry_date date,
  email text,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_full_name text := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p_full_name, '')), '\s+', ' ', 'g');
  normalized_full_name_ar text := nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p_full_name_ar, '')), '\s+', ' ', 'g'), '');
  normalized_person_code text := nullif(pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p_person_code, '')), '\s+', ' ', 'g'), '');
  normalized_phone_number text := nullif(pg_catalog.btrim(coalesce(p_phone_number, '')), '');
  normalized_country_code text := nullif(pg_catalog.upper(pg_catalog.btrim(coalesce(p_country_code, ''))), '');
  normalized_iqama_number text := nullif(pg_catalog.btrim(coalesce(p_iqama_number, '')), '');
  primary_branch_id uuid;
begin
  if not private.is_internal_admin(p_actor_user_id)
    or not exists(select 1 from public.organizations organization where organization.id = p_organization_id)
  then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if pg_catalog.length(normalized_full_name) = 0
    or pg_catalog.length(normalized_full_name) > 120
    or (normalized_full_name_ar is not null and pg_catalog.length(normalized_full_name_ar) > 120)
    or (normalized_person_code is not null and pg_catalog.length(normalized_person_code) > 80)
    or (normalized_phone_number is not null and pg_catalog.length(normalized_phone_number) > 40)
    or (normalized_country_code is not null and normalized_country_code !~ '^[A-Z]{2}$')
    or (normalized_iqama_number is not null and pg_catalog.length(normalized_iqama_number) > 80)
  then
    raise exception 'invalid supervisor profile' using errcode = '22023';
  end if;

  select membership.branch_id into primary_branch_id
  from public.branch_memberships membership
  join public.branches branch on branch.id = membership.branch_id
  where branch.organization_id = p_organization_id
    and membership.user_id = p_supervisor_user_id
    and membership.role = 'branch_manager'
  order by membership.created_at, membership.branch_id
  limit 1;

  if primary_branch_id is null then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  update public.profiles profile
  set full_name = normalized_full_name,
      full_name_ar = normalized_full_name_ar,
      person_code = normalized_person_code,
      phone_number = normalized_phone_number,
      country_code = normalized_country_code,
      iqama_number = normalized_iqama_number,
      iqama_expiry_date = p_iqama_expiry_date,
      updated_at = now()
  where profile.id = p_supervisor_user_id;

  if not found then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, branch_id, action, details)
  values(
    p_organization_id,
    p_actor_user_id,
    p_supervisor_user_id,
    primary_branch_id,
    'supervisor_profile_updated',
    pg_catalog.jsonb_build_object(
      'role', 'branch_manager',
      'updated_fields', pg_catalog.jsonb_build_array(
        'full_name',
        'full_name_ar',
        'person_code',
        'phone_number',
        'country_code',
        'iqama_number',
        'iqama_expiry_date'
      )
    )
  );

  return query
    select profile.id,
      profile.full_name,
      profile.full_name_ar,
      profile.person_code,
      profile.phone_number,
      profile.country_code,
      profile.iqama_number,
      profile.iqama_expiry_date,
      auth_user.email::text,
      profile.updated_at
    from public.profiles profile
    join auth.users auth_user on auth_user.id = profile.id
    where profile.id = p_supervisor_user_id;
end;
$$;

revoke all on function public.update_internal_admin_supervisor_profile(uuid, uuid, uuid, text, text, text, text, text, text, date)
  from public, anon, authenticated;
grant execute on function public.update_internal_admin_supervisor_profile(uuid, uuid, uuid, text, text, text, text, text, text, date)
  to service_role;
