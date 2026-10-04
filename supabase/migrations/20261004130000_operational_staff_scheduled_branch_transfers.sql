-- Cross-branch staff transfers use source-branch business time and preserve the
-- current assignment until the next source business day when Hygiene is final.

create table public.operational_staff_scheduled_branch_transfers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  operational_staff_id uuid not null,
  source_branch_id uuid not null,
  source_assignment_id uuid not null,
  source_operational_team_id uuid not null,
  destination_branch_id uuid not null,
  destination_operational_team_id uuid not null,
  requested_by_user_id uuid not null references auth.users(id) on delete restrict,
  requested_at timestamptz not null default now(),
  requested_source_business_date date not null,
  effective_source_business_date date not null,
  effective_at timestamptz not null,
  status text not null default 'pending',
  applied_at timestamptz,
  cancelled_at timestamptz,
  cancelled_by_user_id uuid references auth.users(id) on delete restrict,
  blocked_at timestamptz,
  blocked_reason text,
  applied_assignment_id uuid references public.operational_staff_assignments(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint operational_staff_scheduled_branch_transfers_staff_fkey
    foreign key(operational_staff_id,organization_id)
    references public.operational_staff(id,organization_id) on delete restrict,
  constraint operational_staff_scheduled_branch_transfers_source_branch_fkey
    foreign key(source_branch_id,organization_id) references public.branches(id,organization_id) on delete restrict,
  constraint operational_staff_scheduled_branch_transfers_destination_branch_fkey
    foreign key(destination_branch_id,organization_id) references public.branches(id,organization_id) on delete restrict,
  constraint operational_staff_scheduled_branch_transfers_source_assignment_fkey
    foreign key(source_assignment_id,operational_staff_id,source_branch_id,organization_id)
    references public.operational_staff_assignments(id,operational_staff_id,branch_id,organization_id) on delete restrict,
  constraint operational_staff_scheduled_branch_transfers_source_team_fkey
    foreign key(source_operational_team_id,source_branch_id,organization_id)
    references public.branch_operational_teams(id,branch_id,organization_id) on delete restrict,
  constraint operational_staff_scheduled_branch_transfers_destination_team_fkey
    foreign key(destination_operational_team_id,destination_branch_id,organization_id)
    references public.branch_operational_teams(id,branch_id,organization_id) on delete restrict,
  constraint operational_staff_scheduled_branch_transfers_distinct_branches_check
    check(source_branch_id<>destination_branch_id),
  constraint operational_staff_scheduled_branch_transfers_effective_date_check
    check(effective_source_business_date=requested_source_business_date+1),
  constraint operational_staff_scheduled_branch_transfers_status_check
    check(status in('pending','applied','cancelled','blocked')),
  constraint operational_staff_scheduled_branch_transfers_blocked_reason_check
    check(blocked_reason is null or blocked_reason in(
      'source_assignment_changed','employee_inactive','destination_branch_inactive',
      'destination_team_inactive','hygiene_already_submitted','scope_invalid'
    )),
  constraint operational_staff_scheduled_branch_transfers_lifecycle_check check(
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

create unique index operational_staff_scheduled_branch_transfers_one_pending_key
  on public.operational_staff_scheduled_branch_transfers(operational_staff_id) where status='pending';
create index operational_staff_scheduled_branch_transfers_due_idx
  on public.operational_staff_scheduled_branch_transfers(effective_at,source_branch_id) where status='pending';
create index operational_staff_scheduled_branch_transfers_branch_status_idx
  on public.operational_staff_scheduled_branch_transfers(source_branch_id,status,requested_at desc);

create trigger operational_staff_scheduled_branch_transfers_set_updated_at
before update on public.operational_staff_scheduled_branch_transfers
for each row execute function private.set_updated_at();

alter table public.operational_staff_scheduled_branch_transfers enable row level security;
revoke all on public.operational_staff_scheduled_branch_transfers from public,anon,authenticated,service_role;

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
      'scheduled_transfer_id','move_status','effective_business_date','effective_at','blocked_reason')
  );
$$;

