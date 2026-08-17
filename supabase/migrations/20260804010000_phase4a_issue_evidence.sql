-- Private issue-evidence storage and normalized lifecycle for Phase 4A opening checklists.
-- Storage bytes stay outside PostgreSQL. Only the backend service role may call these RPCs.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('checklist-issue-evidence','checklist-issue-evidence',false,5242880,array['image/jpeg','image/png','image/webp'])
on conflict(id)do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

alter table public.branch_supervisor_teams add constraint branch_supervisor_teams_evidence_scope_key unique(id,branch_id,organization_id,supervisor_user_id);
alter table public.checklist_submissions add constraint checklist_submissions_evidence_scope_key unique(id,organization_id,branch_id,supervisor_team_id,supervisor_user_id);
alter table public.opening_item_results add constraint opening_item_results_evidence_scope_key unique(id,submission_id);

create table public.checklist_issue_evidence(
 id uuid primary key,organization_id uuid not null references public.organizations(id)on delete restrict,branch_id uuid not null,
 supervisor_user_id uuid not null references auth.users(id)on delete restrict,supervisor_team_id uuid not null,
 checklist_type text not null check(checklist_type in('kitchen_opening','foh_opening')),
 definition_id text generated always as(checklist_type||'_v1')stored,item_id text not null,business_date date not null,
 storage_object_path text not null unique check(length(storage_object_path)between 20 and 500 and storage_object_path=btrim(storage_object_path)),
 mime_type text not null check(mime_type in('image/jpeg','image/png','image/webp')),byte_size bigint not null check(byte_size between 1 and 5242880),
 sha256_checksum text not null check(sha256_checksum~'^[0-9a-f]{64}$'),status text not null check(status in('pending','draft','finalized','deleted')),
 draft_submission_id uuid,draft_result_id uuid,final_submission_id uuid,final_result_id uuid,
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),finalized_at timestamptz,expires_at timestamptz,
 constraint checklist_issue_evidence_item_fkey foreign key(definition_id,item_id)references public.checklist_definition_items(definition_id,item_id)on delete restrict,
 constraint checklist_issue_evidence_team_scope_fkey foreign key(supervisor_team_id,branch_id,organization_id,supervisor_user_id)references public.branch_supervisor_teams(id,branch_id,organization_id,supervisor_user_id)on delete restrict,
 constraint checklist_issue_evidence_draft_submission_fkey foreign key(draft_submission_id,organization_id,branch_id,supervisor_team_id,supervisor_user_id)references public.checklist_submissions(id,organization_id,branch_id,supervisor_team_id,supervisor_user_id)on delete restrict,
 constraint checklist_issue_evidence_final_submission_fkey foreign key(final_submission_id,organization_id,branch_id,supervisor_team_id,supervisor_user_id)references public.checklist_submissions(id,organization_id,branch_id,supervisor_team_id,supervisor_user_id)on delete restrict,
 constraint checklist_issue_evidence_draft_result_fkey foreign key(draft_result_id,draft_submission_id)references public.opening_item_results(id,submission_id)on delete restrict,
 constraint checklist_issue_evidence_final_result_fkey foreign key(final_result_id,final_submission_id)references public.opening_item_results(id,submission_id)on delete restrict,
 constraint checklist_issue_evidence_lifecycle_check check(
  (status='pending'and draft_submission_id is null and draft_result_id is null and final_submission_id is null and final_result_id is null and expires_at is not null and finalized_at is null)
  or(status='draft'and draft_submission_id is not null and draft_result_id is not null and final_submission_id is null and final_result_id is null and expires_at is null and finalized_at is null)
  or(status='finalized'and draft_submission_id is null and draft_result_id is null and final_submission_id is not null and final_result_id is not null and expires_at is null and finalized_at is not null)
  or(status='deleted'and draft_submission_id is null and draft_result_id is null and final_submission_id is null and final_result_id is null and expires_at is null and finalized_at is null))
);
create unique index checklist_issue_evidence_active_item_key on public.checklist_issue_evidence(supervisor_team_id,business_date,checklist_type,item_id)where status in('pending','draft','finalized');
create unique index checklist_issue_evidence_draft_result_key on public.checklist_issue_evidence(draft_result_id)where status='draft';
create unique index checklist_issue_evidence_final_result_key on public.checklist_issue_evidence(final_result_id)where status='finalized';
create index checklist_issue_evidence_org_report_idx on public.checklist_issue_evidence(organization_id,final_submission_id)where status='finalized';
create index checklist_issue_evidence_team_date_idx on public.checklist_issue_evidence(supervisor_team_id,business_date,checklist_type);
create index checklist_issue_evidence_pending_expiry_idx on public.checklist_issue_evidence(expires_at)where status='pending';

