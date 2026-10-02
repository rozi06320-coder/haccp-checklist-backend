-- Add a durable account-to-staff identity and an atomic Internal Admin demotion flow.

alter table public.operational_staff
  add column if not exists account_user_id uuid references auth.users(id) on delete restrict;

with promotion_links as (
  select distinct
    training.organization_id,
    training.operational_staff_id,
    training.promoted_supervisor_user_id
  from public.operational_staff_supervisor_training training
  join public.operational_staff staff
    on staff.id = training.operational_staff_id
   and staff.organization_id = training.organization_id
  where training.promoted_supervisor_user_id is not null
), unambiguous as (
  select link.organization_id, link.operational_staff_id, link.promoted_supervisor_user_id
  from promotion_links link
  where (
    select count(distinct other.operational_staff_id)
    from promotion_links other
    where other.organization_id = link.organization_id
      and other.promoted_supervisor_user_id = link.promoted_supervisor_user_id
  ) = 1
  and (
    select count(distinct other.promoted_supervisor_user_id)
    from promotion_links other
    where other.organization_id = link.organization_id
      and other.operational_staff_id = link.operational_staff_id
  ) = 1
)
update public.operational_staff staff
set account_user_id = link.promoted_supervisor_user_id,
    updated_at = now()
from unambiguous link
where staff.id = link.operational_staff_id
  and staff.organization_id = link.organization_id
  and staff.account_user_id is null;

create unique index if not exists operational_staff_organization_account_user_key
  on public.operational_staff(organization_id, account_user_id)
  where account_user_id is not null;

create or replace function private.link_promoted_operational_staff_account()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'promoted' and new.promoted_supervisor_user_id is not null then
    update public.operational_staff staff
    set account_user_id = new.promoted_supervisor_user_id,
        updated_at = now()
    where staff.id = new.operational_staff_id
      and staff.organization_id = new.organization_id
      and (
        staff.account_user_id is null
        or staff.account_user_id = new.promoted_supervisor_user_id
      );

    if not found then
      raise exception 'operational staff account identity conflict' using errcode = '23505';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists operational_staff_supervisor_training_link_account
  on public.operational_staff_supervisor_training;
create trigger operational_staff_supervisor_training_link_account
after insert or update of status, promoted_supervisor_user_id
on public.operational_staff_supervisor_training
for each row execute function private.link_promoted_operational_staff_account();

create or replace function private.enforce_account_operational_role_exclusivity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_user_id uuid;
  target_organization_id uuid;
begin
  if tg_table_name = 'operational_staff' then
    target_user_id := new.account_user_id;
    target_organization_id := new.organization_id;
  else
    target_user_id := new.user_id;
    select branch.organization_id into target_organization_id
    from public.branches branch
    where branch.id = new.branch_id;
  end if;

  if target_user_id is not null and exists (
    select 1
    from public.operational_staff staff
    where staff.organization_id = target_organization_id
      and staff.account_user_id = target_user_id
      and staff.employment_status = 'active'
  ) and exists (
    select 1
    from public.branch_memberships membership
    join public.branches branch on branch.id = membership.branch_id
    where branch.organization_id = target_organization_id
      and membership.user_id = target_user_id
      and membership.role = 'branch_manager'
      and membership.active
  ) then
    raise exception 'account cannot be active as supervisor and operational staff'
      using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists operational_staff_account_role_exclusivity on public.operational_staff;
create constraint trigger operational_staff_account_role_exclusivity
after insert or update of account_user_id, employment_status
on public.operational_staff
deferrable initially deferred
for each row execute function private.enforce_account_operational_role_exclusivity();

drop trigger if exists branch_memberships_account_role_exclusivity on public.branch_memberships;
create constraint trigger branch_memberships_account_role_exclusivity
after insert or update of role, active
on public.branch_memberships
deferrable initially deferred
for each row execute function private.enforce_account_operational_role_exclusivity();

alter table public.account_management_audit_logs
  drop constraint account_management_audit_logs_action_check;