create function private.guard_operational_staff_pending_movement()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status<>'pending' then return new; end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(new.operational_staff_id::text||':operational-staff-movement',0));
  if tg_table_name='operational_staff_scheduled_team_moves' and exists(
    select 1 from public.operational_staff_scheduled_branch_transfers transfer
    where transfer.operational_staff_id=new.operational_staff_id and transfer.status='pending'
  ) then raise exception 'staff pending movement already exists' using errcode='23505'; end if;
  if tg_table_name='operational_staff_scheduled_branch_transfers' and exists(
    select 1 from public.operational_staff_scheduled_team_moves move
    where move.operational_staff_id=new.operational_staff_id and move.status='pending'
  ) then raise exception 'staff pending movement already exists' using errcode='23505'; end if;
  return new;
end $$;

create trigger operational_staff_scheduled_team_moves_pending_movement_guard
before insert on public.operational_staff_scheduled_team_moves
for each row execute function private.guard_operational_staff_pending_movement();
create trigger operational_staff_scheduled_branch_transfers_pending_movement_guard
before insert on public.operational_staff_scheduled_branch_transfers
for each row execute function private.guard_operational_staff_pending_movement();

create or replace function private.request_operational_staff_team_move(actor_user_id uuid,target_branch_id uuid,
  target_staff_id uuid,expected_assignment_id uuid,target_operational_team_id uuid,allow_scheduled boolean)
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
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(target_staff_id::text||':operational-staff-movement',0));

  select * into staff_row from public.operational_staff staff
  where staff.id=target_staff_id and staff.branch_id=target_branch_id for update;
  if not found then raise exception 'staff move denied' using errcode='42501'; end if;
  select * into old_assignment from public.operational_staff_assignments assignment
  where assignment.operational_staff_id=target_staff_id and assignment.active for update;
  if not found or old_assignment.id<>expected_assignment_id then
    raise exception 'staff assignment changed' using errcode='40001'; end if;
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
  if exists(select 1 from public.operational_staff_scheduled_branch_transfers transfer
    where transfer.operational_staff_id=target_staff_id and transfer.status='pending' for update)
  then raise exception 'staff pending movement already exists' using errcode='23505'; end if;

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
      raise exception 'scheduled team move requires a compatible client' using errcode='40001'; end if;
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
    return query select target_staff_id,old_assignment.id,target_team.id,'scheduled'::text,
      created_move,current_business_date+1;
    return;
  end if;

  select duty.duty_status into prior_duty from public.operational_staff_duty_statuses duty
  where duty.assignment_id=old_assignment.id and duty.duty_date=current_business_date;
  update public.operational_staff_assignments assignment
  set active=false,valid_to=current_business_date,closed_at=now(),closed_by_user_id=actor_user_id,
    closure_reason='team_move' where assignment.id=old_assignment.id;
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