create function private.reject_finalized_evidence_mutation()returns trigger language plpgsql set search_path=''as $$begin raise exception'finalized evidence is immutable'using errcode='55000';end$$;
revoke all on function private.reject_finalized_evidence_mutation()from public,anon,authenticated;
create trigger immutable_finalized_evidence before update or delete on public.checklist_issue_evidence for each row when(old.status='finalized')execute function private.reject_finalized_evidence_mutation();
alter table public.checklist_issue_evidence enable row level security;
revoke all on public.checklist_issue_evidence from public,anon,authenticated;

create function public.authorize_phase4a_evidence_upload(actor_user_id uuid,target_branch_id uuid,target_checklist_type text,target_item_id text)
returns table(organization_id uuid,branch_id uuid,supervisor_user_id uuid,supervisor_team_id uuid,business_date date)
language plpgsql security definer set search_path=''as $$declare c record;def text;begin
 select*into strict c from private.phase4a_actor_context(actor_user_id,target_branch_id);def:=target_checklist_type||'_v1';
 if target_checklist_type not in('kitchen_opening','foh_opening')or not exists(select 1 from public.checklist_definitions d join public.checklist_definition_items i on i.definition_id=d.id where d.id=def and d.active and i.item_id=target_item_id)then raise exception'evidence upload denied'using errcode='42501';end if;
 if exists(select 1 from public.checklist_submissions s where s.supervisor_team_id=c.team_id and s.business_date=c.business_date and s.checklist_type=target_checklist_type and s.state='submitted')then raise exception'evidence final exists'using errcode='23505';end if;
 return query select c.organization_id,c.branch_id,actor_user_id,c.team_id,c.business_date;
exception when no_data_found or too_many_rows then raise exception'evidence upload denied'using errcode='42501';end$$;

create function public.register_phase4a_evidence_upload(actor_user_id uuid,target_branch_id uuid,target_checklist_type text,target_item_id text,evidence_id uuid,object_path text,detected_mime_type text,actual_byte_size bigint,checksum_sha256 text)
returns table(id uuid,status text,mime_type text,byte_size bigint,retired_object_paths text[])
language plpgsql security definer set search_path=''as $$declare c record;def text;retired text[];begin
 select*into strict c from private.phase4a_actor_context(actor_user_id,target_branch_id);def:=target_checklist_type||'_v1';
 if target_checklist_type not in('kitchen_opening','foh_opening')or detected_mime_type not in('image/jpeg','image/png','image/webp')or actual_byte_size not between 1 and 5242880 or checksum_sha256!~'^[0-9a-f]{64}$'or length(object_path)not between 20 and 500 or object_path<>btrim(object_path)or not exists(select 1 from public.checklist_definitions d join public.checklist_definition_items i on i.definition_id=d.id where d.id=def and d.active and i.item_id=target_item_id)then raise exception'invalid evidence metadata'using errcode='22023';end if;
 if exists(select 1 from public.checklist_submissions s where s.supervisor_team_id=c.team_id and s.business_date=c.business_date and s.checklist_type=target_checklist_type and s.state='submitted')then raise exception'evidence final exists'using errcode='23505';end if;
 with retired_rows as(update public.checklist_issue_evidence e set status='deleted',draft_submission_id=null,draft_result_id=null,expires_at=null,updated_at=now()where e.supervisor_team_id=c.team_id and e.business_date=c.business_date and e.checklist_type=target_checklist_type and e.item_id=target_item_id and e.status in('pending','draft')returning e.storage_object_path)
 select coalesce(pg_catalog.array_agg(storage_object_path),'{}'::text[])into retired from retired_rows;
 insert into public.checklist_issue_evidence(id,organization_id,branch_id,supervisor_user_id,supervisor_team_id,checklist_type,item_id,business_date,storage_object_path,mime_type,byte_size,sha256_checksum,status,expires_at)
 values(evidence_id,c.organization_id,c.branch_id,actor_user_id,c.team_id,target_checklist_type,target_item_id,c.business_date,object_path,detected_mime_type,actual_byte_size,checksum_sha256,'pending',now()+interval'1 hour');
 return query select evidence_id,'pending'::text,detected_mime_type,actual_byte_size,retired;
