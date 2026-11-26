-- 20261126003000_supervisor_health_cards.sql
-- Phase 1: Additive supervisor health card storage and RPC foundation.

create table if not exists public.supervisor_health_cards (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  supervisor_user_id uuid not null references auth.users(id) on delete restrict,
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
  constraint supervisor_health_cards_org_supervisor_key unique (organization_id, supervisor_user_id),
  constraint supervisor_health_cards_status_check check (status in ('not_done', 'pending', 'passed', 'done_waiting_id', 'failed')),
  constraint supervisor_health_cards_certificate_check check (
    certificate_number is null or (certificate_number = pg_catalog.btrim(certificate_number) and length(certificate_number) between 1 and 120)
  ),
  constraint supervisor_health_cards_place_check check (
    place_of_issue is null or (place_of_issue = pg_catalog.btrim(place_of_issue) and length(place_of_issue) between 1 and 120)
  ),
  constraint supervisor_health_cards_occupation_check check (
    occupation is null or (occupation = pg_catalog.btrim(occupation) and length(occupation) between 1 and 120)
  ),
  constraint supervisor_health_cards_company_check check (
    company is null or (company = pg_catalog.btrim(company) and length(company) between 1 and 160)
  ),
  constraint supervisor_health_cards_branch_snapshot_check check (
    branch_name_snapshot is null or (branch_name_snapshot = pg_catalog.btrim(branch_name_snapshot) and length(branch_name_snapshot) between 1 and 120)
  ),
  constraint supervisor_health_cards_notes_check check (
    notes is null or (notes = pg_catalog.btrim(notes) and length(notes) between 1 and 2000)
  )
);

drop trigger if exists supervisor_health_cards_set_updated_at on public.supervisor_health_cards;
create trigger supervisor_health_cards_set_updated_at
before update on public.supervisor_health_cards
for each row execute function private.set_updated_at();

alter table public.supervisor_health_cards enable row level security;

revoke all on table public.supervisor_health_cards from public, anon, authenticated, service_role;

