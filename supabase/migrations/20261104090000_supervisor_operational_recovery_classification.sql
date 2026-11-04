-- Restore operational Supervisor access after a Training Supervisor transition.
-- Classification is display metadata; branch_manager remains the authorization role.

alter table public.account_management_audit_logs
  drop constraint if exists account_management_audit_logs_action_check;

alter table public.account_management_audit_logs
  add constraint account_management_audit_logs_action_check check (
    action in (
      'user_created','user_disabled','user_enabled','temporary_password_reset','password_changed',
      'branch_created','branch_assignment_added','branch_assignment_removed','branch_role_changed',
      'daily_audit_pin_configured','daily_audit_pin_replaced','daily_audit_access_granted',
      'daily_audit_user_access_granted','daily_audit_user_access_revoked','daily_audit_access_user_created',
      'daily_audit_access_user_revoked','maintenance_access_user_created','maintenance_access_user_deactivated',
      'maintenance_user_created','maintenance_user_deactivated','training_account_created',
      'training_account_updated','training_account_deactivated','training_account_reactivated',
      'training_account_password_reset','branch_shift_created','branch_shift_updated',
      'training_supervisor_granted','training_supervisor_suspended','training_supervisor_reactivated',
      'training_supervisor_revoked','training_supervisor_reassigned',
      'supervisor_team_assigned','supervisor_team_deactivated','supervisor_profile_updated',
      'operational_staff_created','operational_staff_updated','operational_staff_deactivated',
      'operational_staff_assignment_created','operational_staff_assignment_updated',
      'operational_staff_assignment_deactivated','operational_staff_duty_changed',
      'organization_logo_updated','branch_logo_updated','operational_staff_supervisor_training_started',
      'operational_staff_supervisor_training_cancelled','operational_staff_supervisor_training_promoted',
      'purchasing_user_created','purchasing_membership_enabled','purchasing_membership_disabled',
      'supervisor_demoted_to_staff','user_role_transitioned',
      'supervisor_operational_access_restored','supervisor_classification_changed',
      'training_membership_deactivated_for_supervisor_restore'
    )
  );

