-- Phase 2: branch-consistent supervisor overview and submission history.

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
 ), active_staff as (
  select a.operational_staff_id from public.operational_staff_assignments a
  join public.operational_staff staff on staff.id=a.operational_staff_id and staff.employment_status='active'
  left join public.operational_staff_duty_statuses duty on duty.assignment_id=a.id and duty.duty_date=c.business_date
  where a.organization_id=c.organization_id and a.branch_id=c.branch_id and a.active
   and coalesce(duty.duty_status,'on_duty')='on_duty'
 ), hygiene_submissions as (
  select distinct on(s.operational_team_id)s.id,s.state from public.checklist_submissions s
  where s.organization_id=c.organization_id and s.branch_id=c.branch_id and s.business_date=c.business_date
   and s.checklist_type='staff_hygiene'
  order by s.operational_team_id,case s.state when'submitted'then 0 else 1 end,s.updated_at desc
 ), hygiene_values as (
  select v.value from hygiene_submissions s join public.hygiene_staff_snapshots h on h.submission_id=s.id
  cross join lateral(values(h.uniform_result),(h.fingernails_result),(h.hair_result),(h.facial_hair_result))v(value)
 ), hygiene_metrics as (
  select 'staff_hygiene'::text checklist_type,
   case when not exists(select 1 from hygiene_submissions)then'not_started'
    when not exists(select 1 from hygiene_submissions where state<>'submitted')then'submitted'else'draft'end state,
   ((select count(*)from active_staff)*4)::bigint expected_checks,
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
   greatest(expected_checks-answered_checks,0)::bigint pending_checks,
   case when expected_checks=0 then null else round(answered_checks*100.0/expected_checks)::int end completion_percentage,
   case when answered_checks=0 then null else round(compliant_checks*100.0/answered_checks)::int end compliance_percentage from required
 ), totals as(select sum(expected_checks)::bigint expected_checks,sum(answered_checks)::bigint answered_checks,sum(compliant_checks)::bigint compliant_checks,sum(issue_checks)::bigint issue_checks,sum(pending_checks)::bigint pending_checks from metrics)
 select pg_catalog.jsonb_build_object('business_date',c.business_date,
  'totals',pg_catalog.jsonb_build_object('expected_checks',t.expected_checks,'answered_checks',t.answered_checks,'compliant_checks',t.compliant_checks,'issue_checks',t.issue_checks,'pending_checks',t.pending_checks,'completion_percentage',case when t.expected_checks=0 then null else round(t.answered_checks*100.0/t.expected_checks)::int end,'compliance_percentage',case when t.answered_checks=0 then null else round(t.compliant_checks*100.0/t.answered_checks)::int end),
  'checklists',(select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('checklist_type',m.checklist_type,'state',m.state,'expected_checks',m.expected_checks,'answered_checks',m.answered_checks,'compliant_checks',m.compliant_checks,'issue_checks',m.issue_checks,'pending_checks',m.pending_checks,'completion_percentage',m.completion_percentage,'compliance_percentage',m.compliance_percentage)order by case m.checklist_type when'kitchen_opening'then 1 when'foh_opening'then 2 when'staff_hygiene'then 3 when'oil_tracking'then 4 else 5 end)from metrics m))into result from totals t;
 return result;
exception when no_data_found or too_many_rows then raise exception'overview access denied'using errcode='42501';end$$;

