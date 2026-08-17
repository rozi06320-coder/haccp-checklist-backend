-- Preserve Phase 1 behavior while avoiding an unused lock variable and a
-- temporary-table dependency that plpgsql_check cannot validate statically.

create or replace function public.update_operational_team_staff(actor_user_id uuid,target_branch_id uuid,target_staff_id uuid,
  new_display_name text,new_employment_status text,new_operational_roles text[],new_staff_code text,new_company_name text,
  new_iqama_number text,new_iqama_expiry_date date,new_phone_number text,new_email text)
returns table(staff_id uuid,assignment_id uuid,duplicate_name_warning boolean,iqama_number text,iqama_expiry_date date,phone_number text,email text)
language plpgsql security definer set search_path = '' as $$
declare assignment_row public.operational_staff_assignments%rowtype;
 clean_name text:=pg_catalog.regexp_replace(pg_catalog.btrim(new_display_name),'[[:space:]]+',' ','g');
 clean_code text:=private.clean_operational_staff_code(new_staff_code);
 clean_company text:=private.clean_operational_staff_company_name(new_company_name);
 clean_iqama text:=private.clean_operational_staff_optional_text(new_iqama_number,80);
 clean_phone text:=private.clean_operational_staff_optional_text(new_phone_number,40);
 clean_email text:=private.clean_operational_staff_email(new_email);
begin
  select assignment.* into strict assignment_row
  from public.operational_staff_assignments assignment
  join public.operational_staff staff on staff.id=assignment.operational_staff_id
  where assignment.operational_staff_id=target_staff_id and assignment.active
    and staff.branch_id=target_branch_id
  for update of assignment,staff;
  if not private.actor_can_write_operational_team(actor_user_id,target_branch_id,assignment_row.operational_team_id)
    or new_employment_status not in('active','inactive') or length(clean_name) not between 1 and 120
    or length(coalesce(clean_company,'')) not between 1 and 160
    or (clean_code is not null and length(clean_code) not between 1 and 80)
    or not private.operational_roles_are_valid(new_operational_roles)
  then raise exception 'staff operation denied' using errcode='42501'; end if;
  update public.operational_staff set display_name=clean_name,company_name=clean_company,staff_code=clean_code,
    iqama_number=clean_iqama,iqama_expiry_date=new_iqama_expiry_date,phone_number=clean_phone,email=clean_email,
    employment_status=new_employment_status,
    deactivated_at=case when new_employment_status='inactive' then coalesce(deactivated_at,now()) else null end,
    deactivated_by=case when new_employment_status='inactive' then coalesce(deactivated_by,actor_user_id) else null end
  where id=target_staff_id;
  update public.operational_staff_assignments set operational_roles=new_operational_roles,
    active=(new_employment_status='active'),valid_to=case when new_employment_status='inactive' then current_date else null end
  where id=assignment_row.id returning * into assignment_row;
  return query select target_staff_id,assignment_row.id,false,clean_iqama,new_iqama_expiry_date,clean_phone,clean_email;
exception when unique_violation then raise exception 'staff identity already exists' using errcode='23505';
when no_data_found or too_many_rows then raise exception 'staff operation denied' using errcode='42501';
end $$;

create or replace function public.save_operational_staff_monthly_evaluation(actor_user_id uuid,target_branch_id uuid,
  target_staff_id uuid,requested_month date,new_evaluator_name text,score_payload jsonb,new_status text)
returns table(id uuid,operational_staff_id uuid,evaluation_month date,evaluator_name text,status text,average_score numeric,scores jsonb,updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare assignment public.operational_staff_assignments%rowtype; saved_id uuid; computed_average numeric; normalized_scores jsonb;
 clean_evaluator text:=private.clean_monthly_evaluation_text(new_evaluator_name,120); completed boolean:=new_status='completed';
begin
  if requested_month is null or requested_month<>pg_catalog.date_trunc('month',requested_month)::date
    or new_status not in('draft','completed') then raise exception 'invalid monthly evaluation' using errcode='22023'; end if;
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'section',parsed.section,'factor_key',parsed.factor_key,'factor_label',parsed.factor_label,
      'rating',parsed.rating,'comment',parsed.comment
    )),'[]'::jsonb),
    case when count(parsed.rating)=0 then null else pg_catalog.round(avg(parsed.rating)::numeric,2) end
  into normalized_scores,computed_average
  from private.monthly_evaluation_scores(score_payload,completed) parsed;
  select a.* into strict assignment from public.operational_staff_assignments a join public.operational_staff staff
    on staff.id=a.operational_staff_id where a.operational_staff_id=target_staff_id and a.active
      and staff.branch_id=target_branch_id and staff.employment_status='active' for update;
  if not private.actor_can_write_operational_team(actor_user_id,target_branch_id,assignment.operational_team_id)
  then raise exception 'monthly evaluation access denied' using errcode='42501'; end if;
  insert into public.operational_staff_monthly_evaluations(organization_id,branch_id,supervisor_team_id,operational_staff_id,
    evaluation_month,evaluator_name,status,average_score,evaluated_by_user_id)
  select staff.organization_id,target_branch_id,assignment.supervisor_team_id,target_staff_id,requested_month,clean_evaluator,
    new_status,computed_average,actor_user_id from public.operational_staff staff where staff.id=target_staff_id
  on conflict on constraint operational_staff_monthly_evaluations_staff_month_key do update set
    supervisor_team_id=excluded.supervisor_team_id,evaluator_name=excluded.evaluator_name,status=excluded.status,
    average_score=excluded.average_score,evaluated_by_user_id=excluded.evaluated_by_user_id,updated_at=now()
  returning operational_staff_monthly_evaluations.id into saved_id;
  delete from public.operational_staff_monthly_evaluation_scores where evaluation_id=saved_id;
  insert into public.operational_staff_monthly_evaluation_scores(evaluation_id,section,factor_key,factor_label,rating,comment)
    select saved_id,payload.section,payload.factor_key,payload.factor_label,payload.rating,payload.comment
    from pg_catalog.jsonb_to_recordset(normalized_scores) as payload(
      section text,factor_key text,factor_label text,rating integer,comment text
    );
  return query select evaluation.id,evaluation.operational_staff_id,evaluation.evaluation_month,evaluation.evaluator_name,
    evaluation.status,evaluation.average_score,coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'section',score.section,'factor_key',score.factor_key,'factor_label',score.factor_label,'rating',score.rating,
      'comment',score.comment) order by score.section,score.factor_key) filter(where score.id is not null),'[]'::jsonb),evaluation.updated_at
  from public.operational_staff_monthly_evaluations evaluation
  left join public.operational_staff_monthly_evaluation_scores score on score.evaluation_id=evaluation.id
  where evaluation.id=saved_id group by evaluation.id;
exception when no_data_found or too_many_rows then raise exception 'monthly evaluation access denied' using errcode='42501';
end $$;

revoke all on function public.update_operational_team_staff(uuid,uuid,uuid,text,text,text[],text,text,text,date,text,text),
  public.save_operational_staff_monthly_evaluation(uuid,uuid,uuid,date,text,jsonb,text)
  from public,anon,authenticated;
grant execute on function public.update_operational_team_staff(uuid,uuid,uuid,text,text,text[],text,text,text,date,text,text),
  public.save_operational_staff_monthly_evaluation(uuid,uuid,uuid,date,text,jsonb,text)
  to service_role;
