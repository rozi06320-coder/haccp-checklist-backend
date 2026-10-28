-- Supervisor Overview: Chiller & Freezer completion is stage-based.
-- A stage is complete only when every active unit has a submitted, valid reading.
-- Draft/pending readings and partially completed stages never produce 100%.

do $$
declare
  definition text;
  updated_definition text;
begin
  select pg_catalog.pg_get_functiondef(
    'public.get_phase4a_supervisor_overview(uuid,uuid)'::regprocedure
  ) into definition;

  updated_definition := replace(definition, $old$
 ), cold_metrics as (
  select 'cold_storage'::text checklist_type,case when s.id is null then'not_started'when s.state='submitted'then'submitted'else'draft'end state,
   count(r.id)::bigint expected_checks,count(r.id)filter(where r.status<>'pending')::bigint answered_checks,
   count(r.id)filter(where r.status='pass')::bigint compliant_checks,count(r.id)filter(where r.status='fail')::bigint issue_checks
  from public.cold_storage_submissions s left join public.cold_storage_readings r on r.submission_id=s.id
  where s.organization_id=c.organization_id and s.branch_id=c.branch_id and s.business_date=c.business_date
  group by s.id,s.state
 ), raw as (
$old$, $new$
 ), cold_stage_flags as (
  select s.id submission_id,
    s.state,
    expected.slot,
    count(distinct e.equipment_id)::bigint active_equipment_count,
    count(distinct r.equipment_id) filter (
      where r.submitted_at is not null
        and r.temperature_c is not null
        and r.status in ('pass','fail')
    )::bigint valid_reading_count,
    count(distinct r.equipment_id) filter (where r.status='fail')::bigint failed_reading_count
  from public.cold_storage_submissions s
  cross join (values ('12:00'),('20:00'),('02:00')) expected(slot)
  left join public.cold_storage_equipment e
    on e.submission_id=s.id and e.active
  left join public.cold_storage_readings r
    on r.submission_id=s.id
   and r.equipment_id=e.equipment_id
   and r.slot=expected.slot
  where s.organization_id=c.organization_id
    and s.branch_id=c.branch_id
    and s.business_date=c.business_date
  group by s.id,s.state,expected.slot
 ), cold_metrics as (
  select 'cold_storage'::text checklist_type,
   case when count(*) filter (
      where active_equipment_count > 0
        and valid_reading_count=active_equipment_count
    )=3 then 'submitted' else 'draft' end state,
   case when max(active_equipment_count)>0 then 3 else 0 end::bigint expected_checks,
   count(*) filter (
      where active_equipment_count > 0
        and valid_reading_count=active_equipment_count
   )::bigint answered_checks,
   count(*) filter (
      where active_equipment_count > 0
        and valid_reading_count=active_equipment_count
        and failed_reading_count=0
   )::bigint compliant_checks,
   count(*) filter (
      where active_equipment_count > 0
        and valid_reading_count=active_equipment_count
        and failed_reading_count>0
   )::bigint issue_checks
  from cold_stage_flags
  group by submission_id
 ), raw as (
$new$);

  if updated_definition=definition then
    raise exception 'failed to locate Supervisor Overview cold-storage metrics' using errcode='22023';
  end if;

  execute updated_definition;
end $$;
