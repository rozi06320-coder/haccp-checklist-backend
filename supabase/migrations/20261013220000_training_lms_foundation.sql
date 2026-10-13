-- Training LMS Phase 2A: employee credentials, persistent learner sessions,
-- and immutable versioned course-content foundations. This migration does not
-- change the current learner portal or create progress/enrollment records.

create table public.operational_staff_training_credentials (
  employee_id uuid primary key,
  organization_id uuid not null,
  pin_hash text not null,
  salt text not null,
  kdf_version integer not null,
  cost integer not null,
  block_size integer not null,
  parallelization integer not null,
  credential_version uuid not null default gen_random_uuid(),
  status text not null default 'active',
  failed_attempt_count integer not null default 0,
  locked_until timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  constraint operational_staff_training_credentials_employee_org_fkey
    foreign key (employee_id, organization_id)
    references public.operational_staff(id, organization_id)
    on delete restrict,
  constraint operational_staff_training_credentials_kdf_check check (
    length(pin_hash) = 66
    and left(pin_hash, 2) = E'\\x'
    and substring(pin_hash from 3) ~ '^[0-9a-f]{64}$'
    and length(salt) = 34
    and left(salt, 2) = E'\\x'
    and substring(salt from 3) ~ '^[0-9a-f]{32}$'
    and kdf_version = 1
    and cost = 16384
    and block_size = 8
    and parallelization = 1
  ),
  constraint operational_staff_training_credentials_status_check
    check (status in ('active', 'locked', 'revoked')),
  constraint operational_staff_training_credentials_failures_check
    check (failed_attempt_count >= 0),
  constraint operational_staff_training_credentials_locked_check
    check (status <> 'locked' or locked_until is not null)
);

create index operational_staff_training_credentials_organization_idx
  on public.operational_staff_training_credentials(organization_id, employee_id);
create index operational_staff_training_credentials_lock_state_idx
  on public.operational_staff_training_credentials(status, locked_until)
  where status = 'locked';

create table public.training_learner_sessions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  employee_id uuid not null,
  branch_id_at_auth uuid not null,
  credential_version uuid not null,
  identity_method text not null default 'branch_pin_employee_pin',
  issued_at timestamptz not null default statement_timestamp(),
  expires_at timestamptz not null,
  last_seen_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  constraint training_learner_sessions_employee_org_fkey
    foreign key (employee_id, organization_id)
    references public.operational_staff(id, organization_id)
    on delete restrict,
  constraint training_learner_sessions_branch_org_fkey
    foreign key (branch_id_at_auth, organization_id)
    references public.branches(id, organization_id)
    on delete restrict,
  constraint training_learner_sessions_identity_method_check
    check (identity_method = 'branch_pin_employee_pin'),
  constraint training_learner_sessions_expiry_check
    check (expires_at > issued_at),
  constraint training_learner_sessions_last_seen_check
    check (last_seen_at is null or (last_seen_at >= issued_at and last_seen_at <= expires_at)),
  constraint training_learner_sessions_revoked_check
    check (revoked_at is null or revoked_at >= issued_at)
);

create index training_learner_sessions_employee_idx
  on public.training_learner_sessions(organization_id, employee_id, issued_at desc);
create index training_learner_sessions_expires_idx
  on public.training_learner_sessions(expires_at);
create index training_learner_sessions_active_idx
  on public.training_learner_sessions(organization_id, employee_id, expires_at)
  where revoked_at is null;
create index training_learner_sessions_revoked_idx
  on public.training_learner_sessions(revoked_at)
  where revoked_at is not null;

