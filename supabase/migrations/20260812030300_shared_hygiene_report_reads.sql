-- Phase 1 compatibility: submitted Daily Hygiene is branch-readable while
-- opening checklists retain their existing legacy supervisor-team ownership.

create or replace function public.list_phase4a_supervisor_reports(
  actor_user_id uuid,
  target_branch_id uuid,
  requested_page int default 1,
  requested_page_size int default 20,
  target_checklist_type text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c record;
begin
  select * into strict c from private.phase4a_actor_context(actor_user_id,target_branch_id);
  if requested_page<1 or requested_page_size not between 1 and 50
    or (target_checklist_type is not null and target_checklist_type not in('kitchen_opening','foh_opening','staff_hygiene'))
  then
    raise exception 'invalid list' using errcode='22023';
  end if;

  return pg_catalog.jsonb_build_object(
    'reports',coalesce((
      select pg_catalog.jsonb_agg(q.dto order by q.business_date desc,q.submitted_at desc,q.id desc)
      from (
        select s.id,s.business_date,s.submitted_at,
          pg_catalog.jsonb_build_object(
            'id',s.id,'branch_id',s.branch_id,'checklist_type',s.checklist_type,
            'definition_id',s.definition_id,'business_date',s.business_date,
            'submitted_at',s.submitted_at,'submitted_by',s.supervisor_name_snapshot,
            'completion',100,
            'issue_count',(select count(*) from public.checklist_issues i where i.source_submission_id=s.id),
            'status',case when exists(select 1 from public.checklist_issues i where i.source_submission_id=s.id)
              then 'issues_found' else 'compliant' end
          ) dto
        from public.checklist_submissions s
        where s.organization_id=c.organization_id and s.branch_id=c.branch_id and s.state='submitted'
          and (s.checklist_type='staff_hygiene' or s.supervisor_team_id=c.team_id)
          and (target_checklist_type is null or s.checklist_type=target_checklist_type)
        order by s.business_date desc,s.submitted_at desc,s.id desc
        limit requested_page_size offset((requested_page-1)*requested_page_size)
      ) q
    ),'[]'::jsonb),
    'page',requested_page,
    'page_size',requested_page_size,
    'total',(
      select count(*) from public.checklist_submissions s
      where s.organization_id=c.organization_id and s.branch_id=c.branch_id and s.state='submitted'
        and (s.checklist_type='staff_hygiene' or s.supervisor_team_id=c.team_id)
        and (target_checklist_type is null or s.checklist_type=target_checklist_type)
    )
  );
exception when no_data_found or too_many_rows then
  raise exception 'report access denied' using errcode='42501';
end
$$;

create or replace function public.get_phase4a_report_detail(
  actor_user_id uuid,
  target_report_id uuid,
  manager_mode boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  s public.checklist_submissions%rowtype;
begin
  select * into strict s from public.checklist_submissions x
  where x.id=target_report_id and x.state='submitted';

  if (manager_mode and not private.actor_manages_active_organization(actor_user_id,s.organization_id))
    or (not manager_mode and not (
      (s.checklist_type='staff_hygiene' and private.actor_can_read_operational_branch(actor_user_id,s.branch_id))
      or (s.checklist_type<>'staff_hygiene' and s.supervisor_user_id=actor_user_id and exists(
        select 1 from public.profiles p where p.id=actor_user_id
          and p.disabled_at is null and not p.must_change_password
      ))
    ))
  then
    raise exception 'report access denied' using errcode='42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'id',s.id,'organization_id',s.organization_id,'branch_id',s.branch_id,
    'branch_name',s.branch_name_snapshot,'branch_code',s.branch_code_snapshot,
    'supervisor_team_id',s.supervisor_team_id,'operational_team_id',s.operational_team_id,
    'operational_team_name',s.operational_team_name_snapshot,
    'business_date',s.business_date,'checklist_type',s.checklist_type,
    'definition_id',s.definition_id,'submitted_at',s.submitted_at,
    'submitted_by',s.supervisor_name_snapshot,'completion',100,
    'status',case when exists(select 1 from public.checklist_issues i where i.source_submission_id=s.id)
      then 'issues_found' else 'compliant' end,
    'issue_count',(select count(*) from public.checklist_issues i where i.source_submission_id=s.id),
    'items',coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'item_id',r.item_id,'item_text',r.item_text_snapshot,'answer',r.answer,'remark',r.remark,
        'evidence',(select pg_catalog.jsonb_build_object(
          'id',e.id,'status',e.status,'mime_type',e.mime_type,'byte_size',e.byte_size,'available',true
        ) from public.checklist_issue_evidence e
        where e.final_result_id=r.id and e.status='finalized' limit 1)
      ) order by r.ordinal)
      from public.opening_item_results r where r.submission_id=s.id
    ),'[]'::jsonb),
    'staff',coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'staff_id',h.operational_staff_id,'display_name',h.display_name_snapshot,
        'operational_roles',h.operational_roles_snapshot,'uniform',h.uniform_result,
        'fingernails',h.fingernails_result,'hair',h.hair_result,
        'facial_hair',h.facial_hair_result,'remark',h.remark
      ) order by h.display_name_snapshot,h.id)
      from public.hygiene_staff_snapshots h where h.submission_id=s.id
    ),'[]'::jsonb)
  );
exception when no_data_found or too_many_rows then
  raise exception 'report access denied' using errcode='42501';
end
$$;

revoke all on function public.list_phase4a_supervisor_reports(uuid,uuid,int,int,text),
  public.get_phase4a_report_detail(uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function public.list_phase4a_supervisor_reports(uuid,uuid,int,int,text),
  public.get_phase4a_report_detail(uuid,uuid,boolean) to service_role;
