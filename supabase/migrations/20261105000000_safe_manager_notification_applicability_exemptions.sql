-- Migration: safe_manager_notification_applicability_exemptions
-- Applies organization and branch exemptions for Burger Hunch (org a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1)
-- 1. Bakery Riyadh (03acf21e-fbca-48d0-955f-5e783d43c23e): sales_tracking and oil_tracking exempt.
-- 2. Central Kitchen (4fafc3dc-269b-4864-8625-5d7a66d39c50): sales_tracking, oil_tracking, and foh_opening exempt.
-- 3. Burger Hunch and Molt Dubai (dea33e25-4732-4dcf-96db-010ad917c16c): cold_storage 02:00 slot excluded from Manager incomplete-task notification evaluation only.
-- 4. Burger Hunch Unaiza (82321e25-25f2-490a-a933-7c15e11c6428): cold_storage 02:00 slot excluded from Manager incomplete-task notification evaluation only.
-- 5. Incomplete Tasks: Evaluates zero Cold Storage submissions as incomplete when eligible equipment and required closed slots exist.
-- 6. Maintenance In-App: Decouples organization_manager_notifications insertion from Web Push producer configuration.
-- 7. Maintenance Projection: Removes branch_date_closed gate for maintenance_issue_created so reported issues appear immediately.
-- 8. Business Date: Standardizes on canonical private.phase4a_business_date_at across scheduler and notification queries.

begin;

-- 1. Add branch configuration flags if not already present
alter table public.branches
  add column if not exists cold_storage_0200_notification_required boolean not null default true;

alter table public.branches
  add column if not exists foh_opening_included boolean not null default true;

-- 2. Update branch-level exemption configuration for target organization
-- Note: Bakery Riyadh and Central Kitchen already have sales_tracking_percentage_included = false
-- and oil_tracking_percentage_included = false in baseline. We preserve and ensure those values here.
update public.branches
set sales_tracking_percentage_included = false,
    oil_tracking_percentage_included = false
where organization_id = 'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1'::uuid
  and id in (
    '03acf21e-fbca-48d0-955f-5e783d43c23e'::uuid, -- Bakery Riyadh
    '4fafc3dc-269b-4864-8625-5d7a66d39c50'::uuid  -- Central Kitchen
  );

update public.branches
set foh_opening_included = false
where organization_id = 'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1'::uuid
  and id = '4fafc3dc-269b-4864-8625-5d7a66d39c50'::uuid; -- Central Kitchen

update public.branches
set cold_storage_0200_notification_required = false
where organization_id = 'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1'::uuid
  and id in (
    'dea33e25-4732-4dcf-96db-010ad917c16c'::uuid, -- Burger Hunch and Molt Dubai
    '82321e25-25f2-490a-a933-7c15e11c6428'::uuid  -- Burger Hunch Unaiza
  );

-- 3. Correct daily_report_module_applicability for exempt modules
-- Bakery Riyadh and Central Kitchen were already exempt before the 2026-10-27 initial seed.
-- Treat the initial required=true seed as incorrect, not an intentionally required historical period.
-- Correct the active row directly from its inception (effective_from_business_date) so that
-- historical catch-up scans cannot create false notifications.
do $applicability_transition$
declare
  v_target record;
  v_current record;
  v_effective_date date;
begin
  for v_target in
    select b.id as branch_id, b.organization_id, b.timezone, m.module_key
    from public.branches b
    cross join (values ('sales_tracking'), ('oil_tracking')) as m(module_key)
    where b.organization_id = 'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1'::uuid
      and b.id in (
        '03acf21e-fbca-48d0-955f-5e783d43c23e'::uuid, -- Bakery Riyadh
        '4fafc3dc-269b-4864-8625-5d7a66d39c50'::uuid  -- Central Kitchen
      )
    union all
    select b.id as branch_id, b.organization_id, b.timezone, 'foh_opening' as module_key
    from public.branches b
    where b.organization_id = 'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1'::uuid
      and b.id = '4fafc3dc-269b-4864-8625-5d7a66d39c50'::uuid -- Central Kitchen
  loop
    select * into v_current
    from public.daily_report_module_applicability
    where branch_id = v_target.branch_id
      and organization_id = v_target.organization_id
      and module_key = v_target.module_key
      and effective_to_business_date is null;

    if v_current.id is not null then
      v_effective_date := v_current.effective_from_business_date;
    else
      v_effective_date := private.phase4a_business_date_at(v_target.timezone, pg_catalog.statement_timestamp());
    end if;

    perform private.record_daily_report_module_applicability(
      v_target.organization_id,
      v_target.branch_id,
      v_target.module_key,
      false, -- required = false
      v_effective_date,
      null
    );
  end loop;
end
$applicability_transition$;

-- 4. Harden future branch seeding to validate tenant scope and respect branch applicability flags
create or replace function private.seed_daily_report_module_applicability(
  p_organization_id uuid,p_branch_id uuid,p_effective_from_business_date date
)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare
  v_branch record;
begin
  if p_organization_id is null or p_branch_id is null or p_effective_from_business_date is null then
    raise exception 'invalid seed scope' using errcode='22023';
  end if;

  select sales_tracking_percentage_included, oil_tracking_percentage_included, foh_opening_included
  into v_branch
  from public.branches
  where id=p_branch_id and organization_id=p_organization_id;

  if not found then
    raise exception 'branch not found for organization' using errcode='22023';
  end if;

  insert into public.daily_report_module_applicability(
    organization_id,branch_id,module_key,requirement_basis,effective_from_business_date,required
  )
  select p_organization_id,p_branch_id,module.module_key,
    case module.module_key
      when'staff_hygiene'then'eligible_operational_staff'
      when'cold_storage'then'eligible_cold_storage_equipment'
      when'oil_tracking'then'eligible_oil_tracking_fryers'
      else'static'end,
    p_effective_from_business_date,
    case module.module_key
      when 'sales_tracking' then coalesce(v_branch.sales_tracking_percentage_included, true)
      when 'oil_tracking' then coalesce(v_branch.oil_tracking_percentage_included, true)
      when 'foh_opening' then coalesce(v_branch.foh_opening_included, true)
      else true
    end
  from pg_catalog.unnest(array[
    'kitchen_opening','foh_opening','staff_hygiene','daily_audit',
    'cold_storage','oil_tracking','sales_tracking'
  ]::text[]) module(module_key)
  where not exists(select 1 from public.daily_report_module_applicability existing
    where existing.branch_id=p_branch_id and existing.module_key=module.module_key);