create table public.training_courses (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  course_key text not null,
  status text not null default 'active',
  created_at timestamptz not null default statement_timestamp(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default statement_timestamp(),
  updated_by uuid references auth.users(id) on delete set null,
  archived_at timestamptz,
  archived_by uuid references auth.users(id) on delete set null,
  constraint training_courses_id_organization_key unique(id, organization_id),
  constraint training_courses_organization_course_key_key unique(organization_id, course_key),
  constraint training_courses_course_key_check check (
    course_key = lower(course_key)
    and course_key ~ '^[a-z0-9]+(?:[a-z0-9_-]*[a-z0-9])?$'
    and length(course_key) between 1 and 120
  ),
  constraint training_courses_status_check check (status in ('active', 'archived')),
  constraint training_courses_archive_check check (
    (status = 'active' and archived_at is null and archived_by is null)
    or (status = 'archived' and archived_at is not null)
  )
);

create table public.training_course_versions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  course_id uuid not null,
  version_number integer not null,
  status text not null default 'draft',
  default_locale text not null,
  supported_locales text[] not null,
  title_i18n jsonb not null default '{}'::jsonb,
  description_i18n jsonb not null default '{}'::jsonb,
  content_schema_version integer not null default 1,
  revision bigint not null default 0,
  content_hash text,
  created_at timestamptz not null default statement_timestamp(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default statement_timestamp(),
  updated_by uuid references auth.users(id) on delete set null,
  published_at timestamptz,
  published_by uuid references auth.users(id) on delete restrict,
  retired_at timestamptz,
  retired_by uuid references auth.users(id) on delete restrict,
  constraint training_course_versions_id_organization_key unique(id, organization_id),
  constraint training_course_versions_course_number_key unique(course_id, version_number),
  constraint training_course_versions_course_org_fkey
    foreign key (course_id, organization_id)
    references public.training_courses(id, organization_id)
    on delete restrict,
  constraint training_course_versions_number_check check (version_number > 0),
  constraint training_course_versions_status_check check (status in ('draft', 'published', 'retired')),
  constraint training_course_versions_default_locale_check check (
    default_locale = btrim(default_locale)
    and default_locale ~ '^[a-z]{2,3}(?:-[A-Z]{2})?$'
  ),
  constraint training_course_versions_locales_check check (
    cardinality(supported_locales) between 1 and 20
    and array_position(supported_locales, null) is null
    and default_locale = any(supported_locales)
  ),
  constraint training_course_versions_title_i18n_check check (jsonb_typeof(title_i18n) = 'object'),
  constraint training_course_versions_description_i18n_check check (jsonb_typeof(description_i18n) = 'object'),
  constraint training_course_versions_schema_check check (content_schema_version > 0),
  constraint training_course_versions_revision_check check (revision >= 0),
  constraint training_course_versions_content_hash_check check (
    content_hash is null or length(btrim(content_hash)) between 1 and 256
  ),
  constraint training_course_versions_lifecycle_check check (
    (status = 'draft'
      and published_at is null and published_by is null
      and retired_at is null and retired_by is null)
    or (status = 'published'
      and published_at is not null and published_by is not null
      and retired_at is null and retired_by is null)
    or (status = 'retired'
      and published_at is not null and published_by is not null
      and retired_at is not null and retired_by is not null
      and retired_at >= published_at)
  )
);

create unique index training_course_versions_one_draft_idx
  on public.training_course_versions(course_id)
  where status = 'draft';
create index training_course_versions_scope_status_idx
  on public.training_course_versions(organization_id, course_id, status, version_number desc);

create table public.training_modules (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  course_version_id uuid not null,
  stable_key text not null,
  position integer not null,
  category_key text,
  title_i18n jsonb not null default '{}'::jsonb,
  description_i18n jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default statement_timestamp(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default statement_timestamp(),
  updated_by uuid references auth.users(id) on delete set null,
  constraint training_modules_id_version_organization_key unique(id, course_version_id, organization_id),
  constraint training_modules_version_stable_key_key unique(course_version_id, stable_key),
  constraint training_modules_version_position_key unique(course_version_id, position),
  constraint training_modules_version_org_fkey
    foreign key (course_version_id, organization_id)
    references public.training_course_versions(id, organization_id)
    on delete restrict,
  constraint training_modules_stable_key_check check (
    stable_key = lower(stable_key)
    and stable_key ~ '^[a-z0-9]+(?:[a-z0-9_-]*[a-z0-9])?$'
    and length(stable_key) between 1 and 120
  ),
  constraint training_modules_position_check check (position >= 0),
  constraint training_modules_category_key_check check (
    category_key is null
    or (
      category_key = lower(category_key)
      and category_key ~ '^[a-z0-9]+(?:[a-z0-9_-]*[a-z0-9])?$'
      and length(category_key) between 1 and 120
    )
  ),
  constraint training_modules_title_i18n_check check (jsonb_typeof(title_i18n) = 'object'),
  constraint training_modules_description_i18n_check check (jsonb_typeof(description_i18n) = 'object'),
  constraint training_modules_metadata_check check (jsonb_typeof(metadata) = 'object')
);

create index training_modules_version_position_idx
  on public.training_modules(course_version_id, position);

create table public.training_lessons (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  course_version_id uuid not null,
  module_id uuid not null,
  stable_key text not null,
  position integer not null,
  lesson_type text not null,
  required boolean not null default true,
  title_i18n jsonb not null default '{}'::jsonb,
  objective_i18n jsonb not null default '{}'::jsonb,
  content_i18n jsonb not null default '{}'::jsonb,
  estimated_duration_seconds integer,
  minimum_engagement_seconds integer not null default 0,
  pass_threshold_bps integer,
  max_attempts integer,
  retry_delay_seconds integer not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default statement_timestamp(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default statement_timestamp(),
  updated_by uuid references auth.users(id) on delete set null,
  constraint training_lessons_id_version_organization_key unique(id, course_version_id, organization_id),
  constraint training_lessons_module_stable_key_key unique(module_id, stable_key),
  constraint training_lessons_module_position_key unique(module_id, position),
  constraint training_lessons_version_org_fkey
    foreign key (course_version_id, organization_id)
    references public.training_course_versions(id, organization_id)
    on delete restrict,
  constraint training_lessons_module_version_org_fkey
    foreign key (module_id, course_version_id, organization_id)
    references public.training_modules(id, course_version_id, organization_id)
    on delete restrict,
  constraint training_lessons_stable_key_check check (
    stable_key = lower(stable_key)
    and stable_key ~ '^[a-z0-9]+(?:[a-z0-9_-]*[a-z0-9])?$'
    and length(stable_key) between 1 and 120
  ),
  constraint training_lessons_position_check check (position >= 0),
  constraint training_lessons_type_check check (lesson_type in ('reading', 'key_points', 'video', 'quiz')),
  constraint training_lessons_title_i18n_check check (jsonb_typeof(title_i18n) = 'object'),
  constraint training_lessons_objective_i18n_check check (jsonb_typeof(objective_i18n) = 'object'),
  constraint training_lessons_content_i18n_check check (jsonb_typeof(content_i18n) = 'object'),
  constraint training_lessons_metadata_check check (jsonb_typeof(metadata) = 'object'),
  constraint training_lessons_estimated_duration_check check (
    estimated_duration_seconds is null or estimated_duration_seconds >= 0
  ),
  constraint training_lessons_minimum_engagement_check check (minimum_engagement_seconds >= 0),
  constraint training_lessons_pass_threshold_check check (
    pass_threshold_bps is null or pass_threshold_bps between 0 and 10000
  ),
  constraint training_lessons_max_attempts_check check (max_attempts is null or max_attempts > 0),
  constraint training_lessons_retry_delay_check check (retry_delay_seconds >= 0),
  constraint training_lessons_quiz_configuration_check check (
    (lesson_type = 'quiz' and pass_threshold_bps is not null)
    or (lesson_type <> 'quiz' and pass_threshold_bps is null and max_attempts is null and retry_delay_seconds = 0)
  )
);

create index training_lessons_module_position_idx
  on public.training_lessons(module_id, position);
create index training_lessons_version_required_idx
  on public.training_lessons(course_version_id, required);

create or replace function private.apply_training_lesson_defaults()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.lesson_type = 'quiz' and new.pass_threshold_bps is null then
    new.pass_threshold_bps := 8000;
  end if;
  return new;
end;
$$;

create or replace function private.enforce_training_draft_content()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  old_version_status text;
  new_version_status text;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    select version.status
    into old_version_status
    from public.training_course_versions version
    where version.id = old.course_version_id
      and version.organization_id = old.organization_id;

    if old_version_status is distinct from 'draft' then
      raise exception 'Published or retired Training content is immutable' using errcode = '55000';
    end if;
  end if;

  if tg_op in ('INSERT', 'UPDATE') then
    select version.status
    into new_version_status
    from public.training_course_versions version
    where version.id = new.course_version_id
      and version.organization_id = new.organization_id;

    -- Let the composite FK report a missing/cross-organization version. A
    -- version found in this scope must still be an editable draft.
    if new_version_status is not null and new_version_status <> 'draft' then
      raise exception 'Published or retired Training content is immutable' using errcode = '55000';
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create or replace function private.enforce_training_course_version_immutability()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status = 'retired' then
    raise exception 'Retired Training course versions are immutable' using errcode = '55000';
  end if;

  if old.status = 'published' then
    if tg_op = 'DELETE' then
      raise exception 'Published Training course versions are immutable' using errcode = '55000';
    end if;

    if new.status = 'retired'
      and new.id = old.id
      and new.organization_id = old.organization_id
      and new.course_id = old.course_id
      and new.version_number = old.version_number
      and new.default_locale = old.default_locale
      and new.supported_locales = old.supported_locales
      and new.title_i18n = old.title_i18n
      and new.description_i18n = old.description_i18n
      and new.content_schema_version = old.content_schema_version
      and new.revision = old.revision
      and new.content_hash is not distinct from old.content_hash
      and new.created_at = old.created_at
      and new.created_by is not distinct from old.created_by
      and new.published_at = old.published_at
      and new.published_by = old.published_by
      and new.retired_at is not null
      and new.retired_by is not null then
      return new;
    end if;

    raise exception 'Published Training course version content is immutable' using errcode = '55000';
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create trigger training_lessons_05_defaults
before insert or update on public.training_lessons
for each row execute function private.apply_training_lesson_defaults();

create trigger training_modules_10_draft_guard
before insert or update or delete on public.training_modules
for each row execute function private.enforce_training_draft_content();
create trigger training_lessons_10_draft_guard
before insert or update or delete on public.training_lessons
for each row execute function private.enforce_training_draft_content();
create trigger training_course_versions_10_immutability_guard
before update or delete on public.training_course_versions
for each row execute function private.enforce_training_course_version_immutability();

create trigger operational_staff_training_credentials_90_set_updated_at
before update on public.operational_staff_training_credentials
for each row execute function private.set_updated_at();
create trigger training_courses_90_set_updated_at
before update on public.training_courses
for each row execute function private.set_updated_at();
create trigger training_course_versions_90_set_updated_at
before update on public.training_course_versions
for each row execute function private.set_updated_at();
create trigger training_modules_90_set_updated_at
before update on public.training_modules
for each row execute function private.set_updated_at();
create trigger training_lessons_90_set_updated_at
before update on public.training_lessons
for each row execute function private.set_updated_at();

alter table public.operational_staff_training_credentials enable row level security;
alter table public.training_learner_sessions enable row level security;
alter table public.training_courses enable row level security;
alter table public.training_course_versions enable row level security;
alter table public.training_modules enable row level security;
alter table public.training_lessons enable row level security;

revoke all on table public.operational_staff_training_credentials from public, anon, authenticated, service_role;
revoke all on table public.training_learner_sessions from public, anon, authenticated, service_role;
revoke all on table public.training_courses from public, anon, authenticated, service_role;
revoke all on table public.training_course_versions from public, anon, authenticated, service_role;
revoke all on table public.training_modules from public, anon, authenticated, service_role;
revoke all on table public.training_lessons from public, anon, authenticated, service_role;

create or replace function public.store_internal_admin_operational_staff_training_credential(
  actor_user_id uuid,
  target_organization_id uuid,
  target_employee_id uuid,
  new_pin_hash text,
  new_salt text,
  new_kdf_version integer,
  new_cost integer,
  new_block_size integer,
  new_parallelization integer
)
returns table(
  employee_id uuid,
  organization_id uuid,
  status text,
  credential_version uuid,
  failed_attempt_count integer,
  locked_until timestamptz,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  saved public.operational_staff_training_credentials%rowtype;
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'Access denied' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.operational_staff staff
    where staff.id = target_employee_id
      and staff.organization_id = target_organization_id
  ) then
    raise exception 'Employee not found' using errcode = 'P0002';
  end if;

  if new_pin_hash is null
    or length(new_pin_hash) <> 66
    or left(new_pin_hash, 2) <> E'\\x'
    or substring(new_pin_hash from 3) !~ '^[0-9a-fA-F]{64}$'
    or new_salt is null
    or length(new_salt) <> 34
    or left(new_salt, 2) <> E'\\x'
    or substring(new_salt from 3) !~ '^[0-9a-fA-F]{32}$'
    or new_kdf_version <> 1
    or new_cost <> 16384
    or new_block_size <> 8
    or new_parallelization <> 1 then
    raise exception 'Invalid PIN credential' using errcode = '22023';
  end if;

  insert into public.operational_staff_training_credentials as credential(
    employee_id,
    organization_id,
    pin_hash,
    salt,
    kdf_version,
    cost,
    block_size,
    parallelization,
    credential_version,
    status,
    failed_attempt_count,
    locked_until,
    created_by,
    updated_by
  ) values (
    target_employee_id,
    target_organization_id,
    lower(new_pin_hash),
    lower(new_salt),
    new_kdf_version,
    new_cost,
    new_block_size,
    new_parallelization,
    gen_random_uuid(),
    'active',
    0,
    null,
    actor_user_id,
    actor_user_id
  )
  on conflict on constraint operational_staff_training_credentials_pkey do update set
    pin_hash = excluded.pin_hash,
    salt = excluded.salt,
    kdf_version = excluded.kdf_version,
    cost = excluded.cost,
    block_size = excluded.block_size,
    parallelization = excluded.parallelization,
    credential_version = gen_random_uuid(),
    status = 'active',
    failed_attempt_count = 0,
    locked_until = null,
    updated_by = actor_user_id,
    updated_at = statement_timestamp()
  where credential.organization_id = target_organization_id
  returning credential.* into saved;

  if saved.employee_id is null then
    raise exception 'Employee scope conflict' using errcode = '42501';
  end if;

  update public.training_learner_sessions session_row
  set revoked_at = statement_timestamp()
  where session_row.organization_id = target_organization_id
    and session_row.employee_id = target_employee_id
    and session_row.revoked_at is null;

  return query select
    saved.employee_id,
    saved.organization_id,
    saved.status,
    saved.credential_version,
    saved.failed_attempt_count,
    saved.locked_until,
    saved.created_at,
    saved.updated_at;
end;
$$;

create or replace function public.revoke_internal_admin_operational_staff_training_credential(
  actor_user_id uuid,
  target_organization_id uuid,
  target_employee_id uuid
)
returns table(
  employee_id uuid,
  organization_id uuid,
  status text,
  credential_version uuid,
  failed_attempt_count integer,
  locked_until timestamptz,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  saved public.operational_staff_training_credentials%rowtype;
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'Access denied' using errcode = '42501';
  end if;

  select credential.*
  into saved
  from public.operational_staff_training_credentials credential
  where credential.employee_id = target_employee_id
    and credential.organization_id = target_organization_id
  for update;

  if saved.employee_id is null then
    raise exception 'Training credential not found' using errcode = 'P0002';
  end if;

  if saved.status <> 'revoked' then
    update public.operational_staff_training_credentials credential
    set status = 'revoked',
        credential_version = gen_random_uuid(),
        locked_until = null,
        updated_by = actor_user_id,
        updated_at = statement_timestamp()
    where credential.employee_id = target_employee_id
      and credential.organization_id = target_organization_id
    returning credential.* into saved;
  end if;

  update public.training_learner_sessions session_row
  set revoked_at = statement_timestamp()
  where session_row.organization_id = target_organization_id
    and session_row.employee_id = target_employee_id
    and session_row.revoked_at is null;

  return query select
    saved.employee_id,
    saved.organization_id,
    saved.status,
    saved.credential_version,
    saved.failed_attempt_count,
    saved.locked_until,
    saved.created_at,
    saved.updated_at;
end;
$$;

create or replace function public.get_internal_admin_operational_staff_training_credential_status(
  actor_user_id uuid,
  target_organization_id uuid,
  target_employee_id uuid
)
returns table(
  employee_id uuid,
  organization_id uuid,
  configured boolean,
  status text,
  credential_version uuid,
  failed_attempt_count integer,
  locked_until timestamptz,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'Access denied' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.operational_staff staff
    where staff.id = target_employee_id
      and staff.organization_id = target_organization_id
  ) then
    raise exception 'Employee not found' using errcode = 'P0002';
  end if;

  return query
  select
    target_employee_id,
    target_organization_id,
    credential.employee_id is not null,
    credential.status,
    credential.credential_version,
    coalesce(credential.failed_attempt_count, 0),
    credential.locked_until,
    credential.created_at,
    credential.updated_at
  from (select 1) seed
  left join public.operational_staff_training_credentials credential
    on credential.employee_id = target_employee_id
   and credential.organization_id = target_organization_id;
end;
$$;

revoke all on function private.apply_training_lesson_defaults() from public, anon, authenticated;
revoke all on function private.enforce_training_draft_content() from public, anon, authenticated;
revoke all on function private.enforce_training_course_version_immutability() from public, anon, authenticated;
grant execute on function private.apply_training_lesson_defaults() to service_role;
grant execute on function private.enforce_training_draft_content() to service_role;
grant execute on function private.enforce_training_course_version_immutability() to service_role;

revoke all on function public.store_internal_admin_operational_staff_training_credential(uuid, uuid, uuid, text, text, integer, integer, integer, integer) from public, anon, authenticated;
revoke all on function public.revoke_internal_admin_operational_staff_training_credential(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.get_internal_admin_operational_staff_training_credential_status(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.store_internal_admin_operational_staff_training_credential(uuid, uuid, uuid, text, text, integer, integer, integer, integer) to service_role;
grant execute on function public.revoke_internal_admin_operational_staff_training_credential(uuid, uuid, uuid) to service_role;
grant execute on function public.get_internal_admin_operational_staff_training_credential_status(uuid, uuid, uuid) to service_role;

comment on table public.operational_staff_training_credentials is
  'Employee-specific scrypt credentials for the future persistent Training learner identity flow. Plaintext PINs are never stored.';
comment on table public.training_learner_sessions is
  'Revocable persistent learner sessions. A future cookie carries only the session ID and expiry; employee identity is resolved server-side.';
comment on table public.training_courses is
  'Organization-scoped stable Training course identities.';
comment on table public.training_course_versions is
  'Versioned Training course metadata. Published and retired version content is immutable.';
comment on table public.training_modules is
  'Ordered modules owned by a draft/published Training course version.';
comment on table public.training_lessons is
  'Ordered version-owned lessons. Quiz grading entities are intentionally deferred beyond Phase 2A.';
