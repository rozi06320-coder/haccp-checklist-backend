-- Phase 2: one shared Oil Tracking ledger per branch and business date.
drop function if exists public.save_oil_tracking_draft(uuid,uuid,jsonb);
drop function if exists public.submit_oil_tracking_opening(uuid,uuid,uuid,text,jsonb);
drop function if exists public.submit_oil_tracking_closing(uuid,uuid,uuid,text,jsonb);
drop function if exists private.upsert_oil_tracking_submission(uuid,uuid,jsonb);

create or replace function public.get_oil_tracking_current_state(actor_user_id uuid,target_branch_id uuid)
returns jsonb language plpgsql security definer set search_path=''as $$declare c record;s public.oil_tracking_submissions%rowtype;begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 select*into s from public.oil_tracking_submissions x where x.organization_id=c.organization_id and x.branch_id=c.branch_id and x.business_date=c.business_date;
 return pg_catalog.jsonb_build_object('submission_id',s.id,'business_date',c.business_date,'revision',coalesce(s.branch_revision,0),'opening_submitted_at',s.opening_submitted_at,'closing_submitted_at',s.closing_submitted_at,'opening_submitted',s.opening_submitted_at is not null,'closing_submitted',s.closing_submitted_at is not null,
  'rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id',r.id,'fryer_id',r.fryer_id,'fryer_label_snapshot',r.fryer_label_snapshot,'fryer_short_label_snapshot',r.fryer_short_label_snapshot,'in_use_today',r.in_use_today,'oil_status',r.oil_status,'opening_temperature_c',r.opening_temperature_c,'opening_status',r.opening_status,'opening_note',r.opening_note,'closing_tpm_percent',r.closing_tpm_percent,'closing_note',r.closing_note)order by r.fryer_id)from public.oil_tracking_fryer_results r where r.submission_id=s.id),'[]'::jsonb));
exception when no_data_found or too_many_rows then raise exception'oil tracking state denied'using errcode='42501';end$$;

create function private.upsert_oil_tracking_submission(actor_user_id uuid,target_branch_id uuid,expected_revision bigint,rows jsonb)
returns public.oil_tracking_submissions language plpgsql security definer set search_path=''as $$
#variable_conflict use_column
declare c record;s public.oil_tracking_submissions%rowtype;
begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||c.business_date::text||':oil_tracking',0));
 select*into s from public.oil_tracking_submissions x where x.organization_id=c.organization_id and x.branch_id=c.branch_id and x.business_date=c.business_date for update;
 if(s.id is null and coalesce(expected_revision,0)<>0)or(s.id is not null and coalesce(expected_revision,-1)<>s.branch_revision)then raise exception'oil tracking changed'using errcode='40001';end if;
 if s.id is null then
  insert into public.oil_tracking_submissions(organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,state,branch_name_snapshot,supervisor_name_snapshot,team_name_snapshot,branch_revision,updated_by_user_id)
  values(c.organization_id,c.branch_id,actor_user_id,c.legacy_team_id,c.business_date,'draft',c.branch_name,c.actor_name,c.actor_name||' Team',1,actor_user_id)returning*into s;
 else
  update public.oil_tracking_submissions set updated_by_user_id=actor_user_id,branch_revision=branch_revision+1,updated_at=now()where id=s.id returning*into s;
 end if;
 if exists(select 1 from public.oil_tracking_fryer_results r where r.submission_id=s.id)then
  if s.opening_submitted_at is not null and s.closing_submitted_at is not null then
   if not private.oil_tracking_row_set_matches(s.id,rows)then raise exception'submitted oil tracking row set is immutable'using errcode='23505';end if;
  elsif s.opening_submitted_at is not null then perform private.merge_oil_tracking_rows(s.id,rows,'opening');
  elsif s.closing_submitted_at is not null then perform private.merge_oil_tracking_rows(s.id,rows,'closing');
  else perform private.replace_oil_tracking_rows(s.id,rows);end if;
 else perform private.replace_oil_tracking_rows(s.id,rows);end if;
 return s;
exception when no_data_found or too_many_rows then raise exception'oil tracking operation denied'using errcode='42501';end$$;

create function public.save_oil_tracking_draft(actor_user_id uuid,target_branch_id uuid,expected_revision bigint,rows jsonb)
returns jsonb language plpgsql security definer set search_path=''as $$begin perform private.validate_oil_tracking_rows(rows);perform private.upsert_oil_tracking_submission(actor_user_id,target_branch_id,expected_revision,rows);return public.get_oil_tracking_current_state(actor_user_id,target_branch_id);end$$;

