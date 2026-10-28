begin;

-- Daily Business Report Phase 1 is intentionally persistence-only. It installs
-- future-effective eligibility, immutable report revisions and a private job
-- queue. It does not schedule jobs, generate reports or create notifications.

create table private.daily_report_timezones(
  name text primary key
);
insert into private.daily_report_timezones(name)
select zone.name from pg_catalog.pg_timezone_names zone;

create table public.daily_report_branch_lifecycle (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  effective_from_business_date date not null,
  effective_to_business_date date,
  active boolean not null,
  timezone text not null,
  recorded_at timestamptz not null default pg_catalog.statement_timestamp(),
  constraint daily_report_branch_lifecycle_branch_scope_fkey
    foreign key(branch_id,organization_id)
    references public.branches(id,organization_id) on delete restrict,
  constraint daily_report_branch_lifecycle_period_check
    check(effective_to_business_date is null
      or effective_to_business_date>effective_from_business_date),
  constraint daily_report_branch_lifecycle_timezone_check
    check(timezone=pg_catalog.btrim(timezone) and pg_catalog.length(timezone) between 1 and 80),
  constraint daily_report_branch_lifecycle_timezone_fkey
    foreign key(timezone)references private.daily_report_timezones(name)on delete restrict,
  unique(branch_id,effective_from_business_date)
);
create unique index daily_report_branch_lifecycle_open_key
  on public.daily_report_branch_lifecycle(branch_id)
  where effective_to_business_date is null;
create index daily_report_branch_lifecycle_org_date_idx
  on public.daily_report_branch_lifecycle(
    organization_id,effective_from_business_date,effective_to_business_date,branch_id
  );

create table public.daily_report_module_applicability (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  module_key text not null,
  requirement_basis text not null default 'static',
  effective_from_business_date date not null,
  effective_to_business_date date,
  required boolean not null,
  recorded_at timestamptz not null default pg_catalog.statement_timestamp(),
  recorded_by uuid references public.profiles(id) on delete restrict,
  constraint daily_report_module_applicability_branch_scope_fkey
    foreign key(branch_id,organization_id)
    references public.branches(id,organization_id) on delete restrict,
  constraint daily_report_module_applicability_module_check check(module_key in(
    'kitchen_opening','foh_opening','staff_hygiene','daily_audit',
    'cold_storage','oil_tracking','sales_tracking'
  )),
  constraint daily_report_module_applicability_basis_check check(
    (module_key='staff_hygiene' and requirement_basis='eligible_operational_staff')
    or (module_key='cold_storage' and requirement_basis='eligible_cold_storage_equipment')
    or (module_key='oil_tracking' and requirement_basis='eligible_oil_tracking_fryers')
    or (module_key not in('staff_hygiene','cold_storage','oil_tracking') and requirement_basis='static')
  ),
  constraint daily_report_module_applicability_period_check
    check(effective_to_business_date is null
      or effective_to_business_date>effective_from_business_date),
  unique(branch_id,module_key,effective_from_business_date)
);
create unique index daily_report_module_applicability_open_key
  on public.daily_report_module_applicability(branch_id,module_key)
  where effective_to_business_date is null;
create index daily_report_module_applicability_org_date_idx
  on public.daily_report_module_applicability(
    organization_id,branch_id,effective_from_business_date,effective_to_business_date,module_key
  );

create function private.guard_daily_report_effective_period_overlap()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare conflict_found boolean;
begin
  if tg_table_name='daily_report_branch_lifecycle'then
    if not exists(select 1 from private.daily_report_timezones zone where zone.name=new.timezone)then
      raise exception 'invalid daily report timezone' using errcode='22023';
    end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
      'daily-report:lifecycle:'||new.branch_id::text,0));
  else
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
      'daily-report:applicability:'||new.branch_id::text||':'||new.module_key,0));
  end if;
  if tg_table_name='daily_report_branch_lifecycle' then
    select exists(
      select 1 from public.daily_report_branch_lifecycle candidate
      where candidate.branch_id=new.branch_id and candidate.id<>new.id
        and candidate.effective_from_business_date<coalesce(new.effective_to_business_date,'infinity'::date)
        and new.effective_from_business_date<coalesce(candidate.effective_to_business_date,'infinity'::date)
    ) into conflict_found;
  else
    select exists(
      select 1 from public.daily_report_module_applicability candidate
      where candidate.branch_id=new.branch_id and candidate.module_key=new.module_key
        and candidate.id<>new.id
        and candidate.effective_from_business_date<coalesce(new.effective_to_business_date,'infinity'::date)
        and new.effective_from_business_date<coalesce(candidate.effective_to_business_date,'infinity'::date)
    ) into conflict_found;
  end if;
  if conflict_found then
    raise exception 'daily report effective periods overlap' using errcode='23505';
  end if;
  return new;
end;
$$;
create trigger daily_report_branch_lifecycle_no_overlap
before insert or update on public.daily_report_branch_lifecycle
for each row execute function private.guard_daily_report_effective_period_overlap();
create trigger daily_report_module_applicability_no_overlap
before insert or update on public.daily_report_module_applicability
for each row execute function private.guard_daily_report_effective_period_overlap();

create function private.record_daily_report_branch_lifecycle(
  p_organization_id uuid,p_branch_id uuid,p_active boolean,p_timezone text,
  p_effective_from_business_date date
)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare current_row public.daily_report_branch_lifecycle%rowtype;
begin
  if p_organization_id is null or p_branch_id is null or p_active is null
    or p_effective_from_business_date is null
    or p_timezone is null or p_timezone<>pg_catalog.btrim(p_timezone)
    or not exists(select 1 from private.daily_report_timezones zone where zone.name=p_timezone)
    or not exists(select 1 from public.branches branch
      where branch.id=p_branch_id and branch.organization_id=p_organization_id)
  then raise exception 'invalid daily report branch lifecycle' using errcode='22023'; end if;

  select * into current_row from public.daily_report_branch_lifecycle lifecycle
  where lifecycle.branch_id=p_branch_id and lifecycle.effective_to_business_date is null
  for update;
  if current_row.id is not null and current_row.effective_from_business_date>p_effective_from_business_date then
    raise exception 'daily report branch lifecycle cannot move backward' using errcode='22023';
  elsif current_row.id is not null and current_row.effective_from_business_date=p_effective_from_business_date then
    update public.daily_report_branch_lifecycle lifecycle
    set active=p_active,timezone=p_timezone,recorded_at=pg_catalog.statement_timestamp()
    where lifecycle.id=current_row.id;
  else
    if current_row.id is not null then
      update public.daily_report_branch_lifecycle lifecycle
      set effective_to_business_date=p_effective_from_business_date
      where lifecycle.id=current_row.id;
    end if;
    insert into public.daily_report_branch_lifecycle(
      organization_id,branch_id,effective_from_business_date,active,timezone
    ) values(p_organization_id,p_branch_id,p_effective_from_business_date,p_active,p_timezone);
  end if;
end;
$$;

