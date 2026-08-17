-- Phase 4A HACCP persistence. JSONB is accepted only at the RPC boundary as a
-- compact transport DTO; every key and value is validated before normalized rows are written.
create table public.checklist_definitions (
  id text primary key check (id in ('kitchen_opening_v1','foh_opening_v1','staff_hygiene_v1')),
  checklist_type text not null unique check (checklist_type in ('kitchen_opening','foh_opening','staff_hygiene')),
  version integer not null check (version = 1),
  active boolean not null default true
);
create table public.checklist_definition_items (
  definition_id text not null references public.checklist_definitions(id) on delete restrict,
  item_id text not null,
  ordinal integer not null check (ordinal > 0),
  item_text text not null check (item_text = btrim(item_text) and length(item_text) > 0),
  primary key (definition_id,item_id), unique (definition_id,ordinal)
);

insert into public.checklist_definitions(id,checklist_type,version) values
 ('kitchen_opening_v1','kitchen_opening',1),('foh_opening_v1','foh_opening',1),
 ('staff_hygiene_v1','staff_hygiene',1);
insert into public.checklist_definition_items values
 ('kitchen_opening_v1','kitchen-opening-1',1,'Line check has been completed.'),
 ('kitchen_opening_v1','kitchen-opening-2',2,'Product shelf life has been checked.'),
 ('kitchen_opening_v1','kitchen-opening-3',3,'Prep tables are wiped and sanitized.'),
 ('kitchen_opening_v1','kitchen-opening-4',4,'Daily order requirements have been checked.'),
 ('kitchen_opening_v1','kitchen-opening-5',5,'Deliveries have been received and stored correctly.'),
 ('kitchen_opening_v1','kitchen-opening-6',6,'Prep items are checked and in good condition.'),
 ('kitchen_opening_v1','kitchen-opening-7',7,'Employee uniforms and hygiene levels are checked.'),
 ('kitchen_opening_v1','kitchen-opening-8',8,'All preparation has been initiated by the cooking staff, including sauces, patties, buns, and other required items.'),
 ('kitchen_opening_v1','kitchen-opening-9',9,'Refrigerators are clean, organized, and operating correctly.'),
 ('kitchen_opening_v1','kitchen-opening-10',10,'Garbage bins are clean.'),
 ('kitchen_opening_v1','kitchen-opening-11',11,'Kitchen utensils are clean, sanitized, polished, and organized.'),
 ('kitchen_opening_v1','kitchen-opening-12',12,'Electric fryers, gas fryers, and production equipment are switched on.'),
 ('kitchen_opening_v1','kitchen-opening-13',13,'Fryer oil has been checked and filtered.'),
 ('kitchen_opening_v1','kitchen-opening-14',14,'The extraction hood system is switched on.'),
 ('kitchen_opening_v1','kitchen-opening-15',15,'Electric fly killers are operational.'),
 ('kitchen_opening_v1','kitchen-opening-16',16,'Refrigerator temperatures have been checked and logged.'),
 ('kitchen_opening_v1','kitchen-opening-17',17,'All food items are stored according to FIFO.'),
 ('foh_opening_v1','foh-opening-1',1,'Unlock and open the doors, then inspect the restaurant.'),
 ('foh_opening_v1','foh-opening-2',2,'Switch on the essential lights and air conditioning.'),
 ('foh_opening_v1','foh-opening-3',3,'Read the manager’s logbook or the previous group message from the preceding closing manager.'),
 ('foh_opening_v1','foh-opening-4',4,'Turn on the PC, server, and printer.'),
 ('foh_opening_v1','foh-opening-5',5,'Check the overall cleanliness of the seating area.'),
 ('foh_opening_v1','foh-opening-6',6,'Check the cleanliness of the reception area.'),
 ('foh_opening_v1','foh-opening-7',7,'Stock the condiment dispensers.'),
 ('foh_opening_v1','foh-opening-8',8,'Ensure the restaurant smells fresh and switch on the hood system.'),
 ('foh_opening_v1','foh-opening-9',9,'Ensure service-station condiments are stocked and the drinks chiller is fully replenished.'),
 ('foh_opening_v1','foh-opening-10',10,'Check the cleanliness of the guests’ toilets and handwashing area.'),
 ('foh_opening_v1','foh-opening-11',11,'Ensure the main entrance is clean and dust-free.'),
 ('foh_opening_v1','foh-opening-12',12,'Check that the restaurant blinds are working and raised for opening.'),
 ('foh_opening_v1','foh-opening-13',13,'Check for damaged bulbs and other maintenance issues in the FOH area.'),
 ('foh_opening_v1','foh-opening-14',14,'Ensure decorative elements are properly maintained.'),
 ('foh_opening_v1','foh-opening-15',15,'Complete the daily briefing for FOH staff.'),
 ('foh_opening_v1','foh-opening-16',16,'Polish glass surfaces, including windows and the main door, using glass cleaner.'),
 ('foh_opening_v1','foh-opening-17',17,'Confirm the opening team is fully groomed and uniformed, and check personal hygiene during the shift briefing.'),
 ('foh_opening_v1','foh-opening-18',18,'Confirm the restaurant is ready to welcome guests.'),
 ('staff_hygiene_v1','uniform',1,'Uniform'),
 ('staff_hygiene_v1','fingernails',2,'Fingernails'),
 ('staff_hygiene_v1','hair',3,'Hair / Haircut'),
 ('staff_hygiene_v1','facial_hair',4,'Shave / Facial Hair');