create function public.submit_oil_tracking_opening(actor_user_id uuid,target_branch_id uuid,expected_revision bigint,idempotency_key uuid,request_hash text,rows jsonb)
returns jsonb language plpgsql security definer set search_path=''as $$declare s public.oil_tracking_submissions%rowtype;prior record;begin
 if length(request_hash)<>64 then raise exception'invalid oil tracking opening'using errcode='22023';end if;perform private.validate_oil_tracking_opening(rows);
 insert into public.oil_tracking_submission_idempotency(actor_user_id,section,idempotency_key,request_hash)values(actor_user_id,'opening',idempotency_key,request_hash)on conflict do nothing;
 select*into strict prior from public.oil_tracking_submission_idempotency x where x.actor_user_id=submit_oil_tracking_opening.actor_user_id and x.section='opening'and x.idempotency_key=submit_oil_tracking_opening.idempotency_key for update;
 if prior.request_hash<>request_hash then raise exception'idempotency conflict'using errcode='23505';end if;if prior.submission_id is not null then return private.oil_tracking_current_result(actor_user_id,target_branch_id,prior.submission_id);end if;
 s:=private.upsert_oil_tracking_submission(actor_user_id,target_branch_id,expected_revision,rows);select*into strict s from public.oil_tracking_submissions where id=s.id for update;
 if s.opening_submitted_at is not null then raise exception'opening already submitted'using errcode='23505';end if;
 update public.oil_tracking_submissions set opening_submitted_at=now(),opening_submitted_by_user_id=actor_user_id,updated_by_user_id=actor_user_id,branch_revision=branch_revision+1,state=case when closing_submitted_at is null then'draft'else'submitted'end where id=s.id returning*into s;
 insert into public.oil_tracking_issues(organization_id,branch_id,source_submission_id,fryer_result_id,section,fryer_id,fryer_label_snapshot,title,remark)
 select s.organization_id,s.branch_id,s.id,r.id,'opening',r.fryer_id,r.fryer_label_snapshot,'Opening oil check failed',r.opening_note from public.oil_tracking_fryer_results r where r.submission_id=s.id and r.in_use_today and r.opening_status='fail';
 update public.oil_tracking_submission_idempotency set submission_id=s.id where oil_tracking_submission_idempotency.actor_user_id=submit_oil_tracking_opening.actor_user_id and oil_tracking_submission_idempotency.section='opening'and oil_tracking_submission_idempotency.idempotency_key=submit_oil_tracking_opening.idempotency_key;
 return private.oil_tracking_current_result(actor_user_id,target_branch_id,s.id);
exception when no_data_found or too_many_rows then raise exception'oil tracking opening denied'using errcode='42501';end$$;

create function public.submit_oil_tracking_closing(actor_user_id uuid,target_branch_id uuid,expected_revision bigint,idempotency_key uuid,request_hash text,rows jsonb)
returns jsonb language plpgsql security definer set search_path=''as $$declare s public.oil_tracking_submissions%rowtype;prior record;begin
 if length(request_hash)<>64 then raise exception'invalid oil tracking closing'using errcode='22023';end if;perform private.validate_oil_tracking_closing(rows);
 insert into public.oil_tracking_submission_idempotency(actor_user_id,section,idempotency_key,request_hash)values(actor_user_id,'closing',idempotency_key,request_hash)on conflict do nothing;
 select*into strict prior from public.oil_tracking_submission_idempotency x where x.actor_user_id=submit_oil_tracking_closing.actor_user_id and x.section='closing'and x.idempotency_key=submit_oil_tracking_closing.idempotency_key for update;
 if prior.request_hash<>request_hash then raise exception'idempotency conflict'using errcode='23505';end if;if prior.submission_id is not null then return private.oil_tracking_current_result(actor_user_id,target_branch_id,prior.submission_id);end if;
 s:=private.upsert_oil_tracking_submission(actor_user_id,target_branch_id,expected_revision,rows);select*into strict s from public.oil_tracking_submissions where id=s.id for update;
 if s.closing_submitted_at is not null then raise exception'closing already submitted'using errcode='23505';end if;
 update public.oil_tracking_submissions set closing_submitted_at=now(),closing_submitted_by_user_id=actor_user_id,updated_by_user_id=actor_user_id,branch_revision=branch_revision+1,state=case when opening_submitted_at is null then'draft'else'submitted'end where id=s.id returning*into s;
 insert into public.oil_tracking_issues(organization_id,branch_id,source_submission_id,fryer_result_id,section,fryer_id,fryer_label_snapshot,title,remark,tpm_status)
 select s.organization_id,s.branch_id,s.id,r.id,'closing',r.fryer_id,r.fryer_label_snapshot,case private.oil_tracking_tpm_status(r.closing_tpm_percent)when'nearing_end'then'Closing TPM nearing oil end of life'when'filtering_required'then'Closing TPM filtering required'else'Closing TPM oil change or discard required'end,r.closing_note,private.oil_tracking_tpm_status(r.closing_tpm_percent) from public.oil_tracking_fryer_results r where r.submission_id=s.id and r.in_use_today and private.oil_tracking_tpm_status(r.closing_tpm_percent)<>'good';
 update public.oil_tracking_submission_idempotency set submission_id=s.id where oil_tracking_submission_idempotency.actor_user_id=submit_oil_tracking_closing.actor_user_id and oil_tracking_submission_idempotency.section='closing'and oil_tracking_submission_idempotency.idempotency_key=submit_oil_tracking_closing.idempotency_key;
 return private.oil_tracking_current_result(actor_user_id,target_branch_id,s.id);
exception when no_data_found or too_many_rows then raise exception'oil tracking closing denied'using errcode='42501';end$$;

revoke all on function private.upsert_oil_tracking_submission(uuid,uuid,bigint,jsonb),public.save_oil_tracking_draft(uuid,uuid,bigint,jsonb),public.submit_oil_tracking_opening(uuid,uuid,bigint,uuid,text,jsonb),public.submit_oil_tracking_closing(uuid,uuid,bigint,uuid,text,jsonb)from public,anon,authenticated;
grant execute on function public.save_oil_tracking_draft(uuid,uuid,bigint,jsonb),public.submit_oil_tracking_opening(uuid,uuid,bigint,uuid,text,jsonb),public.submit_oil_tracking_closing(uuid,uuid,bigint,uuid,text,jsonb)to service_role;
