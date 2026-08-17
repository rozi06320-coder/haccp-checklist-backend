-- Additive corrections for the already-applied Phase 4A foundation.
-- Current-state DTOs use JSONB only as a validated RPC transport shape; storage remains normalized.

create function private.phase4a_enforce_final_precedence()returns trigger language plpgsql security definer set search_path=''as $$begin
 if new.state='draft' and exists(select 1 from public.checklist_submissions s where s.supervisor_team_id=new.supervisor_team_id and s.business_date=new.business_date and s.checklist_type=new.checklist_type and s.state='submitted')then raise exception'final submission already exists'using errcode='23505';end if;
 if tg_op='INSERT'and new.state='submitted'then
  delete from public.opening_item_results r using public.checklist_submissions d where r.submission_id=d.id and d.supervisor_team_id=new.supervisor_team_id and d.business_date=new.business_date and d.checklist_type=new.checklist_type and d.state='draft';
  delete from public.hygiene_staff_snapshots h using public.checklist_submissions d where h.submission_id=d.id and d.supervisor_team_id=new.supervisor_team_id and d.business_date=new.business_date and d.checklist_type=new.checklist_type and d.state='draft';
  delete from public.checklist_submissions d where d.supervisor_team_id=new.supervisor_team_id and d.business_date=new.business_date and d.checklist_type=new.checklist_type and d.state='draft';
 end if;return new;end $$;
revoke all on function private.phase4a_enforce_final_precedence()from public,anon,authenticated;
create trigger phase4a_final_precedence before insert or update on public.checklist_submissions for each row execute function private.phase4a_enforce_final_precedence();

create function public.save_phase4a_hygiene_draft(actor_user_id uuid,target_branch_id uuid,staff_answers jsonb)
returns table(id uuid,business_date date,checklist_type text,state text,created_at timestamptz,updated_at timestamptz)
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare c record; report public.checklist_submissions%rowtype; entry jsonb; eligible_count int;
begin
 select * into strict c from private.phase4a_actor_context(actor_user_id,target_branch_id);
 if pg_catalog.jsonb_typeof(staff_answers)<>'array' or pg_catalog.jsonb_array_length(staff_answers)>500 then raise exception 'invalid hygiene draft' using errcode='22023'; end if;
 select count(*) into eligible_count from public.operational_staff_assignments a join public.operational_staff s on s.id=a.operational_staff_id
 left join public.operational_staff_duty_statuses d on d.assignment_id=a.id and d.duty_date=c.business_date
 where a.supervisor_team_id=c.team_id and a.active and s.employment_status='active' and coalesce(d.duty_status,'on_duty')='on_duty';
 if pg_catalog.jsonb_array_length(staff_answers)<>eligible_count or (select count(distinct value->>'staff_id') from pg_catalog.jsonb_array_elements(staff_answers))<>eligible_count then raise exception 'staff set changed' using errcode='22023'; end if;
 for entry in select value from pg_catalog.jsonb_array_elements(staff_answers) loop
  if (select count(*) from pg_catalog.jsonb_object_keys(entry))<>6
   or not(entry?'staff_id' and entry?'uniform' and entry?'fingernails' and entry?'hair' and entry?'facial_hair' and entry?'remark')
   or pg_catalog.jsonb_typeof(entry->'remark')<>'string' or length(entry->>'remark')>2000
   or entry->>'uniform' not in ('pending','pass','issue') or entry->>'fingernails' not in ('pending','pass','issue')
   or entry->>'hair' not in ('pending','pass','issue') or entry->>'facial_hair' not in ('pending','pass','issue')
   or not exists(select 1 from public.operational_staff_assignments a join public.operational_staff s on s.id=a.operational_staff_id
    left join public.operational_staff_duty_statuses d on d.assignment_id=a.id and d.duty_date=c.business_date
    where s.id=(entry->>'staff_id')::uuid and a.supervisor_team_id=c.team_id and a.active and s.employment_status='active' and coalesce(d.duty_status,'on_duty')='on_duty')
  then raise exception 'invalid hygiene draft' using errcode='22023'; end if;
 end loop;
 insert into public.checklist_submissions(organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,checklist_type,definition_id,state,branch_name_snapshot,branch_code_snapshot,supervisor_name_snapshot)
 values(c.organization_id,c.branch_id,actor_user_id,c.team_id,c.business_date,'staff_hygiene','staff_hygiene_v1','draft',c.branch_name,c.branch_code,c.supervisor_name)
 on conflict(supervisor_team_id,business_date,checklist_type) where state='draft' do update set updated_at=now() returning * into report;
 delete from public.hygiene_staff_snapshots where submission_id=report.id;
 insert into public.hygiene_staff_snapshots(submission_id,operational_staff_id,display_name_snapshot,operational_roles_snapshot,remark,uniform_result,fingernails_result,hair_result,facial_hair_result)
 select report.id,s.id,s.display_name,a.operational_roles,e.value->>'remark',e.value->>'uniform',e.value->>'fingernails',e.value->>'hair',e.value->>'facial_hair'
 from pg_catalog.jsonb_array_elements(staff_answers)e(value) join public.operational_staff s on s.id=(e.value->>'staff_id')::uuid
 join public.operational_staff_assignments a on a.operational_staff_id=s.id and a.supervisor_team_id=c.team_id and a.active;
 return query select report.id,report.business_date,report.checklist_type,report.state,report.created_at,report.updated_at;