create function public.list_phase2_branch_reports(actor_user_id uuid,target_branch_id uuid,requested_page int default 1,requested_page_size int default 20,target_checklist_type text default null)
returns jsonb language plpgsql stable security definer set search_path=''as $$declare c record;begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 if requested_page<1 or requested_page_size not between 1 and 50 or(target_checklist_type is not null and target_checklist_type not in('kitchen_opening','foh_opening','staff_hygiene','oil_tracking','cold_storage','sales_tracking','daily_audit'))then raise exception'invalid report list'using errcode='22023';end if;
 return(select pg_catalog.jsonb_build_object('reports',coalesce(pg_catalog.jsonb_agg(x.dto order by x.business_date desc,x.submitted_at desc,x.id desc)filter(where x.rn between(requested_page-1)*requested_page_size+1 and requested_page*requested_page_size),'[]'::jsonb),'page',requested_page,'page_size',requested_page_size,'total',count(*))from(
  select q.*,row_number()over(order by q.business_date desc,q.submitted_at desc,q.id desc)rn from(
   select s.id,s.business_date,s.submitted_at,s.checklist_type,pg_catalog.jsonb_build_object('id',s.id,'branch_id',s.branch_id,'checklist_type',s.checklist_type,'business_date',s.business_date,'submitted_at',s.submitted_at,'submitted_by',coalesce(p.full_name,s.supervisor_name_snapshot),'completion',100,'issue_count',case when s.checklist_type='daily_audit'then(select count(*)from public.daily_audit_item_results r where r.submission_id=s.id and r.answer='non_compliant')else(select count(*)from public.checklist_issues i where i.source_submission_id=s.id)end,'status',case when s.checklist_type='daily_audit'and exists(select 1 from public.daily_audit_item_results r where r.submission_id=s.id and r.answer='non_compliant')then'issues_found'when s.checklist_type<>'daily_audit'and exists(select 1 from public.checklist_issues i where i.source_submission_id=s.id)then'issues_found'else'compliant'end)dto
   from public.checklist_submissions s left join public.profiles p on p.id=coalesce(s.submitted_by_user_id,s.supervisor_user_id)
   where s.organization_id=c.organization_id and s.branch_id=c.branch_id and s.state='submitted'and s.checklist_type in('kitchen_opening','foh_opening','staff_hygiene','daily_audit')
   union all
   select s.id,s.business_date,greatest(coalesce(s.opening_submitted_at,'-infinity'::timestamptz),coalesce(s.closing_submitted_at,'-infinity'::timestamptz)),'oil_tracking',pg_catalog.jsonb_build_object('id',s.id,'branch_id',s.branch_id,'checklist_type','oil_tracking','business_date',s.business_date,'submitted_at',greatest(coalesce(s.opening_submitted_at,'-infinity'::timestamptz),coalesce(s.closing_submitted_at,'-infinity'::timestamptz)),'submitted_by',coalesce(p.full_name,s.supervisor_name_snapshot),'completion',case when s.opening_submitted_at is not null and s.closing_submitted_at is not null then 100 else 50 end,'issue_count',(select count(*)from public.oil_tracking_issues i where i.source_submission_id=s.id),'status',case when s.opening_submitted_at is null or s.closing_submitted_at is null then'in_progress'when exists(select 1 from public.oil_tracking_issues i where i.source_submission_id=s.id)then'issues_found'else'compliant'end)
   from public.oil_tracking_submissions s left join public.profiles p on p.id=coalesce(s.closing_submitted_by_user_id,s.opening_submitted_by_user_id,s.supervisor_user_id)where s.organization_id=c.organization_id and s.branch_id=c.branch_id and(s.opening_submitted_at is not null or s.closing_submitted_at is not null)
   union all
   select s.id,s.business_date,max(r.submitted_at),'cold_storage',pg_catalog.jsonb_build_object('id',s.id,'branch_id',s.branch_id,'checklist_type','cold_storage','business_date',s.business_date,'submitted_at',max(r.submitted_at),'submitted_by',coalesce(max(p.full_name),s.supervisor_name_snapshot),'completion',100,'issue_count',(select count(*)from public.cold_storage_issues i where i.submission_id=s.id),'status',case when exists(select 1 from public.cold_storage_issues i where i.submission_id=s.id)then'issues_found'else'compliant'end)
   from public.cold_storage_submissions s join public.cold_storage_readings r on r.submission_id=s.id and r.submitted_at is not null left join public.profiles p on p.id=r.submitted_by_user_id where s.organization_id=c.organization_id and s.branch_id=c.branch_id group by s.id
   union all
   select s.id,s.business_date,s.submitted_at,'sales_tracking',pg_catalog.jsonb_build_object('id',s.id,'branch_id',s.branch_id,'checklist_type','sales_tracking','business_date',s.business_date,'submitted_at',s.submitted_at,'submitted_by',coalesce(p.full_name,s.supervisor_name_snapshot),'completion',100,'issue_count',0,'status','compliant')from public.sales_tracking_reports s left join public.profiles p on p.id=coalesce(s.submitted_by_user_id,s.supervisor_user_id)where s.organization_id=c.organization_id and s.branch_id=c.branch_id and s.state='submitted'
  )q where target_checklist_type is null or q.checklist_type=target_checklist_type
 )x);