exception when no_data_found or too_many_rows then raise exception'evidence upload denied'using errcode='42501';end$$;

create function public.retire_phase4a_evidence(actor_user_id uuid,target_evidence_id uuid)
returns table(id uuid,storage_object_path text)language plpgsql security definer set search_path=''as $$declare e public.checklist_issue_evidence%rowtype;c record;begin
 select*into strict e from public.checklist_issue_evidence where checklist_issue_evidence.id=target_evidence_id for update;
 if e.status not in('pending','draft')then raise exception'evidence delete denied'using errcode='42501';end if;
 select*into strict c from private.phase4a_actor_context(actor_user_id,e.branch_id);
 if e.supervisor_user_id<>actor_user_id or e.supervisor_team_id<>c.team_id or e.organization_id<>c.organization_id or e.business_date<>c.business_date then raise exception'evidence delete denied'using errcode='42501';end if;
 update public.checklist_issue_evidence set status='deleted',draft_submission_id=null,draft_result_id=null,expires_at=null,updated_at=now()where checklist_issue_evidence.id=e.id;
 return query select e.id,e.storage_object_path;
exception when no_data_found or too_many_rows then raise exception'evidence delete denied'using errcode='42501';end$$;

create function public.authorize_phase4a_evidence_set(actor_user_id uuid,target_branch_id uuid,target_checklist_type text,evidence_ids uuid[])
returns table(id uuid,item_id text,storage_object_path text,mime_type text,byte_size bigint,sha256_checksum text,status text)
language plpgsql security definer set search_path=''as $$declare c record;requested int;matched int;begin
 select*into strict c from private.phase4a_actor_context(actor_user_id,target_branch_id);requested:=coalesce(pg_catalog.cardinality(evidence_ids),0);
 if target_checklist_type not in('kitchen_opening','foh_opening')or requested>18 or requested<>(select count(distinct value)from pg_catalog.unnest(coalesce(evidence_ids,'{}'::uuid[]))value)then raise exception'invalid evidence set'using errcode='22023';end if;
 select count(*)into matched from public.checklist_issue_evidence e where e.id=any(coalesce(evidence_ids,'{}'::uuid[]))and e.organization_id=c.organization_id and e.branch_id=c.branch_id and e.supervisor_user_id=actor_user_id and e.supervisor_team_id=c.team_id and e.business_date=c.business_date and e.checklist_type=target_checklist_type and((e.status='pending'and e.expires_at>now())or e.status='draft'or(e.status='finalized'and exists(select 1 from public.checklist_submissions s where s.id=e.final_submission_id and s.supervisor_user_id=actor_user_id)));
 if matched<>requested then raise exception'evidence set denied'using errcode='42501';end if;
 return query select e.id,e.item_id,e.storage_object_path,e.mime_type,e.byte_size,e.sha256_checksum,e.status from public.checklist_issue_evidence e where e.id=any(coalesce(evidence_ids,'{}'::uuid[]));
exception when no_data_found or too_many_rows then raise exception'evidence set denied'using errcode='42501';end$$;

