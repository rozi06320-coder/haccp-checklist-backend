create table public.notification_rules (
  id uuid primary key,
  organization_id uuid null references public.organizations(id) on delete cascade,
  branch_id uuid null,
  checklist_type text not null check (checklist_type in ('oil_tracking', 'cold_storage', 'financial_closing')),
  rule_key text not null,
  reminder_time time not null,
  severity text not null check (severity in ('warning', 'urgent')),
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint notification_rules_rule_key_check check (rule_key = btrim(rule_key) and length(rule_key) between 1 and 120),
  constraint notification_rules_branch_scope_fkey foreign key(branch_id, organization_id)
    references public.branches(id, organization_id) on delete cascade
);

alter table public.notification_rules enable row level security;
revoke all on table public.notification_rules from public, anon, authenticated, service_role;

create unique index notification_rules_platform_key
  on public.notification_rules(rule_key)
  where organization_id is null and branch_id is null;
create unique index notification_rules_org_branch_key
  on public.notification_rules(
    organization_id,
    coalesce(branch_id, '00000000-0000-0000-0000-000000000000'::uuid),
    rule_key
  )
  where organization_id is not null;

create trigger notification_rules_set_updated_at
before update on public.notification_rules
for each row execute function private.set_updated_at();

insert into public.notification_rules(id, organization_id, branch_id, checklist_type, rule_key, reminder_time, severity, enabled)
values
  ('9f100000-0000-4000-8000-000000000001', null, null, 'oil_tracking', 'oil_tracking_1800', '18:00', 'warning', true),
  ('9f100000-0000-4000-8000-000000000002', null, null, 'cold_storage', 'cold_storage_2000', '20:00', 'warning', true),
  ('9f100000-0000-4000-8000-000000000003', null, null, 'financial_closing', 'financial_closing_2200', '22:00', 'warning', true),
  ('9f100000-0000-4000-8000-000000000004', null, null, 'financial_closing', 'financial_closing_2300', '23:00', 'urgent', true),
  ('9f100000-0000-4000-8000-000000000005', null, null, 'financial_closing', 'financial_closing_0200_overdue', '02:00', 'urgent', true)
on conflict (id) do update
set checklist_type = excluded.checklist_type,
    rule_key = excluded.rule_key,
    reminder_time = excluded.reminder_time,
    severity = excluded.severity,
    enabled = excluded.enabled;

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  branch_id uuid not null,
  operational_team_id uuid null,
  recipient_user_id uuid not null references auth.users(id) on delete cascade,
  business_date date not null,
  notification_type text not null,
  rule_id uuid not null references public.notification_rules(id) on delete restrict,
  severity text not null check (severity in ('warning', 'urgent')),
  payload jsonb not null default '{}'::jsonb,
  read_at timestamptz null,
  resolved_at timestamptz null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint notifications_branch_scope_fkey foreign key(branch_id, organization_id)
    references public.branches(id, organization_id) on delete cascade,
  constraint notifications_operational_team_scope_fkey foreign key(operational_team_id, branch_id, organization_id)
    references public.branch_operational_teams(id, branch_id, organization_id) on delete cascade,
  constraint notifications_type_check check (notification_type in ('oil_tracking_reminder', 'cold_storage_reminder', 'financial_closing_reminder', 'financial_closing_overdue')),
  constraint notifications_payload_check check (jsonb_typeof(payload) = 'object')
);

alter table public.notifications enable row level security;
revoke all on table public.notifications from public, anon, authenticated, service_role;

create unique index notifications_dedupe_key
  on public.notifications(
    organization_id,
    branch_id,
    recipient_user_id,
    business_date,
    rule_id,
    coalesce(operational_team_id, '00000000-0000-0000-0000-000000000000'::uuid)
  );
create index notifications_recipient_active_idx
  on public.notifications(recipient_user_id, resolved_at, read_at, created_at desc);
create index notifications_branch_rule_idx
  on public.notifications(organization_id, branch_id, business_date, rule_id)
  where resolved_at is null;

create trigger notifications_set_updated_at
before update on public.notifications
for each row execute function private.set_updated_at();