create function private.block_operational_staff_scheduled_branch_transfer(target_transfer_id uuid,reason text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.operational_staff_scheduled_branch_transfers transfer
  set status='blocked',blocked_at=now(),blocked_reason=reason
  where transfer.id=target_transfer_id and transfer.status='pending';
end $$;

create function private.apply_due_operational_staff_branch_transfers(
  target_branch_id uuid default null,
  target_organization_id uuid default null
)
returns table(transfer_id uuid,move_status text,staff_id uuid,assignment_id uuid,
  destination_branch_id uuid,destination_team_id uuid,effective_business_date date)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  candidate record;
  scheduled public.operational_staff_scheduled_branch_transfers%rowtype;
  staff_row public.operational_staff%rowtype;
  source_assignment public.operational_staff_assignments%rowtype;
  source_branch public.branches%rowtype;
  destination_branch public.branches%rowtype;
  destination_team public.branch_operational_teams%rowtype;
  created_assignment uuid;
  destination_business_date date;
begin
  for candidate in
    select transfer.id,transfer.operational_staff_id
    from public.operational_staff_scheduled_branch_transfers transfer
    where transfer.status='pending' and transfer.effective_at<=now()
      and (target_branch_id is null or target_branch_id in(transfer.source_branch_id,transfer.destination_branch_id))
      and (target_organization_id is null or transfer.organization_id=target_organization_id)
    order by transfer.effective_at,transfer.requested_at,transfer.id
  loop
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(candidate.operational_staff_id::text||':operational-staff-movement',0));
    select * into scheduled from public.operational_staff_scheduled_branch_transfers transfer
    where transfer.id=candidate.id and transfer.status='pending' and transfer.effective_at<=now() for update;
    if not found then continue; end if;

    select * into staff_row from public.operational_staff staff
    where staff.id=scheduled.operational_staff_id and staff.organization_id=scheduled.organization_id for update;
    if not found or staff_row.branch_id<>scheduled.source_branch_id then
      perform private.block_operational_staff_scheduled_branch_transfer(scheduled.id,'scope_invalid');
      return query select scheduled.id,'blocked'::text,scheduled.operational_staff_id,scheduled.source_assignment_id,
        scheduled.destination_branch_id,scheduled.destination_operational_team_id,scheduled.effective_source_business_date;
      continue;
    end if;
    if staff_row.employment_status<>'active' then
      perform private.block_operational_staff_scheduled_branch_transfer(scheduled.id,'employee_inactive');
      return query select scheduled.id,'blocked'::text,scheduled.operational_staff_id,scheduled.source_assignment_id,
        scheduled.destination_branch_id,scheduled.destination_operational_team_id,scheduled.effective_source_business_date;
      continue;
    end if;

    select * into source_assignment from public.operational_staff_assignments assignment
    where assignment.id=scheduled.source_assignment_id and assignment.operational_staff_id=scheduled.operational_staff_id
      and assignment.organization_id=scheduled.organization_id and assignment.branch_id=scheduled.source_branch_id
      and assignment.operational_team_id=scheduled.source_operational_team_id and assignment.active for update;
    if not found then
      perform private.block_operational_staff_scheduled_branch_transfer(scheduled.id,'source_assignment_changed');
      return query select scheduled.id,'blocked'::text,scheduled.operational_staff_id,scheduled.source_assignment_id,
        scheduled.destination_branch_id,scheduled.destination_operational_team_id,scheduled.effective_source_business_date;
      continue;
    end if;

    perform 1 from public.branches branch
    where branch.id in(scheduled.source_branch_id,scheduled.destination_branch_id)
      and branch.organization_id=scheduled.organization_id
    order by branch.id for update;
    select * into source_branch from public.branches branch
    where branch.id=scheduled.source_branch_id and branch.organization_id=scheduled.organization_id;
    if not found or not source_branch.active then
      perform private.block_operational_staff_scheduled_branch_transfer(scheduled.id,'scope_invalid');
      return query select scheduled.id,'blocked'::text,scheduled.operational_staff_id,scheduled.source_assignment_id,
        scheduled.destination_branch_id,scheduled.destination_operational_team_id,scheduled.effective_source_business_date;
      continue;
    end if;
    select * into destination_branch from public.branches branch
    where branch.id=scheduled.destination_branch_id and branch.organization_id=scheduled.organization_id;
    if not found or not destination_branch.active then
      perform private.block_operational_staff_scheduled_branch_transfer(scheduled.id,'destination_branch_inactive');
      return query select scheduled.id,'blocked'::text,scheduled.operational_staff_id,scheduled.source_assignment_id,
        scheduled.destination_branch_id,scheduled.destination_operational_team_id,scheduled.effective_source_business_date;
      continue;
    end if;
    perform 1 from public.branch_operational_teams team
    where team.id in(scheduled.source_operational_team_id,scheduled.destination_operational_team_id)
      and team.organization_id=scheduled.organization_id
    order by team.id for update;
    select * into destination_team from public.branch_operational_teams team
    where team.id=scheduled.destination_operational_team_id and team.branch_id=scheduled.destination_branch_id
      and team.organization_id=scheduled.organization_id;
    if not found or not destination_team.active or destination_team.legacy_supervisor_team_id is null then
      perform private.block_operational_staff_scheduled_branch_transfer(scheduled.id,'destination_team_inactive');
      return query select scheduled.id,'blocked'::text,scheduled.operational_staff_id,scheduled.source_assignment_id,
        scheduled.destination_branch_id,scheduled.destination_operational_team_id,scheduled.effective_source_business_date;
      continue;
    end if;

    destination_business_date:=private.phase4a_business_date_at(destination_branch.timezone,scheduled.effective_at);
    if scheduled.source_branch_id::text||scheduled.source_operational_team_id::text
      < scheduled.destination_branch_id::text||scheduled.destination_operational_team_id::text then
      perform private.lock_operational_team_hygiene(scheduled.source_branch_id,scheduled.source_operational_team_id,
        scheduled.effective_source_business_date);
      perform private.lock_operational_team_hygiene(scheduled.destination_branch_id,
        scheduled.destination_operational_team_id,destination_business_date);
    else
      perform private.lock_operational_team_hygiene(scheduled.destination_branch_id,
        scheduled.destination_operational_team_id,destination_business_date);
      perform private.lock_operational_team_hygiene(scheduled.source_branch_id,scheduled.source_operational_team_id,
        scheduled.effective_source_business_date);
    end if;
    if exists(
      select 1 from public.checklist_submissions submission
      where submission.organization_id=scheduled.organization_id and submission.checklist_type='staff_hygiene'
        and submission.state='submitted' and (
          (submission.branch_id=scheduled.source_branch_id
            and submission.operational_team_id=scheduled.source_operational_team_id
            and submission.business_date>=scheduled.effective_source_business_date)
          or (submission.branch_id=scheduled.destination_branch_id
            and submission.operational_team_id=scheduled.destination_operational_team_id
            and submission.business_date>=destination_business_date)
        )
    ) then
      perform private.block_operational_staff_scheduled_branch_transfer(scheduled.id,'hygiene_already_submitted');
      return query select scheduled.id,'blocked'::text,scheduled.operational_staff_id,scheduled.source_assignment_id,
        scheduled.destination_branch_id,scheduled.destination_operational_team_id,scheduled.effective_source_business_date;
      continue;
    end if;

    update public.operational_staff_assignments assignment
    set active=false,valid_to=scheduled.effective_source_business_date-1,closed_at=now(),
      closed_by_user_id=scheduled.requested_by_user_id,closure_reason='branch_transfer'
    where assignment.id=source_assignment.id;
    update public.operational_staff staff set branch_id=scheduled.destination_branch_id
    where staff.id=scheduled.operational_staff_id;
    insert into public.operational_staff_assignments(organization_id,branch_id,operational_staff_id,supervisor_team_id,
      operational_team_id,operational_roles,valid_from,created_by_user_id)
    values(scheduled.organization_id,scheduled.destination_branch_id,scheduled.operational_staff_id,
      destination_team.legacy_supervisor_team_id,destination_team.id,source_assignment.operational_roles,
      destination_business_date,scheduled.requested_by_user_id)
    returning id into created_assignment;
    update public.operational_staff_scheduled_branch_transfers transfer
    set status='applied',applied_at=now(),applied_assignment_id=created_assignment
    where transfer.id=scheduled.id and transfer.status='pending';
    insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
    values(scheduled.organization_id,scheduled.requested_by_user_id,scheduled.destination_branch_id,
      'operational_staff_assignment_updated',pg_catalog.jsonb_build_object(
        'team_id',destination_team.id,'operational_staff_id',scheduled.operational_staff_id,
        'assignment_id',created_assignment,'previous_status','scheduled','new_status','active',
        'operational_roles',source_assignment.operational_roles,'source_branch_id',scheduled.source_branch_id,
        'source_team_id',scheduled.source_operational_team_id,'destination_branch_id',scheduled.destination_branch_id,
        'destination_team_id',destination_team.id,'closure_reason','branch_transfer',
        'scheduled_transfer_id',scheduled.id,'move_status','applied',
        'effective_business_date',destination_business_date,'effective_at',scheduled.effective_at));
    return query select scheduled.id,'applied'::text,scheduled.operational_staff_id,created_assignment,
      scheduled.destination_branch_id,destination_team.id,scheduled.effective_source_business_date;
  end loop;