create function public.authorize_phase4a_evidence_read(actor_user_id uuid,target_evidence_id uuid)
returns table(id uuid,storage_object_path text,mime_type text,byte_size bigint,sha256_checksum text,status text)
language plpgsql security definer set search_path=''as $$declare e public.checklist_issue_evidence%rowtype;allowed boolean:=false;begin
 select*into strict e from public.checklist_issue_evidence where checklist_issue_evidence.id=target_evidence_id and checklist_issue_evidence.status in('pending','draft','finalized');
 if e.status in('pending','draft')then allowed:=e.supervisor_user_id=actor_user_id and exists(select 1 from private.phase4a_actor_context(actor_user_id,e.branch_id)c where c.team_id=e.supervisor_team_id and c.business_date=e.business_date);
 else allowed:=(e.supervisor_user_id=actor_user_id and exists(select 1 from public.profiles p join public.branch_memberships m on m.user_id=p.id where p.id=actor_user_id and p.disabled_at is null and not p.must_change_password and m.branch_id=e.branch_id and m.role='branch_manager'and m.active))or private.actor_manages_active_organization(actor_user_id,e.organization_id);end if;
 if not allowed then raise exception'evidence read denied'using errcode='42501';end if;
 return query select e.id,e.storage_object_path,e.mime_type,e.byte_size,e.sha256_checksum,e.status;
exception when no_data_found or too_many_rows then raise exception'evidence read denied'using errcode='42501';end$$;

create function public.retire_expired_phase4a_evidence(max_rows int default 25)
returns table(id uuid,storage_object_path text)language plpgsql security definer set search_path=''as $$begin
 if max_rows not between 1 and 100 then raise exception'invalid cleanup'using errcode='22023';end if;
 return query with targets as(select e.id from public.checklist_issue_evidence e where e.status='pending'and e.expires_at<=now()order by e.expires_at,e.id limit max_rows for update skip locked)
 update public.checklist_issue_evidence e set status='deleted',expires_at=null,updated_at=now()from targets where e.id=targets.id returning e.id,e.storage_object_path;
end$$;

create or replace function private.phase4a_validate_opening(definition text,answers jsonb,final boolean)
returns void language plpgsql security definer set search_path=''as $$
declare supplied int;unique_items int;row jsonb;issue_count int;evidence_count int;
begin
 if pg_catalog.jsonb_typeof(answers)<>'array'then raise exception'invalid answers'using errcode='22023';end if;
 select count(*),count(distinct value->>'item_id'),count(*)filter(where value->>'answer'='issue_found'),count(distinct value->>'evidence_id')filter(where value->>'answer'='issue_found')
 into supplied,unique_items,issue_count,evidence_count from pg_catalog.jsonb_array_elements(answers);
 if supplied<>(select count(*)from public.checklist_definition_items where definition_id=definition)or supplied<>unique_items or issue_count<>evidence_count then raise exception'invalid definition items'using errcode='22023';end if;
 for row in select value from pg_catalog.jsonb_array_elements(answers)loop
  if(select count(*)from pg_catalog.jsonb_object_keys(row))<>4 or not(row?'item_id'and row?'answer'and row?'remark'and row?'evidence_id')
   or pg_catalog.jsonb_typeof(row->'item_id')<>'string'or pg_catalog.jsonb_typeof(row->'answer')<>'string'or pg_catalog.jsonb_typeof(row->'remark')<>'string'
   or length(row->>'remark')>2000 or not exists(select 1 from public.checklist_definition_items i where i.definition_id=definition and i.item_id=row->>'item_id')
   or row->>'answer'not in('not_checked','completed','issue_found')or(final and row->>'answer'='not_checked')
   or(row->>'answer'='issue_found'and(length(btrim(row->>'remark'))=0 or pg_catalog.jsonb_typeof(row->'evidence_id')<>'string'or row->>'evidence_id'!~'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'))
   or(row->>'answer'<>'issue_found'and pg_catalog.jsonb_typeof(row->'evidence_id')<>'null')
  then raise exception'invalid answer'using errcode='22023';end if;
 end loop;
end$$;