exception when no_data_found or too_many_rows then raise exception 'draft denied' using errcode='42501'; end $$;

create function public.get_phase4a_current_state(actor_user_id uuid,target_branch_id uuid,target_checklist_type text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record; s public.checklist_submissions%rowtype;
begin
 select * into strict c from private.phase4a_actor_context(actor_user_id,target_branch_id);
 if target_checklist_type not in ('kitchen_opening','foh_opening','staff_hygiene') then raise exception 'invalid checklist type' using errcode='22023'; end if;
 select * into s from public.checklist_submissions x where x.supervisor_team_id=c.team_id and x.business_date=c.business_date and x.checklist_type=target_checklist_type
 order by case x.state when 'submitted' then 0 else 1 end,x.updated_at desc,x.id limit 1;
 if target_checklist_type='staff_hygiene' then
  if s.state='submitted' then return pg_catalog.jsonb_build_object('state',s.state,'business_date',c.business_date,'checklist_type',target_checklist_type,'id',s.id,'created_at',s.created_at,'updated_at',s.updated_at,'submitted_at',s.submitted_at,
   'staff',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('staff_id',h.operational_staff_id,'display_name',h.display_name_snapshot,'operational_roles',h.operational_roles_snapshot,'uniform',h.uniform_result,'fingernails',h.fingernails_result,'hair',h.hair_result,'facial_hair',h.facial_hair_result,'remark',h.remark)order by lower(h.display_name_snapshot),h.id)from public.hygiene_staff_snapshots h where h.submission_id=s.id),'[]'::jsonb));end if;
  return pg_catalog.jsonb_build_object('state',coalesce(s.state,'none'),'business_date',c.business_date,'checklist_type',target_checklist_type,
   'id',s.id,'created_at',s.created_at,'updated_at',s.updated_at,'submitted_at',s.submitted_at,
   'staff',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('staff_id',staff.id,'display_name',staff.display_name,'operational_roles',a.operational_roles,
    'uniform',coalesce(h.uniform_result,'pending'),'fingernails',coalesce(h.fingernails_result,'pending'),'hair',coalesce(h.hair_result,'pending'),'facial_hair',coalesce(h.facial_hair_result,'pending'),'remark',coalesce(h.remark,'')) order by lower(staff.display_name),staff.id)
    from public.operational_staff_assignments a join public.operational_staff staff on staff.id=a.operational_staff_id
    left join public.operational_staff_duty_statuses d on d.assignment_id=a.id and d.duty_date=c.business_date
    left join public.hygiene_staff_snapshots h on h.submission_id=s.id and h.operational_staff_id=staff.id
    where a.supervisor_team_id=c.team_id and a.active and staff.employment_status='active' and coalesce(d.duty_status,'on_duty')='on_duty'),'[]'::jsonb));
 end if;
 return pg_catalog.jsonb_build_object('state',coalesce(s.state,'none'),'business_date',c.business_date,'checklist_type',target_checklist_type,
  'id',s.id,'created_at',s.created_at,'updated_at',s.updated_at,'submitted_at',s.submitted_at,
  'answers',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('item_id',r.item_id,'answer',r.answer,'remark',r.remark) order by r.ordinal) from public.opening_item_results r where r.submission_id=s.id),'[]'::jsonb));
exception when no_data_found or too_many_rows then raise exception 'state denied' using errcode='42501'; end $$;

