create table if not exists public.operational_staff_health_cards (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  supervisor_team_id uuid not null references public.branch_supervisor_teams(id) on delete restrict,
  operational_staff_id uuid not null references public.operational_staff(id) on delete restrict,
  certificate_number text,
  status text not null default 'not_done',
  place_of_issue text,
  expiry_date date,
  date_issue date,
  occupation text,
  company text,
  branch_name_snapshot text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint operational_staff_health_cards_team_staff_key unique (supervisor_team_id, operational_staff_id),
  constraint operational_staff_health_cards_status_check check (status in ('not_done','pending','passed','done_waiting_id')),
  constraint operational_staff_health_cards_certificate_check check (certificate_number is null or (certificate_number=pg_catalog.btrim(certificate_number) and length(certificate_number) between 1 and 120)),
  constraint operational_staff_health_cards_place_check check (place_of_issue is null or (place_of_issue=pg_catalog.btrim(place_of_issue) and length(place_of_issue) between 1 and 120)),
  constraint operational_staff_health_cards_occupation_check check (occupation is null or (occupation=pg_catalog.btrim(occupation) and length(occupation) between 1 and 120)),
  constraint operational_staff_health_cards_company_check check (company is null or (company=pg_catalog.btrim(company) and length(company) between 1 and 160)),
  constraint operational_staff_health_cards_branch_snapshot_check check (branch_name_snapshot is null or (branch_name_snapshot=pg_catalog.btrim(branch_name_snapshot) and length(branch_name_snapshot) between 1 and 120)),
  constraint operational_staff_health_cards_notes_check check (notes is null or (notes=pg_catalog.btrim(notes) and length(notes) between 1 and 2000))
);

drop trigger if exists operational_staff_health_cards_set_updated_at on public.operational_staff_health_cards;
create trigger operational_staff_health_cards_set_updated_at
before update on public.operational_staff_health_cards
for each row execute function private.set_updated_at();

alter table public.operational_staff_health_cards enable row level security;

revoke all on table public.operational_staff_health_cards from public, anon, authenticated, service_role;
grant select on table public.operational_staff_health_cards to authenticated;

create or replace function private.clean_health_card_optional_text(value text, max_length integer)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare cleaned text := nullif(pg_catalog.btrim(value), '');
begin
  if cleaned is not null and length(cleaned) > max_length then
    raise exception 'invalid health card text' using errcode = '22023';
  end if;
  return cleaned;
end;
$$;

create or replace function private.health_card_payload_date(payload jsonb, field_name text)
returns date
language plpgsql
immutable
set search_path = ''
as $$
declare raw_value text := nullif(pg_catalog.btrim(payload->>field_name), '');
declare parsed_value date;
begin
  if raw_value is null then return null; end if;
  if raw_value !~ '^\d{4}-\d{2}-\d{2}$' then
    raise exception 'invalid health card date' using errcode = '22023';
  end if;
  parsed_value := raw_value::date;
  if to_char(parsed_value, 'YYYY-MM-DD') <> raw_value then
    raise exception 'invalid health card date' using errcode = '22023';
  end if;
  return parsed_value;
exception when datetime_field_overflow or invalid_datetime_format then
  raise exception 'invalid health card date' using errcode = '22023';
end;
$$;

