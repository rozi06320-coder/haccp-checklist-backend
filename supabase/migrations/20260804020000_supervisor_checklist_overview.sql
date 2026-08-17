-- Atomic, server-authorized Phase 4A metrics for the Branch Supervisor Overview.
create function public.get_phase4a_supervisor_overview(actor_user_id uuid,target_branch_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare c record; result jsonb;
begin
 select * into strict c from private.phase4a_actor_context(actor_user_id,target_branch_id);
 with selected as (
  select distinct on (s.checklist_type) s.id,s.checklist_type,s.definition_id,s.state
  from public.checklist_submissions s
  where s.organization_id=c.organization_id and s.branch_id=c.branch_id
   and s.supervisor_team_id=c.team_id and s.business_date=c.business_date
   and s.checklist_type in ('kitchen_opening','foh_opening','staff_hygiene')
  order by s.checklist_type,case s.state when 'submitted' then 0 else 1 end,s.updated_at desc,s.id
 ), opening_metrics as (
  select d.checklist_type,coalesce(s.state,'not_started') state,
   case when s.state='submitted' then count(r.id) else count(i.item_id) end::bigint expected_checks,
   count(r.id) filter(where r.answer in ('completed','issue_found'))::bigint answered_checks,
   count(r.id) filter(where r.answer='completed')::bigint compliant_checks,
   count(r.id) filter(where r.answer='issue_found')::bigint issue_checks
  from public.checklist_definitions d
  left join selected s on s.checklist_type=d.checklist_type
  left join public.checklist_definition_items i on i.definition_id=d.id and d.active and s.state is distinct from 'submitted'
  left join public.opening_item_results r on r.submission_id=s.id
   and ((s.state='submitted') or (r.definition_id=d.id and r.item_id=i.item_id))
  where d.active and d.checklist_type in ('kitchen_opening','foh_opening')
  group by d.checklist_type,s.state
 ), eligible_staff as (
  select staff.id
  from public.operational_staff_assignments a
  join public.operational_staff staff on staff.id=a.operational_staff_id
  left join public.operational_staff_duty_statuses duty on duty.assignment_id=a.id and duty.duty_date=c.business_date
  where a.supervisor_team_id=c.team_id and a.active and staff.employment_status='active'
   and coalesce(duty.duty_status,'on_duty')='on_duty'
 ), hygiene_values as (
  select h.uniform_result value from selected s join public.hygiene_staff_snapshots h on h.submission_id=s.id
   where s.checklist_type='staff_hygiene' and (s.state='submitted' or h.operational_staff_id in(select id from eligible_staff))
  union all select h.fingernails_result from selected s join public.hygiene_staff_snapshots h on h.submission_id=s.id
   where s.checklist_type='staff_hygiene' and (s.state='submitted' or h.operational_staff_id in(select id from eligible_staff))
  union all select h.hair_result from selected s join public.hygiene_staff_snapshots h on h.submission_id=s.id
   where s.checklist_type='staff_hygiene' and (s.state='submitted' or h.operational_staff_id in(select id from eligible_staff))
  union all select h.facial_hair_result from selected s join public.hygiene_staff_snapshots h on h.submission_id=s.id
   where s.checklist_type='staff_hygiene' and (s.state='submitted' or h.operational_staff_id in(select id from eligible_staff))
 ), hygiene_metrics as (
  select 'staff_hygiene'::text checklist_type,coalesce((select state from selected where checklist_type='staff_hygiene'),'not_started') state,
   (case when (select state from selected where checklist_type='staff_hygiene')='submitted'
    then (select count(*)*4 from public.hygiene_staff_snapshots h join selected s on s.id=h.submission_id where s.checklist_type='staff_hygiene')
    else (select count(*)*4 from eligible_staff) end)::bigint expected_checks,
   count(*) filter(where value in ('pass','issue'))::bigint answered_checks,
   count(*) filter(where value='pass')::bigint compliant_checks,
   count(*) filter(where value='issue')::bigint issue_checks
  from hygiene_values
 ), raw as (select * from opening_metrics union all select * from hygiene_metrics),
 metrics as (
  select checklist_type,state,expected_checks,answered_checks,compliant_checks,issue_checks,
   (expected_checks-answered_checks)::bigint pending_checks,
   case when expected_checks=0 then null else round(answered_checks*100.0/expected_checks)::int end completion_percentage,
   case when answered_checks=0 then null else round(compliant_checks*100.0/answered_checks)::int end compliance_percentage
  from raw
 ), totals as (
  select sum(expected_checks)::bigint expected_checks,sum(answered_checks)::bigint answered_checks,
   sum(compliant_checks)::bigint compliant_checks,sum(issue_checks)::bigint issue_checks,
   sum(pending_checks)::bigint pending_checks from metrics
 )
 select pg_catalog.jsonb_build_object(
  'business_date',c.business_date,
  'totals',pg_catalog.jsonb_build_object('expected_checks',t.expected_checks,'answered_checks',t.answered_checks,
   'compliant_checks',t.compliant_checks,'issue_checks',t.issue_checks,'pending_checks',t.pending_checks,
   'completion_percentage',case when t.expected_checks=0 then null else round(t.answered_checks*100.0/t.expected_checks)::int end,
   'compliance_percentage',case when t.answered_checks=0 then null else round(t.compliant_checks*100.0/t.answered_checks)::int end),
  'checklists',(select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('checklist_type',m.checklist_type,'state',m.state,
   'expected_checks',m.expected_checks,'answered_checks',m.answered_checks,'compliant_checks',m.compliant_checks,
   'issue_checks',m.issue_checks,'pending_checks',m.pending_checks,'completion_percentage',m.completion_percentage,
   'compliance_percentage',m.compliance_percentage) order by case m.checklist_type when 'kitchen_opening' then 1 when 'foh_opening' then 2 else 3 end) from metrics m)
 ) into result from totals t;
 return result;
exception when no_data_found or too_many_rows then raise exception 'overview access denied' using errcode='42501';
end $$;

revoke all on function public.get_phase4a_supervisor_overview(uuid,uuid) from public,anon,authenticated;
grant execute on function public.get_phase4a_supervisor_overview(uuid,uuid) to service_role;