end;
$$;

revoke all on function private.seed_daily_report_module_applicability(uuid,uuid,date)
  from public,anon,authenticated,service_role;

-- 5. Update incomplete_branch_tasks_completion_at with decoupled allowed/required pairs,
-- zero cold storage submission handling, strict tenant-scoped cold_storage_0200_notification_required check,
-- and completed draft semantics.
create or replace function private.incomplete_branch_tasks_completion_at(
  p_organization_id uuid,
  p_branch_id uuid,
  p_business_date date,
  p_as_of timestamptz
)
returns table(module_key text,module_state text)
language plpgsql
stable
security definer
set search_path=''
as $$
#variable_conflict use_column
declare
  lifecycle_count bigint;
  lifecycle_timezone text;
  lifecycle_active boolean;
  branch_close_at timestamptz;
  module_record record;
  team_record record;
  target_submission_id uuid;
  target_state text;
  target_submitted_at timestamptz;
  target_definition_id text;
  target_opening_submitted_at timestamptz;
  target_closing_submitted_at timestamptz;
  evidence_count bigint;
  expected_count bigint;
  actual_count bigint;
  valid_count bigint;
  eligible_count bigint;
  required_pair_count bigint;
  missing_pair_count bigint;
  closed_slots text[];
  required_closed_slots text[];
  branch_0200_required boolean;
  calculated_state text;
  staff_unknown boolean;