create table public.checklist_submissions (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null references public.organizations(id) on delete restrict,
 branch_id uuid not null, supervisor_user_id uuid not null references auth.users(id) on delete restrict,
 supervisor_team_id uuid not null, business_date date not null, checklist_type text not null,
 definition_id text not null references public.checklist_definitions(id) on delete restrict,
 state text not null check(state in ('draft','submitted')), branch_name_snapshot text not null,
 branch_code_snapshot text not null, supervisor_name_snapshot text not null,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(), submitted_at timestamptz,
 constraint checklist_submissions_lifecycle_check check ((state='draft' and submitted_at is null) or (state='submitted' and submitted_at is not null)),
 constraint checklist_submissions_type_check check(checklist_type in ('kitchen_opening','foh_opening','staff_hygiene')),
 constraint checklist_submissions_branch_scope_fkey foreign key(branch_id,organization_id) references public.branches(id,organization_id) on delete restrict,
 constraint checklist_submissions_team_scope_fkey foreign key(supervisor_team_id,branch_id,organization_id) references public.branch_supervisor_teams(id,branch_id,organization_id) on delete restrict,
 unique(id,organization_id,branch_id,supervisor_team_id), unique(id,organization_id,branch_id)
);
create unique index checklist_submissions_one_draft on public.checklist_submissions(supervisor_team_id,business_date,checklist_type) where state='draft';
create unique index checklist_submissions_one_final on public.checklist_submissions(organization_id,branch_id,supervisor_team_id,business_date,checklist_type) where state='submitted';
create index checklist_submissions_branch_date_type_idx on public.checklist_submissions(branch_id,business_date desc,checklist_type);
create index checklist_submissions_team_date_idx on public.checklist_submissions(supervisor_team_id,business_date desc);
create index checklist_submissions_manager_filter_idx on public.checklist_submissions(organization_id,business_date desc,branch_id,supervisor_user_id,state);

create table public.opening_item_results (
 id uuid primary key default gen_random_uuid(), submission_id uuid not null references public.checklist_submissions(id) on delete restrict,
 definition_id text not null, item_id text not null, ordinal integer not null, item_text_snapshot text not null,
 answer text not null check(answer in ('not_checked','completed','issue_found')), remark text not null default '',
 unique(submission_id,item_id), foreign key(definition_id,item_id) references public.checklist_definition_items(definition_id,item_id) on delete restrict
);
create table public.hygiene_staff_snapshots (
 id uuid primary key default gen_random_uuid(), submission_id uuid not null references public.checklist_submissions(id) on delete restrict,
 operational_staff_id uuid not null, display_name_snapshot text not null, operational_roles_snapshot text[] not null,
 remark text not null default '', uniform_result text not null, fingernails_result text not null,
 hair_result text not null, facial_hair_result text not null, unique(submission_id,operational_staff_id),
 check(uniform_result in ('pending','pass','issue')),check(fingernails_result in ('pending','pass','issue')),
 check(hair_result in ('pending','pass','issue')),check(facial_hair_result in ('pending','pass','issue'))
);
create index hygiene_staff_affected_idx on public.hygiene_staff_snapshots(operational_staff_id,submission_id);
create table public.checklist_issues (
 id uuid primary key default gen_random_uuid(), organization_id uuid not null, branch_id uuid not null,
 source_submission_id uuid not null, opening_result_id uuid, hygiene_staff_snapshot_id uuid,
 status text not null default 'new' check(status='new'), checklist_type text not null,
 item_id text, item_text_snapshot text, affected_staff_id uuid, affected_staff_name_snapshot text,
 remark text not null check(length(btrim(remark))>0), created_at timestamptz not null default now(),
 foreign key(source_submission_id,organization_id,branch_id) references public.checklist_submissions(id,organization_id,branch_id) on delete restrict,
 foreign key(opening_result_id) references public.opening_item_results(id) on delete restrict,
 foreign key(hygiene_staff_snapshot_id) references public.hygiene_staff_snapshots(id) on delete restrict,
 check((opening_result_id is not null)::int+(hygiene_staff_snapshot_id is not null)::int=1)
);
create index checklist_issues_org_status_idx on public.checklist_issues(organization_id,status,created_at desc);
create index checklist_issues_source_idx on public.checklist_issues(source_submission_id);
create index checklist_issues_staff_idx on public.checklist_issues(affected_staff_id) where affected_staff_id is not null;
create table public.checklist_submission_idempotency (
 actor_user_id uuid not null references auth.users(id) on delete restrict, idempotency_key uuid not null,
 request_hash text not null, submission_id uuid references public.checklist_submissions(id) on delete restrict,
 created_at timestamptz not null default now(), primary key(actor_user_id,idempotency_key)
);