end $$;

create function public.apply_due_operational_staff_branch_transfers(
  target_branch_id uuid default null,target_organization_id uuid default null
)
returns table(transfer_id uuid,move_status text,staff_id uuid,assignment_id uuid,
  destination_branch_id uuid,destination_team_id uuid,effective_business_date date)
language sql security definer set search_path = '' as $$
  select * from private.apply_due_operational_staff_branch_transfers(target_branch_id,target_organization_id)
$$;

create function public.request_operational_staff_branch_transfer(
  actor_user_id uuid,p_organization_id uuid,p_source_branch_id uuid,p_operational_staff_id uuid,
  p_expected_assignment_id uuid,p_destination_branch_id uuid,p_destination_team_id uuid,allow_schedule boolean
)
returns table(staff_id uuid,assignment_id uuid,move_status text,scheduled_transfer_id uuid,
  destination_branch_id uuid,destination_team_id uuid,effective_business_date date)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  staff_row public.operational_staff%rowtype;
  old_assignment public.operational_staff_assignments%rowtype;
  source_branch public.branches%rowtype;
  destination_branch public.branches%rowtype;
  destination_team public.branch_operational_teams%rowtype;
  existing_transfer public.operational_staff_scheduled_branch_transfers%rowtype;
  created_assignment uuid;
  created_transfer uuid;
  source_business_date date;
  destination_business_date date;
  effective_source_date date;
  activation_at timestamptz;
  prior_duty text;
  source_recorded boolean;
  destination_submitted boolean;