create or replace function private.supervisor_notification_branch_scope(actor_user_id uuid)
returns table(
  organization_id uuid,
  branch_id uuid,
  branch_name text,
  branch_code text,
  branch_timezone text,
  business_date date,
  local_time time
)
language sql stable security definer set search_path = '' as $$
  select distinct branch.organization_id,
    branch.id,
    branch.name,
    branch.code,
    branch.timezone,
    (pg_catalog.statement_timestamp() at time zone branch.timezone)::date,
    (pg_catalog.statement_timestamp() at time zone branch.timezone)::time
  from public.branch_operational_team_supervisors assignment
  join public.branch_operational_teams team
    on team.id = assignment.operational_team_id
   and team.branch_id = assignment.branch_id
   and team.organization_id = assignment.organization_id
   and team.active
  join public.branches branch
    on branch.id = assignment.branch_id
   and branch.organization_id = assignment.organization_id
   and branch.active
  join public.organizations organization on organization.id = branch.organization_id and organization.active
  join public.branch_memberships membership
    on membership.branch_id = branch.id
   and membership.user_id = assignment.supervisor_user_id
   and membership.role = 'branch_manager'
   and membership.active
  join public.profiles profile
    on profile.id = assignment.supervisor_user_id
   and profile.disabled_at is null
   and not profile.must_change_password
  where assignment.supervisor_user_id = actor_user_id
    and assignment.active;
$$;

create or replace function private.supervisor_notification_recipients(target_branch_id uuid)
returns table(
  organization_id uuid,
  branch_id uuid,
  recipient_user_id uuid
)
language sql stable security definer set search_path = '' as $$
  select distinct branch.organization_id, branch.id, assignment.supervisor_user_id
  from public.branch_operational_team_supervisors assignment
  join public.branch_operational_teams team
    on team.id = assignment.operational_team_id
   and team.branch_id = assignment.branch_id
   and team.organization_id = assignment.organization_id
   and team.active
  join public.branches branch
    on branch.id = assignment.branch_id
   and branch.organization_id = assignment.organization_id
   and branch.active
  join public.organizations organization on organization.id = branch.organization_id and organization.active
  join public.branch_memberships membership
    on membership.branch_id = branch.id
   and membership.user_id = assignment.supervisor_user_id
   and membership.role = 'branch_manager'
   and membership.active
  join public.profiles profile
    on profile.id = assignment.supervisor_user_id
   and profile.disabled_at is null
   and not profile.must_change_password
  where branch.id = target_branch_id
    and assignment.active;
$$;

create or replace function private.supervisor_notification_oil_unresolved(
  target_organization_id uuid,
  target_branch_id uuid,
  target_business_date date
) returns boolean language sql stable security definer set search_path = '' as $$
  select not exists (
    select 1
    from public.oil_tracking_submissions submission
    where submission.organization_id = target_organization_id
      and submission.branch_id = target_branch_id
      and submission.business_date = target_business_date
      and (
        submission.state = 'submitted'
        or (submission.opening_submitted_at is not null and submission.closing_submitted_at is not null)
      )
  );
$$;

create or replace function private.supervisor_notification_cold_unresolved(
  target_organization_id uuid,
  target_branch_id uuid,
  target_business_date date,
  as_of timestamptz
) returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  submitted_slots text[];
begin
  select coalesce(array_agg(distinct reading.slot), array[]::text[])
    into submitted_slots
  from public.cold_storage_submissions submission
  join public.cold_storage_readings reading on reading.submission_id = submission.id
  where submission.organization_id = target_organization_id
    and submission.branch_id = target_branch_id
    and submission.business_date = target_business_date
    and reading.submitted_at is not null;

  return cardinality(private.cold_storage_due_slots_for(target_branch_id, target_business_date, as_of)) > 0
    and cardinality(private.cold_storage_missed_slots_for(target_branch_id, target_business_date, submitted_slots, as_of)) > 0;
end;
$$;

create or replace function private.supervisor_notification_financial_closing_unresolved(
  target_organization_id uuid,
  target_branch_id uuid,
  target_business_date date
) returns boolean language sql stable security definer set search_path = '' as $$
  select not exists (
    select 1
    from public.financial_closing_reports report
    where report.organization_id = target_organization_id
      and report.branch_id = target_branch_id
      and report.business_date = target_business_date
      and report.state = 'submitted'
  );
$$;