create function private.seed_daily_report_module_applicability(
  p_organization_id uuid,p_branch_id uuid,p_effective_from_business_date date
)
returns void
language sql
security definer
set search_path=''
as $$
  insert into public.daily_report_module_applicability(
    organization_id,branch_id,module_key,requirement_basis,effective_from_business_date,required
  )
  select p_organization_id,p_branch_id,module.module_key,
    case module.module_key
      when'staff_hygiene'then'eligible_operational_staff'
      when'cold_storage'then'eligible_cold_storage_equipment'
      when'oil_tracking'then'eligible_oil_tracking_fryers'
      else'static'end,
    p_effective_from_business_date,true
  from pg_catalog.unnest(array[
    'kitchen_opening','foh_opening','staff_hygiene','daily_audit',
    'cold_storage','oil_tracking','sales_tracking'
  ]::text[]) module(module_key)
  where not exists(select 1 from public.daily_report_module_applicability existing
    where existing.branch_id=p_branch_id and existing.module_key=module.module_key)
$$;

create function private.capture_daily_report_branch_lifecycle()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare effective_date date;
begin
  if tg_op='INSERT' then
    effective_date:=private.phase4a_business_date_at(new.timezone,pg_catalog.statement_timestamp())+1;
  elsif new.active is not distinct from old.active and new.timezone is not distinct from old.timezone then
    return new;
  else
    effective_date:=private.phase4a_business_date_at(old.timezone,pg_catalog.statement_timestamp())+1;
  end if;
  perform private.record_daily_report_branch_lifecycle(
    new.organization_id,new.id,new.active,new.timezone,effective_date
  );
  if new.active then
    perform private.seed_daily_report_module_applicability(new.organization_id,new.id,effective_date);
  end if;
  return new;
end;
$$;
create trigger branches_capture_daily_report_lifecycle
after insert or update of active,timezone on public.branches
for each row execute function private.capture_daily_report_branch_lifecycle();

-- The trigger is installed before this snapshot. Concurrent branch writes are
-- therefore either visible here or captured by the trigger; none can be missed.
-- This establishes only a future boundary and does not invent earlier history.
insert into public.daily_report_branch_lifecycle(
  organization_id,branch_id,effective_from_business_date,active,timezone
)
select branch.organization_id,branch.id,
  private.phase4a_business_date_at(branch.timezone,pg_catalog.statement_timestamp())+1,
  branch.active,branch.timezone
from public.branches branch
on conflict(branch_id,effective_from_business_date)do nothing;

insert into public.daily_report_module_applicability(
  organization_id,branch_id,module_key,requirement_basis,effective_from_business_date,required
)
select branch.organization_id,branch.id,module.module_key,
  case module.module_key
    when'staff_hygiene'then'eligible_operational_staff'
    when'cold_storage'then'eligible_cold_storage_equipment'
    when'oil_tracking'then'eligible_oil_tracking_fryers'
    else'static'end,
  private.phase4a_business_date_at(branch.timezone,pg_catalog.statement_timestamp())+1,true
from public.branches branch
cross join pg_catalog.unnest(array[
  'kitchen_opening','foh_opening','staff_hygiene','daily_audit',
  'cold_storage','oil_tracking','sales_tracking'
]::text[]) module(module_key)
where branch.active
on conflict(branch_id,module_key,effective_from_business_date)do nothing;

create function private.record_daily_report_module_applicability(
  p_organization_id uuid,p_branch_id uuid,p_module_key text,p_required boolean,
  p_effective_from_business_date date,p_recorded_by uuid
)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare current_row public.daily_report_module_applicability%rowtype;
begin
  if p_module_key not in('kitchen_opening','foh_opening','staff_hygiene','daily_audit',
      'cold_storage','oil_tracking','sales_tracking')
    or p_required is null or p_effective_from_business_date is null
    or not exists(select 1 from public.branches branch
      where branch.id=p_branch_id and branch.organization_id=p_organization_id)
  then raise exception 'invalid daily report module applicability' using errcode='22023'; end if;
  select * into current_row from public.daily_report_module_applicability applicability
  where applicability.branch_id=p_branch_id and applicability.module_key=p_module_key
    and applicability.effective_to_business_date is null for update;
  if current_row.id is not null and current_row.effective_from_business_date>p_effective_from_business_date then
    raise exception 'daily report module applicability cannot move backward' using errcode='22023';
  elsif current_row.id is not null and current_row.effective_from_business_date=p_effective_from_business_date then
    update public.daily_report_module_applicability applicability
    set required=p_required,recorded_at=pg_catalog.statement_timestamp(),recorded_by=p_recorded_by
    where applicability.id=current_row.id;
  else
    if current_row.id is not null then
      update public.daily_report_module_applicability applicability
      set effective_to_business_date=p_effective_from_business_date
      where applicability.id=current_row.id;
    end if;
    insert into public.daily_report_module_applicability(
      organization_id,branch_id,module_key,requirement_basis,effective_from_business_date,required,recorded_by
    ) values(p_organization_id,p_branch_id,p_module_key,
      case p_module_key
        when'staff_hygiene'then'eligible_operational_staff'
        when'cold_storage'then'eligible_cold_storage_equipment'
        when'oil_tracking'then'eligible_oil_tracking_fryers'
        else'static'end,
      p_effective_from_business_date,p_required,p_recorded_by);
  end if;
end;
$$;

create function public.configure_daily_report_module_applicability(
  p_actor_user_id uuid,p_organization_id uuid,p_branch_id uuid,p_module_key text,
  p_required boolean,p_effective_from_business_date date
)
returns boolean
language plpgsql
security definer
set search_path=''
as $$
declare branch_timezone text; earliest_date date;
begin
  if not private.is_internal_admin(p_actor_user_id) then
    raise exception 'daily report configuration access denied' using errcode='42501';
  end if;
  select branch.timezone into branch_timezone from public.branches branch
  where branch.id=p_branch_id and branch.organization_id=p_organization_id;
  if branch_timezone is null then
    raise exception 'daily report branch unavailable' using errcode='P0002';
  end if;
  earliest_date:=private.phase4a_business_date_at(branch_timezone,pg_catalog.statement_timestamp())+1;
  if p_effective_from_business_date<earliest_date then
    raise exception 'daily report applicability must be future effective' using errcode='22023';
  end if;
  perform private.record_daily_report_module_applicability(
    p_organization_id,p_branch_id,p_module_key,p_required,p_effective_from_business_date,p_actor_user_id
  );
  return true;
end;
$$;

create table public.daily_business_reports (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  business_date date not null,
  current_revision integer not null default 0 check(current_revision>=0),
  created_at timestamptz not null default pg_catalog.statement_timestamp(),
  updated_at timestamptz not null default pg_catalog.statement_timestamp(),
  unique(organization_id,business_date),
  unique(id,organization_id),
  unique(id,organization_id,business_date)
);