create function private.phase4a_business_date(tz text) returns date language sql stable security definer set search_path=''
as $$ select (pg_catalog.now() at time zone tz)::date $$;
revoke all on function private.phase4a_business_date(text) from public,anon,authenticated;

create function private.phase4a_actor_context(actor uuid,target_branch uuid)
returns table(organization_id uuid,branch_id uuid,team_id uuid,business_date date,branch_name text,branch_code text,supervisor_name text)
language sql stable security definer set search_path='' as $$
 select b.organization_id,b.id,t.id,private.phase4a_business_date(b.timezone),b.name,b.code,p.full_name
 from public.profiles p join public.branch_memberships m on m.user_id=p.id
 join public.branches b on b.id=m.branch_id join public.organizations o on o.id=b.organization_id
 join public.branch_supervisor_teams t on t.branch_id=b.id and t.supervisor_user_id=p.id
 where p.id=actor and p.disabled_at is null and not p.must_change_password and m.branch_id=target_branch
 and m.role='branch_manager' and m.active and b.active and o.active and t.active
 $$;
revoke all on function private.phase4a_actor_context(uuid,uuid) from public,anon,authenticated;

create function private.phase4a_validate_opening(definition text, answers jsonb, final boolean)
returns void language plpgsql security definer set search_path='' as $$
declare expected int; supplied int; row jsonb;
begin
 if pg_catalog.jsonb_typeof(answers)<>'array' then raise exception 'invalid answers' using errcode='22023'; end if;
 select count(*) into expected from public.checklist_definition_items where definition_id=definition;
 select count(*),count(distinct value->>'item_id') into supplied,expected
 from pg_catalog.jsonb_array_elements(answers);
 if supplied<>(select count(*) from public.checklist_definition_items where definition_id=definition) or supplied<>expected then raise exception 'invalid definition items' using errcode='22023'; end if;
 for row in select value from pg_catalog.jsonb_array_elements(answers) loop
  if (select count(*) from pg_catalog.jsonb_object_keys(row))<>3 or not(row?'item_id' and row?'answer' and row?'remark')
   or pg_catalog.jsonb_typeof(row->'item_id')<>'string' or pg_catalog.jsonb_typeof(row->'answer')<>'string' or pg_catalog.jsonb_typeof(row->'remark')<>'string'
   or not exists(select 1 from public.checklist_definition_items i where i.definition_id=definition and i.item_id=row->>'item_id')
   or row->>'answer' not in ('not_checked','completed','issue_found')
   or (final and row->>'answer'='not_checked')
   or (row->>'answer'='issue_found' and length(btrim(row->>'remark'))=0)
  then raise exception 'invalid answer' using errcode='22023'; end if;
 end loop;
end $$;
revoke all on function private.phase4a_validate_opening(text,jsonb,boolean) from public,anon,authenticated;

create function public.save_phase4a_draft(actor_user_id uuid,target_branch_id uuid,target_checklist_type text,answers jsonb)
returns table(id uuid,business_date date,checklist_type text,state text,created_at timestamptz,updated_at timestamptz)
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare c record; def text; report public.checklist_submissions%rowtype;
begin
 select * into strict c from private.phase4a_actor_context(actor_user_id,target_branch_id);
 def:=target_checklist_type||'_v1';
 if target_checklist_type not in ('kitchen_opening','foh_opening') then raise exception 'unsupported draft' using errcode='22023'; end if;
 perform private.phase4a_validate_opening(def,answers,false);
 insert into public.checklist_submissions(organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,checklist_type,definition_id,state,branch_name_snapshot,branch_code_snapshot,supervisor_name_snapshot)
 values(c.organization_id,c.branch_id,actor_user_id,c.team_id,c.business_date,target_checklist_type,def,'draft',c.branch_name,c.branch_code,c.supervisor_name)
 on conflict(supervisor_team_id,business_date,checklist_type) where state='draft' do update set updated_at=now()
 returning * into report;
 delete from public.opening_item_results where submission_id=report.id;
 insert into public.opening_item_results(submission_id,definition_id,item_id,ordinal,item_text_snapshot,answer,remark)
 select report.id,def,i.item_id,i.ordinal,i.item_text,row->>'answer',row->>'remark'
 from pg_catalog.jsonb_array_elements(answers) row join public.checklist_definition_items i on i.definition_id=def and i.item_id=row->>'item_id';
 return query select report.id,report.business_date,report.checklist_type,report.state,report.created_at,report.updated_at;
