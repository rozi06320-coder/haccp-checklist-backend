-- Training question authoring foundation.
-- This migration stores only draft question content. It does not backfill the
-- existing Baladiyah curriculum and does not alter learner/publication RPCs.

create table public.training_question_drafts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  course_version_id uuid not null,
  lesson_id uuid not null,
  stable_key text not null,
  position integer not null,
  prompt_i18n jsonb not null,
  explanation_i18n jsonb not null,
  correct_option_key text not null,
  revision bigint not null default 0,
  created_at timestamptz not null default statement_timestamp(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default statement_timestamp(),
  updated_by uuid references auth.users(id) on delete set null,
  constraint training_question_drafts_id_scope_key
    unique (id, organization_id, course_version_id, lesson_id),
  constraint training_question_drafts_lesson_stable_key
    unique (lesson_id, stable_key),
  constraint training_question_drafts_lesson_position
    unique (lesson_id, position),
  constraint training_question_drafts_scope_fkey
    foreign key (lesson_id, course_version_id, organization_id)
    references public.training_lessons(id, course_version_id, organization_id)
    on delete restrict,
  constraint training_question_drafts_stable_key_check check (
    stable_key = lower(stable_key)
    and stable_key ~ '^[a-z0-9]+(?:[a-z0-9_-]*[a-z0-9])?$'
    and length(stable_key) between 1 and 120
  ),
  constraint training_question_drafts_position_check check (position > 0),
  constraint training_question_drafts_prompt_object_check check (jsonb_typeof(prompt_i18n) = 'object'),
  constraint training_question_drafts_explanation_object_check check (jsonb_typeof(explanation_i18n) = 'object'),
  constraint training_question_drafts_correct_key_check check (
    correct_option_key = lower(correct_option_key)
    and correct_option_key ~ '^[a-z0-9]+(?:[a-z0-9_-]*[a-z0-9])?$'
    and length(correct_option_key) between 1 and 40
  ),
  constraint training_question_drafts_revision_check check (revision >= 0)
);

