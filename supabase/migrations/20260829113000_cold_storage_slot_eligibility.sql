create or replace function private.cold_storage_eligible_slot_at(tz text, as_of timestamptz)
returns text language sql stable strict security definer set search_path=''as $$
  with local_time as (
    select (as_of at time zone tz)::time as value
  )
  select case
    when value >= time '12:00' and value < time '20:00' then '12:00'
    when value >= time '20:00' or value < time '02:00' then '20:00'
    when value >= time '02:00' and value < time '03:00' then '02:00'
    else null
  end
  from local_time
$$;
revoke all on function private.cold_storage_eligible_slot_at(text,timestamptz) from public,anon,authenticated;
grant execute on function private.cold_storage_eligible_slot_at(text,timestamptz) to service_role;

create or replace function private.cold_storage_current_eligible_slot(target_branch_id uuid, as_of timestamptz default pg_catalog.statement_timestamp())
returns text language sql stable security definer set search_path=''as $$
  select private.cold_storage_eligible_slot_at(b.timezone, as_of)
  from public.branches b
  where b.id = target_branch_id
$$;
revoke all on function private.cold_storage_current_eligible_slot(uuid,timestamptz) from public,anon,authenticated;
grant execute on function private.cold_storage_current_eligible_slot(uuid,timestamptz) to service_role;

create or replace function private.enforce_cold_storage_requested_slot(target_branch_id uuid, target_slot text, as_of timestamptz default pg_catalog.statement_timestamp())
returns void language plpgsql stable security definer set search_path=''as $$
declare eligible_slot text;
begin
  eligible_slot := private.cold_storage_current_eligible_slot(target_branch_id, as_of);
  if eligible_slot is null or target_slot is distinct from eligible_slot then
    raise exception 'cold storage slot is not currently eligible' using errcode='22023';
  end if;
end$$;
revoke all on function private.enforce_cold_storage_requested_slot(uuid,text,timestamptz) from public,anon,authenticated;
grant execute on function private.enforce_cold_storage_requested_slot(uuid,text,timestamptz) to service_role;

create or replace function private.enforce_cold_storage_draft_slot(target_branch_id uuid, target_submission_id uuid, as_of timestamptz default pg_catalog.statement_timestamp())
returns void language plpgsql stable security definer set search_path=''as $$
declare eligible_slot text;
begin
  eligible_slot := private.cold_storage_current_eligible_slot(target_branch_id, as_of);
  if eligible_slot is null then
    raise exception 'cold storage slot is not currently eligible' using errcode='22023';
  end if;
  if exists (
    select 1
    from public.cold_storage_readings r
    where r.submission_id = target_submission_id
      and r.submitted_at is null
      and r.slot is distinct from eligible_slot
      and (
        r.temperature_c is not null
        or pg_catalog.length(pg_catalog.btrim(coalesce(r.corrective_action,''))) > 0
      )
  ) then
    raise exception 'cold storage draft slot is not currently eligible' using errcode='22023';
  end if;
end$$;
revoke all on function private.enforce_cold_storage_draft_slot(uuid,uuid,timestamptz) from public,anon,authenticated;
grant execute on function private.enforce_cold_storage_draft_slot(uuid,uuid,timestamptz) to service_role;

create or replace function public.save_cold_storage_draft(actor_user_id uuid,target_branch_id uuid,expected_revision bigint,equipment jsonb,readings jsonb)
returns jsonb language plpgsql security definer set search_path=''as $$declare s public.cold_storage_submissions%rowtype;begin
 s:=private.upsert_cold_storage_submission(actor_user_id,target_branch_id,expected_revision,equipment,readings);
 perform private.enforce_cold_storage_draft_slot(target_branch_id,s.id);
 return public.get_cold_storage_current_state(actor_user_id,target_branch_id);end$$;