exception when no_data_found or too_many_rows then raise exception 'draft denied' using errcode='42501'; end $$;

create function public.submit_phase4a_opening(actor_user_id uuid,target_branch_id uuid,target_checklist_type text,idempotency_key uuid,request_hash text,answers jsonb)
returns table(id uuid,business_date date,checklist_type text,state text,submitted_at timestamptz,issue_count bigint)
language plpgsql security definer set search_path='' as $$
declare c record; def text; report public.checklist_submissions%rowtype; prior record;
begin
 select * into strict c from private.phase4a_actor_context(actor_user_id,target_branch_id); def:=target_checklist_type||'_v1';
 if target_checklist_type not in ('kitchen_opening','foh_opening') or length(request_hash)<>64 then raise exception 'invalid submission' using errcode='22023'; end if;
 perform private.phase4a_validate_opening(def,answers,true);
 insert into public.checklist_submission_idempotency(actor_user_id,idempotency_key,request_hash) values(actor_user_id,idempotency_key,request_hash)
 on conflict do nothing;
 select * into prior from public.checklist_submission_idempotency x where x.actor_user_id=submit_phase4a_opening.actor_user_id and x.idempotency_key=submit_phase4a_opening.idempotency_key for update;
 if prior.request_hash<>request_hash then raise exception 'idempotency conflict' using errcode='23505'; end if;
 if prior.submission_id is not null then return query select s.id,s.business_date,s.checklist_type,s.state,s.submitted_at,(select count(*) from public.checklist_issues i where i.source_submission_id=s.id) from public.checklist_submissions s where s.id=prior.submission_id; return; end if;
 insert into public.checklist_submissions(organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,checklist_type,definition_id,state,branch_name_snapshot,branch_code_snapshot,supervisor_name_snapshot,submitted_at)
 values(c.organization_id,c.branch_id,actor_user_id,c.team_id,c.business_date,target_checklist_type,def,'submitted',c.branch_name,c.branch_code,c.supervisor_name,now()) returning * into report;
 insert into public.opening_item_results(submission_id,definition_id,item_id,ordinal,item_text_snapshot,answer,remark)
 select report.id,def,i.item_id,i.ordinal,i.item_text,row->>'answer',row->>'remark' from pg_catalog.jsonb_array_elements(answers) row join public.checklist_definition_items i on i.definition_id=def and i.item_id=row->>'item_id';
 insert into public.checklist_issues(organization_id,branch_id,source_submission_id,opening_result_id,status,checklist_type,item_id,item_text_snapshot,remark)
 select report.organization_id,report.branch_id,report.id,r.id,'new',report.checklist_type,r.item_id,r.item_text_snapshot,r.remark from public.opening_item_results r where r.submission_id=report.id and r.answer='issue_found';
 update public.checklist_submission_idempotency set submission_id=report.id where checklist_submission_idempotency.actor_user_id=submit_phase4a_opening.actor_user_id and checklist_submission_idempotency.idempotency_key=submit_phase4a_opening.idempotency_key;
 delete from public.opening_item_results r using public.checklist_submissions d where r.submission_id=d.id and d.supervisor_team_id=c.team_id and d.business_date=c.business_date and d.checklist_type=target_checklist_type and d.state='draft';
 delete from public.checklist_submissions d where d.supervisor_team_id=c.team_id and d.business_date=c.business_date and d.checklist_type=target_checklist_type and d.state='draft';
 return query select report.id,report.business_date,report.checklist_type,report.state,report.submitted_at,(select count(*) from public.checklist_issues i where i.source_submission_id=report.id);
exception when no_data_found or too_many_rows then raise exception 'submission denied' using errcode='42501'; end $$;