create or replace function private.supervisor_notification_condition_unresolved(
  target_rule_key text,
  target_organization_id uuid,
  target_branch_id uuid,
  target_business_date date,
  as_of timestamptz
) returns boolean language sql stable security definer set search_path = '' as $$
  select case
    when target_rule_key = 'oil_tracking_1800'
      then private.supervisor_notification_oil_unresolved(target_organization_id, target_branch_id, target_business_date)
    when target_rule_key = 'cold_storage_2000'
      then private.supervisor_notification_cold_unresolved(target_organization_id, target_branch_id, target_business_date, as_of)
    when target_rule_key in ('financial_closing_2200', 'financial_closing_2300', 'financial_closing_0200_overdue')
      then private.supervisor_notification_financial_closing_unresolved(target_organization_id, target_branch_id, target_business_date)
    else false
  end;
$$;

create or replace function private.upsert_supervisor_notification_for_rule(
  target_branch record,
  target_rule public.notification_rules,
  target_business_date date,
  target_notification_type text,
  as_of timestamptz
) returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.supervisor_notification_condition_unresolved(
    target_rule.rule_key,
    target_branch.organization_id,
    target_branch.branch_id,
    target_business_date,
    as_of
  ) then
    return;
  end if;

  insert into public.notifications(
    organization_id,
    branch_id,
    recipient_user_id,
    business_date,
    notification_type,
    rule_id,
    severity,
    payload
  )
  select recipient.organization_id,
    recipient.branch_id,
    recipient.recipient_user_id,
    target_business_date,
    target_notification_type,
    target_rule.id,
    target_rule.severity,
    pg_catalog.jsonb_strip_nulls(pg_catalog.jsonb_build_object(
      'checklist_type', target_rule.checklist_type,
      'rule_key', target_rule.rule_key,
      'branch_name', target_branch.branch_name,
      'branch_code', target_branch.branch_code,
      'reminder_time', target_rule.reminder_time::text
    ))
  from private.supervisor_notification_recipients(target_branch.branch_id) recipient
  on conflict (organization_id, branch_id, recipient_user_id, business_date, rule_id, (coalesce(operational_team_id, '00000000-0000-0000-0000-000000000000'::uuid)))
  do update set
    severity = excluded.severity,
    payload = excluded.payload,
    resolved_at = null,
    updated_at = now();
end;
$$;

create or replace function private.evaluate_supervisor_notification_branch(
  target_branch record,
  as_of timestamptz
) returns void language plpgsql security definer set search_path = '' as $$
declare
  rule public.notification_rules%rowtype;
  local_timestamp timestamp;
  local_date date;
  local_clock time;
begin
  local_timestamp := as_of at time zone target_branch.branch_timezone;
  local_date := local_timestamp::date;
  local_clock := local_timestamp::time;

  update public.notifications notification
  set resolved_at = coalesce(notification.resolved_at, now())
  from public.notification_rules existing_rule
  where notification.rule_id = existing_rule.id
    and notification.organization_id = target_branch.organization_id
    and notification.branch_id = target_branch.branch_id
    and notification.resolved_at is null
    and existing_rule.rule_key in (
      'oil_tracking_1800',
      'cold_storage_2000',
      'financial_closing_2200',
      'financial_closing_2300',
      'financial_closing_0200_overdue'
    )
    and not private.supervisor_notification_condition_unresolved(
      existing_rule.rule_key,
      notification.organization_id,
      notification.branch_id,
      notification.business_date,
      as_of
    );

  if local_clock >= time '18:00' then
    select * into rule from public.notification_rules where rule_key = 'oil_tracking_1800' and organization_id is null and branch_id is null and enabled;
    if rule.id is not null then
      perform private.upsert_supervisor_notification_for_rule(target_branch, rule, local_date, 'oil_tracking_reminder', as_of);
    end if;
  end if;

  if local_clock >= time '20:00' then
    select * into rule from public.notification_rules where rule_key = 'cold_storage_2000' and organization_id is null and branch_id is null and enabled;
    if rule.id is not null then
      perform private.upsert_supervisor_notification_for_rule(target_branch, rule, local_date, 'cold_storage_reminder', as_of);
    end if;
  end if;

  if local_clock >= time '22:00' then
    select * into rule from public.notification_rules where rule_key = 'financial_closing_2200' and organization_id is null and branch_id is null and enabled;
    if rule.id is not null then
      perform private.upsert_supervisor_notification_for_rule(target_branch, rule, local_date, 'financial_closing_reminder', as_of);
    end if;
  end if;

  if local_clock >= time '23:00' then
    select * into rule from public.notification_rules where rule_key = 'financial_closing_2300' and organization_id is null and branch_id is null and enabled;
    if rule.id is not null then
      perform private.upsert_supervisor_notification_for_rule(target_branch, rule, local_date, 'financial_closing_reminder', as_of);
    end if;
  end if;

  if local_clock >= time '02:00' then
    select * into rule from public.notification_rules where rule_key = 'financial_closing_0200_overdue' and organization_id is null and branch_id is null and enabled;
    if rule.id is not null then
      perform private.upsert_supervisor_notification_for_rule(target_branch, rule, local_date - 1, 'financial_closing_overdue', as_of);
    end if;
  end if;