begin
  perform private.apply_due_operational_staff_branch_transfers(p_source_branch_id,p_organization_id);
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_operational_staff_id::text||':operational-staff-movement',0));
  select * into staff_row from public.operational_staff staff
  where staff.id=p_operational_staff_id and staff.organization_id=p_organization_id for update;
  if not found then raise exception 'staff transfer denied' using errcode='42501'; end if;
  select * into old_assignment from public.operational_staff_assignments assignment
  where assignment.operational_staff_id=p_operational_staff_id and assignment.active for update;
  if not found or old_assignment.id<>p_expected_assignment_id then
    raise exception 'staff assignment changed' using errcode='40001'; end if;
  if staff_row.branch_id<>p_source_branch_id or old_assignment.branch_id<>p_source_branch_id
    or old_assignment.organization_id<>p_organization_id or staff_row.employment_status<>'active'
  then raise exception 'staff transfer denied' using errcode='42501'; end if;
  perform 1 from public.branches branch
  where branch.id in(p_source_branch_id,p_destination_branch_id) and branch.organization_id=p_organization_id
  order by branch.id for update;
  select * into source_branch from public.branches branch
    where branch.id=p_source_branch_id and branch.organization_id=p_organization_id and branch.active;
  if not found then raise exception 'staff transfer denied' using errcode='42501'; end if;
  select * into destination_branch from public.branches branch
    where branch.id=p_destination_branch_id and branch.organization_id=p_organization_id and branch.active;
  if not found or p_destination_branch_id=p_source_branch_id then
    raise exception 'staff transfer denied' using errcode='42501'; end if;
  perform 1 from public.branch_operational_teams team
  where team.id in(old_assignment.operational_team_id,p_destination_team_id)
    and team.organization_id=p_organization_id
  order by team.id for update;
  select * into destination_team from public.branch_operational_teams team
    where team.id=p_destination_team_id and team.branch_id=p_destination_branch_id
      and team.organization_id=p_organization_id and team.active;
  if not found or destination_team.legacy_supervisor_team_id is null
    or not private.actor_can_write_operational_team(actor_user_id,p_source_branch_id,old_assignment.operational_team_id)
  then raise exception 'staff transfer denied' using errcode='42501'; end if;

  select * into existing_transfer from public.operational_staff_scheduled_branch_transfers transfer
  where transfer.operational_staff_id=p_operational_staff_id and transfer.status='pending' for update;
  if found then
    if existing_transfer.source_assignment_id=p_expected_assignment_id
      and existing_transfer.destination_branch_id=p_destination_branch_id
      and existing_transfer.destination_operational_team_id=p_destination_team_id
    then return query select p_operational_staff_id,old_assignment.id,'scheduled'::text,existing_transfer.id,
      p_destination_branch_id,p_destination_team_id,existing_transfer.effective_source_business_date; return; end if;
    raise exception 'staff pending movement already exists' using errcode='23505';
  end if;
  if exists(select 1 from public.operational_staff_scheduled_team_moves move
    where move.operational_staff_id=p_operational_staff_id and move.status='pending' for update)
  then raise exception 'staff pending movement already exists' using errcode='23505'; end if;

  source_business_date:=private.phase4a_business_date(source_branch.timezone);
  destination_business_date:=private.phase4a_business_date(destination_branch.timezone);
  if p_source_branch_id::text||old_assignment.operational_team_id::text
    < p_destination_branch_id::text||destination_team.id::text then
    perform private.lock_operational_team_hygiene(p_source_branch_id,old_assignment.operational_team_id,
      source_business_date);
    perform private.lock_operational_team_hygiene(p_destination_branch_id,destination_team.id,
      destination_business_date);
  else
    perform private.lock_operational_team_hygiene(p_destination_branch_id,destination_team.id,
      destination_business_date);
    perform private.lock_operational_team_hygiene(p_source_branch_id,old_assignment.operational_team_id,
      source_business_date);
  end if;
  select exists(
    select 1 from public.hygiene_staff_snapshots snapshot
    join public.checklist_submissions submission on submission.id=snapshot.submission_id
    where snapshot.operational_staff_id=p_operational_staff_id and submission.organization_id=p_organization_id
      and submission.branch_id=p_source_branch_id and submission.operational_team_id=old_assignment.operational_team_id
      and submission.business_date=source_business_date and submission.checklist_type='staff_hygiene'
      and submission.state='submitted'
  ) into source_recorded;
  select exists(
    select 1 from public.checklist_submissions submission
    where submission.organization_id=p_organization_id and submission.branch_id=p_destination_branch_id
      and submission.operational_team_id=p_destination_team_id and submission.business_date=destination_business_date
      and submission.checklist_type='staff_hygiene' and submission.state='submitted'
  ) into destination_submitted;

  if (source_recorded or destination_submitted) and allow_schedule then
    effective_source_date:=source_business_date+1;
    activation_at:=((effective_source_date::timestamp+time '04:00') at time zone source_branch.timezone);
    insert into public.operational_staff_scheduled_branch_transfers(
      organization_id,operational_staff_id,source_branch_id,source_assignment_id,source_operational_team_id,
      destination_branch_id,destination_operational_team_id,requested_by_user_id,requested_source_business_date,
      effective_source_business_date,effective_at)
    values(p_organization_id,p_operational_staff_id,p_source_branch_id,old_assignment.id,
      old_assignment.operational_team_id,p_destination_branch_id,p_destination_team_id,actor_user_id,
      source_business_date,effective_source_date,activation_at)
    returning id into created_transfer;
    insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
    values(p_organization_id,actor_user_id,p_source_branch_id,'operational_staff_assignment_updated',
      pg_catalog.jsonb_build_object('team_id',old_assignment.operational_team_id,
        'operational_staff_id',p_operational_staff_id,'assignment_id',old_assignment.id,
        'previous_status','active','new_status','scheduled','operational_roles',old_assignment.operational_roles,
        'source_branch_id',p_source_branch_id,'source_team_id',old_assignment.operational_team_id,
        'destination_branch_id',p_destination_branch_id,'destination_team_id',p_destination_team_id,
        'scheduled_transfer_id',created_transfer,'move_status','scheduled',
        'effective_business_date',effective_source_date,'effective_at',activation_at));
    return query select p_operational_staff_id,old_assignment.id,'scheduled'::text,created_transfer,
      p_destination_branch_id,p_destination_team_id,effective_source_date; return;
  end if;
  if destination_submitted then
    raise exception 'destination team hygiene already submitted' using errcode='23514'; end if;

  select duty.duty_status into prior_duty from public.operational_staff_duty_statuses duty
  where duty.assignment_id=old_assignment.id and duty.duty_date=source_business_date;
  update public.operational_staff_assignments assignment
  set active=false,valid_to=source_business_date,closed_at=now(),closed_by_user_id=actor_user_id,
    closure_reason='branch_transfer' where assignment.id=old_assignment.id;
  update public.operational_staff staff set branch_id=p_destination_branch_id where staff.id=p_operational_staff_id;
  insert into public.operational_staff_assignments(organization_id,branch_id,operational_staff_id,supervisor_team_id,
    operational_team_id,operational_roles,valid_from,created_by_user_id)
  values(p_organization_id,p_destination_branch_id,p_operational_staff_id,destination_team.legacy_supervisor_team_id,
    destination_team.id,old_assignment.operational_roles,destination_business_date,actor_user_id)
  returning id into created_assignment;
  if prior_duty is not null then
    insert into public.operational_staff_duty_statuses(organization_id,branch_id,operational_staff_id,assignment_id,
      duty_date,duty_status,set_by)
    values(p_organization_id,p_destination_branch_id,p_operational_staff_id,created_assignment,
      destination_business_date,prior_duty,actor_user_id);
  end if;
  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
  values(p_organization_id,actor_user_id,p_destination_branch_id,'operational_staff_assignment_updated',
    pg_catalog.jsonb_build_object('team_id',destination_team.id,'operational_staff_id',p_operational_staff_id,
      'assignment_id',created_assignment,'previous_status','active','new_status','active',
      'operational_roles',old_assignment.operational_roles,'source_branch_id',p_source_branch_id,
      'source_team_id',old_assignment.operational_team_id,'destination_branch_id',p_destination_branch_id,
      'destination_team_id',destination_team.id,'closure_reason','branch_transfer','move_status','applied'));
  return query select p_operational_staff_id,created_assignment,'applied'::text,null::uuid,
    p_destination_branch_id,p_destination_team_id,destination_business_date;