create function public.submit_phase4a_hygiene(actor_user_id uuid,target_branch_id uuid,idempotency_key uuid,request_hash text,staff_answers jsonb)
returns table(id uuid,business_date date,checklist_type text,state text,submitted_at timestamptz,issue_count bigint)
language plpgsql security definer set search_path='' as $$
declare c record; report public.checklist_submissions%rowtype; prior record; staff_row jsonb; eligible_count int;
begin
 select * into strict c from private.phase4a_actor_context(actor_user_id,target_branch_id);
 if length(request_hash)<>64 or pg_catalog.jsonb_typeof(staff_answers)<>'array' then raise exception 'invalid submission' using errcode='22023'; end if;
 select count(*) into eligible_count from public.operational_staff_assignments a join public.operational_staff s on s.id=a.operational_staff_id
 left join public.operational_staff_duty_statuses d on d.assignment_id=a.id and d.duty_date=c.business_date
 where a.supervisor_team_id=c.team_id and a.active and s.employment_status='active' and coalesce(d.duty_status,'on_duty')='on_duty';
 if pg_catalog.jsonb_array_length(staff_answers)<>eligible_count or (select count(distinct value->>'staff_id') from pg_catalog.jsonb_array_elements(staff_answers))<>eligible_count then raise exception 'staff set changed' using errcode='22023'; end if;
 for staff_row in select value from pg_catalog.jsonb_array_elements(staff_answers) loop
  if (select count(*) from pg_catalog.jsonb_object_keys(staff_row))<>6 or not(staff_row?'staff_id' and staff_row?'uniform' and staff_row?'fingernails' and staff_row?'hair' and staff_row?'facial_hair' and staff_row?'remark')
   or staff_row->>'uniform' not in ('pass','issue') or staff_row->>'fingernails' not in ('pass','issue') or staff_row->>'hair' not in ('pass','issue') or staff_row->>'facial_hair' not in ('pass','issue')
   or (('issue'=any(array[staff_row->>'uniform',staff_row->>'fingernails',staff_row->>'hair',staff_row->>'facial_hair'])) and length(btrim(staff_row->>'remark'))=0)
   or not exists(select 1 from public.operational_staff_assignments a join public.operational_staff s on s.id=a.operational_staff_id left join public.operational_staff_duty_statuses d on d.assignment_id=a.id and d.duty_date=c.business_date where s.id=(staff_row->>'staff_id')::uuid and a.supervisor_team_id=c.team_id and a.active and s.employment_status='active' and coalesce(d.duty_status,'on_duty')='on_duty')
  then raise exception 'invalid hygiene answer' using errcode='22023'; end if;
 end loop;
 insert into public.checklist_submission_idempotency(actor_user_id,idempotency_key,request_hash) values(actor_user_id,idempotency_key,request_hash) on conflict do nothing;
 select * into prior from public.checklist_submission_idempotency where checklist_submission_idempotency.actor_user_id=submit_phase4a_hygiene.actor_user_id and checklist_submission_idempotency.idempotency_key=submit_phase4a_hygiene.idempotency_key for update;
 if prior.request_hash<>request_hash then raise exception 'idempotency conflict' using errcode='23505'; end if;
 if prior.submission_id is not null then return query select s.id,s.business_date,s.checklist_type,s.state,s.submitted_at,(select count(*) from public.checklist_issues i where i.source_submission_id=s.id) from public.checklist_submissions s where s.id=prior.submission_id; return; end if;
 insert into public.checklist_submissions(organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,checklist_type,definition_id,state,branch_name_snapshot,branch_code_snapshot,supervisor_name_snapshot,submitted_at)
 values(c.organization_id,c.branch_id,actor_user_id,c.team_id,c.business_date,'staff_hygiene','staff_hygiene_v1','submitted',c.branch_name,c.branch_code,c.supervisor_name,now()) returning * into report;
 insert into public.hygiene_staff_snapshots(submission_id,operational_staff_id,display_name_snapshot,operational_roles_snapshot,remark,uniform_result,fingernails_result,hair_result,facial_hair_result)
 select report.id,s.id,s.display_name,a.operational_roles,entry.value->>'remark',entry.value->>'uniform',entry.value->>'fingernails',entry.value->>'hair',entry.value->>'facial_hair'
 from pg_catalog.jsonb_array_elements(staff_answers) entry(value) join public.operational_staff s on s.id=(entry.value->>'staff_id')::uuid join public.operational_staff_assignments a on a.operational_staff_id=s.id and a.supervisor_team_id=c.team_id and a.active;
 insert into public.checklist_issues(organization_id,branch_id,source_submission_id,hygiene_staff_snapshot_id,status,checklist_type,affected_staff_id,affected_staff_name_snapshot,remark)
 select report.organization_id,report.branch_id,report.id,h.id,'new','staff_hygiene',h.operational_staff_id,h.display_name_snapshot,h.remark from public.hygiene_staff_snapshots h where h.submission_id=report.id and 'issue'=any(array[h.uniform_result,h.fingernails_result,h.hair_result,h.facial_hair_result]);
 update public.checklist_submission_idempotency set submission_id=report.id where checklist_submission_idempotency.actor_user_id=submit_phase4a_hygiene.actor_user_id and checklist_submission_idempotency.idempotency_key=submit_phase4a_hygiene.idempotency_key;
 return query select report.id,report.business_date,report.checklist_type,report.state,report.submitted_at,(select count(*) from public.checklist_issues i where i.source_submission_id=report.id);
