-- Phase 2: one Kitchen/FOH Opening record per branch, business date, and checklist type.
drop function if exists public.save_phase4a_draft(uuid,uuid,text,jsonb);
drop function if exists public.submit_phase4a_opening(uuid,uuid,text,uuid,text,jsonb);

create function public.save_phase4a_draft(actor_user_id uuid,target_branch_id uuid,target_checklist_type text,expected_revision bigint,answers jsonb)
returns table(id uuid,business_date date,checklist_type text,state text,created_at timestamptz,updated_at timestamptz,revision bigint)
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare c record;def text;report public.checklist_submissions%rowtype;entry jsonb;result_id uuid;linked int;
begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);def:=target_checklist_type||'_v1';
 if target_checklist_type not in('kitchen_opening','foh_opening')then raise exception'unsupported draft'using errcode='22023';end if;
 perform private.phase4a_validate_opening(def,answers,false);
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||c.business_date::text||':'||target_checklist_type,0));
 select*into report from public.checklist_submissions s where s.organization_id=c.organization_id and s.branch_id=c.branch_id and s.business_date=c.business_date and s.checklist_type=target_checklist_type for update;
 if(report.id is null and coalesce(expected_revision,0)<>0)or(report.id is not null and coalesce(expected_revision,-1)<>report.branch_revision)then raise exception'opening draft changed'using errcode='40001';end if;
 if report.state='submitted'then raise exception'opening already submitted'using errcode='55000';end if;
 if report.id is null then
  insert into public.checklist_submissions(organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,checklist_type,definition_id,state,branch_name_snapshot,branch_code_snapshot,supervisor_name_snapshot,branch_revision,updated_by_user_id)
  values(c.organization_id,c.branch_id,actor_user_id,c.legacy_team_id,c.business_date,target_checklist_type,def,'draft',c.branch_name,c.branch_code,c.actor_name,1,actor_user_id)returning*into report;
 else
  update public.checklist_submissions set updated_at=now(),updated_by_user_id=actor_user_id,branch_revision=branch_revision+1 where checklist_submissions.id=report.id returning*into report;
 end if;
 update public.checklist_issue_evidence e set status='pending',draft_submission_id=null,draft_result_id=null,expires_at=now()+interval'1 hour',updated_at=now()where e.draft_submission_id=report.id and e.status='draft';
 delete from public.opening_item_results where submission_id=report.id;
 insert into public.opening_item_results(submission_id,definition_id,item_id,ordinal,item_text_snapshot,answer,remark)
 select report.id,def,i.item_id,i.ordinal,i.item_text,row->>'answer',case when row->>'answer'='issue_found'then btrim(row->>'remark')else row->>'remark'end
 from pg_catalog.jsonb_array_elements(answers)row join public.checklist_definition_items i on i.definition_id=def and i.item_id=row->>'item_id';
 for entry in select value from pg_catalog.jsonb_array_elements(answers)where value->>'answer'='issue_found'loop
  select r.id into strict result_id from public.opening_item_results r where r.submission_id=report.id and r.item_id=entry->>'item_id';
  update public.checklist_issue_evidence e set status='draft',draft_submission_id=report.id,draft_result_id=result_id,expires_at=null,updated_at=now()
  where e.id=(entry->>'evidence_id')::uuid and e.organization_id=c.organization_id and e.branch_id=c.branch_id and e.business_date=c.business_date
    and e.checklist_type=target_checklist_type and e.item_id=entry->>'item_id'and((e.status='pending'and e.expires_at>now())or(e.status='draft'and(e.draft_submission_id is null or e.draft_submission_id=report.id)));
  get diagnostics linked=row_count;if linked<>1 then raise exception'evidence link denied'using errcode='42501';end if;
 end loop;
 return query select report.id,report.business_date,report.checklist_type,report.state,report.created_at,report.updated_at,report.branch_revision;
exception when no_data_found or too_many_rows then raise exception'draft denied'using errcode='42501';end$$;