end $$;

create or replace function public.transfer_operational_staff_branch(
  actor_user_id uuid,p_organization_id uuid,p_source_branch_id uuid,p_operational_staff_id uuid,
  p_expected_assignment_id uuid,p_destination_branch_id uuid,p_destination_team_id uuid
)
returns table(staff_id uuid,assignment_id uuid,branch_id uuid,operational_team_id uuid)
language sql security definer set search_path = '' as $$
  select transfer.staff_id,transfer.assignment_id,transfer.destination_branch_id,transfer.destination_team_id
  from public.request_operational_staff_branch_transfer(actor_user_id,p_organization_id,p_source_branch_id,
    p_operational_staff_id,p_expected_assignment_id,p_destination_branch_id,p_destination_team_id,false) transfer
$$;

create function public.list_operational_staff_scheduled_branch_transfers(actor_user_id uuid,target_branch_id uuid)
returns table(scheduled_transfer_id uuid,operational_staff_id uuid,source_assignment_id uuid,
  destination_branch_id uuid,destination_branch_name text,destination_operational_team_id uuid,
  destination_team_name text,effective_business_date date,move_status text,blocked_reason text)
language plpgsql security definer set search_path = '' as $$
begin
  perform private.apply_due_operational_staff_branch_transfers(target_branch_id,null);
  if not private.actor_can_read_operational_branch(actor_user_id,target_branch_id)
  then raise exception 'scheduled transfer access denied' using errcode='42501'; end if;
  return query
  with latest as(
    select distinct on(transfer.operational_staff_id) transfer.*
    from public.operational_staff_scheduled_branch_transfers transfer
    where transfer.source_branch_id=target_branch_id
    order by transfer.operational_staff_id,transfer.requested_at desc,transfer.id desc
  )
  select transfer.id,transfer.operational_staff_id,transfer.source_assignment_id,
    transfer.destination_branch_id,branch.name,transfer.destination_operational_team_id,team.name,
    transfer.effective_source_business_date,transfer.status,transfer.blocked_reason
  from latest transfer
  join public.branches branch on branch.id=transfer.destination_branch_id
  join public.branch_operational_teams team on team.id=transfer.destination_operational_team_id
  where transfer.status in('pending','blocked') order by transfer.requested_at,transfer.id;