create or replace function public.save_phase4a_draft(actor_user_id uuid,target_branch_id uuid,target_checklist_type text,answers jsonb)
returns table(id uuid,business_date date,checklist_type text,state text,created_at timestamptz,updated_at timestamptz)
language plpgsql security definer set search_path=''as $$
#variable_conflict use_column
declare c record;def text;report public.checklist_submissions%rowtype;entry jsonb;result_id uuid;linked int;
begin
 select*into strict c from private.phase4a_actor_context(actor_user_id,target_branch_id);def:=target_checklist_type||'_v1';
 if target_checklist_type not in('kitchen_opening','foh_opening')then raise exception'unsupported draft'using errcode='22023';end if;
 perform private.phase4a_validate_opening(def,answers,false);
 insert into public.checklist_submissions(organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,checklist_type,definition_id,state,branch_name_snapshot,branch_code_snapshot,supervisor_name_snapshot)
 values(c.organization_id,c.branch_id,actor_user_id,c.team_id,c.business_date,target_checklist_type,def,'draft',c.branch_name,c.branch_code,c.supervisor_name)
 on conflict(supervisor_team_id,business_date,checklist_type)where state='draft'do update set updated_at=now()returning*into report;
 update public.checklist_issue_evidence e set status='pending',draft_submission_id=null,draft_result_id=null,expires_at=now()+interval'1 hour',updated_at=now()where e.draft_submission_id=report.id and e.status='draft';
 delete from public.opening_item_results where submission_id=report.id;
 insert into public.opening_item_results(submission_id,definition_id,item_id,ordinal,item_text_snapshot,answer,remark)
 select report.id,def,i.item_id,i.ordinal,i.item_text,row->>'answer',case when row->>'answer'='issue_found'then btrim(row->>'remark')else row->>'remark'end
 from pg_catalog.jsonb_array_elements(answers)row join public.checklist_definition_items i on i.definition_id=def and i.item_id=row->>'item_id';
 for entry in select value from pg_catalog.jsonb_array_elements(answers)where value->>'answer'='issue_found'loop
  select r.id into strict result_id from public.opening_item_results r where r.submission_id=report.id and r.item_id=entry->>'item_id';
  update public.checklist_issue_evidence e set status='draft',draft_submission_id=report.id,draft_result_id=result_id,expires_at=null,updated_at=now()
  where e.id=(entry->>'evidence_id')::uuid and e.organization_id=c.organization_id and e.branch_id=c.branch_id and e.supervisor_user_id=actor_user_id and e.supervisor_team_id=c.team_id
   and e.business_date=c.business_date and e.checklist_type=target_checklist_type and e.item_id=entry->>'item_id'and((e.status='pending'and e.expires_at>now())or(e.status='draft'and(e.draft_submission_id is null or e.draft_submission_id=report.id)));
  get diagnostics linked=row_count;if linked<>1 then raise exception'evidence link denied'using errcode='42501';end if;
 end loop;
 return query select report.id,report.business_date,report.checklist_type,report.state,report.created_at,report.updated_at;
exception when no_data_found or too_many_rows then raise exception'draft denied'using errcode='42501';end$$;