create or replace function public.list_operational_staff_health_cards(actor_user_id uuid, target_branch_id uuid)
returns table(
  id uuid,
  operational_staff_id uuid,
  certificate_number text,
  status text,
  place_of_issue text,
  expiry_date date,
  date_issue date,
  occupation text,
  company text,
  branch_name_snapshot text,
  notes text,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare target_team public.branch_supervisor_teams%rowtype;
begin
  select team.* into strict target_team
  from public.branch_supervisor_teams team
  where team.supervisor_user_id=actor_user_id and team.branch_id=target_branch_id and team.active;

  if not private.actor_owns_operational_team(actor_user_id,target_branch_id,target_team.id) then
    raise exception 'health card access denied' using errcode='42501';
  end if;

  return query
  select card.id, card.operational_staff_id, card.certificate_number, card.status, card.place_of_issue,
    card.expiry_date, card.date_issue, card.occupation, card.company, card.branch_name_snapshot,
    card.notes, card.updated_at
  from public.operational_staff_health_cards card
  join public.operational_staff_assignments assignment
    on assignment.supervisor_team_id=target_team.id
    and assignment.operational_staff_id=card.operational_staff_id
    and assignment.active
  join public.operational_staff staff
    on staff.id=assignment.operational_staff_id
    and staff.branch_id=target_branch_id
    and staff.organization_id=target_team.organization_id
  where card.supervisor_team_id=target_team.id
  order by lower(staff.display_name), staff.id;
exception when no_data_found or too_many_rows then
  raise exception 'health card access denied' using errcode='42501';
end;
$$;

create or replace function public.upsert_operational_staff_health_card(actor_user_id uuid, target_branch_id uuid, payload jsonb)
returns table(
  id uuid,
  operational_staff_id uuid,
  certificate_number text,
  status text,
  place_of_issue text,
  expiry_date date,
  date_issue date,
  occupation text,
  company text,
  branch_name_snapshot text,
  notes text,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare target_team public.branch_supervisor_teams%rowtype;
declare target_staff_id uuid;
declare new_status text := coalesce(nullif(pg_catalog.btrim(payload->>'status'), ''), 'not_done');
declare new_certificate text := private.clean_health_card_optional_text(payload->>'certificate_number', 120);
declare new_place text := private.clean_health_card_optional_text(payload->>'place_of_issue', 120);
declare new_expiry date := private.health_card_payload_date(payload, 'expiry_date');
declare new_issue date := private.health_card_payload_date(payload, 'date_issue');
declare new_occupation text := private.clean_health_card_optional_text(payload->>'occupation', 120);
declare new_company text := private.clean_health_card_optional_text(payload->>'company', 160);
declare new_notes text := private.clean_health_card_optional_text(payload->>'notes', 2000);
declare snapshot_branch text;
begin
  begin
    target_staff_id := (payload->>'operational_staff_id')::uuid;
  exception when invalid_text_representation then
    raise exception 'invalid health card staff' using errcode='22023';
  end;

  select team.* into strict target_team
  from public.branch_supervisor_teams team
  where team.supervisor_user_id=actor_user_id and team.branch_id=target_branch_id and team.active;

  if new_status not in ('not_done','pending','passed','done_waiting_id')
    or not private.actor_owns_operational_team(actor_user_id,target_branch_id,target_team.id)
    or not exists (
      select 1
      from public.operational_staff staff
      join public.operational_staff_assignments assignment
        on assignment.operational_staff_id=staff.id
        and assignment.supervisor_team_id=target_team.id
        and assignment.active
      where staff.id=target_staff_id
        and staff.branch_id=target_branch_id
        and staff.organization_id=target_team.organization_id
        and staff.employment_status='active'
    )
  then raise exception 'health card access denied' using errcode='42501'; end if;

  select branch.name into strict snapshot_branch
  from public.branches branch
  where branch.id=target_branch_id and branch.organization_id=target_team.organization_id and branch.active;

  return query
  insert into public.operational_staff_health_cards(
    organization_id, branch_id, supervisor_team_id, operational_staff_id,
    certificate_number, status, place_of_issue, expiry_date, date_issue,
    occupation, company, branch_name_snapshot, notes
  )
  values (
    target_team.organization_id, target_branch_id, target_team.id, target_staff_id,
    new_certificate, new_status, new_place, new_expiry, new_issue,
    new_occupation, new_company, snapshot_branch, new_notes
  )
  on conflict on constraint operational_staff_health_cards_team_staff_key do update set
    certificate_number=excluded.certificate_number,
    status=excluded.status,
    place_of_issue=excluded.place_of_issue,
    expiry_date=excluded.expiry_date,
    date_issue=excluded.date_issue,
    occupation=excluded.occupation,
    company=excluded.company,
    branch_name_snapshot=excluded.branch_name_snapshot,
    notes=excluded.notes,
    updated_at=now()
  returning operational_staff_health_cards.id, operational_staff_health_cards.operational_staff_id,
    operational_staff_health_cards.certificate_number, operational_staff_health_cards.status,
    operational_staff_health_cards.place_of_issue, operational_staff_health_cards.expiry_date,
    operational_staff_health_cards.date_issue, operational_staff_health_cards.occupation,
    operational_staff_health_cards.company, operational_staff_health_cards.branch_name_snapshot,
    operational_staff_health_cards.notes, operational_staff_health_cards.updated_at;
exception when no_data_found or too_many_rows then
  raise exception 'health card access denied' using errcode='42501';
end;
$$;

revoke all on function public.list_operational_staff_health_cards(uuid, uuid) from public, anon, authenticated;
revoke all on function public.upsert_operational_staff_health_card(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.list_operational_staff_health_cards(uuid, uuid) to service_role;
grant execute on function public.upsert_operational_staff_health_card(uuid, uuid, jsonb) to service_role;