drop function if exists public.list_branch_supervisor_health_cards(uuid, uuid);
create or replace function public.list_branch_supervisor_health_cards(
  actor_user_id uuid,
  target_branch_id uuid
)
returns table(
  id uuid,
  supervisor_user_id uuid,
  full_name text,
  full_name_ar text,
  person_code text,
  assignment_role text,
  operational_team_ids uuid[],
  team_assignment_roles jsonb,
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
begin
  if not private.actor_can_read_operational_branch(actor_user_id, target_branch_id) then
    raise exception 'health card access denied' using errcode = '42501';
  end if;

  return query
  select
    card.id,
    assignment.supervisor_user_id,
    profile.full_name,
    profile.full_name_ar,
    profile.person_code,
    case when bool_or(assignment.assignment_role = 'primary') then 'primary'::text else 'backup'::text end as assignment_role,
    pg_catalog.array_agg(distinct team.id order by team.id) as operational_team_ids,
    pg_catalog.jsonb_object_agg(team.id::text, assignment.assignment_role) as team_assignment_roles,
    card.certificate_number,
    coalesce(card.status, 'not_done'::text) as status,
    card.place_of_issue,
    card.expiry_date,
    card.date_issue,
    card.occupation,
    card.company,
    card.branch_name_snapshot,
    card.notes,
    card.updated_at
  from public.branch_operational_team_supervisors assignment
  join public.branch_operational_teams team
    on team.id = assignment.operational_team_id
  join public.branches branch
    on branch.id = team.branch_id
  join public.organizations organization
    on organization.id = branch.organization_id
  join public.profiles profile
    on profile.id = assignment.supervisor_user_id
  join public.branch_memberships membership
    on membership.user_id = assignment.supervisor_user_id
   and membership.branch_id = branch.id
   and membership.role = 'branch_manager'
   and membership.active
  left join public.supervisor_health_cards card
    on card.organization_id = branch.organization_id
   and card.supervisor_user_id = assignment.supervisor_user_id
  where team.branch_id = target_branch_id
    and team.active
    and branch.active
    and organization.active
    and assignment.branch_id = target_branch_id
    and assignment.organization_id = branch.organization_id
    and assignment.active
    and assignment.valid_from <= current_date
    and (assignment.valid_to is null or assignment.valid_to >= current_date)
    and profile.disabled_at is null
  group by
    card.id,
    assignment.supervisor_user_id,
    profile.full_name,
    profile.full_name_ar,
    profile.person_code,
    card.certificate_number,
    card.status,
    card.place_of_issue,
    card.expiry_date,
    card.date_issue,
    card.occupation,
    card.company,
    card.branch_name_snapshot,
    card.notes,
    card.updated_at
  order by pg_catalog.lower(coalesce(profile.full_name, '')), assignment.supervisor_user_id;
end;
$$;

create or replace function public.upsert_supervisor_health_card(
  actor_user_id uuid,
  target_branch_id uuid,
  target_supervisor_user_id uuid,
  payload jsonb
)
returns table(
  id uuid,
  supervisor_user_id uuid,
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
declare
  new_status text := coalesce(nullif(pg_catalog.btrim(payload->>'status'), ''), 'not_done');
  new_certificate text := private.clean_health_card_optional_text(payload->>'certificate_number', 120);
  new_place text := private.clean_health_card_optional_text(payload->>'place_of_issue', 120);
  new_expiry date := private.health_card_payload_date(payload, 'expiry_date');
  new_issue date := private.health_card_payload_date(payload, 'date_issue');
  new_occupation text := private.clean_health_card_optional_text(payload->>'occupation', 120);
  new_company text := private.clean_health_card_optional_text(payload->>'company', 160);
  new_notes text := private.clean_health_card_optional_text(payload->>'notes', 2000);
  target_org uuid;
  snapshot_branch text;
begin
  if actor_user_id is null
    or target_supervisor_user_id is null
    or actor_user_id <> target_supervisor_user_id
    or new_status not in ('not_done', 'pending', 'passed', 'done_waiting_id', 'failed')
    or not private.actor_can_read_operational_branch(actor_user_id, target_branch_id)
  then
    raise exception 'health card access denied' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.branch_operational_team_supervisors assignment
    join public.branch_operational_teams team
      on team.id = assignment.operational_team_id
    where assignment.supervisor_user_id = actor_user_id
      and assignment.branch_id = target_branch_id
      and team.branch_id = target_branch_id
      and team.active
      and assignment.active
      and assignment.valid_from <= current_date
      and (assignment.valid_to is null or assignment.valid_to >= current_date)
      and private.actor_can_write_operational_team(actor_user_id, target_branch_id, team.id)
  ) then
    raise exception 'health card access denied' using errcode = '42501';
  end if;

  select branch.organization_id, branch.name
  into strict target_org, snapshot_branch
  from public.branches branch
  join public.organizations organization on organization.id = branch.organization_id
  where branch.id = target_branch_id
    and branch.active
    and organization.active;

  return query
  insert into public.supervisor_health_cards(
    organization_id,
    supervisor_user_id,
    certificate_number,
    status,
    place_of_issue,
    expiry_date,
    date_issue,
    occupation,
    company,
    branch_name_snapshot,
    notes
  )
  values(
    target_org,
    target_supervisor_user_id,
    new_certificate,
    new_status,
    new_place,
    new_expiry,
    new_issue,
    new_occupation,
    new_company,
    snapshot_branch,
    new_notes
  )
  on conflict on constraint supervisor_health_cards_org_supervisor_key do update set
    certificate_number = excluded.certificate_number,
    status = excluded.status,
    place_of_issue = excluded.place_of_issue,
    expiry_date = excluded.expiry_date,
    date_issue = excluded.date_issue,
    occupation = excluded.occupation,
    company = excluded.company,
    branch_name_snapshot = excluded.branch_name_snapshot,
    notes = excluded.notes,
    updated_at = now()
  returning
    supervisor_health_cards.id,
    supervisor_health_cards.supervisor_user_id,
    supervisor_health_cards.certificate_number,
    supervisor_health_cards.status,
    supervisor_health_cards.place_of_issue,
    supervisor_health_cards.expiry_date,
    supervisor_health_cards.date_issue,
    supervisor_health_cards.occupation,
    supervisor_health_cards.company,
    supervisor_health_cards.branch_name_snapshot,
    supervisor_health_cards.notes,
    supervisor_health_cards.updated_at;
exception
  when no_data_found or too_many_rows then
    raise exception 'health card access denied' using errcode = '42501';
end;
$$;

revoke all on function public.list_branch_supervisor_health_cards(uuid, uuid) from public, anon, authenticated;
revoke all on function public.upsert_supervisor_health_card(uuid, uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.list_branch_supervisor_health_cards(uuid, uuid) to service_role;
grant execute on function public.upsert_supervisor_health_card(uuid, uuid, uuid, jsonb) to service_role;