create table public.training_question_draft_options (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  course_version_id uuid not null,
  lesson_id uuid not null,
  question_id uuid not null,
  option_key text not null,
  position integer not null,
  label_i18n jsonb not null,
  created_at timestamptz not null default statement_timestamp(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default statement_timestamp(),
  updated_by uuid references auth.users(id) on delete set null,
  constraint training_question_draft_options_id_scope_key
    unique (id, organization_id, course_version_id, lesson_id, question_id),
  constraint training_question_draft_options_question_key
    unique (question_id, option_key),
  constraint training_question_draft_options_question_position
    unique (question_id, position),
  constraint training_question_draft_options_scope_fkey
    foreign key (question_id, organization_id, course_version_id, lesson_id)
    references public.training_question_drafts(id, organization_id, course_version_id, lesson_id)
    on delete cascade,
  constraint training_question_draft_options_lesson_scope_fkey
    foreign key (lesson_id, course_version_id, organization_id)
    references public.training_lessons(id, course_version_id, organization_id)
    on delete restrict,
  constraint training_question_draft_options_key_check check (
    option_key = lower(option_key)
    and option_key ~ '^[a-z0-9]+(?:[a-z0-9_-]*[a-z0-9])?$'
    and length(option_key) between 1 and 40
  ),
  constraint training_question_draft_options_position_check check (position > 0),
  constraint training_question_draft_options_label_object_check check (jsonb_typeof(label_i18n) = 'object')
);

create index training_question_drafts_version_lesson_position_idx
  on public.training_question_drafts(organization_id, course_version_id, lesson_id, position);
create index training_question_draft_options_question_position_idx
  on public.training_question_draft_options(question_id, position);

create or replace function private.training_question_localized_text_valid(
  target_version_id uuid,
  target_content jsonb,
  max_length integer
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  supported_locale text;
  content_locale text;
  locale_count integer;
begin
  if jsonb_typeof(target_content) <> 'object' then
    return false;
  end if;

  select cardinality(version.supported_locales)
    into locale_count
  from public.training_course_versions version
  where version.id = target_version_id;

  if not found then
    return false;
  end if;

  if (select count(*) from jsonb_object_keys(target_content)) <> locale_count then
    return false;
  end if;

  for supported_locale in
    select unnest((select version.supported_locales from public.training_course_versions version where version.id = target_version_id))
  loop
    if jsonb_typeof(target_content -> supported_locale) <> 'string'
      or length(btrim(target_content ->> supported_locale)) not between 1 and max_length then
      return false;
    end if;
  end loop;

  for content_locale in select jsonb_object_keys(target_content)
  loop
    if not exists (
      select 1 from public.training_course_versions version
      where version.id = target_version_id
        and content_locale = any(version.supported_locales)
    ) then
      return false;
    end if;
  end loop;

  return true;
end;
$$;

create or replace function private.enforce_training_question_draft_scope()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  version_status text;
  lesson_type text;
  lesson_version_id uuid;
  lesson_org_id uuid;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    if tg_op = 'UPDATE' and (
      new.id is distinct from old.id
      or new.organization_id is distinct from old.organization_id
      or new.course_version_id is distinct from old.course_version_id
      or new.lesson_id is distinct from old.lesson_id
      or new.stable_key is distinct from old.stable_key
    ) then
      raise exception 'Training question identity is immutable' using errcode = '55000';
    end if;
  end if;

  if tg_op in ('INSERT', 'UPDATE') then
    select version.status, lesson.lesson_type, lesson.course_version_id, lesson.organization_id
      into version_status, lesson_type, lesson_version_id, lesson_org_id
    from public.training_lessons lesson
    join public.training_course_versions version
      on version.id = lesson.course_version_id
     and version.organization_id = lesson.organization_id
    where lesson.id = new.lesson_id
      and lesson.course_version_id = new.course_version_id
      and lesson.organization_id = new.organization_id;

    if version_status is distinct from 'draft' or lesson_type is distinct from 'quiz'
      or lesson_version_id is null or lesson_org_id is null then
      raise exception 'Training questions require a quiz lesson in a draft course version' using errcode = '55000';
    end if;

    if not private.training_question_localized_text_valid(new.course_version_id, new.prompt_i18n, 4000)
      or not private.training_question_localized_text_valid(new.course_version_id, new.explanation_i18n, 4000) then
      raise exception 'Training question locale content is invalid' using errcode = '22023';
    end if;
  end if;

  if tg_op in ('UPDATE', 'DELETE') then
    select version.status into version_status
    from public.training_course_versions version
    where version.id = old.course_version_id
      and version.organization_id = old.organization_id;
    if version_status is distinct from 'draft' then
      raise exception 'Published or retired Training question content is immutable' using errcode = '55000';
    end if;
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create or replace function private.enforce_training_question_option_scope()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  version_status text;
  question_org_id uuid;
  question_version_id uuid;
  question_lesson_id uuid;
begin
  if tg_op = 'UPDATE' and (
    new.id is distinct from old.id
    or new.organization_id is distinct from old.organization_id
    or new.course_version_id is distinct from old.course_version_id
    or new.lesson_id is distinct from old.lesson_id
    or new.question_id is distinct from old.question_id
    or new.option_key is distinct from old.option_key
  ) then
    raise exception 'Training question option identity is immutable' using errcode = '55000';
  end if;

  if tg_op in ('INSERT', 'UPDATE') then
    select question.organization_id, question.course_version_id, question.lesson_id, version.status
      into question_org_id, question_version_id, question_lesson_id, version_status
    from public.training_question_drafts question
    join public.training_course_versions version
      on version.id = question.course_version_id
     and version.organization_id = question.organization_id
    where question.id = new.question_id;
    if question_org_id is distinct from new.organization_id
      or question_version_id is distinct from new.course_version_id
      or question_lesson_id is distinct from new.lesson_id
      or version_status is distinct from 'draft' then
      raise exception 'Training question options require the same draft question scope' using errcode = '55000';
    end if;
    if not private.training_question_localized_text_valid(new.course_version_id, new.label_i18n, 1000) then
      raise exception 'Training question option locale content is invalid' using errcode = '22023';
    end if;
  end if;

  if tg_op = 'DELETE' then
    select version.status into version_status
    from public.training_course_versions version
    where version.id = old.course_version_id
      and version.organization_id = old.organization_id;
    if version_status is distinct from 'draft' then
      raise exception 'Published or retired Training question options are immutable' using errcode = '55000';
    end if;
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create or replace function private.enforce_training_question_revision()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.revision <> old.revision + 1 then
    raise exception 'Training question revision is stale' using errcode = '40001';
  end if;
  return new;
end;
$$;

create or replace function private.validate_training_question_draft_complete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  option_count integer;
  matching_correct integer;
  target_question_id uuid;
begin
  if tg_table_name = 'training_question_drafts' then
    if tg_op = 'DELETE' then
      target_question_id := old.id;
    else
      target_question_id := new.id;
    end if;
  elsif tg_table_name = 'training_question_draft_options' then
    if tg_op = 'DELETE' then
      target_question_id := old.question_id;
    else
      target_question_id := new.question_id;
    end if;
  else
    return null;
  end if;

  if not exists (select 1 from public.training_question_drafts question where question.id = target_question_id) then
    return null;
  end if;

  select count(option.id)::integer,
    count(*) filter (where option.option_key = question.correct_option_key)::integer
    into option_count, matching_correct
  from public.training_question_drafts question
  left join public.training_question_draft_options option on option.question_id = question.id
  where question.id = target_question_id
  group by question.correct_option_key;

  if option_count < 2 or matching_correct <> 1 then
    raise exception 'Training question requires at least two options and a valid correct option' using errcode = '23514';
  end if;
  return null;
end;
$$;

create trigger training_question_drafts_10_scope
before insert or update or delete on public.training_question_drafts
for each row execute function private.enforce_training_question_draft_scope();

create trigger training_question_drafts_20_revision
before update on public.training_question_drafts
for each row execute function private.enforce_training_question_revision();

create trigger training_question_draft_options_10_scope
before insert or update or delete on public.training_question_draft_options
for each row execute function private.enforce_training_question_option_scope();

create constraint trigger training_question_drafts_90_complete
after insert or update or delete on public.training_question_drafts
deferrable initially deferred
for each row execute function private.validate_training_question_draft_complete();

create constraint trigger training_question_draft_options_90_complete
after insert or update or delete on public.training_question_draft_options
deferrable initially deferred
for each row execute function private.validate_training_question_draft_complete();

alter table public.training_question_drafts enable row level security;
alter table public.training_question_draft_options enable row level security;

revoke all on table public.training_question_drafts from public, anon, authenticated, service_role;
revoke all on table public.training_question_draft_options from public, anon, authenticated, service_role;
revoke all on function private.training_question_localized_text_valid(uuid, jsonb, integer) from public, anon, authenticated, service_role;
revoke all on function private.enforce_training_question_draft_scope() from public, anon, authenticated, service_role;
revoke all on function private.enforce_training_question_option_scope() from public, anon, authenticated, service_role;
revoke all on function private.enforce_training_question_revision() from public, anon, authenticated, service_role;
revoke all on function private.validate_training_question_draft_complete() from public, anon, authenticated, service_role;
grant execute on function private.training_question_localized_text_valid(uuid, jsonb, integer) to service_role;
grant execute on function private.enforce_training_question_draft_scope() to service_role;
grant execute on function private.enforce_training_question_option_scope() to service_role;
grant execute on function private.enforce_training_question_revision() to service_role;
grant execute on function private.validate_training_question_draft_complete() to service_role;

comment on table public.training_question_drafts is
  'Version-owned question authoring rows for draft course versions only; compile into the existing lesson JSON before publication.';
comment on table public.training_question_draft_options is
  'Version-owned answer options for draft question authoring; learner APIs must never expose answer keys.';