create or replace function public.list_phase4a_supervisor_reports(actor_user_id uuid,target_branch_id uuid,requested_page int default 1,requested_page_size int default 20,target_checklist_type text default null)
returns jsonb language plpgsql security definer set search_path='' as $$ declare c record; begin
 select * into strict c from private.phase4a_actor_context(actor_user_id,target_branch_id);
 if requested_page<1 or requested_page_size not between 1 and 50 or(target_checklist_type is not null and target_checklist_type not in('kitchen_opening','foh_opening','staff_hygiene'))then raise exception 'invalid list' using errcode='22023';end if;
 return pg_catalog.jsonb_build_object('reports',coalesce((select pg_catalog.jsonb_agg(q.dto order by q.business_date desc,q.submitted_at desc,q.id desc) from(
  select s.id,s.business_date,s.submitted_at,pg_catalog.jsonb_build_object('id',s.id,'branch_id',s.branch_id,'checklist_type',s.checklist_type,'definition_id',s.definition_id,'business_date',s.business_date,'submitted_at',s.submitted_at,'submitted_by',s.supervisor_name_snapshot,'completion',100,'issue_count',(select count(*) from public.checklist_issues i where i.source_submission_id=s.id),'status',case when exists(select 1 from public.checklist_issues i where i.source_submission_id=s.id)then'issues_found'else'compliant'end)dto
  from public.checklist_submissions s where s.supervisor_team_id=c.team_id and s.branch_id=c.branch_id and s.state='submitted'and(target_checklist_type is null or s.checklist_type=target_checklist_type)
  order by s.business_date desc,s.submitted_at desc,s.id desc limit requested_page_size offset((requested_page-1)*requested_page_size))q),'[]'::jsonb),
  'page',requested_page,'page_size',requested_page_size,'total',(select count(*) from public.checklist_submissions s where s.supervisor_team_id=c.team_id and s.branch_id=c.branch_id and s.state='submitted'and(target_checklist_type is null or s.checklist_type=target_checklist_type)));
exception when no_data_found or too_many_rows then raise exception 'report access denied' using errcode='42501';end $$;

create or replace function public.list_phase4a_managed_reports(actor_user_id uuid,target_organization_id uuid,requested_page int default 1,requested_page_size int default 20,date_from date default null,date_to date default null,branch_filter uuid default null,supervisor_filter uuid default null,type_filter text default null,status_filter text default null,search_term text default null)
returns jsonb language plpgsql security definer set search_path='' as $$ begin
 if not private.actor_manages_active_organization(actor_user_id,target_organization_id)or requested_page<1 or requested_page_size not between 1 and 50 or length(coalesce(search_term,''))>120 or(date_from is not null and date_to is not null and date_from>date_to)or(type_filter is not null and type_filter not in('kitchen_opening','foh_opening','staff_hygiene'))or(status_filter is not null and status_filter not in('compliant','issues_found'))then raise exception 'report access denied' using errcode='42501';end if;
 return pg_catalog.jsonb_build_object('reports',coalesce((select pg_catalog.jsonb_agg(q.dto order by q.business_date desc,q.submitted_at desc,q.id desc)from(
 select s.id,s.business_date,s.submitted_at,pg_catalog.jsonb_build_object('id',s.id,'branch_id',s.branch_id,'branch_name',s.branch_name_snapshot,'checklist_type',s.checklist_type,'definition_id',s.definition_id,'business_date',s.business_date,'submitted_at',s.submitted_at,'submitted_by',s.supervisor_name_snapshot,'supervisor_user_id',s.supervisor_user_id,'issue_count',(select count(*)from public.checklist_issues i where i.source_submission_id=s.id),'status',case when exists(select 1 from public.checklist_issues i where i.source_submission_id=s.id)then'issues_found'else'compliant'end)dto
 from public.checklist_submissions s where s.organization_id=target_organization_id and s.state='submitted'and(date_from is null or s.business_date>=date_from)and(date_to is null or s.business_date<=date_to)and(branch_filter is null or s.branch_id=branch_filter)and(supervisor_filter is null or s.supervisor_user_id=supervisor_filter)and(type_filter is null or s.checklist_type=type_filter)and(status_filter is null or(status_filter='issues_found')=exists(select 1 from public.checklist_issues i where i.source_submission_id=s.id))and(nullif(btrim(search_term),'')is null or s.branch_name_snapshot ilike'%'||btrim(search_term)||'%'or s.supervisor_name_snapshot ilike'%'||btrim(search_term)||'%')
 order by s.business_date desc,s.submitted_at desc,s.id desc limit requested_page_size offset((requested_page-1)*requested_page_size))q),'[]'::jsonb),'page',requested_page,'page_size',requested_page_size,
 'total',(select count(*)from public.checklist_submissions s where s.organization_id=target_organization_id and s.state='submitted'and(date_from is null or s.business_date>=date_from)and(date_to is null or s.business_date<=date_to)and(branch_filter is null or s.branch_id=branch_filter)and(supervisor_filter is null or s.supervisor_user_id=supervisor_filter)and(type_filter is null or s.checklist_type=type_filter)and(status_filter is null or(status_filter='issues_found')=exists(select 1 from public.checklist_issues i where i.source_submission_id=s.id))and(nullif(btrim(search_term),'')is null or s.branch_name_snapshot ilike'%'||btrim(search_term)||'%'or s.supervisor_name_snapshot ilike'%'||btrim(search_term)||'%')));
end $$;