create or replace function public.submit_cold_storage_slot(actor_user_id uuid,target_branch_id uuid,expected_revision bigint,slot text,idempotency_key uuid,request_hash text,equipment jsonb,readings jsonb)
returns jsonb language plpgsql security definer set search_path=''as $$declare s public.cold_storage_submissions%rowtype;prior record;submitted_time timestamptz;snapshot_equipment jsonb;begin
 if length(request_hash)<>64 then raise exception'invalid cold storage slot submit'using errcode='22023';end if;
 insert into public.cold_storage_submission_idempotency(actor_user_id,slot,idempotency_key,request_hash)values(actor_user_id,slot,idempotency_key,request_hash)on conflict do nothing;
 select*into strict prior from public.cold_storage_submission_idempotency x where x.actor_user_id=submit_cold_storage_slot.actor_user_id and x.slot=submit_cold_storage_slot.slot and x.idempotency_key=submit_cold_storage_slot.idempotency_key for update;
 if prior.request_hash<>request_hash then raise exception'idempotency conflict'using errcode='23505';end if;if prior.submission_id is not null then return private.cold_storage_current_result(actor_user_id,target_branch_id,prior.submission_id);end if;
 perform private.phase2_branch_context(actor_user_id,target_branch_id);
 perform private.enforce_cold_storage_requested_slot(target_branch_id,slot);
 s:=private.upsert_cold_storage_submission(actor_user_id,target_branch_id,expected_revision,equipment,readings);snapshot_equipment:=private.cold_storage_snapshot_equipment(s.id);perform private.validate_cold_storage_slot_submit(slot,snapshot_equipment,readings);select*into strict s from public.cold_storage_submissions where id=s.id for update;
 if exists(select 1 from public.cold_storage_readings r where r.submission_id=s.id and r.slot=submit_cold_storage_slot.slot and r.submitted_at is not null)then raise exception'cold storage slot already submitted'using errcode='23505';end if;
 submitted_time:=now();update public.cold_storage_readings r set submitted_at=submitted_time,submitted_by_user_id=actor_user_id,temperature_c=private.cold_storage_numeric_field(entry.row_value,'temperature_c'),status=case when private.cold_storage_numeric_field(entry.row_value,'temperature_c')<5 then'pass'else'fail'end,corrective_action=case when private.cold_storage_numeric_field(entry.row_value,'temperature_c')>=5 then btrim(coalesce(entry.row_value->>'corrective_action',''))else coalesce(entry.row_value->>'corrective_action','')end
 from pg_catalog.jsonb_array_elements(readings)entry(row_value)join public.cold_storage_equipment e on e.submission_id=s.id and e.equipment_id=btrim(entry.row_value->>'equipment_id')and e.active where r.submission_id=s.id and r.equipment_id=e.equipment_id and r.slot=submit_cold_storage_slot.slot;
 insert into public.cold_storage_issues(submission_id,equipment_id,slot,temperature_c,corrective_action)select s.id,r.equipment_id,r.slot,r.temperature_c,r.corrective_action from public.cold_storage_readings r join public.cold_storage_equipment e on e.submission_id=r.submission_id and e.equipment_id=r.equipment_id where r.submission_id=s.id and r.slot=submit_cold_storage_slot.slot and e.active and r.temperature_c>=5;
 update public.cold_storage_submissions set state=case when not exists(select 1 from public.cold_storage_equipment e cross join(values('12:00'),('20:00'),('02:00'))expected(slot)where e.submission_id=s.id and e.active and not exists(select 1 from public.cold_storage_readings r where r.submission_id=e.submission_id and r.equipment_id=e.equipment_id and r.slot=expected.slot and r.submitted_at is not null))then'submitted'else'draft'end,branch_revision=branch_revision+1,updated_by_user_id=actor_user_id where id=s.id returning*into s;
 update public.cold_storage_submission_idempotency set submission_id=s.id where cold_storage_submission_idempotency.actor_user_id=submit_cold_storage_slot.actor_user_id and cold_storage_submission_idempotency.slot=submit_cold_storage_slot.slot and cold_storage_submission_idempotency.idempotency_key=submit_cold_storage_slot.idempotency_key;
 return private.cold_storage_current_result(actor_user_id,target_branch_id,s.id);
exception when no_data_found or too_many_rows then raise exception'cold storage submit denied'using errcode='42501';end$$;

revoke all on function public.save_cold_storage_draft(uuid,uuid,bigint,jsonb,jsonb),public.submit_cold_storage_slot(uuid,uuid,bigint,text,uuid,text,jsonb,jsonb)from public,anon,authenticated;
grant execute on function public.save_cold_storage_draft(uuid,uuid,bigint,jsonb,jsonb),public.submit_cold_storage_slot(uuid,uuid,bigint,text,uuid,text,jsonb,jsonb)to service_role;

do $$
declare definition text;
begin
  select pg_catalog.pg_get_functiondef('private.cold_storage_managed_missed_issue_rows(uuid)'::regprocedure) into definition;
  execute replace(replace(definition,'Refrigerator & Freezer missed scheduled check','Chiller & Freezer missed scheduled check'),'scheduled Refrigerator & Freezer check','scheduled Chiller & Freezer check');
  select pg_catalog.pg_get_functiondef('public.get_cold_storage_managed_report_detail(uuid,uuid,uuid)'::regprocedure) into definition;
  execute replace(definition,'scheduled Refrigerator & Freezer check','scheduled Chiller & Freezer check');
end$$;