exception when no_data_found or too_many_rows then raise exception 'submission denied' using errcode='42501'; end $$;

-- Submitted rows and their children are immutable, including to service_role.
create function private.reject_final_report_mutation() returns trigger language plpgsql set search_path='' as $$ begin raise exception 'submitted report is immutable' using errcode='55000'; end $$;
create trigger immutable_submitted_report before update or delete on public.checklist_submissions for each row when(old.state='submitted') execute function private.reject_final_report_mutation();
create function private.reject_final_child_mutation() returns trigger language plpgsql set search_path='' as $$ begin if exists(select 1 from public.checklist_submissions s where s.id=old.submission_id and s.state='submitted') then raise exception 'submitted report is immutable' using errcode='55000'; end if; return old; end $$;
create trigger immutable_opening_results before update or delete on public.opening_item_results for each row execute function private.reject_final_child_mutation();
create trigger immutable_hygiene_results before update or delete on public.hygiene_staff_snapshots for each row execute function private.reject_final_child_mutation();

alter table public.checklist_definitions enable row level security; alter table public.checklist_definition_items enable row level security;
alter table public.checklist_submissions enable row level security; alter table public.opening_item_results enable row level security;
alter table public.hygiene_staff_snapshots enable row level security; alter table public.checklist_issues enable row level security;
alter table public.checklist_submission_idempotency enable row level security;
create policy report_read on public.checklist_submissions for select to authenticated using(
 (supervisor_user_id=auth.uid() and private.actor_owns_operational_team(auth.uid(),branch_id,supervisor_team_id))
 or private.actor_manages_active_organization(auth.uid(),organization_id));
