-- Phase 2: one shared Cold Storage ledger per branch and business date.
drop function if exists public.save_cold_storage_draft(uuid,uuid,jsonb,jsonb);
drop function if exists public.submit_cold_storage_slot(uuid,uuid,text,uuid,text,jsonb,jsonb);
drop function if exists private.upsert_cold_storage_submission(uuid,uuid,jsonb,jsonb);

create or replace function public.get_cold_storage_current_state(actor_user_id uuid,target_branch_id uuid)
returns jsonb language plpgsql security definer set search_path=''as $$declare c record;s public.cold_storage_submissions%rowtype;equipment_result jsonb;readings_result jsonb;has_submitted boolean:=false;begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 select*into s from public.cold_storage_submissions x where x.organization_id=c.organization_id and x.branch_id=c.branch_id and x.business_date=c.business_date;
 if s.id is not null then select exists(select 1 from public.cold_storage_readings r where r.submission_id=s.id and r.submitted_at is not null)into has_submitted;end if;
 if has_submitted then
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id',e.id,'equipment_id',e.equipment_id,'equipment_name',e.equipment_name,'equipment_type',e.equipment_type,'active',e.active)order by lower(e.equipment_name),e.equipment_id),'[]'::jsonb)into equipment_result from public.cold_storage_equipment e where e.submission_id=s.id;
 else
  select coalesce(pg_catalog.jsonb_agg(q.item order by q.sort_name,q.equipment_id),'[]'::jsonb)into equipment_result from(
   select m.id::text equipment_id,lower(m.name)sort_name,pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object('id',e.id,'equipment_id',m.id::text,'equipment_name',m.name,'equipment_type',m.equipment_type,'active',true))item
   from public.branch_cold_storage_equipment m left join lateral(select x.id from public.cold_storage_equipment x where x.submission_id=s.id and x.master_equipment_id=m.id limit 1)e on true
   where m.organization_id=c.organization_id and m.branch_id=c.branch_id and m.active
   union all select e.equipment_id,lower(e.equipment_name),pg_catalog.jsonb_build_object('id',e.id,'equipment_id',e.equipment_id,'equipment_name',e.equipment_name,'equipment_type',e.equipment_type,'active',e.active)from public.cold_storage_equipment e where e.submission_id=s.id and e.master_equipment_id is null
  )q;
 end if;
 select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('id',r.id,'equipment_id',coalesce(e.master_equipment_id::text,r.equipment_id),'slot',r.slot,'temperature_c',r.temperature_c,'status',r.status,'corrective_action',r.corrective_action,'submitted_at',r.submitted_at)order by coalesce(e.master_equipment_id::text,r.equipment_id),case r.slot when'12:00'then 1 when'20:00'then 2 when'02:00'then 3 when'3:00'then 4 else 5 end),'[]'::jsonb)into readings_result
 from public.cold_storage_readings r join public.cold_storage_equipment e on e.submission_id=r.submission_id and e.equipment_id=r.equipment_id left join public.branch_cold_storage_equipment m on m.id=e.master_equipment_id and m.organization_id=c.organization_id and m.branch_id=c.branch_id where r.submission_id=s.id and(has_submitted or e.master_equipment_id is null or m.active);
 return pg_catalog.jsonb_build_object('submission_id',s.id,'business_date',c.business_date,'state',coalesce(s.state,'none'),'revision',coalesce(s.branch_revision,0),'equipment',equipment_result,'readings',readings_result);
exception when no_data_found or too_many_rows then raise exception'cold storage state denied'using errcode='42501';end$$;

create function private.upsert_cold_storage_submission(actor_user_id uuid,target_branch_id uuid,expected_revision bigint,equipment jsonb,readings jsonb)
returns public.cold_storage_submissions language plpgsql security definer set search_path=''as $$
#variable_conflict use_column
declare c record;s public.cold_storage_submissions%rowtype;has_submitted boolean;resolved_equipment jsonb;
begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||c.business_date::text||':cold_storage',0));
 select*into s from public.cold_storage_submissions x where x.organization_id=c.organization_id and x.branch_id=c.branch_id and x.business_date=c.business_date for update;
 if(s.id is null and coalesce(expected_revision,0)<>0)or(s.id is not null and coalesce(expected_revision,-1)<>s.branch_revision)then raise exception'cold storage changed'using errcode='40001';end if;
 if s.id is null then insert into public.cold_storage_submissions(organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,state,branch_name_snapshot,supervisor_name_snapshot,team_name_snapshot,branch_revision,updated_by_user_id)
  values(c.organization_id,c.branch_id,actor_user_id,c.legacy_team_id,c.business_date,'draft',c.branch_name,c.actor_name,c.actor_name||' Team',1,actor_user_id)returning*into s;
 else update public.cold_storage_submissions set branch_revision=branch_revision+1,updated_by_user_id=actor_user_id,updated_at=now()where id=s.id returning*into s;end if;
 select exists(select 1 from public.cold_storage_readings r where r.submission_id=s.id and r.submitted_at is not null)into has_submitted;
 if has_submitted then perform private.validate_cold_storage_equipment(equipment);if not private.cold_storage_equipment_set_matches(s.id,equipment)then raise exception'submitted cold storage equipment is immutable'using errcode='23505';end if;resolved_equipment:=private.cold_storage_snapshot_equipment(s.id);
 else resolved_equipment:=private.resolve_cold_storage_equipment_roster(c.organization_id,c.branch_id,equipment);perform private.replace_cold_storage_equipment(s.id,resolved_equipment);resolved_equipment:=private.cold_storage_snapshot_equipment(s.id);end if;
 perform private.validate_cold_storage_readings(resolved_equipment,readings);perform private.replace_cold_storage_unsubmitted_readings(s.id,readings);return s;
