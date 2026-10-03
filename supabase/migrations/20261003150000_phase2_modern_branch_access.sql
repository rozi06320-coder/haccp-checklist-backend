begin;

-- Legacy Supervisor-team IDs remain useful historical attribution, but modern
-- branch access must not require the compatibility row to exist.
alter table public.oil_tracking_submissions
  alter column supervisor_team_id drop not null;
alter table public.cold_storage_submissions
  alter column supervisor_team_id drop not null;
alter table public.sales_tracking_reports
  alter column supervisor_team_id drop not null;
alter table public.checklist_submissions
  alter column supervisor_team_id drop not null;
alter table public.checklist_issue_evidence
  alter column supervisor_team_id drop not null;
alter table public.branch_suppliers
  alter column supervisor_team_id drop not null;
alter table public.branch_supplier_receivings
  alter column supervisor_team_id drop not null;

create or replace function private.phase2_branch_context(actor uuid, target_branch uuid)
returns table(
  organization_id uuid,
  branch_id uuid,
  legacy_team_id uuid,
  business_date date,
  branch_name text,
  branch_code text,
  actor_name text
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    branch.organization_id,
    branch.id,
    legacy_team.id,
    private.phase4a_business_date(branch.timezone),
    branch.name,
    branch.code,
    profile.full_name
  from public.profiles profile
  join public.branches branch
    on branch.id = target_branch
   and branch.active
  join public.organizations organization
    on organization.id = branch.organization_id
   and organization.active
  left join lateral (
    select legacy.id
    from public.branch_supervisor_teams legacy
    where legacy.supervisor_user_id = actor
      and legacy.branch_id = branch.id
      and legacy.organization_id = branch.organization_id
    order by legacy.active desc, legacy.created_at, legacy.id
    limit 1
  ) legacy_team on true
  where profile.id = actor
    and profile.disabled_at is null
    and not profile.must_change_password
    and private.actor_can_read_operational_branch(actor, target_branch)
$$;

comment on function private.phase2_branch_context(uuid, uuid) is
  'Authorizes active branch managers through canonical branch access and returns an optional legacy Supervisor-team attribution ID.';

commit;