drop function public.list_phase4a_managed_issues(uuid,uuid,int,int,uuid,text,text,text);
create function public.list_phase4a_managed_issues(actor_user_id uuid,target_organization_id uuid,requested_page int default 1,requested_page_size int default 20,date_from date default null,date_to date default null,branch_filter uuid default null,supervisor_filter uuid default null,staff_filter uuid default null,type_filter text default null,status_filter text default null,search_term text default null)
returns jsonb language plpgsql security definer set search_path='' as $$ begin
 if not private.actor_manages_active_organization(actor_user_id,target_organization_id)or requested_page<1 or requested_page_size not between 1 and 50 or length(coalesce(search_term,''))>120 or(date_from is not null and date_to is not null and date_from>date_to)or(status_filter is not null and status_filter<>'new')then raise exception 'issue access denied' using errcode='42501';end if;
 return pg_catalog.jsonb_build_object('issues',coalesce((select pg_catalog.jsonb_agg(q.dto order by q.created_at desc,q.id desc)from(
 select i.id,i.created_at,pg_catalog.jsonb_build_object('id',i.id,'report_id',i.source_submission_id,'branch_id',i.branch_id,'branch_name',s.branch_name_snapshot,'business_date',s.business_date,'submitted_by',s.supervisor_name_snapshot,'supervisor_user_id',s.supervisor_user_id,'checklist_type',i.checklist_type,'title',coalesce(i.item_text_snapshot,i.affected_staff_name_snapshot),'item_id',i.item_id,'item_text',i.item_text_snapshot,'affected_staff_id',i.affected_staff_id,'affected_staff_name',i.affected_staff_name_snapshot,'description',i.remark,'status',i.status,'created_at',i.created_at)dto
 from public.checklist_issues i join public.checklist_submissions s on s.id=i.source_submission_id where i.organization_id=target_organization_id and(date_from is null or s.business_date>=date_from)and(date_to is null or s.business_date<=date_to)and(branch_filter is null or i.branch_id=branch_filter)and(supervisor_filter is null or s.supervisor_user_id=supervisor_filter)and(staff_filter is null or i.affected_staff_id=staff_filter)and(type_filter is null or i.checklist_type=type_filter)and(status_filter is null or i.status=status_filter)and(nullif(btrim(search_term),'')is null or coalesce(i.item_text_snapshot,i.affected_staff_name_snapshot) ilike'%'||btrim(search_term)||'%'or i.remark ilike'%'||btrim(search_term)||'%')
 order by i.created_at desc,i.id desc limit requested_page_size offset((requested_page-1)*requested_page_size))q),'[]'::jsonb),'page',requested_page,'page_size',requested_page_size,
 'total',(select count(*)from public.checklist_issues i join public.checklist_submissions s on s.id=i.source_submission_id where i.organization_id=target_organization_id and(date_from is null or s.business_date>=date_from)and(date_to is null or s.business_date<=date_to)and(branch_filter is null or i.branch_id=branch_filter)and(supervisor_filter is null or s.supervisor_user_id=supervisor_filter)and(staff_filter is null or i.affected_staff_id=staff_filter)and(type_filter is null or i.checklist_type=type_filter)and(status_filter is null or i.status=status_filter)and(nullif(btrim(search_term),'')is null or coalesce(i.item_text_snapshot,i.affected_staff_name_snapshot) ilike'%'||btrim(search_term)||'%'or i.remark ilike'%'||btrim(search_term)||'%')));
end $$;

create or replace function public.get_phase4a_managed_issue(actor_user_id uuid,target_organization_id uuid,target_issue_id uuid)returns jsonb language plpgsql security definer set search_path=''as $$declare result jsonb;begin
 if not private.actor_manages_active_organization(actor_user_id,target_organization_id)then raise exception'issue access denied'using errcode='42501';end if;
 select pg_catalog.jsonb_build_object('id',i.id,'report_id',i.source_submission_id,'branch_id',i.branch_id,'branch_name',s.branch_name_snapshot,'business_date',s.business_date,'submitted_by',s.supervisor_name_snapshot,'checklist_type',i.checklist_type,'item_id',i.item_id,'item_text',i.item_text_snapshot,'affected_staff_id',i.affected_staff_id,'affected_staff_name',i.affected_staff_name_snapshot,'remark',i.remark,'status',i.status,'created_at',i.created_at)into strict result from public.checklist_issues i join public.checklist_submissions s on s.id=i.source_submission_id where i.id=target_issue_id and i.organization_id=target_organization_id;return result;
exception when no_data_found or too_many_rows then raise exception'issue access denied'using errcode='42501';end $$;

revoke all on function public.save_phase4a_hygiene_draft(uuid,uuid,jsonb),public.get_phase4a_current_state(uuid,uuid,text),public.list_phase4a_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.save_phase4a_hygiene_draft(uuid,uuid,jsonb),public.get_phase4a_current_state(uuid,uuid,text),public.list_phase4a_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text) to service_role;
