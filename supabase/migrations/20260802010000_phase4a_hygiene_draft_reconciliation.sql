-- Additive correction: hygiene drafts are reconciled against the current eligible
-- roster. Submitted snapshots remain immutable and are never used as draft state.
create or replace function public.save_phase4a_hygiene_draft(actor_user_id uuid,target_branch_id uuid,staff_answers jsonb)
returns table(id uuid,business_date date,checklist_type text,state text,created_at timestamptz,updated_at timestamptz)
language plpgsql security definer set search_path='' as $$
#variable_conflict use_column
declare c record; report public.checklist_submissions%rowtype; entry jsonb;
begin
 select * into strict c from private.phase4a_actor_context(actor_user_id,target_branch_id);
 if pg_catalog.jsonb_typeof(staff_answers)<>'array' or pg_catalog.jsonb_array_length(staff_answers)>500 then
  raise exception 'invalid hygiene draft' using errcode='22023';
 end if;
 for entry in select value from pg_catalog.jsonb_array_elements(staff_answers) loop
  if (select count(*) from pg_catalog.jsonb_object_keys(entry))<>6
   or not(entry?'staff_id' and entry?'uniform' and entry?'fingernails' and entry?'hair' and entry?'facial_hair' and entry?'remark')
   or pg_catalog.jsonb_typeof(entry->'staff_id')<>'string'
   or entry->>'staff_id' !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
   or pg_catalog.jsonb_typeof(entry->'remark')<>'string' or length(entry->>'remark')>2000
   or entry->>'uniform' not in ('pending','pass','issue') or entry->>'fingernails' not in ('pending','pass','issue')
   or entry->>'hair' not in ('pending','pass','issue') or entry->>'facial_hair' not in ('pending','pass','issue')
   or not exists(select 1 from public.operational_staff_assignments a
    join public.operational_staff s on s.id=a.operational_staff_id
    where s.id=(entry->>'staff_id')::uuid and a.supervisor_team_id=c.team_id and a.active)
  then raise exception 'invalid hygiene draft' using errcode='22023'; end if;
 end loop;
 if (select count(*) from (select value->>'staff_id' from pg_catalog.jsonb_array_elements(staff_answers) group by value->>'staff_id' having count(*)>1)x)>0 then
  raise exception 'invalid hygiene draft' using errcode='22023';
 end if;
 insert into public.checklist_submissions(organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,checklist_type,definition_id,state,branch_name_snapshot,branch_code_snapshot,supervisor_name_snapshot)
 values(c.organization_id,c.branch_id,actor_user_id,c.team_id,c.business_date,'staff_hygiene','staff_hygiene_v1','draft',c.branch_name,c.branch_code,c.supervisor_name)
 on conflict(supervisor_team_id,business_date,checklist_type) where state='draft' do update set updated_at=now() returning * into report;
 delete from public.hygiene_staff_snapshots where submission_id=report.id;
 insert into public.hygiene_staff_snapshots(submission_id,operational_staff_id,display_name_snapshot,operational_roles_snapshot,remark,uniform_result,fingernails_result,hair_result,facial_hair_result)
 select report.id,s.id,s.display_name,a.operational_roles,e.value->>'remark',e.value->>'uniform',e.value->>'fingernails',e.value->>'hair',e.value->>'facial_hair'
 from pg_catalog.jsonb_array_elements(staff_answers)e(value)
 join public.operational_staff s on s.id=(e.value->>'staff_id')::uuid
 join public.operational_staff_assignments a on a.operational_staff_id=s.id and a.supervisor_team_id=c.team_id and a.active
 left join public.operational_staff_duty_statuses d on d.assignment_id=a.id and d.duty_date=c.business_date
 where s.employment_status='active' and coalesce(d.duty_status,'on_duty')='on_duty';
 return query select report.id,report.business_date,report.checklist_type,report.state,report.created_at,report.updated_at;
exception when no_data_found or too_many_rows then raise exception 'draft denied' using errcode='42501'; end $$;
revoke all on function public.save_phase4a_hygiene_draft(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.save_phase4a_hygiene_draft(uuid,uuid,jsonb) to service_role;
