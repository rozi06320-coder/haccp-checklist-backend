-- Same-branch team moves remain immediate until today's Hygiene roster is final.
-- Once the employee or destination roster is submitted, defer the move to the
-- next branch-local business day without changing the current assignment.

create table public.operational_staff_scheduled_team_moves (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  operational_staff_id uuid not null,
  source_assignment_id uuid not null,
  source_operational_team_id uuid not null,
  destination_operational_team_id uuid not null,
  requested_by_user_id uuid not null references auth.users(id) on delete restrict,
  requested_at timestamptz not null default now(),
  requested_business_date date not null,
  effective_business_date date not null,
  status text not null default 'pending',
  applied_at timestamptz,
  applied_assignment_id uuid references public.operational_staff_assignments(id) on delete restrict,
  cancelled_at timestamptz,
  cancelled_by_user_id uuid references auth.users(id) on delete restrict,
  blocked_at timestamptz,
  blocked_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint operational_staff_scheduled_moves_branch_fkey
    foreign key(branch_id,organization_id) references public.branches(id,organization_id) on delete restrict,
  constraint operational_staff_scheduled_moves_staff_fkey
    foreign key(operational_staff_id,branch_id,organization_id)
    references public.operational_staff(id,branch_id,organization_id) on delete restrict,
  constraint operational_staff_scheduled_moves_source_assignment_fkey
    foreign key(source_assignment_id,operational_staff_id,branch_id,organization_id)
    references public.operational_staff_assignments(id,operational_staff_id,branch_id,organization_id) on delete restrict,
  constraint operational_staff_scheduled_moves_source_team_fkey
    foreign key(source_operational_team_id,branch_id,organization_id)
    references public.branch_operational_teams(id,branch_id,organization_id) on delete restrict,
  constraint operational_staff_scheduled_moves_destination_team_fkey
    foreign key(destination_operational_team_id,branch_id,organization_id)
    references public.branch_operational_teams(id,branch_id,organization_id) on delete restrict,
  constraint operational_staff_scheduled_moves_status_check
    check(status in('pending','applied','cancelled','blocked')),
  constraint operational_staff_scheduled_moves_teams_check
    check(source_operational_team_id<>destination_operational_team_id),
  constraint operational_staff_scheduled_moves_effective_date_check
    check(effective_business_date=requested_business_date+1),
  constraint operational_staff_scheduled_moves_blocked_reason_check
    check(blocked_reason is null or blocked_reason in(
      'source_assignment_changed','employee_inactive','destination_inactive','hygiene_already_submitted','scope_invalid'
    )),
  constraint operational_staff_scheduled_moves_lifecycle_check check(
    (status='pending' and applied_at is null and applied_assignment_id is null and cancelled_at is null
      and cancelled_by_user_id is null and blocked_at is null and blocked_reason is null)
    or (status='applied' and applied_at is not null and applied_assignment_id is not null
      and cancelled_at is null and cancelled_by_user_id is null and blocked_at is null and blocked_reason is null)
    or (status='cancelled' and applied_at is null and applied_assignment_id is null
      and cancelled_at is not null and cancelled_by_user_id is not null and blocked_at is null and blocked_reason is null)
    or (status='blocked' and applied_at is null and applied_assignment_id is null
      and cancelled_at is null and cancelled_by_user_id is null and blocked_at is not null and blocked_reason is not null)
  )
);

create unique index operational_staff_scheduled_moves_one_pending_key
  on public.operational_staff_scheduled_team_moves(operational_staff_id)
  where status='pending';
create index operational_staff_scheduled_moves_due_idx
  on public.operational_staff_scheduled_team_moves(effective_business_date,branch_id)
  where status='pending';
create index operational_staff_scheduled_moves_branch_status_idx
  on public.operational_staff_scheduled_team_moves(branch_id,status,requested_at desc);

create trigger operational_staff_scheduled_moves_set_updated_at
before update on public.operational_staff_scheduled_team_moves
for each row execute function private.set_updated_at();

