-- Cold Storage equipment master Phase 1: branch-scoped definitions only.
-- Existing public.cold_storage_equipment rows remain submission snapshots.

create table public.branch_cold_storage_equipment (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null
    references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  name text not null,
  equipment_type text not null,
  active boolean not null default true,
  created_by uuid not null
    references public.profiles(id) on delete restrict,
  updated_by uuid null
    references public.profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint branch_cold_storage_equipment_branch_scope_fkey
    foreign key (branch_id, organization_id)
    references public.branches(id, organization_id)
    on delete restrict,
  constraint branch_cold_storage_equipment_equipment_type_check
    check (equipment_type in ('refrigerator', 'freezer')),
  constraint branch_cold_storage_equipment_name_check
    check (name = pg_catalog.btrim(name) and pg_catalog.length(name) between 1 and 120),
  constraint branch_cold_storage_equipment_id_scope_key
    unique (id, branch_id, organization_id)
);

create unique index branch_cold_storage_equipment_active_name_key
  on public.branch_cold_storage_equipment (
    branch_id,
    pg_catalog.lower(name)
  )
  where active;

create index branch_cold_storage_equipment_branch_active_idx
  on public.branch_cold_storage_equipment (branch_id, active, name);

create trigger branch_cold_storage_equipment_set_updated_at
before update on public.branch_cold_storage_equipment
for each row execute function private.set_updated_at();

alter table public.branch_cold_storage_equipment enable row level security;

revoke all on table public.branch_cold_storage_equipment
  from public, anon, authenticated, service_role;

alter table public.cold_storage_submissions
  add constraint cold_storage_submissions_id_scope_key
  unique (id, branch_id, organization_id);

alter table public.cold_storage_equipment
  add column master_equipment_id uuid null,
  add column organization_id uuid null,
  add column branch_id uuid null,
  add constraint cold_storage_equipment_master_scope_presence_check check (
    (master_equipment_id is null and organization_id is null and branch_id is null)
    or
    (master_equipment_id is not null and organization_id is not null and branch_id is not null)
  ),
  add constraint cold_storage_equipment_submission_scope_fkey
    foreign key (submission_id, branch_id, organization_id)
    references public.cold_storage_submissions(id, branch_id, organization_id)
    on delete cascade,
  add constraint cold_storage_equipment_master_scope_fkey
    foreign key (master_equipment_id, branch_id, organization_id)
    references public.branch_cold_storage_equipment(id, branch_id, organization_id)
    on delete restrict;

create index cold_storage_equipment_master_equipment_idx
  on public.cold_storage_equipment (master_equipment_id)
  where master_equipment_id is not null;

comment on table public.branch_cold_storage_equipment is
  'Branch-level Cold Storage equipment master. Current and historical checklist rows continue to use submission-scoped snapshots.';

comment on column public.cold_storage_equipment.master_equipment_id is
  'Nullable link from a submission snapshot to its branch master definition. Legacy snapshots remain unlinked.';

create function private.backfill_branch_cold_storage_equipment_master()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  latest_submission record;
  snapshot_equipment record;
  new_master_id uuid;
begin
  for latest_submission in
    with ranked_submissions as (
      select
        submission.id,
        submission.organization_id,
        submission.branch_id,
        submission.supervisor_user_id,
        pg_catalog.row_number() over (
          partition by submission.branch_id
          order by
            submission.business_date desc,
            submission.updated_at desc,
            submission.id desc
        ) as roster_rank
      from public.cold_storage_submissions submission
      where exists (
        select 1
        from public.cold_storage_equipment equipment
        where equipment.submission_id = submission.id
      )
    )
    select ranked.id,
      ranked.organization_id,
      ranked.branch_id,
      ranked.supervisor_user_id
    from ranked_submissions ranked
    where ranked.roster_rank = 1
    order by ranked.branch_id
  loop
    -- Re-running the helper must never merge into an already-established master.
    if exists (
      select 1
      from public.branch_cold_storage_equipment master
      where master.branch_id = latest_submission.branch_id
    ) then
      continue;
    end if;

    -- Skip the complete branch roster when two active snapshots normalize to
    -- the same name. Choosing one would silently merge distinct equipment.
    if exists (
      select 1
      from public.cold_storage_equipment equipment
      where equipment.submission_id = latest_submission.id
        and equipment.active
      group by pg_catalog.lower(pg_catalog.btrim(equipment.equipment_name))
      having pg_catalog.count(*) > 1
    ) then
      continue;
    end if;

    for snapshot_equipment in
      select equipment.id,
        equipment.equipment_name,
        equipment.equipment_type,
        equipment.active
      from public.cold_storage_equipment equipment
      where equipment.submission_id = latest_submission.id
      order by equipment.id
    loop
      insert into public.branch_cold_storage_equipment (
        organization_id,
        branch_id,
        name,
        equipment_type,
        active,
        created_by
      ) values (
        latest_submission.organization_id,
        latest_submission.branch_id,
        snapshot_equipment.equipment_name,
        snapshot_equipment.equipment_type,
        snapshot_equipment.active,
        latest_submission.supervisor_user_id
      )
      returning id into new_master_id;

      update public.cold_storage_equipment equipment
      set master_equipment_id = new_master_id,
        organization_id = latest_submission.organization_id,
        branch_id = latest_submission.branch_id
      where equipment.id = snapshot_equipment.id;
    end loop;
  end loop;
end;
$$;

revoke all on function private.backfill_branch_cold_storage_equipment_master()
  from public, anon, authenticated, service_role;

comment on function private.backfill_branch_cold_storage_equipment_master() is
  'Conservatively seeds empty branch masters from one latest unambiguous submission roster and links only that source snapshot.';

select private.backfill_branch_cold_storage_equipment_master();