create policy opening_read on public.opening_item_results for select to authenticated using(exists(select 1 from public.checklist_submissions s where s.id=submission_id));
create policy hygiene_read on public.hygiene_staff_snapshots for select to authenticated using(exists(select 1 from public.checklist_submissions s where s.id=submission_id));
create policy issue_read on public.checklist_issues for select to authenticated using(private.actor_manages_active_organization(auth.uid(),organization_id));
grant select on public.checklist_submissions,public.opening_item_results,public.hygiene_staff_snapshots,public.checklist_issues to authenticated;
revoke all on public.checklist_definitions,public.checklist_definition_items,public.checklist_submissions,public.opening_item_results,public.hygiene_staff_snapshots,public.checklist_issues,public.checklist_submission_idempotency from anon;
revoke all on function public.save_phase4a_draft(uuid,uuid,text,jsonb),public.submit_phase4a_opening(uuid,uuid,text,uuid,text,jsonb),public.submit_phase4a_hygiene(uuid,uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.save_phase4a_draft(uuid,uuid,text,jsonb),public.submit_phase4a_opening(uuid,uuid,text,uuid,text,jsonb),public.submit_phase4a_hygiene(uuid,uuid,uuid,text,jsonb) to service_role;

create function public.get_phase4a_supervisor_draft(actor_user_id uuid,target_branch_id uuid,target_checklist_type text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record; s public.checklist_submissions%rowtype;
begin
 select * into strict c from private.phase4a_actor_context(actor_user_id,target_branch_id);
 select * into s from public.checklist_submissions x where x.supervisor_team_id=c.team_id and x.business_date=c.business_date and x.checklist_type=target_checklist_type and x.state='draft';
 if s.id is null then return null; end if;
 return pg_catalog.jsonb_build_object('id',s.id,'business_date',s.business_date,'checklist_type',s.checklist_type,'state',s.state,'created_at',s.created_at,'updated_at',s.updated_at,
  'answers',(select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('item_id',r.item_id,'answer',r.answer,'remark',r.remark) order by r.ordinal) from public.opening_item_results r where r.submission_id=s.id));
exception when no_data_found or too_many_rows then raise exception 'draft denied' using errcode='42501'; end $$;

create function public.list_phase4a_supervisor_reports(actor_user_id uuid,target_branch_id uuid,requested_page int default 1,requested_page_size int default 20,target_checklist_type text default null)
returns jsonb language plpgsql security definer set search_path='' as $$ declare c record; begin
 select * into strict c from private.phase4a_actor_context(actor_user_id,target_branch_id);
 if requested_page<1 or requested_page_size not between 1 and 50 or (target_checklist_type is not null and target_checklist_type not in ('kitchen_opening','foh_opening','staff_hygiene')) then raise exception 'invalid list' using errcode='22023'; end if;
 return pg_catalog.jsonb_build_object('reports',coalesce((select pg_catalog.jsonb_agg(q.row_data order by q.business_date desc,q.submitted_at desc) from(
  select s.business_date,s.submitted_at,pg_catalog.jsonb_build_object('id',s.id,'checklist_type',s.checklist_type,'business_date',s.business_date,'submitted_at',s.submitted_at,'submitted_by',s.supervisor_name_snapshot,'completion',100,'issue_count',(select count(*) from public.checklist_issues i where i.source_submission_id=s.id),'status',case when exists(select 1 from public.checklist_issues i where i.source_submission_id=s.id) then 'issues_found' else 'compliant' end) row_data
  from public.checklist_submissions s where s.supervisor_team_id=c.team_id and s.branch_id=c.branch_id and s.state='submitted' and (target_checklist_type is null or s.checklist_type=target_checklist_type)
  order by s.business_date desc,s.submitted_at desc limit requested_page_size offset ((requested_page-1)*requested_page_size))q),'[]'::jsonb),
  'total',(select count(*) from public.checklist_submissions s where s.supervisor_team_id=c.team_id and s.branch_id=c.branch_id and s.state='submitted' and (target_checklist_type is null or s.checklist_type=target_checklist_type)));
exception when no_data_found or too_many_rows then raise exception 'report access denied' using errcode='42501'; end $$;

create function public.get_phase4a_report_detail(actor_user_id uuid,target_report_id uuid,manager_mode boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$ declare s public.checklist_submissions%rowtype; begin
 select * into strict s from public.checklist_submissions x where x.id=target_report_id and x.state='submitted';
 if (manager_mode and not private.actor_manages_active_organization(actor_user_id,s.organization_id)) or
   (not manager_mode and not (s.supervisor_user_id=actor_user_id and private.actor_owns_operational_team(actor_user_id,s.branch_id,s.supervisor_team_id))) then raise exception 'report access denied' using errcode='42501'; end if;
 return pg_catalog.jsonb_build_object('id',s.id,'organization_id',s.organization_id,'branch_id',s.branch_id,'branch_name',s.branch_name_snapshot,'branch_code',s.branch_code_snapshot,
 'supervisor_team_id',s.supervisor_team_id,'business_date',s.business_date,'checklist_type',s.checklist_type,'definition_id',s.definition_id,'submitted_at',s.submitted_at,'submitted_by',s.supervisor_name_snapshot,
 'issue_count',(select count(*) from public.checklist_issues i where i.source_submission_id=s.id),
 'items',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('item_id',r.item_id,'item_text',r.item_text_snapshot,'answer',r.answer,'remark',r.remark) order by r.ordinal) from public.opening_item_results r where r.submission_id=s.id),'[]'::jsonb),
 'staff',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('staff_id',h.operational_staff_id,'display_name',h.display_name_snapshot,'operational_roles',h.operational_roles_snapshot,'uniform',h.uniform_result,'fingernails',h.fingernails_result,'hair',h.hair_result,'facial_hair',h.facial_hair_result,'remark',h.remark) order by h.display_name_snapshot,h.id) from public.hygiene_staff_snapshots h where h.submission_id=s.id),'[]'::jsonb));
exception when no_data_found or too_many_rows then raise exception 'report access denied' using errcode='42501'; end $$;

create function public.list_phase4a_managed_reports(actor_user_id uuid,target_organization_id uuid,requested_page int default 1,requested_page_size int default 20,date_from date default null,date_to date default null,branch_filter uuid default null,supervisor_filter uuid default null,type_filter text default null,status_filter text default null,search_term text default null)
returns jsonb language plpgsql security definer set search_path='' as $$ begin
 if not private.actor_manages_active_organization(actor_user_id,target_organization_id) or requested_page<1 or requested_page_size not between 1 and 50 or length(coalesce(search_term,''))>120 then raise exception 'report access denied' using errcode='42501'; end if;
 return pg_catalog.jsonb_build_object('reports',coalesce((select pg_catalog.jsonb_agg(q.row_data order by q.business_date desc,q.submitted_at desc) from(
 select s.business_date,s.submitted_at,pg_catalog.jsonb_build_object('id',s.id,'branch_id',s.branch_id,'branch_name',s.branch_name_snapshot,'checklist_type',s.checklist_type,'business_date',s.business_date,'submitted_at',s.submitted_at,'submitted_by',s.supervisor_name_snapshot,'issue_count',(select count(*) from public.checklist_issues i where i.source_submission_id=s.id),'status',case when exists(select 1 from public.checklist_issues i where i.source_submission_id=s.id) then 'issues_found' else 'compliant' end) row_data
 from public.checklist_submissions s where s.organization_id=target_organization_id and s.state='submitted' and(date_from is null or s.business_date>=date_from)and(date_to is null or s.business_date<=date_to)and(branch_filter is null or s.branch_id=branch_filter)and(supervisor_filter is null or s.supervisor_user_id=supervisor_filter)and(type_filter is null or s.checklist_type=type_filter)and(status_filter is null or (status_filter='issues_found')=exists(select 1 from public.checklist_issues i where i.source_submission_id=s.id))and(nullif(btrim(search_term),'') is null or s.branch_name_snapshot ilike '%'||btrim(search_term)||'%' or s.supervisor_name_snapshot ilike '%'||btrim(search_term)||'%')
 order by s.business_date desc,s.submitted_at desc limit requested_page_size offset((requested_page-1)*requested_page_size))q),'[]'::jsonb),
 'total',(select count(*) from public.checklist_submissions s where s.organization_id=target_organization_id and s.state='submitted' and(date_from is null or s.business_date>=date_from)and(date_to is null or s.business_date<=date_to)and(branch_filter is null or s.branch_id=branch_filter)and(supervisor_filter is null or s.supervisor_user_id=supervisor_filter)and(type_filter is null or s.checklist_type=type_filter)));