create table public.supervisor_access_classifications (
  organization_id uuid not null references public.organizations(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  classification text not null check (classification in ('supervisor','training_supervisor')),
  active boolean not null default true,
  created_by uuid not null references auth.users(id) on delete restrict,
  updated_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (organization_id,user_id)
);

alter table public.supervisor_access_classifications enable row level security;
revoke all on public.supervisor_access_classifications from public, anon, authenticated, service_role;
create index supervisor_access_classifications_user_idx
  on public.supervisor_access_classifications(user_id,organization_id,active);
create trigger supervisor_access_classifications_set_updated_at
  before update on public.supervisor_access_classifications
  for each row execute function private.set_updated_at();

create function public.restore_internal_admin_supervisor_operational_access(
  actor_user_id uuid,
  target_organization_id uuid,
  target_user_id uuid,
  target_branch_ids uuid[],
  historical_assignment_ids uuid[]
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  profile_row public.profiles%rowtype;
  branch_id uuid;
  assignment_row public.branch_operational_team_supervisors%rowtype;
  restored_count integer := 0;
  branch_count integer := 0;
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'internal admin access denied' using errcode='42501';
  end if;
  if target_branch_ids is null or pg_catalog.cardinality(target_branch_ids)=0
     or pg_catalog.cardinality(target_branch_ids)>50
     or (select count(*)<>count(distinct x) from pg_catalog.unnest(target_branch_ids) x)
     or historical_assignment_ids is null
     or (select count(*)<>count(distinct x) from pg_catalog.unnest(historical_assignment_ids) x)
  then raise exception 'invalid supervisor restoration input' using errcode='22023'; end if;

  select profile.* into strict profile_row
  from public.profiles profile
  where profile.id=target_user_id
  for update;
  if profile_row.disabled_at is not null then
    raise exception 'disabled supervisor cannot be restored' using errcode='42501';
  end if;

  if exists (
    select 1
    from public.operational_staff_supervisor_training training
    join public.operational_staff staff on staff.id=training.operational_staff_id
    where training.organization_id=target_organization_id
      and training.promoted_supervisor_user_id=target_user_id
      and training.status='promoted'
      and staff.employment_status='active'
  ) then
    raise exception 'active operational staff record conflicts with supervisor recovery' using errcode='23514';
  end if;

  if (select count(*) from public.branches branch
      where branch.id=any(target_branch_ids)
        and branch.organization_id=target_organization_id and branch.active)
     <> pg_catalog.cardinality(target_branch_ids) then
    raise exception 'invalid supervisor restoration branch scope' using errcode='42501';
  end if;

  if (select count(*) from public.branch_memberships membership
      join public.branches branch on branch.id=membership.branch_id
      where membership.user_id=target_user_id
        and membership.role='branch_manager'
        and branch.organization_id=target_organization_id
        and membership.branch_id=any(target_branch_ids))
     <> pg_catalog.cardinality(target_branch_ids)
     or exists (
       select 1 from public.branch_memberships membership
       join public.branches branch on branch.id=membership.branch_id
       where membership.user_id=target_user_id
         and membership.role='branch_manager' and membership.active
         and branch.organization_id=target_organization_id
         and not (membership.branch_id=any(target_branch_ids))
     ) then
    raise exception 'supervisor restoration branch history conflict' using errcode='23514';
  end if;

  if exists (
    select 1 from public.branch_memberships membership
    join public.branches branch on branch.id=membership.branch_id
    where membership.user_id=target_user_id
      and branch.organization_id=target_organization_id
      and membership.active and membership.role<>'branch_manager'
  ) then raise exception 'conflicting active branch membership' using errcode='23514'; end if;

  if (select count(*) from public.branch_operational_team_supervisors assignment
      where assignment.id=any(historical_assignment_ids)
        and assignment.organization_id=target_organization_id
        and assignment.supervisor_user_id=target_user_id
        and not assignment.active
        and assignment.valid_to is not null
        and assignment.branch_id=any(target_branch_ids))
     <> pg_catalog.cardinality(historical_assignment_ids) then
    raise exception 'historical supervisor assignment is invalid' using errcode='42501';
  end if;

  -- Lock every affected team before checking ownership, making concurrent recovery
  -- or reassignment fail atomically rather than partially restoring this account.
  perform 1
  from public.branch_operational_teams team
  join public.branch_operational_team_supervisors historical
    on historical.operational_team_id=team.id
   and historical.id=any(historical_assignment_ids)
  where team.organization_id=target_organization_id
    and team.active
  for update of team;

  if exists (
    select 1
    from public.branch_operational_team_supervisors existing
    join public.branch_operational_team_supervisors historical
      on historical.id=any(historical_assignment_ids)
     and existing.operational_team_id=historical.operational_team_id
     and existing.assignment_role=historical.assignment_role
    where existing.active and existing.supervisor_user_id<>target_user_id
  ) then raise exception 'historical supervisor team position is occupied' using errcode='23505'; end if;

  -- Remove only the legacy authorization-conflicting Training membership. Its
  -- row and branch history remain intact; the new classification is separate.
  update public.training_memberships membership
  set active=false, updated_at=now(), updated_by=actor_user_id
  where membership.organization_id=target_organization_id
    and membership.user_id=target_user_id
    and membership.active;
  if found then
    insert into public.account_management_audit_logs(
      organization_id,actor_user_id,target_user_id,action,details
    ) values(
      target_organization_id,actor_user_id,target_user_id,
      'training_membership_deactivated_for_supervisor_restore',
      pg_catalog.jsonb_build_object('reason','operational_supervisor_classification_restore')
    );
  end if;

  foreach branch_id in array target_branch_ids loop
    insert into public.branch_memberships(branch_id,user_id,role,active)
    values(branch_id,target_user_id,'branch_manager',true)
    on conflict on constraint branch_memberships_pkey do update
      set role='branch_manager',active=true,updated_at=now();
    branch_count := branch_count + 1;
  end loop;

  for assignment_row in
    select assignment.*
    from public.branch_operational_team_supervisors assignment
    where assignment.id=any(historical_assignment_ids)
    order by assignment.id
  loop
    if not exists (
      select 1 from public.branch_operational_team_supervisors existing
      where existing.operational_team_id=assignment_row.operational_team_id
        and existing.supervisor_user_id=target_user_id and existing.active
    ) then
      insert into public.branch_operational_team_supervisors(
        organization_id,branch_id,operational_team_id,supervisor_user_id,
        assignment_role,active,valid_from,valid_to,created_by
      ) values (
        assignment_row.organization_id,assignment_row.branch_id,assignment_row.operational_team_id,
        target_user_id,assignment_row.assignment_role,true,current_date,null,actor_user_id
      );
      restored_count := restored_count + 1;
    end if;
  end loop;

  insert into public.supervisor_access_classifications(
    organization_id,user_id,classification,active,created_by,updated_by
  ) values(target_organization_id,target_user_id,'training_supervisor',true,actor_user_id,actor_user_id)
  on conflict (organization_id,user_id) do update
    set classification='training_supervisor',active=true,updated_by=actor_user_id,updated_at=now();

  insert into public.account_management_audit_logs(
    organization_id,actor_user_id,target_user_id,action,details
  ) values(
    target_organization_id,actor_user_id,target_user_id,
    'supervisor_operational_access_restored',
    pg_catalog.jsonb_build_object(
      'branch_count',branch_count,
      'restored_assignment_count',restored_count,
      'historical_assignment_ids',historical_assignment_ids
    )
  );
  return pg_catalog.jsonb_build_object(
    'organization_id',target_organization_id,'user_id',target_user_id,
    'classification','training_supervisor','branch_count',branch_count,
    'restored_assignment_count',restored_count
  );
exception
  when unique_violation then
    raise exception 'supervisor restoration conflict' using errcode='23505';
end;
$$;

create function public.set_internal_admin_supervisor_classification(
  actor_user_id uuid,
  target_organization_id uuid,
  target_user_id uuid,
  target_classification text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_internal_admin(actor_user_id)
     or target_classification not in ('supervisor','training_supervisor')
     or not exists(
       select 1 from public.branch_memberships membership
       join public.branches branch on branch.id=membership.branch_id
       where membership.user_id=target_user_id
         and membership.role='branch_manager' and membership.active
         and branch.organization_id=target_organization_id and branch.active
     ) then raise exception 'supervisor classification access denied' using errcode='42501'; end if;

  insert into public.supervisor_access_classifications(
    organization_id,user_id,classification,active,created_by,updated_by
  ) values(target_organization_id,target_user_id,target_classification,true,actor_user_id,actor_user_id)
  on conflict (organization_id,user_id) do update
    set classification=excluded.classification,active=true,updated_by=actor_user_id,updated_at=now();

  insert into public.account_management_audit_logs(
    organization_id,actor_user_id,target_user_id,action,details
  ) values(target_organization_id,actor_user_id,target_user_id,'supervisor_classification_changed',
    pg_catalog.jsonb_build_object('classification',target_classification));
  return pg_catalog.jsonb_build_object(
    'organization_id',target_organization_id,'user_id',target_user_id,
    'classification',target_classification
  );
end;
$$;

revoke all on function public.restore_internal_admin_supervisor_operational_access(uuid,uuid,uuid,uuid[],uuid[])
  from public,anon,authenticated;
revoke all on function public.set_internal_admin_supervisor_classification(uuid,uuid,uuid,text)
  from public,anon,authenticated;
grant execute on function public.restore_internal_admin_supervisor_operational_access(uuid,uuid,uuid,uuid[],uuid[])
  to service_role;
grant execute on function public.set_internal_admin_supervisor_classification(uuid,uuid,uuid,text)
  to service_role;

comment on table public.supervisor_access_classifications is
  'Display classification only; operational Supervisor authorization remains branch_memberships.role=branch_manager.';