exception when no_data_found or too_many_rows then raise exception'report access denied'using errcode='42501';end$$;

create function public.get_phase2_branch_report_detail(actor_user_id uuid,target_report_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''as $$declare result jsonb;branch uuid;begin
 select x.branch_id into branch from(
  select id,branch_id from public.checklist_submissions union all select id,branch_id from public.oil_tracking_submissions union all select id,branch_id from public.cold_storage_submissions union all select id,branch_id from public.sales_tracking_reports)x where x.id=target_report_id;
 if branch is null or not private.actor_can_read_operational_branch(actor_user_id,branch)then raise exception'report access denied'using errcode='42501';end if;
 select pg_catalog.jsonb_build_object('id',s.id,'branch_id',s.branch_id,'branch_name',s.branch_name_snapshot,'business_date',s.business_date,'checklist_type',s.checklist_type,'definition_id',s.definition_id,'submitted_at',s.submitted_at,'submitted_by',coalesce(p.full_name,s.supervisor_name_snapshot),'completion',100,'issue_count',case when s.checklist_type='daily_audit'then(select count(*)from public.daily_audit_item_results r where r.submission_id=s.id and r.answer='non_compliant')else(select count(*)from public.checklist_issues i where i.source_submission_id=s.id)end,'status',case when(s.checklist_type='daily_audit'and exists(select 1 from public.daily_audit_item_results r where r.submission_id=s.id and r.answer='non_compliant'))or(s.checklist_type<>'daily_audit'and exists(select 1 from public.checklist_issues i where i.source_submission_id=s.id))then'issues_found'else'compliant'end,
  'items',case when s.checklist_type='daily_audit'then coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('item_id',r.item_id,'item_text',d.item_label_en,'answer',r.answer,'remark',r.remark)order by r.item_number)from public.daily_audit_item_results r join public.daily_audit_item_definitions d on d.item_id=r.item_id where r.submission_id=s.id),'[]'::jsonb)else coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('item_id',r.item_id,'item_text',r.item_text_snapshot,'answer',r.answer,'remark',r.remark)order by r.ordinal)from public.opening_item_results r where r.submission_id=s.id),'[]'::jsonb)end,
  'staff',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('staff_id',h.operational_staff_id,'display_name',h.display_name_snapshot,'operational_roles',h.operational_roles_snapshot,'uniform',h.uniform_result,'fingernails',h.fingernails_result,'hair',h.hair_result,'facial_hair',h.facial_hair_result,'remark',h.remark)order by h.display_name_snapshot)from public.hygiene_staff_snapshots h where h.submission_id=s.id),'[]'::jsonb))into result from public.checklist_submissions s left join public.profiles p on p.id=coalesce(s.submitted_by_user_id,s.supervisor_user_id)where s.id=target_report_id and s.state='submitted';
 if result is not null then return result;end if;
 select pg_catalog.jsonb_build_object('id',s.id,'branch_id',s.branch_id,'branch_name',s.branch_name_snapshot,'business_date',s.business_date,'checklist_type','oil_tracking','definition_id','oil_tracking_v1','submitted_at',greatest(coalesce(s.opening_submitted_at,'-infinity'::timestamptz),coalesce(s.closing_submitted_at,'-infinity'::timestamptz)),'submitted_by',coalesce(p.full_name,s.supervisor_name_snapshot),'completion',case when s.opening_submitted_at is not null and s.closing_submitted_at is not null then 100 else 50 end,'issue_count',(select count(*)from public.oil_tracking_issues i where i.source_submission_id=s.id),'status',case when exists(select 1 from public.oil_tracking_issues i where i.source_submission_id=s.id)then'issues_found'else'compliant'end,'items',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('item_id',r.fryer_id,'item_text',r.fryer_label_snapshot,'answer',r.opening_status,'remark',r.opening_note||case when r.closing_note=''then''else' / '||r.closing_note end)order by r.fryer_id)from public.oil_tracking_fryer_results r where r.submission_id=s.id),'[]'::jsonb))into result from public.oil_tracking_submissions s left join public.profiles p on p.id=coalesce(s.closing_submitted_by_user_id,s.opening_submitted_by_user_id,s.supervisor_user_id)where s.id=target_report_id and(s.opening_submitted_at is not null or s.closing_submitted_at is not null);if result is not null then return result;end if;
 select pg_catalog.jsonb_build_object('id',s.id,'branch_id',s.branch_id,'branch_name',s.branch_name_snapshot,'business_date',s.business_date,'checklist_type','cold_storage','definition_id','cold_storage_v1','submitted_at',max(r.submitted_at),'submitted_by',coalesce(max(p.full_name),s.supervisor_name_snapshot),'completion',100,'issue_count',(select count(*)from public.cold_storage_issues i where i.submission_id=s.id),'status',case when exists(select 1 from public.cold_storage_issues i where i.submission_id=s.id)then'issues_found'else'compliant'end,'items',pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('item_id',r.equipment_id||':'||r.slot,'item_text',e.equipment_name||' — '||r.slot,'answer',r.status,'remark',r.corrective_action)order by r.slot,r.equipment_id))into result from public.cold_storage_submissions s join public.cold_storage_readings r on r.submission_id=s.id and r.submitted_at is not null join public.cold_storage_equipment e on e.submission_id=s.id and e.equipment_id=r.equipment_id left join public.profiles p on p.id=r.submitted_by_user_id where s.id=target_report_id group by s.id;if result is not null then return result;end if;
 select pg_catalog.jsonb_build_object('id',s.id,'branch_id',s.branch_id,'branch_name',s.branch_name_snapshot,'business_date',s.business_date,'checklist_type','sales_tracking','definition_id','sales_tracking_v1','submitted_at',s.submitted_at,'submitted_by',coalesce(p.full_name,s.supervisor_name_snapshot),'completion',100,'issue_count',0,'status','compliant','items',coalesce((select pg_catalog.jsonb_agg(x.item order by x.entry_date,x.kind)from(select r.entry_date,'sales'kind,pg_catalog.jsonb_build_object('item_id','sales:'||r.id,'item_text','Sales — '||r.entry_date,'answer','recorded','remark',coalesce(r.remarks,''))item from public.sales_tracking_sales_rows r where r.report_id=s.id union all select r.entry_date,'cash',pg_catalog.jsonb_build_object('item_id','cash:'||r.id,'item_text','Cash — '||r.entry_date,'answer','recorded','remark',coalesce(r.remarks,''))from public.sales_tracking_cash_rows r where r.report_id=s.id)x),'[]'::jsonb))into result from public.sales_tracking_reports s left join public.profiles p on p.id=coalesce(s.submitted_by_user_id,s.supervisor_user_id)where s.id=target_report_id and s.state='submitted';if result is not null then return result;end if;
 raise exception'report access denied'using errcode='42501';end$$;

revoke all on function public.get_phase4a_supervisor_overview(uuid,uuid),public.list_phase2_branch_reports(uuid,uuid,int,int,text),public.get_phase2_branch_report_detail(uuid,uuid)from public,anon,authenticated;
grant execute on function public.get_phase4a_supervisor_overview(uuid,uuid),public.list_phase2_branch_reports(uuid,uuid,int,int,text),public.get_phase2_branch_report_detail(uuid,uuid)to service_role;