create table public.daily_business_report_revisions (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null,
  organization_id uuid not null,
  business_date date not null,
  schema_version integer not null check(schema_version=1),
  revision integer not null check(revision>0),
  source_cutoff_at timestamptz not null,
  eligibility_snapshot jsonb not null,
  payload jsonb not null,
  canonical_payload_hash text not null,
  source_watermark text not null,
  generation_reason text not null,
  generated_at timestamptz not null default pg_catalog.statement_timestamp(),
  finalized_at timestamptz not null default pg_catalog.statement_timestamp(),
  constraint daily_business_report_revisions_report_scope_fkey
    foreign key(report_id,organization_id,business_date)
    references public.daily_business_reports(id,organization_id,business_date) on delete restrict,
  constraint daily_business_report_revisions_payload_check
    check(pg_catalog.jsonb_typeof(eligibility_snapshot)='object'
      and pg_catalog.jsonb_typeof(payload)='object'),
  constraint daily_business_report_revisions_hash_check
    check(canonical_payload_hash~'^[0-9a-f]{64}$'),
  constraint daily_business_report_revisions_watermark_check
    check(source_watermark=pg_catalog.btrim(source_watermark)
      and pg_catalog.length(source_watermark) between 1 and 500),
  constraint daily_business_report_revisions_reason_check check(generation_reason in(
    'initial','late_submission','authoritative_report_changed','source_correction'
  )),
  constraint daily_business_report_revisions_time_check
    check(finalized_at>=generated_at and source_cutoff_at<=generated_at),
  unique(report_id,revision)
);
create index daily_business_report_revisions_org_date_idx
  on public.daily_business_report_revisions(organization_id,business_date desc,revision desc);

create function private.guard_daily_business_report_identity()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if tg_op='DELETE' then raise exception 'daily business report identity is immutable' using errcode='42501'; end if;
  if new.id is distinct from old.id or new.organization_id is distinct from old.organization_id
    or new.business_date is distinct from old.business_date or new.created_at is distinct from old.created_at
    or new.current_revision not in(old.current_revision,old.current_revision+1)
  then raise exception 'daily business report identity is immutable' using errcode='42501'; end if;
  new.updated_at:=pg_catalog.statement_timestamp();
  return new;
end;
$$;
create trigger daily_business_reports_identity_guard
before update or delete on public.daily_business_reports
for each row execute function private.guard_daily_business_report_identity();

create function private.guard_daily_business_report_revision()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  raise exception 'daily business report revision is immutable' using errcode='42501';
end;
$$;
create trigger daily_business_report_revisions_immutable
before update or delete on public.daily_business_report_revisions
for each row execute function private.guard_daily_business_report_revision();

create function private.daily_business_report_branch_close_at(
  p_business_date date,p_timezone text
)
returns timestamptz
language plpgsql
stable
strict
security definer
set search_path=''
as $$
begin
  -- IANA validity is enforced once when lifecycle rows are written. Avoid a
  -- pg_timezone_names scan for every branch in every snapshot.
  return ((p_business_date+1)::timestamp+time '04:00') at time zone p_timezone;
end;
$$;

create function private.daily_business_report_organization_due_at(
  p_organization_id uuid,p_business_date date
)
returns timestamptz
language sql
stable
security definer
set search_path=''
as $$
  select pg_catalog.max(private.daily_business_report_branch_close_at(
    p_business_date,lifecycle.timezone
  ))
  from public.daily_report_branch_lifecycle lifecycle
  where lifecycle.organization_id=p_organization_id and lifecycle.active
    and lifecycle.effective_from_business_date<=p_business_date
    and (lifecycle.effective_to_business_date is null
      or lifecycle.effective_to_business_date>p_business_date)
$$;

create function private.daily_business_report_eligibility_snapshot(
  p_organization_id uuid,p_business_date date
)
returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  select pg_catalog.jsonb_build_object(
    'policy_version','daily-business-report-v1',
    'branches',coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'branch_id',lifecycle.branch_id,
      'timezone',lifecycle.timezone,
      'close_at',private.daily_business_report_branch_close_at(p_business_date,lifecycle.timezone),
      'modules',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'module_key',applicability.module_key,'required',applicability.required,
        'requirement_basis',applicability.requirement_basis
      ) order by applicability.module_key)
      from public.daily_report_module_applicability applicability
      where applicability.organization_id=lifecycle.organization_id
        and applicability.branch_id=lifecycle.branch_id
        and applicability.effective_from_business_date<=p_business_date
        and (applicability.effective_to_business_date is null
          or applicability.effective_to_business_date>p_business_date)),'[]'::jsonb)
    ) order by lifecycle.branch_id),'[]'::jsonb)
  )
  from public.daily_report_branch_lifecycle lifecycle
  where lifecycle.organization_id=p_organization_id and lifecycle.active
    and lifecycle.effective_from_business_date<=p_business_date
    and (lifecycle.effective_to_business_date is null
      or lifecycle.effective_to_business_date>p_business_date)
$$;

create function private.daily_business_report_jsonb_has_exact_keys(
  p_value jsonb,p_keys text[]
)
returns boolean
language sql
immutable
strict
security definer
set search_path=''
as $$
  select pg_catalog.jsonb_typeof(p_value)='object'
    and p_value?&p_keys
    and p_value-p_keys='{}'::jsonb
$$;

create function private.validate_daily_business_report_payload(
  p_organization_id uuid,p_business_date date,p_payload jsonb,p_snapshot jsonb
)
returns void
language plpgsql
security definer
set search_path=''
as $$
#variable_conflict use_variable
declare branch_value jsonb;module_value jsonb;summary jsonb;
  branch_uuid uuid;module_key text;basis text;status_value text;detail_path text;
  policy_required boolean;runtime_required boolean;reported_required boolean;
  expected_count integer;submitted_count integer;missing_count integer;issue_count integer;
  expected_ids uuid[];reported_ids uuid[];seen_branches uuid[]:='{}'::uuid[];
  source_id uuid;cold_submission_id uuid;oil_submission_id uuid;
  required_total integer:=0;submitted_total integer:=0;missing_total integer:=0;
  issue_total integer:=0;not_applicable_total integer:=0;unavailable_total integer:=0;
  active_equipment integer;eligible_teams integer;