create function public.submit_phase4a_opening(actor_user_id uuid,target_branch_id uuid,target_checklist_type text,expected_revision bigint,idempotency_key uuid,request_hash text,answers jsonb)
returns table(id uuid,business_date date,checklist_type text,state text,submitted_at timestamptz,issue_count bigint,revision bigint)
language plpgsql security definer set search_path=''as $$
declare c record;def text;report public.checklist_submissions%rowtype;prior record;entry jsonb;result_id uuid;linked int;
begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);def:=target_checklist_type||'_v1';
 if target_checklist_type not in('kitchen_opening','foh_opening')or length(request_hash)<>64 then raise exception'invalid submission'using errcode='22023';end if;
 perform private.phase4a_validate_opening(def,answers,true);
 insert into public.checklist_submission_idempotency(actor_user_id,idempotency_key,request_hash)values(actor_user_id,idempotency_key,request_hash)on conflict do nothing;
 select*into strict prior from public.checklist_submission_idempotency x where x.actor_user_id=submit_phase4a_opening.actor_user_id and x.idempotency_key=submit_phase4a_opening.idempotency_key for update;
 if prior.request_hash<>request_hash then raise exception'idempotency conflict'using errcode='23505';end if;
 if prior.submission_id is not null then
  return query select s.id,s.business_date,s.checklist_type,s.state,s.submitted_at,(select count(*)from public.checklist_issues i where i.source_submission_id=s.id),s.branch_revision from public.checklist_submissions s where s.id=prior.submission_id and s.organization_id=c.organization_id and s.branch_id=c.branch_id;return;
 end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||c.business_date::text||':'||target_checklist_type,0));
 select*into report from public.checklist_submissions s where s.organization_id=c.organization_id and s.branch_id=c.branch_id and s.business_date=c.business_date and s.checklist_type=target_checklist_type for update;
 if(report.id is null and coalesce(expected_revision,0)<>0)or(report.id is not null and coalesce(expected_revision,-1)<>report.branch_revision)then raise exception'opening changed'using errcode='40001';end if;
 if report.state='submitted'then raise exception'opening already submitted'using errcode='55000';end if;
 if report.id is null then
  insert into public.checklist_submissions(organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,checklist_type,definition_id,state,branch_name_snapshot,branch_code_snapshot,supervisor_name_snapshot,submitted_at,branch_revision,updated_by_user_id,submitted_by_user_id)
  values(c.organization_id,c.branch_id,actor_user_id,c.legacy_team_id,c.business_date,target_checklist_type,def,'submitted',c.branch_name,c.branch_code,c.actor_name,now(),1,actor_user_id,actor_user_id)returning*into report;
 else
  update public.checklist_issue_evidence e set status='pending',draft_submission_id=null,draft_result_id=null,expires_at=now()+interval'1 hour',updated_at=now()where e.draft_submission_id=report.id and e.status='draft';
  delete from public.opening_item_results where submission_id=report.id;
  update public.checklist_submissions set state='submitted',submitted_at=now(),updated_at=now(),updated_by_user_id=actor_user_id,submitted_by_user_id=actor_user_id,branch_revision=branch_revision+1 where checklist_submissions.id=report.id returning*into report;
 end if;
 insert into public.opening_item_results(submission_id,definition_id,item_id,ordinal,item_text_snapshot,answer,remark)
 select report.id,def,i.item_id,i.ordinal,i.item_text,row->>'answer',case when row->>'answer'='issue_found'then btrim(row->>'remark')else row->>'remark'end
 from pg_catalog.jsonb_array_elements(answers)row join public.checklist_definition_items i on i.definition_id=def and i.item_id=row->>'item_id';
 for entry in select value from pg_catalog.jsonb_array_elements(answers)where value->>'answer'='issue_found'loop
  select r.id into strict result_id from public.opening_item_results r where r.submission_id=report.id and r.item_id=entry->>'item_id';
  update public.checklist_issue_evidence e set status='finalized',draft_submission_id=null,draft_result_id=null,final_submission_id=report.id,final_result_id=result_id,expires_at=null,finalized_at=now(),updated_at=now()
  where e.id=(entry->>'evidence_id')::uuid and e.organization_id=c.organization_id and e.branch_id=c.branch_id and e.business_date=c.business_date and e.checklist_type=target_checklist_type and e.item_id=entry->>'item_id'and((e.status='pending'and e.expires_at>now())or e.status='draft');
  get diagnostics linked=row_count;if linked<>1 then raise exception'evidence finalization denied'using errcode='42501';end if;
 end loop;
 insert into public.checklist_issues(organization_id,branch_id,source_submission_id,opening_result_id,status,checklist_type,item_id,item_text_snapshot,remark)
 select report.organization_id,report.branch_id,report.id,r.id,'new',report.checklist_type,r.item_id,r.item_text_snapshot,r.remark from public.opening_item_results r where r.submission_id=report.id and r.answer='issue_found';
 update public.checklist_submission_idempotency set submission_id=report.id where checklist_submission_idempotency.actor_user_id=submit_phase4a_opening.actor_user_id and checklist_submission_idempotency.idempotency_key=submit_phase4a_opening.idempotency_key;
 return query select report.id,report.business_date,report.checklist_type,report.state,report.submitted_at,(select count(*)from public.checklist_issues i where i.source_submission_id=report.id),report.branch_revision;