end $$;

create function public.cancel_operational_staff_scheduled_branch_transfer(
  actor_user_id uuid,target_source_branch_id uuid,target_staff_id uuid,
  target_scheduled_transfer_id uuid,expected_assignment_id uuid
)
returns table(staff_id uuid,assignment_id uuid,move_status text,scheduled_transfer_id uuid,
  destination_branch_id uuid,destination_team_id uuid,effective_business_date date)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare scheduled public.operational_staff_scheduled_branch_transfers%rowtype;
begin
  perform private.apply_due_operational_staff_branch_transfers(target_source_branch_id,null);
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(target_staff_id::text||':operational-staff-movement',0));
  select * into scheduled from public.operational_staff_scheduled_branch_transfers transfer
  where transfer.id=target_scheduled_transfer_id and transfer.source_branch_id=target_source_branch_id
    and transfer.operational_staff_id=target_staff_id for update;
  if not found or scheduled.status<>'pending' then
    raise exception 'scheduled transfer is no longer pending' using errcode='23514'; end if;
  if scheduled.source_assignment_id<>expected_assignment_id or not exists(
    select 1 from public.operational_staff_assignments assignment
    where assignment.id=expected_assignment_id and assignment.operational_staff_id=target_staff_id and assignment.active
  ) then raise exception 'staff assignment changed' using errcode='40001'; end if;
  if not private.actor_can_write_operational_team(actor_user_id,target_source_branch_id,
    scheduled.source_operational_team_id)
  then raise exception 'scheduled transfer cancellation denied' using errcode='42501'; end if;
  update public.operational_staff_scheduled_branch_transfers transfer
  set status='cancelled',cancelled_at=now(),cancelled_by_user_id=actor_user_id
  where transfer.id=scheduled.id and transfer.status='pending';
  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
  values(scheduled.organization_id,actor_user_id,scheduled.source_branch_id,
    'operational_staff_assignment_updated',pg_catalog.jsonb_build_object(
      'team_id',scheduled.source_operational_team_id,'operational_staff_id',scheduled.operational_staff_id,
      'assignment_id',scheduled.source_assignment_id,'previous_status','scheduled','new_status','active',
      'source_branch_id',scheduled.source_branch_id,'source_team_id',scheduled.source_operational_team_id,
      'destination_branch_id',scheduled.destination_branch_id,
      'destination_team_id',scheduled.destination_operational_team_id,
      'scheduled_transfer_id',scheduled.id,'move_status','cancelled',
      'effective_business_date',scheduled.effective_source_business_date,'effective_at',scheduled.effective_at));
  return query select scheduled.operational_staff_id,scheduled.source_assignment_id,'cancelled'::text,scheduled.id,
    scheduled.destination_branch_id,scheduled.destination_operational_team_id,scheduled.effective_source_business_date;
