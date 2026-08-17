alter table public.operational_staff_health_cards
  drop constraint if exists operational_staff_health_cards_status_check;

alter table public.operational_staff_health_cards
  add constraint operational_staff_health_cards_status_check
  check (status in ('not_done','pending','passed','done_waiting_id','failed'));

create or replace function public.upsert_operational_staff_health_card(actor_user_id uuid,target_branch_id uuid,payload jsonb)
returns table(id uuid,operational_staff_id uuid,certificate_number text,status text,place_of_issue text,expiry_date date,
  date_issue date,occupation text,company text,branch_name_snapshot text,notes text,updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare target_staff_id uuid; assignment public.operational_staff_assignments%rowtype;
 new_status text:=coalesce(nullif(pg_catalog.btrim(payload->>'status'),''),'not_done');
 new_certificate text:=private.clean_health_card_optional_text(payload->>'certificate_number',120);
 new_place text:=private.clean_health_card_optional_text(payload->>'place_of_issue',120);
 new_expiry date:=private.health_card_payload_date(payload,'expiry_date'); new_issue date:=private.health_card_payload_date(payload,'date_issue');
 new_occupation text:=private.clean_health_card_optional_text(payload->>'occupation',120);
 new_company text:=private.clean_health_card_optional_text(payload->>'company',160);
 new_notes text:=private.clean_health_card_optional_text(payload->>'notes',2000); snapshot_branch text; staff_org uuid;
begin
  target_staff_id:=(payload->>'operational_staff_id')::uuid;
  select a.* into strict assignment from public.operational_staff_assignments a join public.operational_staff staff
    on staff.id=a.operational_staff_id where a.operational_staff_id=target_staff_id and a.active
      and staff.branch_id=target_branch_id and staff.employment_status='active' for update;
  if new_status not in('not_done','pending','passed','done_waiting_id','failed')
    or not private.actor_can_write_operational_team(actor_user_id,target_branch_id,assignment.operational_team_id)
  then raise exception 'health card access denied' using errcode='42501'; end if;
  select branch.organization_id,branch.name into strict staff_org,snapshot_branch from public.branches branch
    where branch.id=target_branch_id and branch.active;
  return query insert into public.operational_staff_health_cards(organization_id,branch_id,supervisor_team_id,operational_staff_id,
    certificate_number,status,place_of_issue,expiry_date,date_issue,occupation,company,branch_name_snapshot,notes)
  values(staff_org,target_branch_id,assignment.supervisor_team_id,target_staff_id,new_certificate,new_status,new_place,new_expiry,
    new_issue,new_occupation,new_company,snapshot_branch,new_notes)
  on conflict on constraint operational_staff_health_cards_staff_key do update set
    supervisor_team_id=excluded.supervisor_team_id,certificate_number=excluded.certificate_number,status=excluded.status,
    place_of_issue=excluded.place_of_issue,expiry_date=excluded.expiry_date,date_issue=excluded.date_issue,
    occupation=excluded.occupation,company=excluded.company,branch_name_snapshot=excluded.branch_name_snapshot,
    notes=excluded.notes,updated_at=now()
  returning operational_staff_health_cards.id,operational_staff_health_cards.operational_staff_id,
    operational_staff_health_cards.certificate_number,operational_staff_health_cards.status,
    operational_staff_health_cards.place_of_issue,operational_staff_health_cards.expiry_date,
    operational_staff_health_cards.date_issue,operational_staff_health_cards.occupation,operational_staff_health_cards.company,
    operational_staff_health_cards.branch_name_snapshot,operational_staff_health_cards.notes,operational_staff_health_cards.updated_at;
exception when invalid_text_representation then raise exception 'invalid health card staff' using errcode='22023';
when no_data_found or too_many_rows then raise exception 'health card access denied' using errcode='42501';
end $$;