begin
  if p_organization_id is null or p_branch_id is null or p_business_date is null or p_as_of is null then
    raise exception 'invalid incomplete branch task evaluation scope' using errcode='22023';
  end if;

  select pg_catalog.count(*),
    pg_catalog.min(lifecycle.timezone),
    pg_catalog.bool_or(lifecycle.active)
  into lifecycle_count,lifecycle_timezone,lifecycle_active
  from public.daily_report_branch_lifecycle lifecycle
  where lifecycle.organization_id=p_organization_id
    and lifecycle.branch_id=p_branch_id
    and lifecycle.effective_from_business_date<=p_business_date
    and (lifecycle.effective_to_business_date is null
      or lifecycle.effective_to_business_date>p_business_date);
  if lifecycle_count<>1 then
    raise exception 'incomplete branch task lifecycle is missing or ambiguous' using errcode='22023';
  end if;
  branch_close_at:=private.daily_business_report_branch_close_at(
    p_business_date,lifecycle_timezone);
  if p_as_of<branch_close_at then
    raise exception 'branch business date is not complete' using errcode='55000';
  end if;

  if not lifecycle_active then
    return query
    select requested.module_key,'not_required'::text
    from pg_catalog.unnest(array[
      'kitchen_opening','foh_opening','staff_hygiene','daily_audit','cold_storage','oil_tracking'
    ]::text[]) with ordinality requested(module_key,ordinal)
    order by requested.ordinal;
    return;
  end if;

  if exists(
    select requested.module_key
    from pg_catalog.unnest(array[
      'kitchen_opening','foh_opening','staff_hygiene','daily_audit','cold_storage','oil_tracking'
    ]::text[]) requested(module_key)
    left join public.daily_report_module_applicability applicability
      on applicability.organization_id=p_organization_id
      and applicability.branch_id=p_branch_id
      and applicability.module_key=requested.module_key
      and applicability.effective_from_business_date<=p_business_date
      and (applicability.effective_to_business_date is null
        or applicability.effective_to_business_date>p_business_date)
    group by requested.module_key
    having pg_catalog.count(applicability.id)<>1
  ) then
    raise exception 'incomplete branch task applicability is missing or ambiguous' using errcode='22023';
  end if;

  for module_record in
    select requested.module_key,applicability.required,requested.ordinal
    from pg_catalog.unnest(array[
      'kitchen_opening','foh_opening','staff_hygiene','daily_audit','cold_storage','oil_tracking'
    ]::text[]) with ordinality requested(module_key,ordinal)
    join public.daily_report_module_applicability applicability
      on applicability.organization_id=p_organization_id
      and applicability.branch_id=p_branch_id
      and applicability.module_key=requested.module_key
      and applicability.effective_from_business_date<=p_business_date
      and (applicability.effective_to_business_date is null
        or applicability.effective_to_business_date>p_business_date)
    order by requested.ordinal
  loop
    calculated_state:='unknown';
    if not module_record.required then
      calculated_state:='not_required';

    elsif module_record.module_key in('kitchen_opening','foh_opening') then
      select pg_catalog.count(*) into evidence_count
      from public.checklist_submissions submission
      where submission.organization_id=p_organization_id
        and submission.branch_id=p_branch_id
        and submission.business_date=p_business_date
        and submission.checklist_type=module_record.module_key;
      if evidence_count=0 then
        calculated_state:='incomplete';
      elsif evidence_count>1 then
        calculated_state:='unknown';
      else
        select submission.id,submission.state,submission.submitted_at,submission.definition_id
        into target_submission_id,target_state,target_submitted_at,target_definition_id
        from public.checklist_submissions submission
        where submission.organization_id=p_organization_id
          and submission.branch_id=p_branch_id
          and submission.business_date=p_business_date
          and submission.checklist_type=module_record.module_key;
        if target_state='draft' and target_submitted_at is null then
          calculated_state:='incomplete';
        elsif target_state<>'submitted' or target_submitted_at is null
          or target_submitted_at>p_as_of
          or not exists(
            select 1 from public.checklist_definitions definition
            where definition.id=target_definition_id
              and definition.checklist_type=module_record.module_key
          ) then
          calculated_state:='unknown';
        else
          select pg_catalog.count(*) into expected_count
          from public.checklist_definition_items definition_item
          where definition_item.definition_id=target_definition_id;
          select pg_catalog.count(*),
            pg_catalog.count(*) filter(where result.answer in('completed','issue_found'))
          into actual_count,valid_count
          from public.opening_item_results result
          join public.checklist_definition_items definition_item
            on definition_item.definition_id=result.definition_id
            and definition_item.item_id=result.item_id
            and definition_item.ordinal=result.ordinal
          where result.submission_id=target_submission_id
            and result.definition_id=target_definition_id;
          if expected_count>0 and actual_count=expected_count and valid_count=expected_count
            and not exists(
              select result.item_id from public.opening_item_results result
              where result.submission_id=target_submission_id
              group by result.item_id having pg_catalog.count(*)>1
            )
            and not exists(
              select 1 from public.opening_item_results result
              where result.submission_id=target_submission_id
              and (result.definition_id<>target_definition_id
                or not exists(
                  select 1 from public.checklist_definition_items definition_item
                  where definition_item.definition_id=result.definition_id
                    and definition_item.item_id=result.item_id
                    and definition_item.ordinal=result.ordinal
                ))
            ) then calculated_state:='completed';
          else calculated_state:='unknown'; end if;
        end if;
      end if;

    elsif module_record.module_key='daily_audit' then
      select pg_catalog.count(*) into evidence_count
      from public.checklist_submissions submission
      where submission.organization_id=p_organization_id
        and submission.branch_id=p_branch_id
        and submission.business_date=p_business_date
        and submission.checklist_type='daily_audit';
      if evidence_count=0 then calculated_state:='incomplete';
      elsif evidence_count>1 then calculated_state:='unknown';
      else
        select submission.id,submission.state,submission.submitted_at,submission.definition_id
        into target_submission_id,target_state,target_submitted_at,target_definition_id
        from public.checklist_submissions submission
        where submission.organization_id=p_organization_id
          and submission.branch_id=p_branch_id
          and submission.business_date=p_business_date
          and submission.checklist_type='daily_audit';
        if target_state='draft' and target_submitted_at is null then
          calculated_state:='incomplete';
        elsif target_state<>'submitted' or target_submitted_at is null
          or target_submitted_at>p_as_of then
          calculated_state:='unknown';
        else
          select pg_catalog.count(*) into expected_count
          from public.daily_audit_item_definitions definition where definition.active;
          select pg_catalog.count(*),
            pg_catalog.count(*) filter(where result.answer in('compliant','non_compliant'))
          into actual_count,valid_count
          from public.daily_audit_item_results result
          join public.daily_audit_item_definitions definition
            on definition.item_id=result.item_id and definition.item_number=result.item_number
          where result.submission_id=target_submission_id
            and result.organization_id=p_organization_id
            and result.branch_id=p_branch_id and definition.active;
          if expected_count=13 and actual_count=expected_count and valid_count=expected_count
            and not exists(
              select result.item_id from public.daily_audit_item_results result
              where result.submission_id=target_submission_id
              group by result.item_id having pg_catalog.count(*)>1
            )
            and not exists(
              select 1 from public.daily_audit_item_results result
              where result.submission_id=target_submission_id
              and (result.organization_id<>p_organization_id or result.branch_id<>p_branch_id
                or not exists(
                  select 1 from public.daily_audit_item_definitions definition
                  where definition.item_id=result.item_id
                    and definition.item_number=result.item_number and definition.active
                ))
            ) then calculated_state:='completed';
          else calculated_state:='unknown'; end if;
        end if;
      end if;

    elsif module_record.module_key='staff_hygiene' then
      staff_unknown:=false;
      if exists(
        select assignment.operational_staff_id
        from public.operational_staff_assignments assignment
        where assignment.organization_id=p_organization_id
          and assignment.valid_from<=p_business_date
          and (assignment.valid_to is null or assignment.valid_to>=p_business_date)
        group by assignment.operational_staff_id
        having pg_catalog.count(*)>1
      ) or exists(
        select 1 from public.operational_staff_assignments assignment
        join public.branch_operational_teams team
          on team.id=assignment.operational_team_id
        join public.operational_staff staff
          on staff.id=assignment.operational_staff_id
          and staff.organization_id=assignment.organization_id
        where assignment.organization_id=p_organization_id
          and assignment.branch_id=p_branch_id
          and assignment.valid_from<=p_business_date
          and (assignment.valid_to is null or assignment.valid_to>=p_business_date)
          and (team.organization_id<>p_organization_id or team.branch_id<>p_branch_id
            or assignment.created_at>branch_close_at
            or team.created_at>branch_close_at
            or staff.created_at>branch_close_at)
      ) then
        staff_unknown:=true;
      end if;

      with eligible as(
        select assignment.operational_team_id,assignment.operational_staff_id
        from public.operational_staff_assignments assignment
        join public.branch_operational_teams team
          on team.id=assignment.operational_team_id
          and team.organization_id=assignment.organization_id
          and team.branch_id=assignment.branch_id
        join public.operational_staff staff
          on staff.id=assignment.operational_staff_id
          and staff.organization_id=assignment.organization_id
        left join public.operational_staff_duty_statuses duty
          on duty.assignment_id=assignment.id
          and duty.operational_staff_id=assignment.operational_staff_id
          and duty.organization_id=assignment.organization_id
          and duty.branch_id=assignment.branch_id
          and duty.duty_date=p_business_date
        where assignment.organization_id=p_organization_id
          and assignment.branch_id=p_branch_id
          and assignment.valid_from<=p_business_date
          and (assignment.valid_to is null or assignment.valid_to>=p_business_date)
          and assignment.created_at<=branch_close_at
          and team.created_at<=branch_close_at
          and staff.created_at<=branch_close_at
          and coalesce(duty.duty_status,'on_duty')='on_duty'
      ) select pg_catalog.count(*) into eligible_count from eligible;

      if staff_unknown then calculated_state:='unknown';
      elsif eligible_count=0 then calculated_state:='not_required';
      elsif exists(
        with eligible_teams as(
          select distinct assignment.operational_team_id
          from public.operational_staff_assignments assignment
          join public.branch_operational_teams team
            on team.id=assignment.operational_team_id
            and team.organization_id=assignment.organization_id
            and team.branch_id=assignment.branch_id
          join public.operational_staff staff
            on staff.id=assignment.operational_staff_id
            and staff.organization_id=assignment.organization_id
          left join public.operational_staff_duty_statuses duty
            on duty.assignment_id=assignment.id
            and duty.operational_staff_id=assignment.operational_staff_id
            and duty.organization_id=assignment.organization_id
            and duty.branch_id=assignment.branch_id
            and duty.duty_date=p_business_date
          where assignment.organization_id=p_organization_id
            and assignment.branch_id=p_branch_id
            and assignment.valid_from<=p_business_date
            and (assignment.valid_to is null or assignment.valid_to>=p_business_date)
            and assignment.created_at<=branch_close_at
            and team.created_at<=branch_close_at
            and staff.created_at<=branch_close_at
            and coalesce(duty.duty_status,'on_duty')='on_duty'
        )
        select 1 from public.checklist_submissions submission
        where submission.organization_id=p_organization_id
          and submission.branch_id=p_branch_id
          and submission.business_date=p_business_date
          and submission.checklist_type='staff_hygiene'
          and (submission.operational_team_id is null
            or not exists(select 1 from eligible_teams team
              where team.operational_team_id=submission.operational_team_id))
      ) then calculated_state:='unknown';
      else
        calculated_state:='completed';
        for team_record in
          with eligible as(
            select assignment.operational_team_id,assignment.operational_staff_id
            from public.operational_staff_assignments assignment
            join public.branch_operational_teams team
              on team.id=assignment.operational_team_id
              and team.organization_id=assignment.organization_id
              and team.branch_id=assignment.branch_id
            join public.operational_staff staff
              on staff.id=assignment.operational_staff_id
              and staff.organization_id=assignment.organization_id
            left join public.operational_staff_duty_statuses duty
              on duty.assignment_id=assignment.id
              and duty.operational_staff_id=assignment.operational_staff_id
              and duty.organization_id=assignment.organization_id
              and duty.branch_id=assignment.branch_id
              and duty.duty_date=p_business_date
            where assignment.organization_id=p_organization_id
              and assignment.branch_id=p_branch_id
              and assignment.valid_from<=p_business_date
              and (assignment.valid_to is null or assignment.valid_to>=p_business_date)
              and assignment.created_at<=branch_close_at
              and team.created_at<=branch_close_at
              and staff.created_at<=branch_close_at
              and coalesce(duty.duty_status,'on_duty')='on_duty'
          ) select eligible.operational_team_id,pg_catalog.count(*) eligible_staff_count
            from eligible group by eligible.operational_team_id
        loop
          select pg_catalog.count(*) into evidence_count
          from public.checklist_submissions submission
          where submission.organization_id=p_organization_id
            and submission.branch_id=p_branch_id
            and submission.business_date=p_business_date
            and submission.checklist_type='staff_hygiene'
            and submission.operational_team_id=team_record.operational_team_id;
          if evidence_count=0 then calculated_state:='incomplete';
          elsif evidence_count>1 then calculated_state:='unknown'; exit;
          else
            select submission.id,submission.state,submission.submitted_at
            into target_submission_id,target_state,target_submitted_at
            from public.checklist_submissions submission
            where submission.organization_id=p_organization_id
              and submission.branch_id=p_branch_id
              and submission.business_date=p_business_date
              and submission.checklist_type='staff_hygiene'
              and submission.operational_team_id=team_record.operational_team_id;
            if target_state='draft' and target_submitted_at is null then
              calculated_state:='incomplete';
            elsif target_state<>'submitted' or target_submitted_at is null
              or target_submitted_at>p_as_of then
              calculated_state:='unknown'; exit;
            else
              with eligible as(
                select assignment.operational_staff_id
                from public.operational_staff_assignments assignment
                join public.branch_operational_teams team
                  on team.id=assignment.operational_team_id
                  and team.organization_id=assignment.organization_id
                  and team.branch_id=assignment.branch_id
                join public.operational_staff staff
                  on staff.id=assignment.operational_staff_id
                  and staff.organization_id=assignment.organization_id
                left join public.operational_staff_duty_statuses duty
                  on duty.assignment_id=assignment.id
                  and duty.operational_staff_id=assignment.operational_staff_id
                  and duty.organization_id=assignment.organization_id
                  and duty.branch_id=assignment.branch_id
                  and duty.duty_date=p_business_date
                where assignment.organization_id=p_organization_id
                  and assignment.branch_id=p_branch_id
                  and assignment.operational_team_id=team_record.operational_team_id
                  and assignment.valid_from<=p_business_date
                  and (assignment.valid_to is null or assignment.valid_to>=p_business_date)
                  and assignment.created_at<=branch_close_at
                  and team.created_at<=branch_close_at
                  and staff.created_at<=branch_close_at
                  and coalesce(duty.duty_status,'on_duty')='on_duty'
              ), snapshots as(
                select snapshot.operational_staff_id,snapshot.uniform_result,
                  snapshot.fingernails_result,snapshot.hair_result,snapshot.facial_hair_result
                from public.hygiene_staff_snapshots snapshot
                where snapshot.submission_id=target_submission_id
              )
              select pg_catalog.count(*),
                pg_catalog.count(*) filter(where snapshots.uniform_result in('pass','issue')
                  and snapshots.fingernails_result in('pass','issue')
                  and snapshots.hair_result in('pass','issue')
                  and snapshots.facial_hair_result in('pass','issue'))
              into actual_count,valid_count from snapshots;
              if actual_count<>team_record.eligible_staff_count
                or valid_count<>team_record.eligible_staff_count
                or exists(
                  select snapshot.operational_staff_id
                  from public.hygiene_staff_snapshots snapshot
                  where snapshot.submission_id=target_submission_id
                  group by snapshot.operational_staff_id having pg_catalog.count(*)>1
                )
                or exists(
                  with eligible as(
                    select assignment.operational_staff_id
                    from public.operational_staff_assignments assignment
                    join public.branch_operational_teams team
                      on team.id=assignment.operational_team_id
                      and team.organization_id=assignment.organization_id
                      and team.branch_id=assignment.branch_id
                    join public.operational_staff staff
                      on staff.id=assignment.operational_staff_id
                      and staff.organization_id=assignment.organization_id
                    left join public.operational_staff_duty_statuses duty
                      on duty.assignment_id=assignment.id
                      and duty.operational_staff_id=assignment.operational_staff_id
                      and duty.organization_id=assignment.organization_id
                      and duty.branch_id=assignment.branch_id
                      and duty.duty_date=p_business_date
                    where assignment.organization_id=p_organization_id
                      and assignment.branch_id=p_branch_id
                      and assignment.operational_team_id=team_record.operational_team_id
                      and assignment.valid_from<=p_business_date
                      and (assignment.valid_to is null or assignment.valid_to>=p_business_date)
                      and assignment.created_at<=branch_close_at
                      and team.created_at<=branch_close_at
                      and staff.created_at<=branch_close_at
                      and coalesce(duty.duty_status,'on_duty')='on_duty'
                  ), snapshots as(
                    select snapshot.operational_staff_id
                    from public.hygiene_staff_snapshots snapshot
                    where snapshot.submission_id=target_submission_id
                  )
                  select 1 from eligible
                  full join snapshots
                    on snapshots.operational_staff_id=eligible.operational_staff_id
                  where eligible.operational_staff_id is null or snapshots.operational_staff_id is null
                ) then calculated_state:='unknown'; exit; end if;
            end if;
          end if;
        end loop;
      end if;

    elsif module_record.module_key='cold_storage' then
      select pg_catalog.count(*) into evidence_count
      from public.cold_storage_submissions submission
      where submission.organization_id=p_organization_id
        and submission.branch_id=p_branch_id and submission.business_date=p_business_date;

      select coalesce(b.cold_storage_0200_notification_required, true)
      into branch_0200_required
      from public.branches b
      where b.id=p_branch_id and b.organization_id=p_organization_id;

      select private.cold_storage_closed_slots_for(p_branch_id,p_business_date,p_as_of)
        into closed_slots;

      if not branch_0200_required then
        required_closed_slots := array_remove(closed_slots, '02:00');
      else
        required_closed_slots := closed_slots;
      end if;

      if closed_slots is null or pg_catalog.cardinality(closed_slots)=0
        or pg_catalog.cardinality(closed_slots)<>(select pg_catalog.count(distinct slot_value.slot)
          from pg_catalog.unnest(closed_slots) slot_value(slot))
        or not (closed_slots<@array['12:00','20:00','02:00']::text[]) then
        calculated_state:='unknown';
      elsif evidence_count=0 then
        with required_pairs as(
          select master.id,slot.slot
          from public.branch_cold_storage_equipment master
          cross join pg_catalog.unnest(required_closed_slots) slot(slot)
          left join lateral private.cold_storage_master_first_eligible_slot(
            lifecycle_timezone,master.created_at) eligibility on true
          where master.organization_id=p_organization_id
            and master.branch_id=p_branch_id
            and master.active
            and master.created_at<=branch_close_at
            and private.cold_storage_equipment_slot_eligible(
              eligibility.first_eligible_business_date,eligibility.first_eligible_slot,
              p_business_date,slot.slot)
        ) select pg_catalog.count(*) into required_pair_count from required_pairs;

        if required_pair_count>0 then
          calculated_state:='incomplete';
        else
          calculated_state:='unknown';
        end if;
      elsif evidence_count>1 then
        calculated_state:='unknown';
      else
        select submission.id,submission.state into target_submission_id,target_state
        from public.cold_storage_submissions submission
        where submission.organization_id=p_organization_id
          and submission.branch_id=p_branch_id and submission.business_date=p_business_date;

        if not exists(select 1 from public.cold_storage_equipment equipment
          where equipment.submission_id=target_submission_id)
          or exists(
            select 1 from public.cold_storage_equipment equipment
            left join public.branch_cold_storage_equipment master
              on master.id=equipment.master_equipment_id
              and master.organization_id=p_organization_id and master.branch_id=p_branch_id
            where equipment.submission_id=target_submission_id
              and (equipment.master_equipment_id is null or equipment.organization_id<>p_organization_id
                or equipment.branch_id<>p_branch_id or master.id is null)
          ) or exists(
            select equipment.master_equipment_id from public.cold_storage_equipment equipment
            where equipment.submission_id=target_submission_id
            group by equipment.master_equipment_id having pg_catalog.count(*)>1
          ) or exists(
            select equipment.equipment_id from public.cold_storage_equipment equipment
            where equipment.submission_id=target_submission_id
            group by equipment.equipment_id having pg_catalog.count(*)>1
          ) or exists(
            select reading.equipment_id,reading.slot from public.cold_storage_readings reading
            where reading.submission_id=target_submission_id
            group by reading.equipment_id,reading.slot having pg_catalog.count(*)>1
          ) then calculated_state:='unknown';
        else
          with required_pairs as(
            select equipment.equipment_id,slot.slot
            from public.cold_storage_equipment equipment
            join public.branch_cold_storage_equipment master
              on master.id=equipment.master_equipment_id
              and master.organization_id=p_organization_id and master.branch_id=p_branch_id
            cross join pg_catalog.unnest(required_closed_slots) slot(slot)
            left join lateral private.cold_storage_master_first_eligible_slot(
              lifecycle_timezone,master.created_at) eligibility on true
            where equipment.submission_id=target_submission_id and equipment.active
              and private.cold_storage_equipment_slot_eligible(
                eligibility.first_eligible_business_date,eligibility.first_eligible_slot,
                p_business_date,slot.slot)
          ) select pg_catalog.count(*),pg_catalog.count(*) filter(where reading.id is null
              or reading.submitted_at is null or reading.submitted_at>p_as_of
              or reading.temperature_c is null or reading.status not in('pass','fail'))
            into required_pair_count,missing_pair_count
            from required_pairs pair
            left join public.cold_storage_readings reading
              on reading.submission_id=target_submission_id
              and reading.equipment_id=pair.equipment_id and reading.slot=pair.slot;

          if required_pair_count=0 then calculated_state:='unknown';
          elsif exists(
            with allowed_pairs as(
              select equipment.equipment_id,slot.slot
              from public.cold_storage_equipment equipment
              join public.branch_cold_storage_equipment master
                on master.id=equipment.master_equipment_id
                and master.organization_id=p_organization_id and master.branch_id=p_branch_id
              cross join pg_catalog.unnest(closed_slots) slot(slot)
              left join lateral private.cold_storage_master_first_eligible_slot(
                lifecycle_timezone,master.created_at) eligibility on true
              where equipment.submission_id=target_submission_id and equipment.active
                and private.cold_storage_equipment_slot_eligible(
                  eligibility.first_eligible_business_date,eligibility.first_eligible_slot,
                  p_business_date,slot.slot)
            ) select 1 from public.cold_storage_readings reading
              where reading.submission_id=target_submission_id and reading.submitted_at is not null
                and not exists(select 1 from allowed_pairs pair
                  where pair.equipment_id=reading.equipment_id and pair.slot=reading.slot)
          ) then calculated_state:='unknown';
          elsif missing_pair_count>0 then
            calculated_state:=case when target_state='submitted' then'unknown'else'incomplete'end;
          elsif target_state<>'submitted' then
            if not branch_0200_required and target_state='draft' then
              calculated_state:='completed';
            else
              calculated_state:='unknown';
            end if;
          else calculated_state:='completed'; end if;
        end if;
      end if;

    elsif module_record.module_key='oil_tracking' then
      select pg_catalog.count(*) into evidence_count
      from public.oil_tracking_submissions submission
      where submission.organization_id=p_organization_id
        and submission.branch_id=p_branch_id and submission.business_date=p_business_date;
      if evidence_count<>1 then calculated_state:='unknown';
      else
        select submission.id,submission.state,submission.opening_submitted_at,
          submission.closing_submitted_at
        into target_submission_id,target_state,target_opening_submitted_at,target_closing_submitted_at
        from public.oil_tracking_submissions submission
        where submission.organization_id=p_organization_id
          and submission.branch_id=p_branch_id and submission.business_date=p_business_date;
        select pg_catalog.count(*),pg_catalog.count(*) filter(where result.in_use_today)
          into actual_count,eligible_count
        from public.oil_tracking_fryer_results result
        where result.submission_id=target_submission_id;
        if actual_count=0 or eligible_count=0 or exists(
          select result.fryer_id from public.oil_tracking_fryer_results result
          where result.submission_id=target_submission_id
          group by result.fryer_id having pg_catalog.count(*)>1
        ) then calculated_state:='unknown';
        elsif target_opening_submitted_at is not null
          and (target_opening_submitted_at>p_as_of or exists(
            select 1 from public.oil_tracking_fryer_results result
            where result.submission_id=target_submission_id and result.in_use_today
              and (result.oil_status not in('new_oil','filtered_oil')
                or result.opening_temperature_c is null
                or result.opening_status not in('pass','fail')
                or (result.opening_status='fail' and pg_catalog.length(pg_catalog.btrim(result.opening_note))=0))
          )) then calculated_state:='unknown';
        elsif target_closing_submitted_at is not null
          and (target_closing_submitted_at>p_as_of or exists(
            select 1 from public.oil_tracking_fryer_results result
            where result.submission_id=target_submission_id and result.in_use_today
              and (result.closing_tpm_percent is null
                or (result.closing_tpm_percent>=21
                  and pg_catalog.length(pg_catalog.btrim(result.closing_note))=0))
          )) then calculated_state:='unknown';
        elsif target_opening_submitted_at is null
          or target_closing_submitted_at is null then
          calculated_state:=case when target_state='submitted' then'unknown'else'incomplete'end;
        elsif target_state<>'submitted' then calculated_state:='unknown';
        else calculated_state:='completed'; end if;
      end if;
    end if;

    if calculated_state not in('completed','incomplete','not_required','unknown') then
      raise exception 'invalid incomplete branch task module state' using errcode='22023';
    end if;
    module_key:=module_record.module_key;
    module_state:=calculated_state;
    return next;
  end loop;