end $$;

create or replace function private.cancel_scheduled_move_for_inactive_staff()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.employment_status='active' and new.employment_status='inactive' then
    update public.operational_staff_scheduled_team_moves move
    set status='cancelled',cancelled_at=now(),cancelled_by_user_id=new.deactivated_by
    where move.operational_staff_id=new.id and move.status='pending';
    update public.operational_staff_scheduled_branch_transfers transfer
    set status='cancelled',cancelled_at=now(),cancelled_by_user_id=new.deactivated_by
    where transfer.operational_staff_id=new.id and transfer.status='pending';
  end if;
  return new;
end $$;

do $migration$
declare job_id bigint;
begin
  if pg_catalog.to_regprocedure('cron.schedule(text,text,text)') is not null then
    select cron.schedule('operational-staff-scheduled-branch-transfers','* * * * *',
      'select public.apply_due_operational_staff_branch_transfers(null::uuid, null::uuid);') into job_id;
    perform cron.alter_job(job_id,active:=true);
  end if;
end $migration$;

revoke all on function private.guard_operational_staff_pending_movement(),
  private.block_operational_staff_scheduled_branch_transfer(uuid,text),
  private.apply_due_operational_staff_branch_transfers(uuid,uuid),
  private.cancel_scheduled_move_for_inactive_staff()
  from public,anon,authenticated;
revoke all on function public.request_operational_staff_branch_transfer(uuid,uuid,uuid,uuid,uuid,uuid,uuid,boolean),
  public.transfer_operational_staff_branch(uuid,uuid,uuid,uuid,uuid,uuid,uuid),
  public.apply_due_operational_staff_branch_transfers(uuid,uuid),
  public.list_operational_staff_scheduled_branch_transfers(uuid,uuid),
  public.cancel_operational_staff_scheduled_branch_transfer(uuid,uuid,uuid,uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.request_operational_staff_branch_transfer(uuid,uuid,uuid,uuid,uuid,uuid,uuid,boolean),
  public.transfer_operational_staff_branch(uuid,uuid,uuid,uuid,uuid,uuid,uuid),
  public.apply_due_operational_staff_branch_transfers(uuid,uuid),
  public.list_operational_staff_scheduled_branch_transfers(uuid,uuid),
  public.cancel_operational_staff_scheduled_branch_transfer(uuid,uuid,uuid,uuid,uuid)
  to service_role;

comment on table public.operational_staff_scheduled_branch_transfers is
  'Audited cross-branch staff transfers deferred to the next source-branch business day.';