end;
$$;

create or replace function public.evaluate_supervisor_notifications(
  actor_user_id uuid,
  as_of timestamptz default pg_catalog.statement_timestamp()
) returns table(
  id uuid,
  organization_id uuid,
  branch_id uuid,
  business_date date,
  notification_type text,
  checklist_type text,
  rule_key text,
  severity text,
  read_at timestamptz,
  resolved_at timestamptz,
  created_at timestamptz,
  payload jsonb
)
language plpgsql security definer set search_path = '' as $$
declare
  branch_scope record;
  branch_count integer := 0;
begin
  for branch_scope in
    select * from private.supervisor_notification_branch_scope(actor_user_id)
  loop
    branch_count := branch_count + 1;
    perform private.evaluate_supervisor_notification_branch(branch_scope, as_of);
  end loop;

  if branch_count = 0 then
    raise exception 'notification access denied' using errcode = '42501';
  end if;

  return query
    select notification.id,
      notification.organization_id,
      notification.branch_id,
      notification.business_date,
      notification.notification_type,
      rule.checklist_type,
      rule.rule_key,
      notification.severity,
      notification.read_at,
      notification.resolved_at,
      notification.created_at,
      notification.payload
    from public.notifications notification
    join public.notification_rules rule on rule.id = notification.rule_id
    where notification.recipient_user_id = actor_user_id
    order by notification.resolved_at is not null,
      notification.read_at is not null,
      notification.created_at desc,
      notification.id
    limit 50;
end;
$$;

create or replace function public.mark_supervisor_notification_read(
  actor_user_id uuid,
  target_notification_id uuid
) returns table(
  id uuid,
  organization_id uuid,
  branch_id uuid,
  business_date date,
  notification_type text,
  checklist_type text,
  rule_key text,
  severity text,
  read_at timestamptz,
  resolved_at timestamptz,
  created_at timestamptz,
  payload jsonb
)
language plpgsql security definer set search_path = '' as $$
begin
  update public.notifications notification
  set read_at = coalesce(notification.read_at, now())
  where notification.id = target_notification_id
    and notification.recipient_user_id = actor_user_id;

  if not found then
    raise exception 'notification not found' using errcode = '42501';
  end if;

  return query
    select notification.id,
      notification.organization_id,
      notification.branch_id,
      notification.business_date,
      notification.notification_type,
      rule.checklist_type,
      rule.rule_key,
      notification.severity,
      notification.read_at,
      notification.resolved_at,
      notification.created_at,
      notification.payload
    from public.notifications notification
    join public.notification_rules rule on rule.id = notification.rule_id
    where notification.id = target_notification_id
      and notification.recipient_user_id = actor_user_id;
end;
$$;

revoke all on function private.supervisor_notification_branch_scope(uuid) from public, anon, authenticated;
revoke all on function private.supervisor_notification_recipients(uuid) from public, anon, authenticated;
revoke all on function private.supervisor_notification_oil_unresolved(uuid, uuid, date) from public, anon, authenticated;
revoke all on function private.supervisor_notification_cold_unresolved(uuid, uuid, date, timestamptz) from public, anon, authenticated;
revoke all on function private.supervisor_notification_financial_closing_unresolved(uuid, uuid, date) from public, anon, authenticated;
revoke all on function private.supervisor_notification_condition_unresolved(text, uuid, uuid, date, timestamptz) from public, anon, authenticated;
revoke all on function private.upsert_supervisor_notification_for_rule(record, public.notification_rules, date, text, timestamptz) from public, anon, authenticated;
revoke all on function private.evaluate_supervisor_notification_branch(record, timestamptz) from public, anon, authenticated;
revoke all on function public.evaluate_supervisor_notifications(uuid, timestamptz) from public, anon, authenticated;
revoke all on function public.mark_supervisor_notification_read(uuid, uuid) from public, anon, authenticated;
grant execute on function public.evaluate_supervisor_notifications(uuid, timestamptz) to service_role;
grant execute on function public.mark_supervisor_notification_read(uuid, uuid) to service_role;