exception when no_data_found or too_many_rows then raise exception'cold storage operation denied'using errcode='42501';end$$;

create function public.save_cold_storage_draft(actor_user_id uuid,target_branch_id uuid,expected_revision bigint,equipment jsonb,readings jsonb)
returns jsonb language plpgsql security definer set search_path=''as $$begin perform private.upsert_cold_storage_submission(actor_user_id,target_branch_id,expected_revision,equipment,readings);return public.get_cold_storage_current_state(actor_user_id,target_branch_id);end$$;

create function public.submit_cold_storage_slot(actor_user_id uuid,target_branch_id uuid,expected_revision bigint,slot text,idempotency_key uuid,request_hash text,equipment jsonb,readings jsonb)
returns jsonb language plpgsql security definer set search_path=''as $$declare s public.cold_storage_submissions%rowtype;prior record;submitted_time timestamptz;snapshot_equipment jsonb;begin
 if length(request_hash)<>64 then raise exception'invalid cold storage slot submit'using errcode='22023';end if;
 insert into public.cold_storage_submission_idempotency(actor_user_id,slot,idempotency_key,request_hash)values(actor_user_id,slot,idempotency_key,request_hash)on conflict do nothing;
 select*into strict prior from public.cold_storage_submission_idempotency x where x.actor_user_id=submit_cold_storage_slot.actor_user_id and x.slot=submit_cold_storage_slot.slot and x.idempotency_key=submit_cold_storage_slot.idempotency_key for update;
 if prior.request_hash<>request_hash then raise exception'idempotency conflict'using errcode='23505';end if;if prior.submission_id is not null then return private.cold_storage_current_result(actor_user_id,target_branch_id,prior.submission_id);end if;
 s:=private.upsert_cold_storage_submission(actor_user_id,target_branch_id,expected_revision,equipment,readings);snapshot_equipment:=private.cold_storage_snapshot_equipment(s.id);perform private.validate_cold_storage_slot_submit(slot,snapshot_equipment,readings);select*into strict s from public.cold_storage_submissions where id=s.id for update;
 if exists(select 1 from public.cold_storage_readings r where r.submission_id=s.id and r.slot=submit_cold_storage_slot.slot and r.submitted_at is not null)then raise exception'cold storage slot already submitted'using errcode='23505';end if;
 submitted_time:=now();update public.cold_storage_readings r set submitted_at=submitted_time,submitted_by_user_id=actor_user_id,temperature_c=private.cold_storage_numeric_field(entry.row_value,'temperature_c'),status=case when private.cold_storage_numeric_field(entry.row_value,'temperature_c')<5 then'pass'else'fail'end,corrective_action=case when private.cold_storage_numeric_field(entry.row_value,'temperature_c')>=5 then btrim(coalesce(entry.row_value->>'corrective_action',''))else coalesce(entry.row_value->>'corrective_action','')end
 from pg_catalog.jsonb_array_elements(readings)entry(row_value)join public.cold_storage_equipment e on e.submission_id=s.id and e.equipment_id=btrim(entry.row_value->>'equipment_id')and e.active where r.submission_id=s.id and r.equipment_id=e.equipment_id and r.slot=submit_cold_storage_slot.slot;
 insert into public.cold_storage_issues(submission_id,equipment_id,slot,temperature_c,corrective_action)select s.id,r.equipment_id,r.slot,r.temperature_c,r.corrective_action from public.cold_storage_readings r join public.cold_storage_equipment e on e.submission_id=r.submission_id and e.equipment_id=r.equipment_id where r.submission_id=s.id and r.slot=submit_cold_storage_slot.slot and e.active and r.temperature_c>=5;
 update public.cold_storage_submissions set state=case when not exists(select 1 from public.cold_storage_equipment e cross join(values('12:00'),('20:00'),('02:00'))expected(slot)where e.submission_id=s.id and e.active and not exists(select 1 from public.cold_storage_readings r where r.submission_id=e.submission_id and r.equipment_id=e.equipment_id and r.slot=expected.slot and r.submitted_at is not null))then'submitted'else'draft'end,branch_revision=branch_revision+1,updated_by_user_id=actor_user_id where id=s.id returning*into s;
 update public.cold_storage_submission_idempotency set submission_id=s.id where cold_storage_submission_idempotency.actor_user_id=submit_cold_storage_slot.actor_user_id and cold_storage_submission_idempotency.slot=submit_cold_storage_slot.slot and cold_storage_submission_idempotency.idempotency_key=submit_cold_storage_slot.idempotency_key;
 return private.cold_storage_current_result(actor_user_id,target_branch_id,s.id);
exception when no_data_found or too_many_rows then raise exception'cold storage submit denied'using errcode='42501';end$$;

revoke all on function private.upsert_cold_storage_submission(uuid,uuid,bigint,jsonb,jsonb),public.save_cold_storage_draft(uuid,uuid,bigint,jsonb,jsonb),public.submit_cold_storage_slot(uuid,uuid,bigint,text,uuid,text,jsonb,jsonb)from public,anon,authenticated;
grant execute on function public.save_cold_storage_draft(uuid,uuid,bigint,jsonb,jsonb),public.submit_cold_storage_slot(uuid,uuid,bigint,text,uuid,text,jsonb,jsonb)to service_role;
