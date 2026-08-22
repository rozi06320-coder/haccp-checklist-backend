-- Keep Supervisor Overview Staff Hygiene numerator on the same eligible staff
-- population as its denominator.

create or replace function public.get_phase4a_supervisor_overview(actor_user_id uuid,target_branch_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c record; result jsonb;
begin
 select * into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 with opening_metrics as (
  select d.checklist_type,coalesce(s.state,'not_started') state,count(i.item_id)::bigint expected_checks,
   count(r.id)filter(where r.answer in('completed','issue_found'))::bigint answered_checks,
   count(r.id)filter(where r.answer='completed')::bigint compliant_checks,
   count(r.id)filter(where r.answer='issue_found')::bigint issue_checks
  from public.checklist_definitions d
  left join public.checklist_definition_items i on i.definition_id=d.id
  left join public.checklist_submissions s on s.organization_id=c.organization_id and s.branch_id=c.branch_id
   and s.business_date=c.business_date and s.checklist_type=d.checklist_type
  left join public.opening_item_results r on r.submission_id=s.id and r.item_id=i.item_id
  where d.active and d.checklist_type in('kitchen_opening','foh_opening')
  group by d.checklist_type,s.state
 ), eligible_staff as (
  select distinct a.operational_staff_id
  from public.operational_staff_assignments a
  join public.operational_staff staff on staff.id=a.operational_staff_id and staff.employment_status='active'
  left join public.operational_staff_duty_statuses duty on duty.assignment_id=a.id and duty.duty_date=c.business_date
  where a.organization_id=c.organization_id and a.branch_id=c.branch_id and a.active
   and coalesce(duty.duty_status,'on_duty')='on_duty'
 ), hygiene_submissions as (
  select distinct on(s.operational_team_id)s.id,s.state,s.updated_at
  from public.checklist_submissions s
  where s.organization_id=c.organization_id and s.branch_id=c.branch_id and s.business_date=c.business_date
   and s.checklist_type='staff_hygiene'
  order by s.operational_team_id,case s.state when'submitted'then 0 else 1 end,s.updated_at desc,s.id
 ), hygiene_candidate_values as (
  select h.operational_staff_id,v.check_key,v.value,s.state,s.updated_at,s.id submission_id,h.id snapshot_id
  from hygiene_submissions s
  join public.hygiene_staff_snapshots h on h.submission_id=s.id
  join eligible_staff e on e.operational_staff_id=h.operational_staff_id
  cross join lateral(values
   ('uniform',h.uniform_result),
   ('fingernails',h.fingernails_result),
   ('hair',h.hair_result),
   ('facial_hair',h.facial_hair_result)
  )v(check_key,value)
 ), hygiene_values as (
  select distinct on(operational_staff_id,check_key)operational_staff_id,check_key,value
  from hygiene_candidate_values
  order by operational_staff_id,check_key,case state when'submitted'then 0 else 1 end,updated_at desc,submission_id,snapshot_id
 ), hygiene_metrics as (
  select 'staff_hygiene'::text checklist_type,
   case when not exists(select 1 from hygiene_submissions)then'not_started'
    when not exists(select 1 from hygiene_submissions where state<>'submitted')then'submitted'else'draft'end state,
   ((select count(*)from eligible_staff)*4)::bigint expected_checks,
   count(*)filter(where value in('pass','issue'))::bigint answered_checks,
   count(*)filter(where value='pass')::bigint compliant_checks,
   count(*)filter(where value='issue')::bigint issue_checks from hygiene_values
 ), oil_metrics as (
  select 'oil_tracking'::text checklist_type,
   case when s.id is null then'not_started'when s.opening_submitted_at is not null and s.closing_submitted_at is not null then'submitted'else'draft'end state,
   (count(r.id)*2)::bigint expected_checks,
   (count(r.id)filter(where r.opening_status<>'pending')+count(r.id)filter(where r.closing_tpm_percent is not null))::bigint answered_checks,
   (count(r.id)filter(where r.opening_status='pass')+count(r.id)filter(where r.closing_tpm_percent is not null and private.oil_tracking_tpm_status(r.closing_tpm_percent)<>'critical'))::bigint compliant_checks,
   (count(r.id)filter(where r.opening_status='fail')+count(r.id)filter(where r.closing_tpm_percent is not null and private.oil_tracking_tpm_status(r.closing_tpm_percent)='critical'))::bigint issue_checks
  from public.oil_tracking_submissions s left join public.oil_tracking_fryer_results r on r.submission_id=s.id
  where s.organization_id=c.organization_id and s.branch_id=c.branch_id and s.business_date=c.business_date
  group by s.id,s.opening_submitted_at,s.closing_submitted_at
 ), cold_metrics as (
  select 'cold_storage'::text checklist_type,case when s.id is null then'not_started'when s.state='submitted'then'submitted'else'draft'end state,
   count(r.id)::bigint expected_checks,count(r.id)filter(where r.status<>'pending')::bigint answered_checks,
   count(r.id)filter(where r.status='pass')::bigint compliant_checks,count(r.id)filter(where r.status='fail')::bigint issue_checks
  from public.cold_storage_submissions s left join public.cold_storage_readings r on r.submission_id=s.id
  where s.organization_id=c.organization_id and s.branch_id=c.branch_id and s.business_date=c.business_date
  group by s.id,s.state
 ), raw as (
  select*from opening_metrics union all select*from hygiene_metrics
  union all select*from oil_metrics union all select*from cold_metrics
 ), required as (
  select*from raw union all
  select 'oil_tracking','not_started',0::bigint,0::bigint,0::bigint,0::bigint where not exists(select 1 from raw where checklist_type='oil_tracking') union all
  select 'cold_storage','not_started',0::bigint,0::bigint,0::bigint,0::bigint where not exists(select 1 from raw where checklist_type='cold_storage')
 ), metrics as (
  select checklist_type,state,expected_checks,answered_checks,compliant_checks,issue_checks,
   (expected_checks-answered_checks)::bigint pending_checks,
   case when expected_checks=0 then null else round(answered_checks*100.0/expected_checks)::int end completion_percentage,
   case when answered_checks=0 then null else round(compliant_checks*100.0/answered_checks)::int end compliance_percentage from required
 ), totals as(select sum(expected_checks)::bigint expected_checks,sum(answered_checks)::bigint answered_checks,sum(compliant_checks)::bigint compliant_checks,sum(issue_checks)::bigint issue_checks,sum(pending_checks)::bigint pending_checks from metrics)
 select pg_catalog.jsonb_build_object('business_date',c.business_date,
  'totals',pg_catalog.jsonb_build_object('expected_checks',t.expected_checks,'answered_checks',t.answered_checks,'compliant_checks',t.compliant_checks,'issue_checks',t.issue_checks,'pending_checks',t.pending_checks,'completion_percentage',case when t.expected_checks=0 then null else round(t.answered_checks*100.0/t.expected_checks)::int end,'compliance_percentage',case when t.answered_checks=0 then null else round(t.compliant_checks*100.0/t.answered_checks)::int end),
  'checklists',(select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('checklist_type',m.checklist_type,'state',m.state,'expected_checks',m.expected_checks,'answered_checks',m.answered_checks,'compliant_checks',m.compliant_checks,'issue_checks',m.issue_checks,'pending_checks',m.pending_checks,'completion_percentage',m.completion_percentage,'compliance_percentage',m.compliance_percentage)order by case m.checklist_type when'kitchen_opening'then 1 when'foh_opening'then 2 when'staff_hygiene'then 3 when'oil_tracking'then 4 else 5 end)from metrics m))into result from totals t;
 return result;
exception when no_data_found or too_many_rows then raise exception'overview access denied'using errcode='42501';end$$;