end
$$;

revoke all on function private.incomplete_branch_tasks_completion_at(uuid,uuid,date,timestamptz)
  from public,anon,authenticated,service_role;

-- 6. Decouple Manager In-App Maintenance Issue notification from Push Producer configuration
create or replace function private.enqueue_organization_manager_maintenance_issue()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  recipient record;
begin
  for recipient in
    select distinct membership.user_id
    from public.organization_memberships membership
    join public.organizations organization on organization.id = membership.organization_id
    join public.profiles profile on profile.id = membership.user_id
    where membership.organization_id = new.organization_id
      and membership.role = 'organization_manager'
      and membership.active
      and organization.active
      and profile.disabled_at is null
      and not profile.must_change_password
  loop
    perform public.create_organization_manager_notification(
      new.organization_id,
      recipient.user_id,
      'maintenance_issue_created',
      'maintenance_issue',
      new.id,
      'maintenance-issue:' || new.id::text
    );
  end loop;
  return new;
end;
$$;

revoke all on function private.enqueue_organization_manager_maintenance_issue()
  from public,anon,authenticated,service_role;

-- 7. Immediate Manager Dashboard Projection for Maintenance Issues (removes 04:00 branch_date_closed gate)
create or replace function public.list_organization_manager_notification_projection(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_before timestamptz default null,
  p_limit integer default 50
)
returns table(
  id uuid,
  organization_id uuid,
  category text,
  branch_id uuid,
  business_date date,
  source_type text,
  source_id uuid,
  legacy_notification_id uuid,
  occurrence_key text,
  category_context jsonb,
  read_at timestamptz,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.assert_active_organization_manager(p_actor_user_id,p_organization_id);
  if p_limit not between 1 and 100 then
    raise exception 'invalid manager notification projection list' using errcode='22023';
  end if;

  return query
  with projected as (
    -- Category rollup rows remain strictly gated on closed business date
    select n.id,n.organization_id,n.event_type as category,n.branch_id,n.business_date,
      n.source_type,n.source_id,null::uuid as legacy_notification_id,n.occurrence_key,
      n.category_context,n.read_at,n.created_at
    from public.organization_manager_notifications n
    where n.organization_id=p_organization_id
      and n.recipient_user_id=p_actor_user_id
      and n.event_type in('sales_tracking_missing','maintenance_issue','incomplete_branch_tasks')
      and private.organization_manager_category_context_valid(n.event_type,n.category_context)
      and private.organization_manager_notification_branch_date_closed(
        n.organization_id,n.branch_id,n.business_date,pg_catalog.statement_timestamp())

    union all

    -- Maintenance issue notifications are visible immediately upon creation
    select n.id,n.organization_id,'maintenance_issue'::text,
      issue.branch_id,
      private.phase4a_business_date_at(branch.timezone,n.created_at),
      'maintenance_issue'::text,issue.id,n.id,n.occurrence_key,
      pg_catalog.jsonb_build_object('schema_version','1','category','maintenance_issue','scope','branch','legacy',true,'issue_id',issue.id),
      n.read_at,n.created_at
    from public.organization_manager_notifications n
    join public.maintenance_issues issue
      on issue.id=n.source_id and issue.organization_id=n.organization_id
    join public.branches branch
      on branch.id=issue.branch_id and branch.organization_id=issue.organization_id
    where n.organization_id=p_organization_id
      and n.recipient_user_id=p_actor_user_id
      and n.event_type='maintenance_issue_created'
      and n.source_type='maintenance_issue'
      and not exists(
        select 1
        from public.organization_manager_notifications category_notification
        where category_notification.organization_id=n.organization_id
          and category_notification.recipient_user_id=n.recipient_user_id
          and category_notification.event_type='maintenance_issue'
          and private.organization_manager_category_context_valid(
            category_notification.event_type,category_notification.category_context)
          and category_notification.category_context->'issue_ids' ? issue.id::text
      )

    union all

    -- Office-scoped legacy maintenance
    select n.id,n.organization_id,'maintenance_issue'::text,null::uuid,null::date,
      n.source_type,n.source_id,n.id,n.occurrence_key,
      pg_catalog.jsonb_build_object('schema_version','1','category','maintenance_issue','scope','office','legacy',true),
      n.read_at,n.created_at
    from public.organization_manager_notifications n
    where n.organization_id=p_organization_id
      and n.recipient_user_id=p_actor_user_id
      and n.event_type='maintenance_issue_created'
      and (n.source_type is null or n.source_type<>'maintenance_issue'
        or not exists(
          select 1 from public.maintenance_issues issue
          where issue.id=n.source_id and issue.organization_id=n.organization_id
        ))
  )
  select projected.id,projected.organization_id,projected.category,projected.branch_id,
    projected.business_date,projected.source_type,projected.source_id,
    projected.legacy_notification_id,projected.occurrence_key,projected.category_context,
    projected.read_at,projected.created_at
  from projected
  where p_before is null
    or projected.created_at<p_before
  order by projected.created_at desc,projected.id desc
  limit p_limit;
end;
$$;

create or replace function public.count_organization_manager_notification_projection(
  p_actor_user_id uuid,
  p_organization_id uuid
)
returns bigint
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.assert_active_organization_manager(p_actor_user_id,p_organization_id);
  return (
    with counts as (
      select count(*)::bigint as item_count
      from public.organization_manager_notifications n
      where n.organization_id=p_organization_id
        and n.recipient_user_id=p_actor_user_id
        and n.read_at is null
        and n.event_type in('sales_tracking_missing','maintenance_issue','incomplete_branch_tasks')
        and private.organization_manager_category_context_valid(n.event_type,n.category_context)
        and private.organization_manager_notification_branch_date_closed(
          n.organization_id,n.branch_id,n.business_date,pg_catalog.statement_timestamp())
      union all
      select count(*)::bigint
      from public.organization_manager_notifications n
      join public.maintenance_issues issue
        on issue.id=n.source_id and issue.organization_id=n.organization_id
      join public.branches branch
        on branch.id=issue.branch_id and branch.organization_id=issue.organization_id
      where n.organization_id=p_organization_id
        and n.recipient_user_id=p_actor_user_id
        and n.read_at is null
        and n.event_type='maintenance_issue_created'
        and n.source_type='maintenance_issue'
        and not exists(
          select 1 from public.organization_manager_notifications category_notification
          where category_notification.organization_id=n.organization_id
            and category_notification.recipient_user_id=n.recipient_user_id
            and category_notification.event_type='maintenance_issue'
            and private.organization_manager_category_context_valid(
              category_notification.event_type,category_notification.category_context)
            and category_notification.category_context->'issue_ids' ? issue.id::text
        )
      union all
      select count(*)::bigint
      from public.organization_manager_notifications n
      where n.organization_id=p_organization_id
        and n.recipient_user_id=p_actor_user_id
        and n.read_at is null
        and n.event_type='maintenance_issue_created'
        and (n.source_type is null or n.source_type<>'maintenance_issue'
          or not exists(
            select 1 from public.maintenance_issues issue
            where issue.id=n.source_id and issue.organization_id=n.organization_id
          ))
    )
    select coalesce(sum(item_count),0)::bigint from counts
  );
end;
$$;

revoke all on function public.list_organization_manager_notification_projection(uuid,uuid,timestamptz,integer)
  from public,anon,authenticated,service_role;
revoke all on function public.count_organization_manager_notification_projection(uuid,uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.list_organization_manager_notification_projection(uuid,uuid,timestamptz,integer)
  to service_role;
grant execute on function public.count_organization_manager_notification_projection(uuid,uuid)
  to service_role;

-- 8. Cursor-based Manager Dashboard Projection (immediate maintenance projection)
create or replace function public.list_organization_manager_notification_projection_cursor(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
)
returns table(
  id uuid,
  organization_id uuid,
  category text,
  branch_id uuid,
  business_date date,
  source_type text,
  source_id uuid,
  legacy_notification_id uuid,
  occurrence_key text,
  category_context jsonb,
  read_at timestamptz,
  created_at timestamptz
)
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform private.assert_active_organization_manager(p_actor_user_id,p_organization_id);
  if p_limit not between 1 and 100 then
    raise exception 'invalid manager notification projection cursor list' using errcode='22023';
  end if;
  if (p_before_created_at is null) <> (p_before_id is null) then
    raise exception 'invalid manager notification projection cursor' using errcode='22023';
  end if;

  return query
  with projected as (
    select n.id,n.organization_id,n.event_type as category,n.branch_id,n.business_date,
      n.source_type,n.source_id,null::uuid as legacy_notification_id,n.occurrence_key,
      n.category_context,n.read_at,n.created_at
    from public.organization_manager_notifications n
    where n.organization_id=p_organization_id
      and n.recipient_user_id=p_actor_user_id
      and n.event_type in('sales_tracking_missing','maintenance_issue','incomplete_branch_tasks')
      and private.organization_manager_category_context_valid(n.event_type,n.category_context)
      and private.organization_manager_notification_branch_date_closed(
        n.organization_id,n.branch_id,n.business_date,pg_catalog.statement_timestamp())

    union all

    select n.id,n.organization_id,'maintenance_issue'::text,issue.branch_id,
      private.phase4a_business_date_at(branch.timezone,n.created_at),
      'maintenance_issue'::text,issue.id,n.id,n.occurrence_key,
      pg_catalog.jsonb_build_object('schema_version','1','category','maintenance_issue','scope','branch','legacy',true,'issue_id',issue.id),
      n.read_at,n.created_at
    from public.organization_manager_notifications n
    join public.maintenance_issues issue on issue.id=n.source_id and issue.organization_id=n.organization_id
    join public.branches branch on branch.id=issue.branch_id and branch.organization_id=issue.organization_id
    where n.organization_id=p_organization_id and n.recipient_user_id=p_actor_user_id
      and n.event_type='maintenance_issue_created' and n.source_type='maintenance_issue'
      and not exists(
        select 1 from public.organization_manager_notifications category_notification
        where category_notification.organization_id=n.organization_id
          and category_notification.recipient_user_id=n.recipient_user_id
          and category_notification.event_type='maintenance_issue'
          and private.organization_manager_category_context_valid(category_notification.event_type,category_notification.category_context)
          and category_notification.category_context->'issue_ids' ? issue.id::text
      )

    union all

    select n.id,n.organization_id,'maintenance_issue'::text,null::uuid,null::date,
      n.source_type,n.source_id,n.id,n.occurrence_key,
      pg_catalog.jsonb_build_object('schema_version','1','category','maintenance_issue','scope','office','legacy',true),
      n.read_at,n.created_at
    from public.organization_manager_notifications n
    where n.organization_id=p_organization_id and n.recipient_user_id=p_actor_user_id
      and n.event_type='maintenance_issue_created'
      and (n.source_type is null or n.source_type<>'maintenance_issue' or not exists(
        select 1 from public.maintenance_issues issue
        where issue.id=n.source_id and issue.organization_id=n.organization_id
      ))
  )
  select projected.id,projected.organization_id,projected.category,projected.branch_id,
    projected.business_date,projected.source_type,projected.source_id,
    projected.legacy_notification_id,projected.occurrence_key,projected.category_context,
    projected.read_at,projected.created_at
  from projected
  where p_before_created_at is null
    or (projected.created_at,projected.id) < (p_before_created_at,p_before_id)
  order by projected.created_at desc,projected.id desc
  limit p_limit;
end;
$$;

revoke all on function public.list_organization_manager_notification_projection_cursor(uuid,uuid,timestamptz,uuid,integer)
  from public,anon,authenticated,service_role;
grant execute on function public.list_organization_manager_notification_projection_cursor(uuid,uuid,timestamptz,uuid,integer)
  to service_role;

-- 9. Canonical branch business-date calculation in evaluation job scheduler
create or replace function public.enqueue_due_organization_manager_notification_evaluation_jobs(
  p_catch_up_days integer default 3,
  p_as_of timestamptz default null
)
returns table(
  job_id uuid,
  organization_id uuid,
  branch_id uuid,
  business_date date,
  notification_category text,
  enqueued boolean
)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  now_at timestamptz := coalesce(p_as_of, pg_catalog.statement_timestamp());
  branch_record record;
  latest_closed_business_date date;
  earliest_business_date date;
  candidate_date date;
  category_item text;
  saved_id uuid;
  is_new boolean;
begin
  if p_catch_up_days is null or p_catch_up_days not between 1 and 7 then
    raise exception 'invalid catch_up_days: must be between 1 and 7' using errcode = '22023';
  end if;

  for branch_record in
    select
      organization.id as org_id,
      branch.id as b_id,
      lifecycle.timezone as tz
    from public.organizations organization
    join public.branches branch on branch.organization_id = organization.id
    join public.daily_report_branch_lifecycle lifecycle
      on lifecycle.organization_id = organization.id
     and lifecycle.branch_id = branch.id
    where organization.active = true
      and branch.active = true
      and lifecycle.active = true
      and lifecycle.effective_to_business_date is null
    order by organization.id, branch.id
  loop
    -- Canonical branch-local closed date: yesterday relative to current branch business date
    latest_closed_business_date := private.phase4a_business_date_at(branch_record.tz, now_at) - 1;
    earliest_business_date := latest_closed_business_date - (p_catch_up_days - 1);

    candidate_date := earliest_business_date;
    while candidate_date <= latest_closed_business_date loop
      if private.organization_manager_notification_branch_date_closed(
        branch_record.org_id, branch_record.b_id, candidate_date, now_at
      ) then
        foreach category_item in array array['sales_tracking_missing', 'maintenance_issue', 'incomplete_branch_tasks'] loop
          saved_id := null;
          is_new := false;

          insert into private.organization_manager_notification_evaluation_jobs(
            notification_category, organization_id, branch_id, business_date
          ) values (
            category_item, branch_record.org_id, branch_record.b_id, candidate_date
          )
          on conflict (organization_id, branch_id, business_date, notification_category) do nothing
          returning id into saved_id;

          if saved_id is not null then
            is_new := true;
          else
            select job.id into strict saved_id
            from private.organization_manager_notification_evaluation_jobs job
            where job.organization_id = branch_record.org_id
              and job.branch_id = branch_record.b_id
              and job.business_date = candidate_date
              and job.notification_category = category_item;
            is_new := false;
          end if;

          job_id := saved_id;
          organization_id := branch_record.org_id;
          branch_id := branch_record.b_id;
          business_date := candidate_date;
          notification_category := category_item;
          enqueued := is_new;
          return next;
        end loop;
      end if;
      candidate_date := candidate_date + 1;
    end loop;
  end loop;
end;
$$;

revoke all on function public.enqueue_due_organization_manager_notification_evaluation_jobs(integer, timestamptz)
  from public, anon, authenticated, service_role;
grant execute on function public.enqueue_due_organization_manager_notification_evaluation_jobs(integer, timestamptz)
  to service_role;

commit;
