-- Phase B3: Daily Audit submit persistence only. Repeated submits return a safe conflict.
create or replace function public.submit_supervisor_daily_audit(
  actor_user_id uuid,target_branch_id uuid,target_business_date date,auditor_kind text,auditor_id uuid,
  auditor_name_snapshot text,access_credential_version uuid,items jsonb,idempotency_key text default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare c record; s public.checklist_submissions%rowtype; entry jsonb; item text; answer text; remark text; seen text[] := '{}';
begin
  select * into strict c from private.phase4a_actor_context(actor_user_id,target_branch_id);
  if auditor_kind not in ('manual_access_user','organization_manager_pin') or auditor_id is null or length(btrim(auditor_name_snapshot)) not between 1 and 120 or access_credential_version is null or jsonb_typeof(items)<>'array' or jsonb_array_length(items)<>13 then raise exception 'invalid daily audit submission' using errcode='22023'; end if;
  for entry in select value from jsonb_array_elements(items) loop
    item=entry->>'item_id'; answer=entry->>'answer'; remark=btrim(coalesce(entry->>'remark',''));
    if item is null or item not in (select d.item_id from public.daily_audit_item_definitions d where d.active) then raise exception 'unknown daily audit item' using errcode='22023'; end if;
    if item=any(seen) then raise exception 'duplicate daily audit item' using errcode='22023'; end if; seen=array_append(seen,item);
    if answer not in ('compliant','non_compliant') then raise exception 'daily audit submission requires answered items' using errcode='22023'; end if;
    if answer='non_compliant' and length(remark)=0 then raise exception 'non-compliant daily audit items require remarks' using errcode='22023'; end if;
  end loop;
  if cardinality(seen)<>13 or exists(select 1 from public.daily_audit_item_definitions d where d.active and not(d.item_id=any(seen))) then raise exception 'daily audit submission requires all items' using errcode='22023'; end if;
  select * into s from public.checklist_submissions where organization_id=c.organization_id and branch_id=target_branch_id and supervisor_team_id=c.team_id and business_date=target_business_date and checklist_type='daily_audit' and state='submitted' limit 1;
  if s.id is not null then raise exception 'daily audit already submitted' using errcode='55000'; end if;
  select * into s from public.checklist_submissions where organization_id=c.organization_id and branch_id=target_branch_id and supervisor_team_id=c.team_id and business_date=target_business_date and checklist_type='daily_audit' and state='draft' for update;
  if s.id is null then
    insert into public.checklist_submissions(organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,checklist_type,definition_id,state,branch_name_snapshot,branch_code_snapshot,supervisor_name_snapshot,submitted_at,daily_audit_auditor_kind,daily_audit_auditor_id,daily_audit_auditor_name_snapshot,daily_audit_access_credential_version)
    values(c.organization_id,target_branch_id,actor_user_id,c.team_id,target_business_date,'daily_audit','daily_audit_v1','submitted',c.branch_name,c.branch_code,c.supervisor_name,now(),auditor_kind,auditor_id,btrim(auditor_name_snapshot),access_credential_version) returning * into s;
  else
    update public.checklist_submissions set state='submitted',submitted_at=now(),updated_at=now(),daily_audit_auditor_kind=auditor_kind,daily_audit_auditor_id=auditor_id,daily_audit_auditor_name_snapshot=btrim(auditor_name_snapshot),daily_audit_access_credential_version=access_credential_version where id=s.id returning * into s;
    delete from public.daily_audit_item_results where submission_id=s.id;
  end if;
  insert into public.daily_audit_item_results(submission_id,organization_id,branch_id,item_id,item_number,answer,remark)
  select s.id,c.organization_id,target_branch_id,d.item_id,d.item_number,x.answer,btrim(coalesce(x.remark,''))
  from public.daily_audit_item_definitions d join lateral (select value->>'answer' answer,value->>'remark' remark from jsonb_array_elements(items) where value->>'item_id'=d.item_id limit 1) x on true where d.active;
  return public.get_supervisor_daily_audit_current_state(actor_user_id,target_branch_id,target_business_date);
end; $$;
revoke all on function public.submit_supervisor_daily_audit(uuid,uuid,date,text,uuid,text,uuid,jsonb,text) from public,anon,authenticated;
grant execute on function public.submit_supervisor_daily_audit(uuid,uuid,date,text,uuid,text,uuid,jsonb,text) to service_role;