create or replace function public.submit_phase4a_opening(actor_user_id uuid,target_branch_id uuid,target_checklist_type text,idempotency_key uuid,request_hash text,answers jsonb)
returns table(id uuid,business_date date,checklist_type text,state text,submitted_at timestamptz,issue_count bigint)
language plpgsql security definer set search_path=''as $$
declare c record;def text;report public.checklist_submissions%rowtype;prior record;draft_id uuid;entry jsonb;result_id uuid;linked int;
begin
 select*into strict c from private.phase4a_actor_context(actor_user_id,target_branch_id);def:=target_checklist_type||'_v1';
 if target_checklist_type not in('kitchen_opening','foh_opening')or length(request_hash)<>64 then raise exception'invalid submission'using errcode='22023';end if;
 perform private.phase4a_validate_opening(def,answers,true);
 insert into public.checklist_submission_idempotency(actor_user_id,idempotency_key,request_hash)values(actor_user_id,idempotency_key,request_hash)on conflict do nothing;
 select*into prior from public.checklist_submission_idempotency x where x.actor_user_id=submit_phase4a_opening.actor_user_id and x.idempotency_key=submit_phase4a_opening.idempotency_key for update;
 if prior.request_hash<>request_hash then raise exception'idempotency conflict'using errcode='23505';end if;
 if prior.submission_id is not null then return query select s.id,s.business_date,s.checklist_type,s.state,s.submitted_at,(select count(*)from public.checklist_issues i where i.source_submission_id=s.id)from public.checklist_submissions s where s.id=prior.submission_id;return;end if;
 select s.id into draft_id from public.checklist_submissions s where s.supervisor_team_id=c.team_id and s.business_date=c.business_date and s.checklist_type=target_checklist_type and s.state='draft'for update;
 if draft_id is not null then update public.checklist_issue_evidence e set status='pending',draft_submission_id=null,draft_result_id=null,expires_at=now()+interval'1 hour',updated_at=now()where e.draft_submission_id=draft_id and e.status='draft';end if;
 insert into public.checklist_submissions(organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,checklist_type,definition_id,state,branch_name_snapshot,branch_code_snapshot,supervisor_name_snapshot,submitted_at)
 values(c.organization_id,c.branch_id,actor_user_id,c.team_id,c.business_date,target_checklist_type,def,'submitted',c.branch_name,c.branch_code,c.supervisor_name,now())returning*into report;
 insert into public.opening_item_results(submission_id,definition_id,item_id,ordinal,item_text_snapshot,answer,remark)
 select report.id,def,i.item_id,i.ordinal,i.item_text,row->>'answer',case when row->>'answer'='issue_found'then btrim(row->>'remark')else row->>'remark'end
 from pg_catalog.jsonb_array_elements(answers)row join public.checklist_definition_items i on i.definition_id=def and i.item_id=row->>'item_id';
 for entry in select value from pg_catalog.jsonb_array_elements(answers)where value->>'answer'='issue_found'loop
  select r.id into strict result_id from public.opening_item_results r where r.submission_id=report.id and r.item_id=entry->>'item_id';
  update public.checklist_issue_evidence e set status='finalized',draft_submission_id=null,draft_result_id=null,final_submission_id=report.id,final_result_id=result_id,expires_at=null,finalized_at=now(),updated_at=now()
  where e.id=(entry->>'evidence_id')::uuid and e.organization_id=c.organization_id and e.branch_id=c.branch_id and e.supervisor_user_id=actor_user_id and e.supervisor_team_id=c.team_id
   and e.business_date=c.business_date and e.checklist_type=target_checklist_type and e.item_id=entry->>'item_id'and((e.status='pending'and e.expires_at>now())or e.status='draft');
  get diagnostics linked=row_count;if linked<>1 then raise exception'evidence finalization denied'using errcode='42501';end if;
 end loop;
 insert into public.checklist_issues(organization_id,branch_id,source_submission_id,opening_result_id,status,checklist_type,item_id,item_text_snapshot,remark)
 select report.organization_id,report.branch_id,report.id,r.id,'new',report.checklist_type,r.item_id,r.item_text_snapshot,r.remark from public.opening_item_results r where r.submission_id=report.id and r.answer='issue_found';
 update public.checklist_submission_idempotency set submission_id=report.id where checklist_submission_idempotency.actor_user_id=submit_phase4a_opening.actor_user_id and checklist_submission_idempotency.idempotency_key=submit_phase4a_opening.idempotency_key;
 return query select report.id,report.business_date,report.checklist_type,report.state,report.submitted_at,(select count(*)from public.checklist_issues i where i.source_submission_id=report.id);
exception when no_data_found or too_many_rows then raise exception'submission denied'using errcode='42501';end$$;