begin
  if p_payload is null or p_snapshot is null or not private.daily_business_report_jsonb_has_exact_keys(
      p_payload,array['organization_id','business_date','summary','branches'])
    or pg_catalog.jsonb_typeof(p_payload->'organization_id')<>'string'
    or pg_catalog.jsonb_typeof(p_payload->'business_date')<>'string'
    or (p_payload->>'organization_id')::uuid<>p_organization_id
    or (p_payload->>'business_date')::date<>p_business_date
    or pg_catalog.jsonb_typeof(p_payload->'branches')<>'array'
    or not private.daily_business_report_jsonb_has_exact_keys(
      p_payload->'summary',array['required_count','submitted_count','missing_count',
        'issue_count','not_applicable_count','unavailable_count'])
  then raise exception 'invalid daily business report payload' using errcode='22023';end if;
  summary:=p_payload->'summary';

  for branch_value in select value from pg_catalog.jsonb_array_elements(p_payload->'branches')loop
    if not private.daily_business_report_jsonb_has_exact_keys(branch_value,array['branch_id','modules'])
      or pg_catalog.jsonb_typeof(branch_value->'branch_id')<>'string'
      or pg_catalog.jsonb_typeof(branch_value->'modules')<>'object'
      or not private.daily_business_report_jsonb_has_exact_keys(branch_value->'modules',array[
        'kitchen_opening','foh_opening','staff_hygiene','daily_audit',
        'cold_storage','oil_tracking','sales_tracking'])
    then raise exception 'invalid daily business report branch payload' using errcode='22023';end if;
    branch_uuid:=(branch_value->>'branch_id')::uuid;
    if branch_uuid=any(seen_branches)or not exists(
      select 1 from pg_catalog.jsonb_array_elements(p_snapshot->'branches')snapshot_branch
      where (snapshot_branch->>'branch_id')::uuid=branch_uuid
    )then raise exception 'daily business report branch scope mismatch' using errcode='42501';end if;
    seen_branches:=pg_catalog.array_append(seen_branches,branch_uuid);

    foreach module_key in array array[
      'kitchen_opening','foh_opening','staff_hygiene','daily_audit',
      'cold_storage','oil_tracking','sales_tracking'
    ]loop
      module_value:=branch_value->'modules'->module_key;
      if not private.daily_business_report_jsonb_has_exact_keys(module_value,
          case when module_key='sales_tracking' then array['status','required','requirement_basis',
            'expected_count','submitted_count','missing_count','issue_count','source_report_ids',
            'detail_path','cash_monitoring_source_report_id']
          else array['status','required','requirement_basis','expected_count','submitted_count',
            'missing_count','issue_count','source_report_ids','detail_path']end)
        or pg_catalog.jsonb_typeof(module_value->'status')<>'string'
        or module_value->>'status' not in('submitted','missing','issues_detected','not_applicable','unavailable')
        or pg_catalog.jsonb_typeof(module_value->'required')<>'boolean'
        or pg_catalog.jsonb_typeof(module_value->'requirement_basis')<>'string'
        or pg_catalog.jsonb_typeof(module_value->'expected_count')<>'number'
        or pg_catalog.jsonb_typeof(module_value->'submitted_count')<>'number'
        or pg_catalog.jsonb_typeof(module_value->'missing_count')<>'number'
        or pg_catalog.jsonb_typeof(module_value->'issue_count')<>'number'
        or pg_catalog.jsonb_typeof(module_value->'source_report_ids')<>'array'
        or module_value->>'expected_count'!~'^(0|[1-9][0-9]*)$'
        or module_value->>'submitted_count'!~'^(0|[1-9][0-9]*)$'
        or module_value->>'missing_count'!~'^(0|[1-9][0-9]*)$'
        or module_value->>'issue_count'!~'^(0|[1-9][0-9]*)$'
      then raise exception 'invalid daily business report module payload' using errcode='22023';end if;

      status_value:=module_value->>'status';reported_required:=(module_value->>'required')::boolean;
      expected_count:=(module_value->>'expected_count')::integer;
      submitted_count:=(module_value->>'submitted_count')::integer;
      missing_count:=(module_value->>'missing_count')::integer;
      issue_count:=(module_value->>'issue_count')::integer;
      detail_path:=module_value->>'detail_path';
      if module_value->'detail_path'<>'null'::jsonb and(
          pg_catalog.jsonb_typeof(module_value->'detail_path')<>'string'
          or pg_catalog.length(detail_path)not between 1 and 500
          or detail_path!~'^/[A-Za-z0-9/_?=&.%:-]+$'or detail_path~'^//'
          or pg_catalog.strpos(detail_path,'://')>0 or pg_catalog.strpos(detail_path,E'\\\\')>0)
      then raise exception 'invalid daily business report detail path' using errcode='22023';end if;

      select applicability.required,applicability.requirement_basis
      into strict policy_required,basis
      from public.daily_report_module_applicability applicability
      where applicability.organization_id=p_organization_id and applicability.branch_id=branch_uuid
        and applicability.module_key=module_key
        and applicability.effective_from_business_date<=p_business_date
        and(applicability.effective_to_business_date is null
          or applicability.effective_to_business_date>p_business_date);
      expected_ids:='{}'::uuid[];runtime_required:=policy_required;expected_count:=0;

      if module_key in('kitchen_opening','foh_opening','daily_audit')then
        expected_count:=case when runtime_required then 1 else 0 end;
        select coalesce(pg_catalog.array_agg(submission.id order by submission.id),'{}'::uuid[])
        into expected_ids from public.checklist_submissions submission
        where submission.organization_id=p_organization_id and submission.branch_id=branch_uuid
          and submission.business_date=p_business_date and submission.checklist_type=module_key
          and submission.state='submitted';
      elsif module_key='staff_hygiene'then
        with eligible as(
          select distinct team.id
          from public.branch_operational_teams team
          join public.operational_staff_assignments assignment
            on assignment.organization_id=p_organization_id and assignment.branch_id=branch_uuid
            and assignment.operational_team_id=team.id and assignment.valid_from<=p_business_date
            and(assignment.valid_to is null or assignment.valid_to>=p_business_date)
          join public.operational_staff staff on staff.id=assignment.operational_staff_id
            and staff.organization_id=p_organization_id
          left join public.operational_staff_duty_statuses duty on duty.assignment_id=assignment.id
            and duty.operational_staff_id=staff.id and duty.duty_date=p_business_date
          where team.organization_id=p_organization_id and team.branch_id=branch_uuid and team.active
            and team.created_at<=private.daily_business_report_branch_close_at(p_business_date,
              (select lifecycle.timezone from public.daily_report_branch_lifecycle lifecycle
               where lifecycle.branch_id=branch_uuid and lifecycle.active
                 and lifecycle.effective_from_business_date<=p_business_date
                 and(lifecycle.effective_to_business_date is null or lifecycle.effective_to_business_date>p_business_date)))
            and coalesce(duty.duty_status,'on_duty')='on_duty'
        )select pg_catalog.count(*)::integer into eligible_teams from eligible;
        runtime_required:=policy_required and eligible_teams>0;
        expected_count:=case when runtime_required then eligible_teams else 0 end;
        select coalesce(pg_catalog.array_agg(submission.id order by submission.id),'{}'::uuid[])
        into expected_ids from public.checklist_submissions submission
        where submission.organization_id=p_organization_id and submission.branch_id=branch_uuid
          and submission.business_date=p_business_date and submission.checklist_type='staff_hygiene'
          and submission.state='submitted'and exists(
            select 1 from public.branch_operational_teams team
            join public.operational_staff_assignments assignment on assignment.organization_id=p_organization_id
              and assignment.branch_id=branch_uuid and assignment.operational_team_id=team.id
              and assignment.valid_from<=p_business_date
              and(assignment.valid_to is null or assignment.valid_to>=p_business_date)
            join public.operational_staff staff on staff.id=assignment.operational_staff_id
              and staff.organization_id=p_organization_id
            left join public.operational_staff_duty_statuses duty on duty.assignment_id=assignment.id
              and duty.operational_staff_id=staff.id and duty.duty_date=p_business_date
            where team.id=submission.operational_team_id and team.active
              and coalesce(duty.duty_status,'on_duty')='on_duty');
      elsif module_key='cold_storage'then
        select submission.id into cold_submission_id from public.cold_storage_submissions submission
        where submission.organization_id=p_organization_id and submission.branch_id=branch_uuid
          and submission.business_date=p_business_date;
        select pg_catalog.count(*)::integer into active_equipment
        from public.cold_storage_equipment equipment where equipment.submission_id=cold_submission_id and equipment.active;
        runtime_required:=policy_required and(cold_submission_id is null or active_equipment>0);
        expected_count:=case when runtime_required then 1 else 0 end;
        select coalesce(pg_catalog.array_agg(submission.id order by submission.id),'{}'::uuid[])
        into expected_ids from public.cold_storage_submissions submission
        where submission.id=cold_submission_id and submission.state='submitted';
      elsif module_key='oil_tracking'then
        select submission.id into oil_submission_id from public.oil_tracking_submissions submission
        where submission.organization_id=p_organization_id and submission.branch_id=branch_uuid
          and submission.business_date=p_business_date;
        select pg_catalog.count(*)::integer into active_equipment
        from public.oil_tracking_fryer_results fryer
        where fryer.submission_id=oil_submission_id and fryer.in_use_today;
        runtime_required:=policy_required and(oil_submission_id is null or active_equipment>0);
        expected_count:=case when runtime_required then 1 else 0 end;
        select coalesce(pg_catalog.array_agg(submission.id order by submission.id),'{}'::uuid[])
        into expected_ids from public.oil_tracking_submissions submission
        where submission.id=oil_submission_id and submission.state='submitted';
      else
        expected_count:=case when runtime_required then 1 else 0 end;
        select coalesce(pg_catalog.array_agg(report.id order by report.id),'{}'::uuid[])
        into expected_ids from public.sales_tracking_report_cases report_case
        join public.sales_tracking_reports report on report.id=report_case.authoritative_report_id
          and report.case_id=report_case.id and report.state='submitted'
        where report_case.organization_id=p_organization_id and report_case.branch_id=branch_uuid
          and report_case.business_date=p_business_date;
      end if;

      if module_value->>'requirement_basis'<>basis or reported_required<>runtime_required
        or(module_value->>'expected_count')::integer<>expected_count
      then raise exception 'daily business report runtime applicability mismatch' using errcode='22023';end if;

      reported_ids:='{}'::uuid[];
      if exists(select 1 from pg_catalog.jsonb_array_elements(module_value->'source_report_ids')source
        where pg_catalog.jsonb_typeof(source.value)<>'string')
      then raise exception 'invalid daily business report source identifier' using errcode='22023';end if;
      for source_id in select value#>>'{}' from pg_catalog.jsonb_array_elements(module_value->'source_report_ids')loop
        if source_id=any(reported_ids)then
          raise exception 'duplicate daily business report source' using errcode='22023';end if;
        reported_ids:=pg_catalog.array_append(reported_ids,source_id);
      end loop;
      select coalesce(pg_catalog.array_agg(id order by id),'{}'::uuid[])into reported_ids
      from pg_catalog.unnest(reported_ids)id;
      if status_value='unavailable'then
        if reported_ids<>expected_ids or submitted_count<>pg_catalog.cardinality(expected_ids)
          or missing_count<>0 or issue_count<>0
        then raise exception 'invalid unavailable daily business report module' using errcode='22023';end if;
      else
        if reported_ids<>expected_ids or submitted_count<>pg_catalog.cardinality(expected_ids)
          or missing_count<>(case when runtime_required then greatest(expected_count-pg_catalog.cardinality(expected_ids),0)else 0 end)
          or status_value<>(case
            when not runtime_required and pg_catalog.cardinality(expected_ids)=0 then'not_applicable'
            when runtime_required and expected_count>pg_catalog.cardinality(expected_ids)then'missing'
            when issue_count>0 then'issues_detected'else'submitted'end)
        then raise exception 'daily business report source or count mismatch' using errcode='22023';end if;
      end if;
      if module_key='sales_tracking'and(
          (module_value->'cash_monitoring_source_report_id'='null'::jsonb
            and pg_catalog.cardinality(reported_ids)<>0)
          or(module_value->'cash_monitoring_source_report_id'<>'null'::jsonb and(
            pg_catalog.jsonb_typeof(module_value->'cash_monitoring_source_report_id')<>'string'
            or(module_value->>'cash_monitoring_source_report_id')::uuid
              is distinct from reported_ids[1] or pg_catalog.cardinality(reported_ids)<>1)))
      then raise exception 'cash monitoring must share the authoritative sales report' using errcode='22023';end if;

      required_total:=required_total+expected_count;submitted_total:=submitted_total+submitted_count;
      missing_total:=missing_total+missing_count;issue_total:=issue_total+issue_count;
      not_applicable_total:=not_applicable_total+(status_value='not_applicable')::integer;
      unavailable_total:=unavailable_total+(status_value='unavailable')::integer;
    end loop;
  end loop;
  if pg_catalog.cardinality(seen_branches)<>pg_catalog.jsonb_array_length(p_snapshot->'branches')
    or exists(select 1 from pg_catalog.jsonb_each(summary)item
      where pg_catalog.jsonb_typeof(item.value)<>'number'or(item.value#>>'{}')!~'^(0|[1-9][0-9]*)$')
    or(summary->>'required_count')::integer<>required_total
    or(summary->>'submitted_count')::integer<>submitted_total
    or(summary->>'missing_count')::integer<>missing_total
    or(summary->>'issue_count')::integer<>issue_total
    or(summary->>'not_applicable_count')::integer<>not_applicable_total
    or(summary->>'unavailable_count')::integer<>unavailable_total
  then raise exception 'daily business report summary mismatch' using errcode='22023';end if;
exception when invalid_text_representation or numeric_value_out_of_range or no_data_found or too_many_rows then
  raise exception 'invalid daily business report payload' using errcode='22023';
end;
$$;

create function public.get_daily_business_report(
  p_actor_user_id uuid,p_organization_id uuid,p_business_date date,p_revision integer default null
)
returns table(
  report_id uuid,revision_id uuid,organization_id uuid,business_date date,
  schema_version integer,revision integer,source_cutoff_at timestamptz,
  eligibility_snapshot jsonb,payload jsonb,canonical_payload_hash text,
  source_watermark text,generation_reason text,generated_at timestamptz,finalized_at timestamptz
)
language plpgsql
stable
security definer
set search_path=''
as $$
begin
  if not private.actor_manages_active_organization(p_actor_user_id,p_organization_id) then
    raise exception 'daily business report access denied' using errcode='42501';
  end if;
  return query select report.id,item.id,item.organization_id,item.business_date,
    item.schema_version,item.revision,item.source_cutoff_at,item.eligibility_snapshot,
    item.payload,item.canonical_payload_hash,item.source_watermark,item.generation_reason,
    item.generated_at,item.finalized_at
  from public.daily_business_reports report
  join public.daily_business_report_revisions item on item.report_id=report.id
    and item.organization_id=report.organization_id
    and item.revision=coalesce(p_revision,report.current_revision)
  where report.organization_id=p_organization_id and report.business_date=p_business_date;
end;
$$;

create table private.daily_business_report_activations(
  organization_id uuid primary key references public.organizations(id) on delete restrict,
  activated_at timestamptz not null,
  activated_by uuid references public.profiles(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.statement_timestamp(),
  check(activated_at=created_at)
);

create function public.activate_daily_business_report_system(
  p_actor_user_id uuid,p_organization_id uuid
)
returns timestamptz
language plpgsql
security definer
set search_path=''
as $$
declare activation_time timestamptz:=pg_catalog.statement_timestamp();
begin
  if not private.is_internal_admin(p_actor_user_id)or not exists(
    select 1 from public.organizations organization
    where organization.id=p_organization_id and organization.active
  )then raise exception 'daily business report activation denied' using errcode='42501';end if;
  insert into private.daily_business_report_activations(
    organization_id,activated_at,activated_by,created_at
  )values(p_organization_id,activation_time,p_actor_user_id,activation_time)
  on conflict(organization_id)do nothing;
  return(select activation.activated_at from private.daily_business_report_activations activation
    where activation.organization_id=p_organization_id);
end;
$$;

create table private.daily_business_report_generation_jobs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  business_date date not null,
  due_at timestamptz not null,
  state text not null default 'pending' check(state in('pending','running','retry','completed','failed')),
  attempt_count integer not null default 0 check(attempt_count between 0 and 8),
  max_attempts integer not null default 8 check(max_attempts between 1 and 8),
  requeue_count integer not null default 0 check(requeue_count between 0 and 3),
  next_attempt_at timestamptz not null,
  lease_token uuid,
  leased_by uuid,
  lease_expires_at timestamptz,
  error_code text,
  source_watermark text not null,
  created_at timestamptz not null default pg_catalog.statement_timestamp(),
  updated_at timestamptz not null default pg_catalog.statement_timestamp(),
  completed_at timestamptz,
  constraint daily_business_report_generation_jobs_lease_check check(
    (state='running' and lease_token is not null and leased_by is not null and lease_expires_at is not null)
    or (state<>'running' and lease_token is null and leased_by is null and lease_expires_at is null)
  ),
  constraint daily_business_report_generation_jobs_completion_check check(
    (state='completed' and completed_at is not null and error_code is null)
    or (state<>'completed' and completed_at is null)
  ),
  constraint daily_business_report_generation_jobs_error_check check(
    error_code is null or (error_code=pg_catalog.btrim(error_code)
      and pg_catalog.length(error_code) between 1 and 80 and error_code~'^[a-z0-9_:-]+$')
  ),
  constraint daily_business_report_generation_jobs_watermark_check check(
    source_watermark=pg_catalog.btrim(source_watermark)
      and pg_catalog.length(source_watermark) between 1 and 500
  ),
  unique(organization_id,business_date)
);
create index daily_business_report_generation_jobs_claim_idx
  on private.daily_business_report_generation_jobs(next_attempt_at,due_at,created_at,id)
  where state in('pending','retry');
create index daily_business_report_generation_jobs_lease_idx
  on private.daily_business_report_generation_jobs(lease_expires_at,id)
  where state='running';

create table private.daily_business_report_job_recovery_audit(
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references private.daily_business_report_generation_jobs(id) on delete restrict,
  organization_id uuid not null references public.organizations(id) on delete restrict,
  previous_attempt_count integer not null check(previous_attempt_count between 0 and 8),
  previous_error_code text not null,
  recovery_reason text not null check(recovery_reason=pg_catalog.btrim(recovery_reason)
    and pg_catalog.length(recovery_reason)between 1 and 200),
  recovered_at timestamptz not null default pg_catalog.statement_timestamp(),
  recovered_by uuid not null references public.profiles(id) on delete restrict
);
create index daily_business_report_job_recovery_audit_job_idx
  on private.daily_business_report_job_recovery_audit(job_id,recovered_at desc);

create function public.enqueue_daily_business_report_generation_job(
  p_organization_id uuid,p_business_date date,p_source_watermark text
)
returns table(job_id uuid,state text,due_at timestamptz)
language plpgsql
security definer
set search_path=''
as $$
#variable_conflict use_column
declare calculated_due_at timestamptz;activation_cutoff timestamptz;
begin
  if p_business_date is null or p_source_watermark is null
    or p_source_watermark<>pg_catalog.btrim(p_source_watermark)
    or pg_catalog.length(p_source_watermark) not between 1 and 500
    or not exists(select 1 from public.organizations organization
      where organization.id=p_organization_id and organization.active)
  then raise exception 'invalid daily business report job' using errcode='22023'; end if;
  calculated_due_at:=private.daily_business_report_organization_due_at(p_organization_id,p_business_date);
  select activation.activated_at into activation_cutoff
  from private.daily_business_report_activations activation
  where activation.organization_id=p_organization_id;
  if calculated_due_at is null or activation_cutoff is null or calculated_due_at<=activation_cutoff then
    raise exception 'daily business report is outside the active reporting window' using errcode='55000';
  end if;
  return query
  insert into private.daily_business_report_generation_jobs(
    organization_id,business_date,due_at,next_attempt_at,source_watermark
  ) values(p_organization_id,p_business_date,calculated_due_at,calculated_due_at,p_source_watermark)
  on conflict(organization_id,business_date) do update set
    due_at=calculated_due_at,
    state=case when daily_business_report_generation_jobs.source_watermark
      is distinct from excluded.source_watermark then'pending'
      else daily_business_report_generation_jobs.state end,
    attempt_count=case when daily_business_report_generation_jobs.source_watermark
      is distinct from excluded.source_watermark then 0
      else daily_business_report_generation_jobs.attempt_count end,
    next_attempt_at=case when daily_business_report_generation_jobs.source_watermark
      is distinct from excluded.source_watermark then calculated_due_at
      else daily_business_report_generation_jobs.next_attempt_at end,
    lease_token=case when daily_business_report_generation_jobs.source_watermark
      is distinct from excluded.source_watermark then null
      else daily_business_report_generation_jobs.lease_token end,
    leased_by=case when daily_business_report_generation_jobs.source_watermark
      is distinct from excluded.source_watermark then null
      else daily_business_report_generation_jobs.leased_by end,
    lease_expires_at=case when daily_business_report_generation_jobs.source_watermark
      is distinct from excluded.source_watermark then null
      else daily_business_report_generation_jobs.lease_expires_at end,
    error_code=case when daily_business_report_generation_jobs.source_watermark
      is distinct from excluded.source_watermark then null
      else daily_business_report_generation_jobs.error_code end,
    completed_at=case when daily_business_report_generation_jobs.source_watermark
      is distinct from excluded.source_watermark then null
      else daily_business_report_generation_jobs.completed_at end,
    source_watermark=excluded.source_watermark,
    updated_at=pg_catalog.statement_timestamp()
  returning daily_business_report_generation_jobs.id,
    daily_business_report_generation_jobs.state,daily_business_report_generation_jobs.due_at;
end;
$$;

create function public.claim_daily_business_report_generation_jobs(
  p_worker_id uuid,p_limit integer default 20,p_lease_seconds integer default 120
)
returns table(
  job_id uuid,lease_token uuid,organization_id uuid,business_date date,due_at timestamptz,
  source_watermark text,attempt_count integer,lease_expires_at timestamptz
)
language plpgsql
security definer
set search_path=''
as $$
declare server_now timestamptz:=pg_catalog.statement_timestamp();
begin
  if p_worker_id is null or p_limit not between 1 and 100
    or p_lease_seconds not between 30 and 600
  then raise exception 'invalid daily business report claim' using errcode='22023'; end if;
  update private.daily_business_report_generation_jobs job set
    state=case when job.attempt_count>=job.max_attempts then'failed'else'retry'end,
    next_attempt_at=case when job.attempt_count>=job.max_attempts then job.next_attempt_at else server_now end,
    error_code='lease_expired',lease_token=null,leased_by=null,lease_expires_at=null,
    updated_at=server_now
  where job.state='running' and job.lease_expires_at<=server_now;
  return query
  with candidates as materialized(
    select job.id from private.daily_business_report_generation_jobs job
    where job.state in('pending','retry') and job.due_at<=server_now
      and job.next_attempt_at<=server_now and job.attempt_count<job.max_attempts
    order by job.next_attempt_at,job.due_at,job.created_at,job.id
    for update of job skip locked limit p_limit
  ),claimed as(
    update private.daily_business_report_generation_jobs job set
      state='running',attempt_count=job.attempt_count+1,lease_token=gen_random_uuid(),
      leased_by=p_worker_id,lease_expires_at=server_now+pg_catalog.make_interval(secs=>p_lease_seconds),
      error_code=null,updated_at=server_now
    from candidates where job.id=candidates.id returning job.*
  )
  select claimed.id,claimed.lease_token,claimed.organization_id,claimed.business_date,
    claimed.due_at,claimed.source_watermark,claimed.attempt_count,claimed.lease_expires_at
  from claimed order by claimed.created_at,claimed.id;
end;
$$;

create function public.finalize_daily_business_report_generation_job(
  p_job_id uuid,p_lease_token uuid,p_organization_id uuid,p_business_date date,
  p_schema_version integer,p_source_cutoff_at timestamptz,p_payload jsonb,
  p_source_watermark text,p_generation_reason text
)
returns table(report_id uuid,revision_id uuid,revision integer,created boolean)
language plpgsql
security definer
set search_path=''
as $$
#variable_conflict use_column
declare job private.daily_business_report_generation_jobs%rowtype;
  report public.daily_business_reports%rowtype;
  current_revision_row public.daily_business_report_revisions%rowtype;
  saved_revision public.daily_business_report_revisions%rowtype;
  snapshot jsonb;payload_hash text;next_revision integer;
  server_now timestamptz:=pg_catalog.statement_timestamp();
begin
  select * into job from private.daily_business_report_generation_jobs candidate
  where candidate.id=p_job_id for update;
  if job.id is null or job.state<>'running' or job.lease_token<>p_lease_token
    or job.lease_expires_at<=server_now or job.organization_id<>p_organization_id
    or job.business_date<>p_business_date or job.source_watermark<>p_source_watermark
  then raise exception 'daily business report lease is not active' using errcode='55000'; end if;
  if p_schema_version<>1 or p_source_cutoff_at is null or p_payload is null
    or p_source_cutoff_at>server_now
    or p_source_cutoff_at<job.due_at or pg_catalog.jsonb_typeof(p_payload)<>'object'
    or p_source_watermark is null or p_source_watermark<>pg_catalog.btrim(p_source_watermark)
    or pg_catalog.length(p_source_watermark)not between 1 and 500
    or p_generation_reason not in('initial','late_submission','authoritative_report_changed','source_correction')
  then raise exception 'invalid daily business report finalization' using errcode='22023';end if;
  snapshot:=private.daily_business_report_eligibility_snapshot(p_organization_id,p_business_date);
  perform private.validate_daily_business_report_payload(
    p_organization_id,p_business_date,p_payload,snapshot);
  payload_hash:=encode(extensions.digest(pg_catalog.convert_to(pg_catalog.jsonb_build_object(
    'schema_version',p_schema_version,'eligibility',snapshot,'payload',p_payload
  )::text,'UTF8'),'sha256'),'hex');

  insert into public.daily_business_reports(organization_id,business_date)
  values(p_organization_id,p_business_date)
  on conflict(organization_id,business_date)do nothing;
  select * into report from public.daily_business_reports candidate
  where candidate.organization_id=p_organization_id and candidate.business_date=p_business_date
  for update;
  select * into current_revision_row from public.daily_business_report_revisions candidate
  where candidate.report_id=report.id and candidate.revision=report.current_revision;
  if current_revision_row.id is not null
    and current_revision_row.canonical_payload_hash=payload_hash
    and current_revision_row.source_watermark=p_source_watermark
    and current_revision_row.source_cutoff_at=p_source_cutoff_at
  then
    saved_revision:=current_revision_row;
    created:=false;
  else
    next_revision:=report.current_revision+1;
    if(next_revision=1 and p_generation_reason<>'initial')
      or(next_revision>1 and p_generation_reason='initial')
    then raise exception 'invalid daily business report generation reason' using errcode='22023';end if;
    insert into public.daily_business_report_revisions(
      report_id,organization_id,business_date,schema_version,revision,source_cutoff_at,
      eligibility_snapshot,payload,canonical_payload_hash,source_watermark,generation_reason,
      generated_at,finalized_at
    )values(
      report.id,p_organization_id,p_business_date,p_schema_version,next_revision,p_source_cutoff_at,
      snapshot,p_payload,payload_hash,p_source_watermark,p_generation_reason,server_now,server_now
    )returning * into saved_revision;
    update public.daily_business_reports candidate set current_revision=next_revision
    where candidate.id=report.id;
    created:=true;
  end if;
  update private.daily_business_report_generation_jobs candidate set
    state='completed',error_code=null,lease_token=null,leased_by=null,lease_expires_at=null,
    completed_at=server_now,updated_at=server_now
  where candidate.id=job.id;
  return query select report.id,saved_revision.id,saved_revision.revision,created;
end;
$$;

create function public.release_daily_business_report_generation_job(
  p_job_id uuid,p_lease_token uuid,p_result text,p_error_code text
)
returns table(job_id uuid,state text,next_attempt_at timestamptz)
language plpgsql
security definer
set search_path=''
as $$
#variable_conflict use_column
declare job private.daily_business_report_generation_jobs%rowtype;
  next_state text;retry_at timestamptz;clean_error text;
  server_now timestamptz:=pg_catalog.statement_timestamp();
begin
  clean_error:=nullif(pg_catalog.btrim(coalesce(p_error_code,'')),'');
  if p_job_id is null or p_lease_token is null or p_result not in('retry','failed')
    or clean_error is null or pg_catalog.length(clean_error)>80
    or clean_error!~'^[a-z0-9_:-]+$'
  then raise exception 'invalid daily business report release' using errcode='22023';end if;
  select * into job from private.daily_business_report_generation_jobs candidate
  where candidate.id=p_job_id for update;
  if job.id is null or job.state<>'running' or job.lease_token<>p_lease_token
    or job.lease_expires_at<=server_now
  then raise exception 'daily business report lease is not active' using errcode='55000';end if;
  next_state:=case when p_result='retry'and job.attempt_count>=job.max_attempts then'failed'else p_result end;
  retry_at:=case when next_state='retry'then server_now+pg_catalog.make_interval(secs=>
    least((30*pg_catalog.power(2,job.attempt_count-1))::integer,3600))
    else job.next_attempt_at end;
  return query update private.daily_business_report_generation_jobs candidate set
    state=next_state,next_attempt_at=retry_at,error_code=clean_error,
    lease_token=null,leased_by=null,lease_expires_at=null,completed_at=null,updated_at=server_now
  where candidate.id=job.id returning candidate.id,candidate.state,candidate.next_attempt_at;
end;
$$;

create function public.requeue_failed_daily_business_report_generation_job(
  p_actor_user_id uuid,p_job_id uuid,p_expected_source_watermark text,p_recovery_reason text
)
returns table(job_id uuid,state text,requeue_count integer)
language plpgsql
security definer
set search_path=''
as $$
#variable_conflict use_column
declare job private.daily_business_report_generation_jobs%rowtype;
  clean_reason text:=pg_catalog.btrim(coalesce(p_recovery_reason,''));
  server_now timestamptz:=pg_catalog.statement_timestamp();
begin
  if not private.is_internal_admin(p_actor_user_id)or pg_catalog.length(clean_reason)not between 1 and 200
    or p_expected_source_watermark is null
  then raise exception 'daily business report recovery denied' using errcode='42501';end if;
  select * into job from private.daily_business_report_generation_jobs candidate
  where candidate.id=p_job_id for update;
  if job.id is null or job.state<>'failed'or job.source_watermark<>p_expected_source_watermark
    or job.requeue_count>=3
  then raise exception 'daily business report job is not recoverable' using errcode='55000';end if;
  insert into private.daily_business_report_job_recovery_audit(
    job_id,organization_id,previous_attempt_count,previous_error_code,recovery_reason,recovered_by
  )values(job.id,job.organization_id,job.attempt_count,coalesce(job.error_code,'unspecified'),
    clean_reason,p_actor_user_id);
  return query update private.daily_business_report_generation_jobs candidate set
    state='retry',attempt_count=0,requeue_count=candidate.requeue_count+1,
    next_attempt_at=server_now,error_code=null,completed_at=null,updated_at=server_now
  where candidate.id=job.id returning candidate.id,candidate.state,candidate.requeue_count;
end;
$$;

alter table private.daily_report_timezones enable row level security;
alter table public.daily_report_branch_lifecycle enable row level security;
alter table public.daily_report_module_applicability enable row level security;
alter table public.daily_business_reports enable row level security;
alter table public.daily_business_report_revisions enable row level security;
alter table private.daily_business_report_activations enable row level security;
alter table private.daily_business_report_generation_jobs enable row level security;
alter table private.daily_business_report_job_recovery_audit enable row level security;

revoke all on table private.daily_report_timezones from public,anon,authenticated,service_role;
revoke all on table public.daily_report_branch_lifecycle from public,anon,authenticated,service_role;
revoke all on table public.daily_report_module_applicability from public,anon,authenticated,service_role;
revoke all on table public.daily_business_reports from public,anon,authenticated,service_role;
revoke all on table public.daily_business_report_revisions from public,anon,authenticated,service_role;
revoke all on table private.daily_business_report_activations from public,anon,authenticated,service_role;
revoke all on table private.daily_business_report_generation_jobs from public,anon,authenticated,service_role;
revoke all on table private.daily_business_report_job_recovery_audit from public,anon,authenticated,service_role;

revoke all on function private.guard_daily_report_effective_period_overlap() from public,anon,authenticated,service_role;
revoke all on function private.record_daily_report_branch_lifecycle(uuid,uuid,boolean,text,date) from public,anon,authenticated,service_role;
revoke all on function private.seed_daily_report_module_applicability(uuid,uuid,date) from public,anon,authenticated,service_role;
revoke all on function private.capture_daily_report_branch_lifecycle() from public,anon,authenticated,service_role;
revoke all on function private.record_daily_report_module_applicability(uuid,uuid,text,boolean,date,uuid) from public,anon,authenticated,service_role;
revoke all on function private.guard_daily_business_report_identity() from public,anon,authenticated,service_role;
revoke all on function private.guard_daily_business_report_revision() from public,anon,authenticated,service_role;
revoke all on function private.daily_business_report_branch_close_at(date,text) from public,anon,authenticated,service_role;
revoke all on function private.daily_business_report_organization_due_at(uuid,date) from public,anon,authenticated,service_role;
revoke all on function private.daily_business_report_eligibility_snapshot(uuid,date) from public,anon,authenticated,service_role;
revoke all on function private.daily_business_report_jsonb_has_exact_keys(jsonb,text[]) from public,anon,authenticated,service_role;
revoke all on function private.validate_daily_business_report_payload(uuid,date,jsonb,jsonb) from public,anon,authenticated,service_role;

revoke all on function public.configure_daily_report_module_applicability(uuid,uuid,uuid,text,boolean,date) from public,anon,authenticated,service_role;
revoke all on function public.get_daily_business_report(uuid,uuid,date,integer) from public,anon,authenticated,service_role;
revoke all on function public.activate_daily_business_report_system(uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.enqueue_daily_business_report_generation_job(uuid,date,text) from public,anon,authenticated,service_role;
revoke all on function public.claim_daily_business_report_generation_jobs(uuid,integer,integer) from public,anon,authenticated,service_role;
revoke all on function public.finalize_daily_business_report_generation_job(uuid,uuid,uuid,date,integer,timestamptz,jsonb,text,text) from public,anon,authenticated,service_role;
revoke all on function public.release_daily_business_report_generation_job(uuid,uuid,text,text) from public,anon,authenticated,service_role;
revoke all on function public.requeue_failed_daily_business_report_generation_job(uuid,uuid,text,text) from public,anon,authenticated,service_role;

grant execute on function public.configure_daily_report_module_applicability(uuid,uuid,uuid,text,boolean,date) to service_role;
grant execute on function public.get_daily_business_report(uuid,uuid,date,integer) to service_role;
grant execute on function public.activate_daily_business_report_system(uuid,uuid) to service_role;
grant execute on function public.enqueue_daily_business_report_generation_job(uuid,date,text) to service_role;
grant execute on function public.claim_daily_business_report_generation_jobs(uuid,integer,integer) to service_role;
grant execute on function public.finalize_daily_business_report_generation_job(uuid,uuid,uuid,date,integer,timestamptz,jsonb,text,text) to service_role;
grant execute on function public.release_daily_business_report_generation_job(uuid,uuid,text,text) to service_role;
grant execute on function public.requeue_failed_daily_business_report_generation_job(uuid,uuid,text,text) to service_role;

commit;