alter table public.account_management_audit_logs
  add constraint account_management_audit_logs_action_check check(action = any(array[
    'user_created','user_disabled','user_enabled','temporary_password_reset','password_changed',
    'branch_created','branch_assignment_added','branch_assignment_removed','branch_role_changed',
    'daily_audit_pin_configured','daily_audit_pin_replaced','daily_audit_access_granted',
    'daily_audit_user_access_granted','daily_audit_user_access_revoked',
    'daily_audit_access_user_created','daily_audit_access_user_revoked',
    'maintenance_access_user_created','maintenance_access_user_deactivated',
    'maintenance_user_created','maintenance_user_deactivated',
    'training_account_created','training_account_updated','training_account_deactivated',
    'training_account_reactivated','training_account_password_reset',
    'branch_shift_created','branch_shift_updated','supervisor_team_assigned',
    'supervisor_team_deactivated','supervisor_profile_updated',
    'operational_staff_created','operational_staff_updated','operational_staff_deactivated',
    'operational_staff_assignment_created','operational_staff_assignment_updated',
    'operational_staff_assignment_deactivated','operational_staff_duty_changed',
    'organization_logo_updated','branch_logo_updated',
    'operational_staff_supervisor_training_started',
    'operational_staff_supervisor_training_cancelled',
    'operational_staff_supervisor_training_promoted',
    'purchasing_user_created','purchasing_membership_enabled','purchasing_membership_disabled',
    'supervisor_demoted_to_staff'
  ]::text[]));

create or replace function public.get_internal_admin_supervisor_demotion_eligibility(
  actor_user_id uuid,
  target_organization_id uuid,
  target_supervisor_user_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  result jsonb;
begin
  if not private.is_internal_admin(actor_user_id)
    or not exists (
      select 1 from public.organizations organization
      where organization.id = target_organization_id and organization.active
    )
  then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.branch_memberships membership
    join public.branches branch on branch.id = membership.branch_id
    where branch.organization_id = target_organization_id
      and membership.user_id = target_supervisor_user_id
      and membership.role = 'branch_manager'
      and membership.active
  ) then
    raise exception 'active supervisor unavailable' using errcode = 'P0002';
  end if;

  select pg_catalog.jsonb_build_object(
    'supervisor_user_id', target_supervisor_user_id,
    'supervisor_name', profile.full_name,
    'expected_active_branch_ids', coalesce((
      select pg_catalog.jsonb_agg(membership.branch_id order by membership.branch_id)
      from public.branch_memberships membership
      join public.branches branch on branch.id = membership.branch_id
      where branch.organization_id = target_organization_id
        and membership.user_id = target_supervisor_user_id
        and membership.role = 'branch_manager'
        and membership.active
    ), '[]'::jsonb),
    'expected_active_supervisor_assignment_ids', coalesce((
      select pg_catalog.jsonb_agg(assignment.id order by assignment.id)
      from public.branch_operational_team_supervisors assignment
      where assignment.organization_id = target_organization_id
        and assignment.supervisor_user_id = target_supervisor_user_id
        and assignment.active
    ), '[]'::jsonb),
    'destination_branches', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', branch.id,
        'name', branch.name,
        'name_ar', branch.name_ar,
        'code', branch.code,
        'teams', coalesce((
          select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'id', team.id,
            'name', team.name
          ) order by team.normalized_name, team.id)
          from public.branch_operational_teams team
          where team.organization_id = target_organization_id
            and team.branch_id = branch.id
            and team.active
            and team.legacy_supervisor_team_id is not null
        ), '[]'::jsonb)
      ) order by pg_catalog.lower(branch.name), branch.id)
      from public.branches branch
      where branch.organization_id = target_organization_id
        and branch.active
    ), '[]'::jsonb),
    'primary_source_teams', coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'team_id', team.id,
        'team_name', team.name,
        'branch_id', team.branch_id,
        'active_staff_count', (
          select count(*)
          from public.operational_staff_assignments staff_assignment
          where staff_assignment.operational_team_id = team.id
            and staff_assignment.active
        ),
        'eligible_replacements', coalesce((
          select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'user_id', candidate.id,
            'full_name', candidate.full_name,
            'current_role', candidate_assignment.assignment_role
          ) order by pg_catalog.lower(candidate.full_name), candidate.id)
          from public.branch_memberships candidate_membership
          join public.profiles candidate on candidate.id = candidate_membership.user_id
          left join public.branch_operational_team_supervisors candidate_assignment
            on candidate_assignment.operational_team_id = team.id
           and candidate_assignment.supervisor_user_id = candidate.id
           and candidate_assignment.active
          where candidate_membership.branch_id = team.branch_id
            and candidate_membership.role = 'branch_manager'
            and candidate_membership.active
            and candidate.disabled_at is null
            and not candidate.must_change_password
            and candidate.id <> target_supervisor_user_id
            and coalesce(candidate_assignment.assignment_role, 'backup') <> 'primary'
            and not exists (
              select 1 from public.operational_staff active_staff
              where active_staff.organization_id = target_organization_id
                and active_staff.account_user_id = candidate.id
                and active_staff.employment_status = 'active'
            )
        ), '[]'::jsonb)
      ) order by team.branch_id, team.id)
      from public.branch_operational_team_supervisors assignment
      join public.branch_operational_teams team on team.id = assignment.operational_team_id
      where assignment.organization_id = target_organization_id
        and assignment.supervisor_user_id = target_supervisor_user_id
        and assignment.assignment_role = 'primary'
        and assignment.active
        and team.active
    ), '[]'::jsonb)
  ) into result
  from public.profiles profile
  where profile.id = target_supervisor_user_id
    and profile.disabled_at is null;

  if result is null then
    raise exception 'active supervisor unavailable' using errcode = 'P0002';
  end if;
  return result;