-- Preserve the reconciled Hygiene DTO while adding safe opening evidence metadata.
create or replace function public.get_phase4a_current_state(actor_user_id uuid,target_branch_id uuid,target_checklist_type text)
returns jsonb language plpgsql security definer set search_path=''as $$declare c record;s public.checklist_submissions%rowtype;begin
 select*into strict c from private.phase4a_actor_context(actor_user_id,target_branch_id);
 if target_checklist_type not in('kitchen_opening','foh_opening','staff_hygiene')then raise exception'invalid checklist type'using errcode='22023';end if;
 select*into s from public.checklist_submissions x where x.supervisor_team_id=c.team_id and x.business_date=c.business_date and x.checklist_type=target_checklist_type order by case x.state when'submitted'then 0 else 1 end,x.updated_at desc,x.id limit 1;
 if target_checklist_type='staff_hygiene'then
  if s.state='submitted'then return pg_catalog.jsonb_build_object('state',s.state,'business_date',c.business_date,'checklist_type',target_checklist_type,'id',s.id,'created_at',s.created_at,'updated_at',s.updated_at,'submitted_at',s.submitted_at,'staff',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('staff_id',h.operational_staff_id,'display_name',h.display_name_snapshot,'operational_roles',h.operational_roles_snapshot,'uniform',h.uniform_result,'fingernails',h.fingernails_result,'hair',h.hair_result,'facial_hair',h.facial_hair_result,'remark',h.remark)order by lower(h.display_name_snapshot),h.id)from public.hygiene_staff_snapshots h where h.submission_id=s.id),'[]'::jsonb));end if;
  return pg_catalog.jsonb_build_object('state',coalesce(s.state,'none'),'business_date',c.business_date,'checklist_type',target_checklist_type,'id',s.id,'created_at',s.created_at,'updated_at',s.updated_at,'submitted_at',s.submitted_at,
   'staff',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('staff_id',staff.id,'display_name',staff.display_name,'operational_roles',a.operational_roles,'uniform',coalesce(h.uniform_result,'pending'),'fingernails',coalesce(h.fingernails_result,'pending'),'hair',coalesce(h.hair_result,'pending'),'facial_hair',coalesce(h.facial_hair_result,'pending'),'remark',coalesce(h.remark,''))order by lower(staff.display_name),staff.id)
    from public.operational_staff_assignments a join public.operational_staff staff on staff.id=a.operational_staff_id
    left join public.operational_staff_duty_statuses d on d.assignment_id=a.id and d.duty_date=c.business_date
    left join public.hygiene_staff_snapshots h on h.submission_id=s.id and h.operational_staff_id=staff.id
    where a.supervisor_team_id=c.team_id and a.active and staff.employment_status='active'and coalesce(d.duty_status,'on_duty')='on_duty'),'[]'::jsonb));
 end if;
 return pg_catalog.jsonb_build_object('state',coalesce(s.state,'none'),'business_date',c.business_date,'checklist_type',target_checklist_type,'id',s.id,'created_at',s.created_at,'updated_at',s.updated_at,'submitted_at',s.submitted_at,
  'answers',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('item_id',r.item_id,'answer',r.answer,'remark',r.remark,
   'evidence',(select pg_catalog.jsonb_build_object('id',e.id,'status',e.status,'mime_type',e.mime_type,'byte_size',e.byte_size,'available',true)from public.checklist_issue_evidence e where(e.draft_result_id=r.id and e.status='draft')or(e.final_result_id=r.id and e.status='finalized')limit 1))order by r.ordinal)
   from public.opening_item_results r where r.submission_id=s.id),'[]'::jsonb));
exception when no_data_found or too_many_rows then raise exception'state denied'using errcode='42501';end$$;

create or replace function public.get_phase4a_report_detail(actor_user_id uuid,target_report_id uuid,manager_mode boolean default false)
returns jsonb language plpgsql security definer set search_path=''as $$declare s public.checklist_submissions%rowtype;begin
 select*into strict s from public.checklist_submissions x where x.id=target_report_id and x.state='submitted';
 if(manager_mode and not private.actor_manages_active_organization(actor_user_id,s.organization_id))or(not manager_mode and not(s.supervisor_user_id=actor_user_id and exists(select 1 from public.profiles p where p.id=actor_user_id and p.disabled_at is null and not p.must_change_password)))then raise exception'report access denied'using errcode='42501';end if;
 return pg_catalog.jsonb_build_object('id',s.id,'organization_id',s.organization_id,'branch_id',s.branch_id,'branch_name',s.branch_name_snapshot,'branch_code',s.branch_code_snapshot,'supervisor_team_id',s.supervisor_team_id,'business_date',s.business_date,'checklist_type',s.checklist_type,'definition_id',s.definition_id,'submitted_at',s.submitted_at,'submitted_by',s.supervisor_name_snapshot,'completion',100,'status',case when exists(select 1 from public.checklist_issues i where i.source_submission_id=s.id)then'issues_found'else'compliant'end,'issue_count',(select count(*)from public.checklist_issues i where i.source_submission_id=s.id),
  'items',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('item_id',r.item_id,'item_text',r.item_text_snapshot,'answer',r.answer,'remark',r.remark,
   'evidence',(select pg_catalog.jsonb_build_object('id',e.id,'status',e.status,'mime_type',e.mime_type,'byte_size',e.byte_size,'available',true)from public.checklist_issue_evidence e where e.final_result_id=r.id and e.status='finalized'limit 1))order by r.ordinal)
   from public.opening_item_results r where r.submission_id=s.id),'[]'::jsonb),
  'staff',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('staff_id',h.operational_staff_id,'display_name',h.display_name_snapshot,'operational_roles',h.operational_roles_snapshot,'uniform',h.uniform_result,'fingernails',h.fingernails_result,'hair',h.hair_result,'facial_hair',h.facial_hair_result,'remark',h.remark)order by h.display_name_snapshot,h.id)from public.hygiene_staff_snapshots h where h.submission_id=s.id),'[]'::jsonb));