exception when no_data_found or too_many_rows then raise exception'submission denied'using errcode='42501';end$$;

create or replace function public.get_phase4a_current_state(actor_user_id uuid,target_branch_id uuid,target_checklist_type text)
returns jsonb language plpgsql security definer set search_path=''as $$declare c record;s public.checklist_submissions%rowtype;begin
 if target_checklist_type='staff_hygiene'then raise exception'use operational team hygiene state'using errcode='22023';end if;
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 if target_checklist_type not in('kitchen_opening','foh_opening')then raise exception'invalid checklist type'using errcode='22023';end if;
 select*into s from public.checklist_submissions x where x.organization_id=c.organization_id and x.branch_id=c.branch_id and x.business_date=c.business_date and x.checklist_type=target_checklist_type;
 return pg_catalog.jsonb_build_object('state',coalesce(s.state,'none'),'business_date',c.business_date,'checklist_type',target_checklist_type,'id',s.id,'created_at',s.created_at,'updated_at',s.updated_at,'submitted_at',s.submitted_at,'revision',coalesce(s.branch_revision,0),
  'answers',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('item_id',r.item_id,'answer',r.answer,'remark',r.remark,'evidence',(select pg_catalog.jsonb_build_object('id',e.id,'status',e.status,'mime_type',e.mime_type,'byte_size',e.byte_size,'available',true)from public.checklist_issue_evidence e where(e.draft_result_id=r.id and e.status='draft')or(e.final_result_id=r.id and e.status='finalized')limit 1))order by r.ordinal)from public.opening_item_results r where r.submission_id=s.id),'[]'::jsonb));
exception when no_data_found or too_many_rows then raise exception'state denied'using errcode='42501';end$$;

create or replace function public.authorize_phase4a_evidence_upload(actor_user_id uuid,target_branch_id uuid,target_checklist_type text,target_item_id text)
returns table(organization_id uuid,branch_id uuid,supervisor_user_id uuid,supervisor_team_id uuid,business_date date)
language plpgsql security definer set search_path=''as $$declare c record;def text;begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);def:=target_checklist_type||'_v1';
 if target_checklist_type not in('kitchen_opening','foh_opening')or not exists(select 1 from public.checklist_definition_items i where i.definition_id=def and i.item_id=target_item_id)then raise exception'evidence upload denied'using errcode='42501';end if;
 if exists(select 1 from public.checklist_submissions s where s.organization_id=c.organization_id and s.branch_id=c.branch_id and s.business_date=c.business_date and s.checklist_type=target_checklist_type and s.state='submitted')then raise exception'evidence final exists'using errcode='23505';end if;
 return query select c.organization_id,c.branch_id,actor_user_id,c.legacy_team_id,c.business_date;
exception when no_data_found or too_many_rows then raise exception'evidence upload denied'using errcode='42501';end$$;