alter table public.operational_staff_scheduled_team_moves enable row level security;
revoke all on public.operational_staff_scheduled_team_moves from public,anon,authenticated,service_role;

create or replace function private.operational_audit_details_are_allowlisted(action_name text,candidate jsonb)
returns boolean language sql immutable security invoker set search_path = '' as $$
  select action_name not in (
    'branch_shift_created','branch_shift_updated','supervisor_team_assigned','supervisor_team_deactivated',
    'operational_staff_created','operational_staff_updated','operational_staff_deactivated',
    'operational_staff_assignment_created','operational_staff_assignment_updated',
    'operational_staff_assignment_deactivated','operational_staff_duty_changed'
  ) or not exists (
    select 1 from pg_catalog.jsonb_object_keys(candidate) key
    where key not in ('shift_id','team_id','operational_staff_id','assignment_id',
      'previous_status','new_status','operational_roles','source_branch_id','source_team_id',
      'destination_branch_id','destination_team_id','closure_reason','scheduled_move_id',
      'move_status','effective_business_date','blocked_reason')
  );
$$;
revoke all on function private.operational_audit_details_are_allowlisted(text,jsonb) from public,anon,authenticated;
grant execute on function private.operational_audit_details_are_allowlisted(text,jsonb) to service_role;

create function private.block_operational_staff_scheduled_move(target_move_id uuid,reason text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.operational_staff_scheduled_team_moves move
  set status='blocked',blocked_at=now(),blocked_reason=reason
  where move.id=target_move_id and move.status='pending';
end $$;

create function private.apply_due_operational_staff_team_moves(
  target_branch_id uuid default null,
  target_organization_id uuid default null
)
returns table(move_id uuid,move_status text,staff_id uuid,assignment_id uuid,operational_team_id uuid,effective_business_date date)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  scheduled public.operational_staff_scheduled_team_moves%rowtype;
  staff_row public.operational_staff%rowtype;
  source_assignment public.operational_staff_assignments%rowtype;
  destination_team public.branch_operational_teams%rowtype;
  created_assignment uuid;
  current_business_date date;
begin
  for scheduled in
    select move.*
    from public.operational_staff_scheduled_team_moves move
    join public.branches branch on branch.id=move.branch_id and branch.organization_id=move.organization_id
    where move.status='pending'
      and (target_branch_id is null or move.branch_id=target_branch_id)
      and (target_organization_id is null or move.organization_id=target_organization_id)
      and move.effective_business_date<=private.phase4a_business_date(branch.timezone)
    order by move.effective_business_date,move.requested_at,move.id
    for update of move skip locked
  loop
    select private.phase4a_business_date(branch.timezone) into strict current_business_date
    from public.branches branch where branch.id=scheduled.branch_id and branch.organization_id=scheduled.organization_id;

    select * into staff_row from public.operational_staff staff
    where staff.id=scheduled.operational_staff_id and staff.organization_id=scheduled.organization_id for update;
    if not found or staff_row.branch_id<>scheduled.branch_id then
      perform private.block_operational_staff_scheduled_move(scheduled.id,'scope_invalid');
      return query select scheduled.id,'blocked'::text,scheduled.operational_staff_id,
        scheduled.source_assignment_id,scheduled.destination_operational_team_id,scheduled.effective_business_date;
      continue;
    end if;
    if staff_row.employment_status<>'active' then
      perform private.block_operational_staff_scheduled_move(scheduled.id,'employee_inactive');
      return query select scheduled.id,'blocked'::text,scheduled.operational_staff_id,
        scheduled.source_assignment_id,scheduled.destination_operational_team_id,scheduled.effective_business_date;
      continue;
    end if;

    select * into source_assignment from public.operational_staff_assignments assignment
    where assignment.id=scheduled.source_assignment_id
      and assignment.operational_staff_id=scheduled.operational_staff_id
      and assignment.organization_id=scheduled.organization_id
      and assignment.branch_id=scheduled.branch_id
      and assignment.operational_team_id=scheduled.source_operational_team_id
      and assignment.active for update;
    if not found then
      perform private.block_operational_staff_scheduled_move(scheduled.id,'source_assignment_changed');
      return query select scheduled.id,'blocked'::text,scheduled.operational_staff_id,
        scheduled.source_assignment_id,scheduled.destination_operational_team_id,scheduled.effective_business_date;
      continue;
    end if;

    select * into destination_team from public.branch_operational_teams team
    where team.id=scheduled.destination_operational_team_id
      and team.branch_id=scheduled.branch_id and team.organization_id=scheduled.organization_id for update;
    if not found or not destination_team.active or destination_team.legacy_supervisor_team_id is null then
      perform private.block_operational_staff_scheduled_move(scheduled.id,'destination_inactive');
      return query select scheduled.id,'blocked'::text,scheduled.operational_staff_id,
        scheduled.source_assignment_id,scheduled.destination_operational_team_id,scheduled.effective_business_date;
      continue;
    end if;

    if scheduled.source_operational_team_id::text<scheduled.destination_operational_team_id::text then
      perform private.lock_operational_team_hygiene(scheduled.branch_id,scheduled.source_operational_team_id,current_business_date);
      perform private.lock_operational_team_hygiene(scheduled.branch_id,scheduled.destination_operational_team_id,current_business_date);
    else
      perform private.lock_operational_team_hygiene(scheduled.branch_id,scheduled.destination_operational_team_id,current_business_date);
      perform private.lock_operational_team_hygiene(scheduled.branch_id,scheduled.source_operational_team_id,current_business_date);
    end if;

    if exists(
      select 1 from public.checklist_submissions submission
      where submission.organization_id=scheduled.organization_id and submission.branch_id=scheduled.branch_id
        and submission.business_date between scheduled.effective_business_date and current_business_date
        and submission.checklist_type='staff_hygiene'
        and submission.state='submitted' and submission.operational_team_id in(
          scheduled.source_operational_team_id,scheduled.destination_operational_team_id
        )
    ) then
      perform private.block_operational_staff_scheduled_move(scheduled.id,'hygiene_already_submitted');
      return query select scheduled.id,'blocked'::text,scheduled.operational_staff_id,
        scheduled.source_assignment_id,scheduled.destination_operational_team_id,scheduled.effective_business_date;
      continue;
    end if;

    update public.operational_staff_assignments assignment
    set active=false,valid_to=scheduled.effective_business_date-1,closed_at=now(),
      closed_by_user_id=scheduled.requested_by_user_id,closure_reason='team_move'
    where assignment.id=source_assignment.id;

    insert into public.operational_staff_assignments(organization_id,branch_id,operational_staff_id,supervisor_team_id,
      operational_team_id,operational_roles,valid_from,created_by_user_id)
    values(scheduled.organization_id,scheduled.branch_id,scheduled.operational_staff_id,
      destination_team.legacy_supervisor_team_id,destination_team.id,source_assignment.operational_roles,
      scheduled.effective_business_date,scheduled.requested_by_user_id)
    returning id into created_assignment;

    update public.operational_staff_scheduled_team_moves move
    set status='applied',applied_at=now(),applied_assignment_id=created_assignment
    where move.id=scheduled.id and move.status='pending';

    insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
    values(scheduled.organization_id,scheduled.requested_by_user_id,scheduled.branch_id,
      'operational_staff_assignment_updated',pg_catalog.jsonb_build_object(
        'team_id',destination_team.id,'operational_staff_id',scheduled.operational_staff_id,
        'assignment_id',created_assignment,'previous_status','scheduled','new_status','active',
        'operational_roles',source_assignment.operational_roles,'source_team_id',scheduled.source_operational_team_id,
        'destination_team_id',destination_team.id,'closure_reason','team_move','scheduled_move_id',scheduled.id,
        'move_status','applied','effective_business_date',scheduled.effective_business_date));

    return query select scheduled.id,'applied'::text,scheduled.operational_staff_id,created_assignment,
      destination_team.id,scheduled.effective_business_date;
  end loop;
end $$;

create function public.apply_due_operational_staff_team_moves(
  target_branch_id uuid default null,
  target_organization_id uuid default null
)
returns table(move_id uuid,move_status text,staff_id uuid,assignment_id uuid,operational_team_id uuid,effective_business_date date)
language sql security definer set search_path = '' as $$
  select * from private.apply_due_operational_staff_team_moves(target_branch_id,target_organization_id)
$$;

create function private.request_operational_staff_team_move(actor_user_id uuid,target_branch_id uuid,target_staff_id uuid,
  expected_assignment_id uuid,target_operational_team_id uuid,allow_scheduled boolean)
returns table(staff_id uuid,assignment_id uuid,operational_team_id uuid,move_status text,
  scheduled_move_id uuid,effective_business_date date)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  staff_row public.operational_staff%rowtype;
  old_assignment public.operational_staff_assignments%rowtype;
  target_team public.branch_operational_teams%rowtype;
  existing_move public.operational_staff_scheduled_team_moves%rowtype;
  created_assignment uuid;
  created_move uuid;
  current_business_date date;
  prior_duty text;
  source_recorded boolean;
  destination_submitted boolean;
begin
  perform private.apply_due_operational_staff_team_moves(target_branch_id);

  select * into staff_row from public.operational_staff staff
  where staff.id=target_staff_id and staff.branch_id=target_branch_id for update;
  if not found then raise exception 'staff move denied' using errcode='42501'; end if;
  select * into old_assignment from public.operational_staff_assignments assignment
  where assignment.operational_staff_id=target_staff_id and assignment.active for update;
  if not found then raise exception 'staff assignment changed' using errcode='40001'; end if;
  if old_assignment.id<>expected_assignment_id then
    raise exception 'staff assignment changed' using errcode='40001';
  end if;
  select * into target_team from public.branch_operational_teams team
  where team.id=target_operational_team_id and team.branch_id=target_branch_id
    and team.organization_id=staff_row.organization_id for update;
  if not found then raise exception 'invalid destination team' using errcode='22023'; end if;
  if not private.actor_can_write_operational_team(actor_user_id,target_branch_id,old_assignment.operational_team_id)
  then raise exception 'staff move denied' using errcode='42501'; end if;
  if not target_team.active or target_team.legacy_supervisor_team_id is null or staff_row.employment_status<>'active'
  then raise exception 'staff move conflicts with current team data' using errcode='23514'; end if;
  if old_assignment.operational_team_id=target_team.id
  then raise exception 'staff already belongs to team' using errcode='23505'; end if;

  select * into existing_move from public.operational_staff_scheduled_team_moves move
  where move.operational_staff_id=target_staff_id and move.status='pending' for update;
  if found then
    if existing_move.source_assignment_id=expected_assignment_id
      and existing_move.destination_operational_team_id=target_operational_team_id
    then
      return query select target_staff_id,old_assignment.id,target_operational_team_id,'scheduled'::text,
        existing_move.id,existing_move.effective_business_date;
      return;
    end if;
    raise exception 'staff pending move already exists' using errcode='23505';
  end if;

  select private.phase4a_business_date(branch.timezone) into current_business_date
  from public.branches branch where branch.id=target_branch_id and branch.active;
  if not found then raise exception 'staff move denied' using errcode='42501'; end if;

  if old_assignment.operational_team_id::text<target_team.id::text then
    perform private.lock_operational_team_hygiene(target_branch_id,old_assignment.operational_team_id,current_business_date);
    perform private.lock_operational_team_hygiene(target_branch_id,target_team.id,current_business_date);
  else
    perform private.lock_operational_team_hygiene(target_branch_id,target_team.id,current_business_date);
    perform private.lock_operational_team_hygiene(target_branch_id,old_assignment.operational_team_id,current_business_date);
  end if;

  select exists(
    select 1 from public.hygiene_staff_snapshots snapshot
    join public.checklist_submissions submission on submission.id=snapshot.submission_id
    where snapshot.operational_staff_id=target_staff_id
      and submission.organization_id=staff_row.organization_id and submission.branch_id=target_branch_id
      and submission.operational_team_id=old_assignment.operational_team_id
      and submission.business_date=current_business_date and submission.checklist_type='staff_hygiene'
      and submission.state='submitted'
  ) into source_recorded;
  select exists(
    select 1 from public.checklist_submissions submission
    where submission.organization_id=staff_row.organization_id and submission.branch_id=target_branch_id
      and submission.operational_team_id=target_team.id and submission.business_date=current_business_date
      and submission.checklist_type='staff_hygiene' and submission.state='submitted'
  ) into destination_submitted;

  if source_recorded or destination_submitted then
    if not allow_scheduled then
      raise exception 'scheduled team move requires a compatible client' using errcode='40001';
    end if;
    insert into public.operational_staff_scheduled_team_moves(organization_id,branch_id,operational_staff_id,
      source_assignment_id,source_operational_team_id,destination_operational_team_id,requested_by_user_id,
      requested_business_date,effective_business_date)
    values(staff_row.organization_id,target_branch_id,target_staff_id,old_assignment.id,
      old_assignment.operational_team_id,target_team.id,actor_user_id,current_business_date,current_business_date+1)
    returning id into created_move;

    insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
    values(staff_row.organization_id,actor_user_id,target_branch_id,'operational_staff_assignment_updated',
      pg_catalog.jsonb_build_object('team_id',target_team.id,'operational_staff_id',target_staff_id,
        'assignment_id',old_assignment.id,'previous_status','active','new_status','scheduled',
        'operational_roles',old_assignment.operational_roles,'source_team_id',old_assignment.operational_team_id,
        'destination_team_id',target_team.id,'scheduled_move_id',created_move,'move_status','scheduled',
        'effective_business_date',current_business_date+1));
    return query select target_staff_id,old_assignment.id,target_team.id,'scheduled'::text,created_move,current_business_date+1;
    return;
  end if;

  select duty.duty_status into prior_duty from public.operational_staff_duty_statuses duty
  where duty.assignment_id=old_assignment.id and duty.duty_date=current_business_date;
  update public.operational_staff_assignments assignment
  set active=false,valid_to=current_business_date,closed_at=now(),closed_by_user_id=actor_user_id,
    closure_reason='team_move'
  where assignment.id=old_assignment.id;
  insert into public.operational_staff_assignments(organization_id,branch_id,operational_staff_id,supervisor_team_id,
    operational_team_id,operational_roles,valid_from,created_by_user_id)
  values(staff_row.organization_id,target_branch_id,target_staff_id,target_team.legacy_supervisor_team_id,
    target_team.id,old_assignment.operational_roles,current_business_date,actor_user_id)
  returning id into created_assignment;
  if prior_duty is not null then
    insert into public.operational_staff_duty_statuses(organization_id,branch_id,operational_staff_id,assignment_id,
      duty_date,duty_status,set_by)
    values(staff_row.organization_id,target_branch_id,target_staff_id,created_assignment,current_business_date,
      prior_duty,actor_user_id);
  end if;
  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
  values(staff_row.organization_id,actor_user_id,target_branch_id,'operational_staff_assignment_updated',
    pg_catalog.jsonb_build_object('team_id',target_team.id,'operational_staff_id',target_staff_id,
      'assignment_id',created_assignment,'previous_status','active','new_status','active',
      'operational_roles',old_assignment.operational_roles,'source_team_id',old_assignment.operational_team_id,
      'destination_team_id',target_team.id,'move_status','applied'));
  return query select target_staff_id,created_assignment,target_team.id,'applied'::text,null::uuid,current_business_date;
end $$;

create or replace function public.move_operational_staff_team(actor_user_id uuid,target_branch_id uuid,target_staff_id uuid,
  expected_assignment_id uuid,target_operational_team_id uuid)
returns table(staff_id uuid,assignment_id uuid,operational_team_id uuid)
language sql security definer set search_path = '' as $$
  select move.staff_id,move.assignment_id,move.operational_team_id
  from private.request_operational_staff_team_move(actor_user_id,target_branch_id,target_staff_id,
    expected_assignment_id,target_operational_team_id,false) move
$$;

create function public.request_operational_staff_team_move(actor_user_id uuid,target_branch_id uuid,target_staff_id uuid,
  expected_assignment_id uuid,target_operational_team_id uuid)
returns table(staff_id uuid,assignment_id uuid,operational_team_id uuid,move_status text,
  scheduled_move_id uuid,effective_business_date date)
language sql security definer set search_path = '' as $$
  select * from private.request_operational_staff_team_move(actor_user_id,target_branch_id,target_staff_id,
    expected_assignment_id,target_operational_team_id,true)
$$;

create function public.list_operational_staff_scheduled_team_moves(actor_user_id uuid,target_branch_id uuid)
returns table(scheduled_move_id uuid,operational_staff_id uuid,source_assignment_id uuid,
  destination_operational_team_id uuid,destination_team_name text,effective_business_date date,move_status text,
  blocked_reason text)
language plpgsql security definer set search_path = '' as $$
begin
  perform private.apply_due_operational_staff_team_moves(target_branch_id);
  if not private.actor_can_read_operational_branch(actor_user_id,target_branch_id)
  then raise exception 'scheduled move access denied' using errcode='42501'; end if;
  return query
  with latest as(
    select distinct on(move.operational_staff_id) move.*
    from public.operational_staff_scheduled_team_moves move
    where move.branch_id=target_branch_id
    order by move.operational_staff_id,move.requested_at desc,move.id desc
  )
  select move.id,move.operational_staff_id,move.source_assignment_id,move.destination_operational_team_id,
    team.name,move.effective_business_date,move.status,move.blocked_reason
  from latest move
  join public.branch_operational_teams team on team.id=move.destination_operational_team_id
  where move.status in('pending','blocked')
  order by move.requested_at,move.id;
end $$;

create function public.get_operational_staff_team_move_context(actor_user_id uuid,target_branch_id uuid)
returns table(operational_team_id uuid,business_date date,hygiene_submitted_today boolean,recorded_staff_id uuid)
language plpgsql security definer set search_path = '' as $$
declare current_business_date date;
begin
  perform private.apply_due_operational_staff_team_moves(target_branch_id);
  if not private.actor_can_read_operational_branch(actor_user_id,target_branch_id)
  then raise exception 'team move context access denied' using errcode='42501'; end if;
  select private.phase4a_business_date(branch.timezone) into strict current_business_date
  from public.branches branch where branch.id=target_branch_id and branch.active;
  return query
  select team.id,current_business_date,(submission.id is not null),snapshot.operational_staff_id
  from public.branch_operational_teams team
  left join lateral(
    select existing.id from public.checklist_submissions existing
    where existing.branch_id=target_branch_id and existing.operational_team_id=team.id
      and existing.business_date=current_business_date and existing.checklist_type='staff_hygiene'
      and existing.state='submitted'
    order by existing.submitted_at desc,existing.id limit 1
  ) submission on true
  left join public.hygiene_staff_snapshots snapshot on snapshot.submission_id=submission.id
  where team.branch_id=target_branch_id and team.active
  order by team.id,snapshot.operational_staff_id;
exception when no_data_found or too_many_rows then
  raise exception 'team move context access denied' using errcode='42501';
end $$;

create function public.cancel_operational_staff_scheduled_team_move(actor_user_id uuid,target_branch_id uuid,
  target_staff_id uuid,target_scheduled_move_id uuid,expected_assignment_id uuid)
returns table(staff_id uuid,assignment_id uuid,operational_team_id uuid,move_status text,
  scheduled_move_id uuid,effective_business_date date)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  scheduled public.operational_staff_scheduled_team_moves%rowtype;
  source_assignment public.operational_staff_assignments%rowtype;
begin
  perform private.apply_due_operational_staff_team_moves(target_branch_id);
  select * into scheduled from public.operational_staff_scheduled_team_moves move
  where move.id=target_scheduled_move_id and move.branch_id=target_branch_id
    and move.operational_staff_id=target_staff_id for update;
  if not found then raise exception 'scheduled move is no longer pending' using errcode='23514'; end if;
  if scheduled.status<>'pending' then
    raise exception 'scheduled move is no longer pending' using errcode='23514';
  end if;
  select * into source_assignment from public.operational_staff_assignments assignment
  where assignment.id=scheduled.source_assignment_id and assignment.operational_staff_id=target_staff_id
    and assignment.active for update;
  if not found then raise exception 'staff assignment changed' using errcode='40001'; end if;
  if source_assignment.id<>expected_assignment_id then
    raise exception 'staff assignment changed' using errcode='40001';
  end if;
  if not private.actor_can_write_operational_team(actor_user_id,target_branch_id,scheduled.source_operational_team_id)
  then raise exception 'scheduled move cancellation denied' using errcode='42501'; end if;

  update public.operational_staff_scheduled_team_moves move
  set status='cancelled',cancelled_at=now(),cancelled_by_user_id=actor_user_id
  where move.id=scheduled.id and move.status='pending';
  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
  values(scheduled.organization_id,actor_user_id,scheduled.branch_id,'operational_staff_assignment_updated',
    pg_catalog.jsonb_build_object('team_id',scheduled.source_operational_team_id,
      'operational_staff_id',scheduled.operational_staff_id,'assignment_id',scheduled.source_assignment_id,
      'previous_status','scheduled','new_status','active','source_team_id',scheduled.source_operational_team_id,
      'destination_team_id',scheduled.destination_operational_team_id,'scheduled_move_id',scheduled.id,
      'move_status','cancelled','effective_business_date',scheduled.effective_business_date));
  return query select scheduled.operational_staff_id,scheduled.source_assignment_id,
    scheduled.source_operational_team_id,'cancelled'::text,scheduled.id,scheduled.effective_business_date;
end $$;

create function private.cancel_scheduled_move_for_inactive_staff()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.employment_status='active' and new.employment_status='inactive' then
    update public.operational_staff_scheduled_team_moves move
    set status='cancelled',cancelled_at=now(),cancelled_by_user_id=new.deactivated_by
    where move.operational_staff_id=new.id and move.status='pending';
  end if;
  return new;
end $$;

create trigger operational_staff_cancel_scheduled_move_when_inactive
after update of employment_status on public.operational_staff
for each row execute function private.cancel_scheduled_move_for_inactive_staff();

create or replace function public.get_supervisor_operational_team(actor_user_id uuid,target_branch_id uuid,requested_date date)
returns table(team_id uuid,team_name text,team_active boolean,can_write boolean,assignment_role text,
  company_name text,staff_id uuid,display_name text,staff_company_name text,staff_code text,country_code text,
  iqama_number text,iqama_expiry_date date,phone_number text,email text,employment_status text,
  assignment_id uuid,operational_roles text[],duty_status text)
language plpgsql security definer set search_path = '' as $$
begin
  perform private.apply_due_operational_staff_team_moves(target_branch_id);
  if requested_date is null or not private.actor_can_read_operational_branch(actor_user_id,target_branch_id)
  then raise exception 'team access denied' using errcode='42501'; end if;
  return query
  select team.id,team.name,team.active,private.actor_can_write_operational_team(actor_user_id,target_branch_id,team.id),
    actor_assignment.assignment_role,coalesce(legacy.company_name,organization.name),
    staff.id,staff.display_name,staff.company_name,staff.staff_code,staff.country_code,staff.iqama_number,staff.iqama_expiry_date,
    staff.phone_number,staff.email,staff.employment_status,assignment.id,assignment.operational_roles,
    coalesce(duty.duty_status,'on_duty')
  from public.branch_operational_teams team
  join public.organizations organization on organization.id=team.organization_id
  left join public.branch_supervisor_teams legacy on legacy.id=team.legacy_supervisor_team_id
  left join public.branch_operational_team_supervisors actor_assignment
    on actor_assignment.operational_team_id=team.id and actor_assignment.supervisor_user_id=actor_user_id and actor_assignment.active
  left join public.operational_staff_assignments assignment
    on assignment.operational_team_id=team.id and assignment.active
  left join public.operational_staff staff on staff.id=assignment.operational_staff_id
  left join public.operational_staff_duty_statuses duty
    on duty.assignment_id=assignment.id and duty.duty_date=requested_date
  where team.branch_id=target_branch_id and team.active
  order by case actor_assignment.assignment_role when 'primary' then 0 when 'backup' then 1 else 2 end,
    team.normalized_name,pg_catalog.lower(staff.display_name),staff.id;
end $$;

create or replace function private.operational_team_hygiene_context(actor uuid,target_branch uuid,target_team uuid,write_required boolean)
returns table(organization_id uuid,branch_id uuid,operational_team_id uuid,legacy_team_id uuid,business_date date,
  branch_name text,branch_code text,supervisor_name text,team_name text,can_write boolean)
language plpgsql volatile security definer set search_path = '' as $$
begin
  perform private.apply_due_operational_staff_team_moves(target_branch);
  if not private.actor_can_read_operational_branch(actor,target_branch)
    or (write_required and not private.actor_can_write_operational_team(actor,target_branch,target_team))
  then raise exception 'hygiene access denied' using errcode='42501'; end if;
  return query select branch.organization_id,branch.id,team.id,team.legacy_supervisor_team_id,
    private.phase4a_business_date(branch.timezone),branch.name,branch.code,profile.full_name,team.name,
    private.actor_can_write_operational_team(actor,target_branch,team.id)
  from public.branch_operational_teams team
  join public.branches branch on branch.id=team.branch_id and branch.organization_id=team.organization_id
  join public.profiles profile on profile.id=actor
  where team.id=target_team and team.branch_id=target_branch and team.active;
  if not found then raise exception 'hygiene access denied' using errcode='42501'; end if;
end $$;

revoke all on function private.block_operational_staff_scheduled_move(uuid,text),
  private.apply_due_operational_staff_team_moves(uuid,uuid),
  private.request_operational_staff_team_move(uuid,uuid,uuid,uuid,uuid,boolean),
  private.cancel_scheduled_move_for_inactive_staff()
  from public,anon,authenticated;

revoke all on function public.move_operational_staff_team(uuid,uuid,uuid,uuid,uuid),
  public.request_operational_staff_team_move(uuid,uuid,uuid,uuid,uuid),
  public.apply_due_operational_staff_team_moves(uuid,uuid),
  public.list_operational_staff_scheduled_team_moves(uuid,uuid),
  public.get_operational_staff_team_move_context(uuid,uuid),
  public.cancel_operational_staff_scheduled_team_move(uuid,uuid,uuid,uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.move_operational_staff_team(uuid,uuid,uuid,uuid,uuid),
  public.request_operational_staff_team_move(uuid,uuid,uuid,uuid,uuid),
  public.apply_due_operational_staff_team_moves(uuid,uuid),
  public.list_operational_staff_scheduled_team_moves(uuid,uuid),
  public.get_operational_staff_team_move_context(uuid,uuid),
  public.cancel_operational_staff_scheduled_team_move(uuid,uuid,uuid,uuid,uuid)
  to service_role;

comment on table public.operational_staff_scheduled_team_moves is
  'Audited same-branch team moves deferred until the next branch-local business day after Staff Hygiene is final.';