exception when no_data_found or too_many_rows then raise exception'report access denied'using errcode='42501';end$$;

create or replace function public.get_phase4a_managed_issue(actor_user_id uuid,target_organization_id uuid,target_issue_id uuid)
returns jsonb language plpgsql security definer set search_path=''as $$declare result jsonb;begin
 if not private.actor_manages_active_organization(actor_user_id,target_organization_id)then raise exception'issue access denied'using errcode='42501';end if;
 select pg_catalog.jsonb_build_object('id',i.id,'report_id',i.source_submission_id,'branch_id',i.branch_id,'branch_name',s.branch_name_snapshot,'business_date',s.business_date,'submitted_by',s.supervisor_name_snapshot,'checklist_type',i.checklist_type,'item_id',i.item_id,'item_text',i.item_text_snapshot,'affected_staff_id',i.affected_staff_id,'affected_staff_name',i.affected_staff_name_snapshot,'remark',i.remark,'status',i.status,'created_at',i.created_at,
  'evidence',(select pg_catalog.jsonb_build_object('id',e.id,'status',e.status,'mime_type',e.mime_type,'byte_size',e.byte_size,'available',true)from public.checklist_issue_evidence e where e.final_result_id=i.opening_result_id and e.status='finalized'limit 1))
 into strict result from public.checklist_issues i join public.checklist_submissions s on s.id=i.source_submission_id where i.id=target_issue_id and i.organization_id=target_organization_id;return result;
exception when no_data_found or too_many_rows then raise exception'issue access denied'using errcode='42501';end$$;

revoke all on function public.authorize_phase4a_evidence_upload(uuid,uuid,text,text),public.register_phase4a_evidence_upload(uuid,uuid,text,text,uuid,text,text,bigint,text),public.retire_phase4a_evidence(uuid,uuid),public.authorize_phase4a_evidence_set(uuid,uuid,text,uuid[]),public.authorize_phase4a_evidence_read(uuid,uuid),public.retire_expired_phase4a_evidence(int)from public,anon,authenticated;
grant execute on function public.authorize_phase4a_evidence_upload(uuid,uuid,text,text),public.register_phase4a_evidence_upload(uuid,uuid,text,text,uuid,text,text,bigint,text),public.retire_phase4a_evidence(uuid,uuid),public.authorize_phase4a_evidence_set(uuid,uuid,text,uuid[]),public.authorize_phase4a_evidence_read(uuid,uuid),public.retire_expired_phase4a_evidence(int)to service_role;
revoke all on function private.phase4a_validate_opening(text,jsonb,boolean)from public,anon,authenticated;
revoke all on function public.save_phase4a_draft(uuid,uuid,text,jsonb),public.submit_phase4a_opening(uuid,uuid,text,uuid,text,jsonb),public.get_phase4a_current_state(uuid,uuid,text),public.get_phase4a_report_detail(uuid,uuid,boolean),public.get_phase4a_managed_issue(uuid,uuid,uuid)from public,anon,authenticated;
grant execute on function public.save_phase4a_draft(uuid,uuid,text,jsonb),public.submit_phase4a_opening(uuid,uuid,text,uuid,text,jsonb),public.get_phase4a_current_state(uuid,uuid,text),public.get_phase4a_report_detail(uuid,uuid,boolean),public.get_phase4a_managed_issue(uuid,uuid,uuid)to service_role;