end;
$$;

create or replace function public.demote_internal_admin_supervisor_to_staff(
  actor_user_id uuid,
  target_organization_id uuid,
  target_supervisor_user_id uuid,
  destination_branch_id uuid,
  destination_team_id uuid,
  new_operational_roles text[],
  expected_active_branch_ids uuid[],
  expected_active_supervisor_assignment_ids uuid[],
  replacement_primary_supervisor_user_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_variable
declare
  target_profile public.profiles%rowtype;
  destination_branch public.branches%rowtype;
  destination_team public.branch_operational_teams%rowtype;
  staff_row public.operational_staff%rowtype;
  replacement_profile public.profiles%rowtype;
  replacement_assignment public.branch_operational_team_supervisors%rowtype;
  required_replacement_team public.branch_operational_teams%rowtype;
  actual_branch_ids uuid[];
  actual_assignment_ids uuid[];
  legacy_staff_count integer := 0;
  required_replacement_count integer := 0;
  destination_business_date date;
  replacement_business_date date;
  created_staff boolean := false;
  new_staff_assignment_id uuid;
  new_replacement_assignment_id uuid;
  closed_assignments jsonb := '[]'::jsonb;
  replacement_assignments jsonb := '[]'::jsonb;
  clean_staff_code text;
  auth_email text;
  changed_at timestamptz := now();
begin
  if not private.is_internal_admin(actor_user_id)
    or not private.operational_roles_are_valid(new_operational_roles)
  then
    raise exception 'supervisor demotion denied' using errcode = '42501';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(target_organization_id::text || ':' || target_supervisor_user_id::text || ':supervisor-lifecycle', 0)
  );

  select profile.* into strict target_profile
  from public.profiles profile
  where profile.id = target_supervisor_user_id
    and profile.disabled_at is null
  for update;

  select auth_user.email::text into auth_email
  from auth.users auth_user
  where auth_user.id = target_supervisor_user_id;

  if nullif(pg_catalog.btrim(coalesce(target_profile.full_name, '')), '') is null then
    raise exception 'supervisor profile name is required' using errcode = '22023';
  end if;

  select branch.* into strict destination_branch
  from public.branches branch
  join public.organizations organization on organization.id = branch.organization_id
  where branch.id = destination_branch_id
    and branch.organization_id = target_organization_id
    and branch.active
    and organization.active
  for update of branch;

  select team.* into strict destination_team
  from public.branch_operational_teams team
  where team.id = destination_team_id
    and team.organization_id = target_organization_id
    and team.branch_id = destination_branch_id
    and team.active
    and team.legacy_supervisor_team_id is not null
  for update;

  perform 1
  from public.branch_memberships membership
  join public.branches branch on branch.id = membership.branch_id
  where branch.organization_id = target_organization_id
    and membership.user_id = target_supervisor_user_id
    and membership.role = 'branch_manager'
  order by membership.branch_id
  for update of membership;

  select coalesce(pg_catalog.array_agg(membership.branch_id order by membership.branch_id), '{}'::uuid[])
  into actual_branch_ids
  from public.branch_memberships membership
  join public.branches branch on branch.id = membership.branch_id
  where branch.organization_id = target_organization_id
    and membership.user_id = target_supervisor_user_id
    and membership.role = 'branch_manager'
    and membership.active;

  if actual_branch_ids is distinct from coalesce(expected_active_branch_ids, '{}'::uuid[])
    or pg_catalog.cardinality(actual_branch_ids) = 0
  then
    raise exception 'supervisor lifecycle changed' using errcode = '40001';
  end if;

  perform 1
  from public.branch_operational_team_supervisors assignment
  join public.branch_operational_teams team on team.id = assignment.operational_team_id
  where assignment.organization_id = target_organization_id
    and assignment.supervisor_user_id = target_supervisor_user_id
    and assignment.active
  order by assignment.operational_team_id, assignment.id
  for update of assignment, team;

  select coalesce(pg_catalog.array_agg(assignment.id order by assignment.id), '{}'::uuid[])
  into actual_assignment_ids
  from public.branch_operational_team_supervisors assignment
  where assignment.organization_id = target_organization_id
    and assignment.supervisor_user_id = target_supervisor_user_id
    and assignment.active;

  if actual_assignment_ids is distinct from coalesce(expected_active_supervisor_assignment_ids, '{}'::uuid[]) then
    raise exception 'supervisor lifecycle changed' using errcode = '40001';
  end if;

  perform 1
  from public.operational_staff_assignments staff_assignment
  where staff_assignment.active
    and (
      staff_assignment.operational_team_id = destination_team_id
      or staff_assignment.operational_team_id in (
        select assignment.operational_team_id
        from public.branch_operational_team_supervisors assignment
        where assignment.organization_id = target_organization_id
          and assignment.supervisor_user_id = target_supervisor_user_id
          and assignment.assignment_role = 'primary'
          and assignment.active
      )
    )
  order by staff_assignment.operational_team_id, staff_assignment.id
  for update;

  select count(*)::integer into required_replacement_count
  from public.branch_operational_team_supervisors assignment
  join public.branch_operational_teams team on team.id = assignment.operational_team_id
  where assignment.organization_id = target_organization_id
    and assignment.supervisor_user_id = target_supervisor_user_id
    and assignment.assignment_role = 'primary'
    and assignment.active
    and team.active
    and (
      exists (
        select 1 from public.operational_staff_assignments staff_assignment
        where staff_assignment.operational_team_id = team.id and staff_assignment.active
      )
      or team.id = destination_team_id
    );

  if required_replacement_count > 1 then
    raise exception 'multiple staffed primary teams require explicit replacements' using errcode = '23514';
  elsif required_replacement_count = 1 then
    select team.* into strict required_replacement_team
    from public.branch_operational_team_supervisors assignment
    join public.branch_operational_teams team on team.id = assignment.operational_team_id
    where assignment.organization_id = target_organization_id
      and assignment.supervisor_user_id = target_supervisor_user_id
      and assignment.assignment_role = 'primary'
      and assignment.active
      and team.active
      and (
        exists (
          select 1 from public.operational_staff_assignments staff_assignment
          where staff_assignment.operational_team_id = team.id and staff_assignment.active
        )
        or team.id = destination_team_id
      )
    for update of team;

    if replacement_primary_supervisor_user_id is null
      or replacement_primary_supervisor_user_id = target_supervisor_user_id
    then
      raise exception 'replacement primary supervisor required' using errcode = '23514';
    end if;

    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(required_replacement_team.id::text || ':primary-supervisor', 0)
    );

    select profile.* into strict replacement_profile
    from public.profiles profile
    join public.branch_memberships membership
      on membership.user_id = profile.id
     and membership.branch_id = required_replacement_team.branch_id
     and membership.role = 'branch_manager'
     and membership.active
    where profile.id = replacement_primary_supervisor_user_id
      and profile.disabled_at is null
      and not profile.must_change_password
      and not exists (
        select 1 from public.operational_staff active_staff
        where active_staff.organization_id = target_organization_id
          and active_staff.account_user_id = profile.id
          and active_staff.employment_status = 'active'
      )
    for update of profile, membership;

    select assignment.* into replacement_assignment
    from public.branch_operational_team_supervisors assignment
    where assignment.operational_team_id = required_replacement_team.id
      and assignment.supervisor_user_id = replacement_primary_supervisor_user_id
      and assignment.active
    for update;

    if replacement_assignment.id is not null and replacement_assignment.assignment_role <> 'backup' then
      raise exception 'replacement primary supervisor conflict' using errcode = '23505';
    end if;
  elsif replacement_primary_supervisor_user_id is not null then
    raise exception 'replacement primary supervisor is not required' using errcode = '22023';
  end if;

  select staff.* into staff_row
  from public.operational_staff staff
  where staff.organization_id = target_organization_id
    and staff.account_user_id = target_supervisor_user_id
  for update;

  if staff_row.id is null then
    select count(distinct training.operational_staff_id)::integer
    into legacy_staff_count
    from public.operational_staff_supervisor_training training
    join public.operational_staff staff
      on staff.id = training.operational_staff_id
     and staff.organization_id = training.organization_id
    where training.organization_id = target_organization_id
      and training.promoted_supervisor_user_id = target_supervisor_user_id;

    if legacy_staff_count > 1 then
      raise exception 'supervisor staff identity is ambiguous' using errcode = '23514';
    elsif legacy_staff_count = 1 then
      select staff.* into strict staff_row
      from public.operational_staff_supervisor_training training
      join public.operational_staff staff on staff.id = training.operational_staff_id
      where training.organization_id = target_organization_id
        and training.promoted_supervisor_user_id = target_supervisor_user_id
      order by training.promoted_at desc nulls last, training.id
      limit 1
      for update of staff;

      if staff_row.account_user_id is not null
        and staff_row.account_user_id <> target_supervisor_user_id
      then
        raise exception 'supervisor staff identity conflict' using errcode = '23505';
      end if;

      update public.operational_staff
      set account_user_id = target_supervisor_user_id,
          updated_at = changed_at
      where id = staff_row.id;
    end if;
  end if;

  if staff_row.id is not null and staff_row.employment_status = 'active' then
    raise exception 'supervisor already has an active staff identity' using errcode = '23505';
  end if;

  if staff_row.id is not null then
    perform 1
    from public.operational_staff_assignments assignment
    where assignment.operational_staff_id = staff_row.id
    order by assignment.id
    for update;
  end if;

  if staff_row.id is not null and exists (
    select 1 from public.operational_staff_assignments assignment
    where assignment.operational_staff_id = staff_row.id and assignment.active
  ) then
    raise exception 'supervisor staff assignment conflict' using errcode = '23505';
  end if;

  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'assignment_id', assignment.id,
    'operational_team_id', assignment.operational_team_id,
    'assignment_role', assignment.assignment_role
  ) order by assignment.operational_team_id, assignment.id), '[]'::jsonb)
  into closed_assignments
  from public.branch_operational_team_supervisors assignment
  where assignment.organization_id = target_organization_id
    and assignment.supervisor_user_id = target_supervisor_user_id
    and assignment.active;

  update public.branch_operational_team_supervisors assignment
  set active = false,
      valid_to = greatest(assignment.valid_from, private.phase4a_business_date(branch.timezone)),
      updated_at = changed_at
  from public.branches branch
  where branch.id = assignment.branch_id
    and assignment.organization_id = target_organization_id
    and assignment.supervisor_user_id = target_supervisor_user_id
    and assignment.active;

  update public.branch_supervisor_teams legacy
  set active = false,
      updated_at = changed_at
  where legacy.organization_id = target_organization_id
    and legacy.supervisor_user_id = target_supervisor_user_id
    and legacy.active;

  update public.branch_memberships membership
  set active = false,
      updated_at = changed_at
  from public.branches branch
  where branch.id = membership.branch_id
    and branch.organization_id = target_organization_id
    and membership.user_id = target_supervisor_user_id
    and membership.role = 'branch_manager'
    and membership.active;

  if required_replacement_count = 1 then
    replacement_business_date := private.phase4a_business_date((
      select branch.timezone from public.branches branch
      where branch.id = required_replacement_team.branch_id
    ));

    if replacement_assignment.id is not null then
      update public.branch_operational_team_supervisors
      set active = false,
          valid_to = greatest(valid_from, replacement_business_date),
          updated_at = changed_at
      where id = replacement_assignment.id;
    end if;

    insert into public.branch_operational_team_supervisors(
      organization_id, branch_id, operational_team_id, supervisor_user_id,
      assignment_role, active, valid_from, valid_to, created_by
    ) values (
      target_organization_id, required_replacement_team.branch_id,
      required_replacement_team.id, replacement_primary_supervisor_user_id,
      'primary', true, replacement_business_date, null, actor_user_id
    ) returning id into new_replacement_assignment_id;

    replacement_assignments := pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'operational_team_id', required_replacement_team.id,
      'replacement_supervisor_user_id', replacement_primary_supervisor_user_id,
      'new_assignment_id', new_replacement_assignment_id,
      'closed_backup_assignment_id', replacement_assignment.id
    ));
  end if;

  destination_business_date := private.phase4a_business_date(destination_branch.timezone);

  if staff_row.id is null then
    clean_staff_code := nullif(pg_catalog.btrim(target_profile.person_code), '');
    insert into public.operational_staff(
      organization_id, branch_id, display_name, employment_status, created_by,
      staff_code, company_name, country_code, iqama_number, iqama_expiry_date,
      phone_number, email, account_user_id
    ) values (
      target_organization_id, destination_branch_id,
      pg_catalog.regexp_replace(pg_catalog.btrim(target_profile.full_name), '[[:space:]]+', ' ', 'g'),
      'active', actor_user_id, clean_staff_code,
      (select organization.name from public.organizations organization where organization.id = target_organization_id),
      target_profile.country_code, target_profile.iqama_number, target_profile.iqama_expiry_date,
      target_profile.phone_number, nullif(pg_catalog.btrim(auth_email), ''), target_supervisor_user_id
    ) returning * into staff_row;
    created_staff := true;
  else
    update public.operational_staff
    set branch_id = destination_branch_id,
        employment_status = 'active',
        deactivated_at = null,
        deactivated_by = null,
        account_user_id = target_supervisor_user_id,
        updated_at = changed_at
    where id = staff_row.id
    returning * into staff_row;
  end if;

  insert into public.operational_staff_assignments(
    organization_id, branch_id, operational_staff_id, supervisor_team_id,
    operational_team_id, operational_roles, valid_from, created_by_user_id
  ) values (
    target_organization_id, destination_branch_id, staff_row.id,
    destination_team.legacy_supervisor_team_id, destination_team.id,
    new_operational_roles, destination_business_date, actor_user_id
  ) returning id into new_staff_assignment_id;

  insert into public.account_management_audit_logs(
    organization_id, actor_user_id, target_user_id, branch_id, action, details
  ) values (
    target_organization_id, actor_user_id, target_supervisor_user_id,
    destination_branch_id, 'supervisor_demoted_to_staff',
    pg_catalog.jsonb_build_object(
      'supervisor_user_id', target_supervisor_user_id,
      'operational_staff_id', staff_row.id,
      'destination_branch_id', destination_branch_id,
      'destination_team_id', destination_team_id,
      'new_staff_assignment_id', new_staff_assignment_id,
      'operational_roles', to_jsonb(new_operational_roles),
      'closed_supervisor_assignments', closed_assignments,
      'replacement_primary_assignments', replacement_assignments,
      'staff_identity', case when created_staff then 'created' else 'reused' end
    )
  );

  return pg_catalog.jsonb_build_object(
    'supervisor_user_id', target_supervisor_user_id,
    'operational_staff_id', staff_row.id,
    'destination_branch_id', destination_branch_id,
    'destination_team_id', destination_team_id,
    'staff_assignment_id', new_staff_assignment_id,
    'operational_roles', to_jsonb(new_operational_roles),
    'staff_identity', case when created_staff then 'created' else 'reused' end,
    'closed_supervisor_assignments', closed_assignments,
    'replacement_primary_assignments', replacement_assignments
  );
exception
  when no_data_found or too_many_rows then
    raise exception 'supervisor demotion denied' using errcode = '42501';
end;
$$;

revoke all on function public.get_internal_admin_supervisor_demotion_eligibility(uuid,uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.get_internal_admin_supervisor_demotion_eligibility(uuid,uuid,uuid)
  to service_role;

revoke all on function public.demote_internal_admin_supervisor_to_staff(uuid,uuid,uuid,uuid,uuid,text[],uuid[],uuid[],uuid)
  from public, anon, authenticated;
grant execute on function public.demote_internal_admin_supervisor_to_staff(uuid,uuid,uuid,uuid,uuid,text[],uuid[],uuid[],uuid)
  to service_role;

revoke all on function private.link_promoted_operational_staff_account()
  from public, anon, authenticated;
revoke all on function private.enforce_account_operational_role_exclusivity()
  from public, anon, authenticated;

notify pgrst, 'reload schema';
