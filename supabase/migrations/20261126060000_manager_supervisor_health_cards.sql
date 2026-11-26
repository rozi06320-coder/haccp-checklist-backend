-- 20261126060000_manager_supervisor_health_cards.sql
-- Phase 1: Additive Manager read RPC (v3) wrapping list_managed_people_directory_v2
-- to include active primary/backup supervisor Health Cards without modifying v1/v2 or any table data.

create or replace function public.list_managed_people_directory_v3(
  actor_user_id uuid,
  target_organization_id uuid,
  branch_filter uuid default null,
  requested_month date default null,
  search_term text default null,
  code_filter text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  result jsonb;
  supervisor_cards jsonb;
begin
  if not private.actor_manages_active_organization(actor_user_id, target_organization_id)
     or (
       branch_filter is not null
       and not exists (
         select 1
         from public.branches branch
         where branch.id = branch_filter
           and branch.organization_id = target_organization_id
       )
     )
  then
    raise exception 'people directory access denied' using errcode = '42501';
  end if;

  result := public.list_managed_people_directory_v2(
    actor_user_id,
    target_organization_id,
    branch_filter,
    requested_month,
    search_term,
    code_filter
  );

  with active_supervisor_assignments as (
    select
      assignment.supervisor_user_id,
      assignment.assignment_role,
      team.id as team_id,
      branch.id as branch_id,
      branch.name as branch_name,
      branch.name_ar as branch_name_ar,
      profile.full_name,
      profile.full_name_ar,
      profile.person_code,
      card.id as card_id,
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
     and team.organization_id = target_organization_id
     and team.branch_id = assignment.branch_id
     and team.active
    join public.branches branch
      on branch.id = team.branch_id
     and branch.organization_id = target_organization_id
     and branch.active
    join public.organizations organization
      on organization.id = target_organization_id
     and organization.active
    join public.profiles profile
      on profile.id = assignment.supervisor_user_id
     and profile.disabled_at is null
    join public.branch_memberships membership
      on membership.user_id = assignment.supervisor_user_id
     and membership.branch_id = branch.id
     and membership.role = 'branch_manager'
     and membership.active
    left join public.supervisor_health_cards card
      on card.organization_id = target_organization_id
     and card.supervisor_user_id = assignment.supervisor_user_id
    where assignment.organization_id = target_organization_id
      and assignment.active
      and assignment.valid_from <= current_date
      and (assignment.valid_to is null or assignment.valid_to >= current_date)
      and (branch_filter is null or branch.id = branch_filter)
  ),
  deduplicated_supervisors as (
    select
      s.supervisor_user_id,
      s.card_id,
      coalesce(
        nullif(pg_catalog.btrim(s.full_name), ''),
        nullif(pg_catalog.btrim(s.full_name_ar), ''),
        'Supervisor'::text
      ) as display_name,
      s.full_name_ar as display_name_ar,
      s.person_code,
      case when bool_or(s.assignment_role = 'primary') then 'primary'::text else 'backup'::text end as assignment_role,
      (pg_catalog.array_agg(distinct s.branch_id order by s.branch_id))[1] as branch_id,
      pg_catalog.string_agg(distinct s.branch_name, ', ' order by s.branch_name) as branch_name,
      pg_catalog.string_agg(
        distinct coalesce(nullif(pg_catalog.btrim(s.branch_name_ar), ''), s.branch_name),
        '، '
        order by coalesce(nullif(pg_catalog.btrim(s.branch_name_ar), ''), s.branch_name)
      ) as branch_name_ar,
      (
        select pg_catalog.jsonb_agg(
          pg_catalog.jsonb_build_object(
            'id', b.branch_id,
            'name', b.branch_name,
            'name_ar', b.branch_name_ar
          )
          order by pg_catalog.lower(b.branch_name), b.branch_id
        )
        from (
          select distinct a2.branch_id, a2.branch_name, a2.branch_name_ar
          from active_supervisor_assignments a2
          where a2.supervisor_user_id = s.supervisor_user_id
        ) b
      ) as branches,
      pg_catalog.array_agg(distinct s.team_id order by s.team_id) as operational_team_ids,
      pg_catalog.jsonb_object_agg(s.team_id::text, s.assignment_role) as team_assignment_roles,
      s.certificate_number,
      s.status,
      s.place_of_issue,
      s.expiry_date,
      s.date_issue,
      s.occupation,
      s.company,
      s.branch_name_snapshot,
      s.notes,
      s.updated_at
    from active_supervisor_assignments s
    group by
      s.supervisor_user_id,
      s.card_id,
      s.full_name,
      s.full_name_ar,
      s.person_code,
      s.certificate_number,
      s.status,
      s.place_of_issue,
      s.expiry_date,
      s.date_issue,
      s.occupation,
      s.company,
      s.branch_name_snapshot,
      s.notes,
      s.updated_at
  )
  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'id', d.card_id,
        'supervisor_user_id', d.supervisor_user_id,
        'display_name', d.display_name,
        'display_name_ar', d.display_name_ar,
        'person_code', d.person_code,
        'assignment_role', d.assignment_role,
        'branch_id', d.branch_id,
        'branch_name', d.branch_name,
        'branch_name_ar', d.branch_name_ar,
        'branches', d.branches,
        'operational_team_ids', d.operational_team_ids,
        'team_assignment_roles', d.team_assignment_roles,
        'certificate_number', d.certificate_number,
        'status', d.status,
        'place_of_issue', d.place_of_issue,
        'expiry_date', d.expiry_date,
        'date_issue', d.date_issue,
        'occupation', d.occupation,
        'company', d.company,
        'branch_name_snapshot', d.branch_name_snapshot,
        'notes', d.notes,
        'updated_at', d.updated_at
      )
      order by pg_catalog.lower(d.display_name), d.supervisor_user_id
    ),
    '[]'::jsonb
  )
  into supervisor_cards
  from deduplicated_supervisors d;

  return result || pg_catalog.jsonb_build_object('supervisor_health_cards', supervisor_cards);
end;
$$;

revoke all on function public.list_managed_people_directory_v3(uuid, uuid, uuid, date, text, text)
  from public, anon, authenticated;
grant execute on function public.list_managed_people_directory_v3(uuid, uuid, uuid, date, text, text)
  to service_role;
