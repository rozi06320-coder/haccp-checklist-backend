-- 20261108000000_oil_tracking_partial_fryer_completion.sql
-- HACCP: Oil Tracking Partial Fryer Submission Completion Fix
-- Ensures Oil Tracking is COMPLETE when active fryers (1 or more) are validly submitted
-- for both Opening and Closing, regardless of unselected fryers.
-- Zero submissions or zero active fryers on a required branch evaluate to incomplete.
-- Unverifiable or conflicting records fail closed to unknown.
-- Exempt branches evaluate to not_required.

begin;

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

      if evidence_count=0 then
        calculated_state:='incomplete';
      elsif evidence_count>1 then
        calculated_state:='unknown';
      else
        select submission.id,submission.state,submission.opening_submitted_at,
          submission.closing_submitted_at
        into target_submission_id,target_state,target_opening_submitted_at,target_closing_submitted_at
        from public.oil_tracking_submissions submission
        where submission.organization_id=p_organization_id
          and submission.branch_id=p_branch_id and submission.business_date=p_business_date;

        select pg_catalog.count(*),
          pg_catalog.count(*) filter(where result.in_use_today)
        into actual_count,eligible_count
        from public.oil_tracking_fryer_results result
        where result.submission_id=target_submission_id;

        if exists(
          select result.fryer_id from public.oil_tracking_fryer_results result
          where result.submission_id=target_submission_id
          group by result.fryer_id having pg_catalog.count(*)>1
        ) then
          calculated_state:='unknown';
        elsif target_opening_submitted_at is not null
          and (target_opening_submitted_at>p_as_of or exists(
            select 1 from public.oil_tracking_fryer_results result
            where result.submission_id=target_submission_id and result.in_use_today
              and (result.oil_status not in('new_oil','filtered_oil')
                or result.opening_temperature_c is null
                or result.opening_status not in('pass','fail')
                or (result.opening_status='fail' and pg_catalog.length(pg_catalog.btrim(result.opening_note))=0))
          )) then
          calculated_state:='unknown';
        elsif target_closing_submitted_at is not null
          and (target_closing_submitted_at>p_as_of or exists(
            select 1 from public.oil_tracking_fryer_results result
            where result.submission_id=target_submission_id and result.in_use_today
              and (result.closing_tpm_percent is null
                or (result.closing_tpm_percent>=21
                  and pg_catalog.length(pg_catalog.btrim(result.closing_note))=0))
          )) then
          calculated_state:='unknown';
        elsif eligible_count=0 then
          calculated_state:='incomplete';
        elsif target_opening_submitted_at is null
          or target_closing_submitted_at is null then
          calculated_state:=case when target_state='submitted' then'unknown'else'incomplete'end;
        elsif target_state<>'submitted' then
          calculated_state:='unknown';
        else
          calculated_state:='completed';
        end if;
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
  from public,anon,authenticated,service_role;;

commit;