create or replace function public.register_phase4a_evidence_upload(actor_user_id uuid,target_branch_id uuid,target_checklist_type text,target_item_id text,evidence_id uuid,object_path text,detected_mime_type text,actual_byte_size bigint,checksum_sha256 text)
returns table(id uuid,status text,mime_type text,byte_size bigint,retired_object_paths text[])
language plpgsql security definer set search_path=''as $$declare c record;def text;retired text[];begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);def:=target_checklist_type||'_v1';
 if target_checklist_type not in('kitchen_opening','foh_opening')or detected_mime_type not in('image/jpeg','image/png','image/webp')or actual_byte_size not between 1 and 5242880 or checksum_sha256!~'^[0-9a-f]{64}$'or length(object_path)not between 20 and 500 or object_path<>btrim(object_path)or not exists(select 1 from public.checklist_definition_items i where i.definition_id=def and i.item_id=target_item_id)then raise exception'invalid evidence metadata'using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||c.business_date::text||':'||target_checklist_type||':'||target_item_id,0));
 if exists(select 1 from public.checklist_submissions s where s.organization_id=c.organization_id and s.branch_id=c.branch_id and s.business_date=c.business_date and s.checklist_type=target_checklist_type and s.state='submitted')then raise exception'evidence final exists'using errcode='23505';end if;
 with retired_rows as(update public.checklist_issue_evidence e set status='deleted',draft_submission_id=null,draft_result_id=null,expires_at=null,updated_at=now()where e.organization_id=c.organization_id and e.branch_id=c.branch_id and e.business_date=c.business_date and e.checklist_type=target_checklist_type and e.item_id=target_item_id and e.status in('pending','draft')returning e.storage_object_path)
 select coalesce(pg_catalog.array_agg(storage_object_path),'{}'::text[])into retired from retired_rows;
 insert into public.checklist_issue_evidence(id,organization_id,branch_id,supervisor_user_id,supervisor_team_id,checklist_type,item_id,business_date,storage_object_path,mime_type,byte_size,sha256_checksum,status,expires_at)
 values(evidence_id,c.organization_id,c.branch_id,actor_user_id,c.legacy_team_id,target_checklist_type,target_item_id,c.business_date,object_path,detected_mime_type,actual_byte_size,checksum_sha256,'pending',now()+interval'1 hour');
 return query select evidence_id,'pending'::text,detected_mime_type,actual_byte_size,retired;
exception when no_data_found or too_many_rows then raise exception'evidence upload denied'using errcode='42501';end$$;

create or replace function public.authorize_phase4a_evidence_set(actor_user_id uuid,target_branch_id uuid,target_checklist_type text,evidence_ids uuid[])
returns table(id uuid,item_id text,storage_object_path text,mime_type text,byte_size bigint,sha256_checksum text,status text)
language plpgsql security definer set search_path=''as $$declare c record;requested int;matched int;begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);requested:=coalesce(pg_catalog.cardinality(evidence_ids),0);
 if target_checklist_type not in('kitchen_opening','foh_opening')or requested>18 or requested<>(select count(distinct value)from pg_catalog.unnest(coalesce(evidence_ids,'{}'::uuid[]))value)then raise exception'invalid evidence set'using errcode='22023';end if;
 select count(*)into matched from public.checklist_issue_evidence e where e.id=any(coalesce(evidence_ids,'{}'::uuid[]))and e.organization_id=c.organization_id and e.branch_id=c.branch_id and e.business_date=c.business_date and e.checklist_type=target_checklist_type and((e.status='pending'and e.expires_at>now())or e.status in('draft','finalized'));
 if matched<>requested then raise exception'evidence set denied'using errcode='42501';end if;
 return query select e.id,e.item_id,e.storage_object_path,e.mime_type,e.byte_size,e.sha256_checksum,e.status from public.checklist_issue_evidence e where e.id=any(coalesce(evidence_ids,'{}'::uuid[]));
exception when no_data_found or too_many_rows then raise exception'evidence set denied'using errcode='42501';end$$;

create or replace function public.authorize_phase4a_evidence_read(actor_user_id uuid,target_evidence_id uuid)
returns table(id uuid,storage_object_path text,mime_type text,byte_size bigint,sha256_checksum text,status text)
language plpgsql security definer set search_path=''as $$declare e public.checklist_issue_evidence%rowtype;begin
 select*into strict e from public.checklist_issue_evidence where checklist_issue_evidence.id=target_evidence_id and checklist_issue_evidence.status in('pending','draft','finalized');
 if not private.actor_can_read_operational_branch(actor_user_id,e.branch_id)and not private.actor_manages_active_organization(actor_user_id,e.organization_id)then raise exception'evidence read denied'using errcode='42501';end if;
 return query select e.id,e.storage_object_path,e.mime_type,e.byte_size,e.sha256_checksum,e.status;
exception when no_data_found or too_many_rows then raise exception'evidence read denied'using errcode='42501';end$$;

revoke all on function public.save_phase4a_draft(uuid,uuid,text,bigint,jsonb),public.submit_phase4a_opening(uuid,uuid,text,bigint,uuid,text,jsonb)from public,anon,authenticated;
grant execute on function public.save_phase4a_draft(uuid,uuid,text,bigint,jsonb),public.submit_phase4a_opening(uuid,uuid,text,bigint,uuid,text,jsonb)to service_role;