end $$;

create function public.list_phase4a_managed_issues(actor_user_id uuid,target_organization_id uuid,requested_page int default 1,requested_page_size int default 20,branch_filter uuid default null,type_filter text default null,status_filter text default null,search_term text default null)
returns jsonb language plpgsql security definer set search_path='' as $$ begin
 if not private.actor_manages_active_organization(actor_user_id,target_organization_id) or requested_page<1 or requested_page_size not between 1 and 50 or length(coalesce(search_term,''))>120 then raise exception 'issue access denied' using errcode='42501'; end if;
 return pg_catalog.jsonb_build_object('issues',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id',i.id,'report_id',i.source_submission_id,'branch_name',s.branch_name_snapshot,'checklist_type',i.checklist_type,'title',coalesce(i.item_text_snapshot,i.affected_staff_name_snapshot),'description',i.remark,'status',i.status,'created_at',i.created_at) order by i.created_at desc) from public.checklist_issues i join public.checklist_submissions s on s.id=i.source_submission_id where i.organization_id=target_organization_id and(branch_filter is null or i.branch_id=branch_filter)and(type_filter is null or i.checklist_type=type_filter)and(status_filter is null or i.status=status_filter)and(nullif(btrim(search_term),'') is null or coalesce(i.item_text_snapshot,i.affected_staff_name_snapshot) ilike '%'||btrim(search_term)||'%')),'[]'::jsonb),
 'total',(select count(*) from public.checklist_issues i where i.organization_id=target_organization_id and(branch_filter is null or i.branch_id=branch_filter)and(type_filter is null or i.checklist_type=type_filter)and(status_filter is null or i.status=status_filter)));
end $$;
create function public.get_phase4a_managed_issue(actor_user_id uuid,target_organization_id uuid,target_issue_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$ declare result jsonb; begin
 if not private.actor_manages_active_organization(actor_user_id,target_organization_id) then raise exception 'issue access denied' using errcode='42501'; end if;
 select pg_catalog.jsonb_build_object('id',i.id,'report_id',i.source_submission_id,'branch_id',i.branch_id,'branch_name',s.branch_name_snapshot,'checklist_type',i.checklist_type,'title',coalesce(i.item_text_snapshot,i.affected_staff_name_snapshot),'description',i.remark,'status',i.status,'created_at',i.created_at,'affected_staff_id',i.affected_staff_id) into strict result from public.checklist_issues i join public.checklist_submissions s on s.id=i.source_submission_id where i.id=target_issue_id and i.organization_id=target_organization_id; return result;
exception when no_data_found or too_many_rows then raise exception 'issue access denied' using errcode='42501'; end $$;
revoke all on function public.get_phase4a_supervisor_draft(uuid,uuid,text),public.list_phase4a_supervisor_reports(uuid,uuid,int,int,text),public.get_phase4a_report_detail(uuid,uuid,boolean),public.list_phase4a_managed_reports(uuid,uuid,int,int,date,date,uuid,uuid,text,text,text),public.list_phase4a_managed_issues(uuid,uuid,int,int,uuid,text,text,text),public.get_phase4a_managed_issue(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.get_phase4a_supervisor_draft(uuid,uuid,text),public.list_phase4a_supervisor_reports(uuid,uuid,int,int,text),public.get_phase4a_report_detail(uuid,uuid,boolean),public.list_phase4a_managed_reports(uuid,uuid,int,int,date,date,uuid,uuid,text,text,text),public.list_phase4a_managed_issues(uuid,uuid,int,int,uuid,text,text,text),public.get_phase4a_managed_issue(uuid,uuid,uuid) to service_role;
