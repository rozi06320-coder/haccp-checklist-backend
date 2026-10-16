-- Phase 4B: organization-scoped Training programs and authoritative course
-- prerequisites. This migration creates no program data, course versions,
-- enrollments, or learner progress and does not enable learner feature flags.

do $$
begin
  if exists (
    select 1
    from public.training_course_versions version
    where version.status = 'published'
    group by version.course_id
    having count(*) > 1
  ) then
    raise exception 'A Training course has multiple published versions' using errcode = '55000';
  end if;
end;
$$;

create unique index training_course_versions_one_published_idx
  on public.training_course_versions(course_id)
  where status = 'published';

create table public.training_programs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  program_key text not null,
  status text not null default 'draft',
  title_i18n jsonb not null,
  description_i18n jsonb not null,
  created_at timestamptz not null default statement_timestamp(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default statement_timestamp(),
  updated_by uuid references auth.users(id) on delete set null,
  constraint training_programs_id_organization_key unique(id, organization_id),
  constraint training_programs_organization_program_key_key unique(organization_id, program_key),
  constraint training_programs_key_check check(
    program_key = lower(program_key)
    and program_key ~ '^[a-z0-9]+(?:[a-z0-9_-]*[a-z0-9])?$'
    and length(program_key) between 1 and 120
  ),
  constraint training_programs_status_check check(status in ('draft','active','retired')),
  constraint training_programs_title_check check(jsonb_typeof(title_i18n) = 'object'),
  constraint training_programs_description_check check(jsonb_typeof(description_i18n) = 'object')
);

create table public.training_program_courses (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  program_id uuid not null,
  course_id uuid not null,
  position integer not null,
  label_i18n jsonb not null,
  required boolean not null default true,
  prerequisite_program_course_id uuid,
  created_at timestamptz not null default statement_timestamp(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default statement_timestamp(),
  updated_by uuid references auth.users(id) on delete set null,
  constraint training_program_courses_id_program_scope_key unique(id, program_id, organization_id),
  constraint training_program_courses_id_course_scope_key unique(id, course_id, organization_id),
  constraint training_program_courses_program_position_key unique(program_id, position),
  constraint training_program_courses_program_course_key unique(program_id, course_id),
  constraint training_program_courses_program_org_fkey
    foreign key(program_id, organization_id)
    references public.training_programs(id, organization_id) on delete restrict,
  constraint training_program_courses_course_org_fkey
    foreign key(course_id, organization_id)
    references public.training_courses(id, organization_id) on delete restrict,
  constraint training_program_courses_prerequisite_scope_fkey
    foreign key(prerequisite_program_course_id, program_id, organization_id)
    references public.training_program_courses(id, program_id, organization_id) on delete restrict,
  constraint training_program_courses_position_check check(position > 0),
  constraint training_program_courses_label_check check(jsonb_typeof(label_i18n) = 'object'),
  constraint training_program_courses_self_prerequisite_check
    check(prerequisite_program_course_id is null or prerequisite_program_course_id <> id)
);

create index training_programs_organization_status_idx
  on public.training_programs(organization_id, status, program_key);
create index training_program_courses_course_idx
  on public.training_program_courses(organization_id, course_id, program_id);
create index training_program_courses_prerequisite_idx
  on public.training_program_courses(program_id, prerequisite_program_course_id)
  where prerequisite_program_course_id is not null;

create trigger training_programs_90_set_updated_at
before update on public.training_programs
for each row execute function private.set_updated_at();
create trigger training_program_courses_90_set_updated_at
before update on public.training_program_courses
for each row execute function private.set_updated_at();

create or replace function private.training_program_course_order_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare prerequisite_position integer;
begin
  perform 1 from public.training_programs program
  where program.id = new.program_id and program.organization_id = new.organization_id
  for update;

  if new.prerequisite_program_course_id is not null then
    select prerequisite.position into prerequisite_position
    from public.training_program_courses prerequisite
    where prerequisite.id = new.prerequisite_program_course_id
      and prerequisite.program_id = new.program_id
      and prerequisite.organization_id = new.organization_id;
    if prerequisite_position is null or prerequisite_position >= new.position then
      raise exception 'Training prerequisite must be an earlier course in the same program' using errcode = '23514';
    end if;
  end if;

  if tg_op = 'UPDATE' and exists(
    select 1 from public.training_program_courses dependent
    where dependent.program_id = new.program_id
      and dependent.organization_id = new.organization_id
      and dependent.prerequisite_program_course_id = new.id
      and dependent.position <= new.position
  ) then
    raise exception 'Training course order would invalidate an existing prerequisite' using errcode = '23514';
  end if;
  return new;
end;
$$;

create trigger training_program_courses_10_order_guard
before insert or update on public.training_program_courses
for each row execute function private.training_program_course_order_guard();

alter table public.training_programs enable row level security;
alter table public.training_program_courses enable row level security;
revoke all on table public.training_programs from public, anon, authenticated, service_role;
revoke all on table public.training_program_courses from public, anon, authenticated, service_role;

alter table public.training_enrollments
  add column program_course_id uuid;

alter table public.training_enrollments
  add constraint training_enrollments_program_course_scope_fkey
  foreign key(program_course_id, course_id, organization_id)
  references public.training_program_courses(id, course_id, organization_id) on delete restrict;

create index training_enrollments_employee_program_course_idx
  on public.training_enrollments(organization_id, employee_id, program_course_id, status)
  where program_course_id is not null;

create or replace function private.training_enrollment_program_course_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.program_course_id is distinct from old.program_course_id then
    raise exception 'Training enrollment program scope is immutable' using errcode = '55000';
  end if;
  return new;
end;
$$;
create trigger training_enrollments_05_program_course_immutable
before update on public.training_enrollments
for each row execute function private.training_enrollment_program_course_guard();

create or replace function private.training_program_prerequisite_satisfied(
  target_organization_id uuid,
  target_employee_id uuid,
  target_program_course_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when target.prerequisite_program_course_id is null then true
    else exists(
      select 1
      from public.training_program_courses prerequisite
      join public.training_course_completions completion
        on completion.organization_id = prerequisite.organization_id
       and completion.employee_id = target_employee_id
       and completion.course_id = prerequisite.course_id
      join public.training_enrollments enrollment
        on enrollment.id = completion.enrollment_id
       and enrollment.organization_id = completion.organization_id
       and enrollment.employee_id = completion.employee_id
       and enrollment.course_id = completion.course_id
       and enrollment.course_version_id = completion.course_version_id
      join public.training_quiz_attempts attempt
        on attempt.id = completion.passing_attempt_id
       and attempt.organization_id = completion.organization_id
       and attempt.enrollment_id = completion.enrollment_id
       and attempt.employee_id = completion.employee_id
       and attempt.course_version_id = completion.course_version_id
       and attempt.status = 'submitted'
       and attempt.passed
      join public.training_course_versions version
        on version.id = completion.course_version_id
       and version.course_id = completion.course_id
       and version.organization_id = completion.organization_id
       and version.status in ('published','retired')
      where prerequisite.id = target.prerequisite_program_course_id
        and prerequisite.program_id = target.program_id
        and prerequisite.organization_id = target.organization_id
    )
  end
  from public.training_program_courses target
  where target.id = target_program_course_id
    and target.organization_id = target_organization_id;
$$;

create or replace function private.assert_training_program_course_eligible(
  target_organization_id uuid,
  target_branch_id uuid,
  target_employee_id uuid,
  target_program_course_id uuid
)
returns public.training_program_courses
language plpgsql
stable
security definer
set search_path = ''
as $$
declare selected public.training_program_courses%rowtype;
begin
  perform private.assert_training_progress_actor(target_organization_id,target_branch_id,target_employee_id);
  select program_course.* into selected
  from public.training_program_courses program_course
  join public.training_programs program
    on program.id = program_course.program_id
   and program.organization_id = program_course.organization_id
   and program.status = 'active'
  join public.training_courses course
    on course.id = program_course.course_id
   and course.organization_id = program_course.organization_id
   and course.status = 'active'
  where program_course.id = target_program_course_id
    and program_course.organization_id = target_organization_id;
  if selected.id is null then
    raise exception 'Training program course is unavailable' using errcode = 'P0002';
  end if;
  if not coalesce(private.training_program_prerequisite_satisfied(
    target_organization_id,target_employee_id,target_program_course_id
  ),false) then
    raise exception 'Training course prerequisite is incomplete' using errcode = '42501';
  end if;
  return selected;
end;
$$;

create or replace function private.assert_training_progress_enrollment(
  target_organization_id uuid,
  target_branch_id uuid,
  target_employee_id uuid,
  target_enrollment_id uuid
)
returns public.training_enrollments
language plpgsql
stable
security definer
set search_path = ''
as $$
declare selected public.training_enrollments%rowtype;
begin
  perform private.assert_training_progress_actor(target_organization_id,target_branch_id,target_employee_id);
  select enrollment.* into selected
  from public.training_enrollments enrollment
  join public.training_course_versions version
    on version.id = enrollment.course_version_id
   and version.course_id = enrollment.course_id
   and version.organization_id = enrollment.organization_id
  where enrollment.id = target_enrollment_id
    and enrollment.organization_id = target_organization_id
    and enrollment.employee_id = target_employee_id
    and enrollment.status = 'active'
    and version.status = 'published';
  if selected.id is null then
    raise exception 'Training enrollment is unavailable' using errcode = 'P0002';
  end if;
  if selected.program_course_id is not null then
    perform private.assert_training_program_course_eligible(
      target_organization_id,target_branch_id,target_employee_id,selected.program_course_id
    );
  end if;
  return selected;
end;
$$;

create or replace function public.initialize_training_program_enrollment(
  target_organization_id uuid,
  target_branch_id uuid,
  target_employee_id uuid,
  target_program_course_id uuid
)
returns setof public.training_enrollments
language plpgsql
security definer
set search_path = ''
as $$
declare actor record; selected_program_course public.training_program_courses%rowtype;
  selected_version public.training_course_versions%rowtype; saved public.training_enrollments%rowtype;
begin
  selected_program_course := private.assert_training_program_course_eligible(
    target_organization_id,target_branch_id,target_employee_id,target_program_course_id
  );
  select * into actor from private.training_legacy_employee_scope(
    target_organization_id,target_branch_id,target_employee_id
  );
  select version.* into selected_version
  from public.training_course_versions version
  where version.organization_id = target_organization_id
    and version.course_id = selected_program_course.course_id
    and version.status = 'published';
  if selected_version.id is null then
    raise exception 'Published Training course is unavailable' using errcode = '55000';
  end if;
  insert into public.training_enrollments(
    organization_id,employee_id,course_id,course_version_id,program_course_id,
    branch_id_at_enrollment,branch_name_at_enrollment,
    operational_team_id_at_enrollment,operational_team_name_at_enrollment
  ) values(
    target_organization_id,target_employee_id,selected_program_course.course_id,selected_version.id,target_program_course_id,
    actor.branch_id,actor.branch_name,actor.operational_team_id,actor.operational_team_name
  ) on conflict on constraint training_enrollments_employee_version_key do nothing;
  select * into saved from public.training_enrollments enrollment
  where enrollment.organization_id = target_organization_id
    and enrollment.employee_id = target_employee_id
    and enrollment.course_version_id = selected_version.id;
  if saved.status <> 'active'
    or (saved.program_course_id is not null and saved.program_course_id <> target_program_course_id)
    or (saved.program_course_id is null and selected_program_course.prerequisite_program_course_id is not null) then
    raise exception 'Training enrollment is unavailable' using errcode = '55000';
  end if;
  return next saved;
end;
$$;

-- Preserve the Phase 3 course-key entry point, but make it impossible to use
-- it for any course registered behind a program prerequisite.
create or replace function public.initialize_training_enrollment(
  target_organization_id uuid,
  target_branch_id uuid,
  target_employee_id uuid,
  target_course_key text
)
returns setof public.training_enrollments
language plpgsql
security definer
set search_path = ''
as $$
declare actor record; selected_version record; version_count integer;
  selected_program_course_id uuid; program_course_count integer; saved public.training_enrollments%rowtype;
begin
  if exists(
    select 1 from public.training_courses course
    join public.training_program_courses program_course
      on program_course.course_id = course.id and program_course.organization_id = course.organization_id
    where course.organization_id = target_organization_id
      and course.course_key = target_course_key
      and program_course.prerequisite_program_course_id is not null
  ) then
    raise exception 'Program prerequisite enrollment requires program scope' using errcode = '42501';
  end if;
  perform private.assert_training_progress_actor(target_organization_id,target_branch_id,target_employee_id);
  select * into actor from private.training_legacy_employee_scope(target_organization_id,target_branch_id,target_employee_id);
  select count(*)::integer into version_count
  from public.training_courses course
  join public.training_course_versions version
    on version.course_id = course.id and version.organization_id = course.organization_id
  where course.organization_id = target_organization_id
    and course.course_key = target_course_key
    and course.status = 'active' and version.status = 'published';
  if version_count <> 1 then
    raise exception 'Published Training course is unavailable' using errcode = '55000';
  end if;
  select course.id course_id,version.id version_id into selected_version
  from public.training_courses course
  join public.training_course_versions version
    on version.course_id = course.id and version.organization_id = course.organization_id
  where course.organization_id = target_organization_id
    and course.course_key = target_course_key
    and course.status = 'active' and version.status = 'published';
  select count(*)::integer,(array_agg(program_course.id))[1]
    into program_course_count,selected_program_course_id
  from public.training_program_courses program_course
  join public.training_programs program
    on program.id = program_course.program_id
   and program.organization_id = program_course.organization_id
   and program.status = 'active'
  where program_course.organization_id = target_organization_id
    and program_course.course_id = selected_version.course_id
    and program_course.prerequisite_program_course_id is null;
  if program_course_count > 1 then
    raise exception 'Training program configuration is ambiguous' using errcode = '55000';
  end if;
  insert into public.training_enrollments(
    organization_id,employee_id,course_id,course_version_id,program_course_id,
    branch_id_at_enrollment,branch_name_at_enrollment,
    operational_team_id_at_enrollment,operational_team_name_at_enrollment
  ) values(
    target_organization_id,target_employee_id,selected_version.course_id,selected_version.version_id,selected_program_course_id,
    actor.branch_id,actor.branch_name,actor.operational_team_id,actor.operational_team_name
  ) on conflict on constraint training_enrollments_employee_version_key do nothing;
  select * into saved from public.training_enrollments enrollment
  where enrollment.organization_id = target_organization_id
    and enrollment.employee_id = target_employee_id
    and enrollment.course_version_id = selected_version.version_id;
  if saved.status <> 'active' then
    raise exception 'Training enrollment is unavailable' using errcode = '55000';
  end if;
  return next saved;
end;
$$;

create or replace function public.get_training_program_status(
  target_organization_id uuid,
  target_branch_id uuid,
  target_employee_id uuid,
  target_program_key text
)
returns table(
  program_id uuid, program_key text, program_title_i18n jsonb, program_description_i18n jsonb,
  program_course_id uuid, category_position integer, category_label_i18n jsonb, category_required boolean,
  course_id uuid, course_key text, course_available boolean, locked boolean, lock_reason text,
  category_status text, enrollment_id uuid, required_lesson_count integer, completed_lesson_count integer,
  final_assessment_status text, course_completed boolean, course_completed_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare selected_program public.training_programs%rowtype; category public.training_program_courses%rowtype;
  selected_course public.training_courses%rowtype; published_version_id uuid; published_count integer;
  selected_enrollment public.training_enrollments%rowtype; prerequisite_ok boolean;
  required_count integer; completed_count integer; completion_time timestamptz; latest_attempt record; quiz_count integer;
begin
  perform private.assert_training_progress_actor(target_organization_id,target_branch_id,target_employee_id);
  select program.* into selected_program from public.training_programs program
  where program.organization_id = target_organization_id
    and program.program_key = target_program_key and program.status = 'active';
  if selected_program.id is null then
    raise exception 'Training program is unavailable' using errcode = 'P0002';
  end if;
  for category in
    select program_course.* from public.training_program_courses program_course
    where program_course.organization_id = target_organization_id
      and program_course.program_id = selected_program.id
    order by program_course.position
  loop
    select course.* into selected_course from public.training_courses course
    where course.id = category.course_id and course.organization_id = target_organization_id;
    select count(*)::integer,(array_agg(version.id))[1] into published_count,published_version_id
    from public.training_course_versions version
    where version.organization_id = target_organization_id
      and version.course_id = category.course_id and version.status = 'published';
    prerequisite_ok := coalesce(private.training_program_prerequisite_satisfied(
      target_organization_id,target_employee_id,category.id
    ),false);
    selected_enrollment := null; required_count := 0; completed_count := 0;
    completion_time := null; latest_attempt := null; quiz_count := 0;
    if published_count = 1 then
      select enrollment.* into selected_enrollment from public.training_enrollments enrollment
      where enrollment.organization_id = target_organization_id
        and enrollment.employee_id = target_employee_id
        and enrollment.course_version_id = published_version_id
        and enrollment.status = 'active';
      select count(*)::integer into required_count from public.training_lessons lesson
      where lesson.organization_id = target_organization_id
        and lesson.course_version_id = published_version_id
        and lesson.required and lesson.lesson_type <> 'quiz';
      if selected_enrollment.id is not null then
        select count(*)::integer into completed_count
        from public.training_lesson_progress progress
        join public.training_lessons lesson
          on lesson.id = progress.lesson_id and lesson.organization_id = progress.organization_id
         and lesson.course_version_id = progress.course_version_id
        where progress.enrollment_id = selected_enrollment.id and progress.status = 'completed'
          and lesson.required and lesson.lesson_type <> 'quiz';
        select attempt.status,attempt.passed into latest_attempt
        from public.training_quiz_attempts attempt
        where attempt.enrollment_id = selected_enrollment.id
        order by attempt.attempt_number desc limit 1;
      end if;
      select count(*)::integer into quiz_count
      from public.training_modules module join public.training_lessons lesson
        on lesson.module_id = module.id and lesson.organization_id = module.organization_id
       and lesson.course_version_id = module.course_version_id
      where module.organization_id = target_organization_id
        and module.course_version_id = published_version_id
        and module.metadata->>'module_role' = 'final_assessment'
        and lesson.lesson_type = 'quiz' and lesson.required;
    end if;
    select min(completion.completed_at) into completion_time
    from public.training_course_completions completion
    join public.training_course_versions completed_version
      on completed_version.id = completion.course_version_id
     and completed_version.course_id = completion.course_id
     and completed_version.organization_id = completion.organization_id
     and completed_version.status in ('published','retired')
    where completion.organization_id = target_organization_id
      and completion.employee_id = target_employee_id
      and completion.course_id = category.course_id;

    program_id := selected_program.id; program_key := selected_program.program_key;
    program_title_i18n := selected_program.title_i18n; program_description_i18n := selected_program.description_i18n;
    program_course_id := category.id; category_position := category.position;
    category_label_i18n := category.label_i18n; category_required := category.required;
    course_id := selected_course.id; course_key := selected_course.course_key;
    course_available := selected_course.status = 'active' and published_count = 1;
    locked := not prerequisite_ok;
    lock_reason := case when locked then 'prerequisite_incomplete' else null end;
    enrollment_id := selected_enrollment.id; required_lesson_count := required_count;
    completed_lesson_count := completed_count; course_completed := completion_time is not null;
    course_completed_at := completion_time;
    category_status := case
      when completion_time is not null then 'completed'
      when not prerequisite_ok then 'locked'
      when not course_available then 'content_unavailable'
      when selected_enrollment.id is not null then 'in_progress'
      else 'available' end;
    final_assessment_status := case
      when not course_available or quiz_count <> 1 then 'not_configured'
      when completion_time is not null then 'passed'
      when latest_attempt.status = 'in_progress' then 'in_progress'
      when latest_attempt.status = 'submitted' and latest_attempt.passed = false then 'failed'
      when required_count > 0 and completed_count = required_count then 'available'
      else 'locked' end;
    return next;
  end loop;
end;
$$;

create or replace function public.provision_internal_admin_restaurant_training_program(
  actor_user_id uuid,
  target_organization_id uuid,
  new_program_title_i18n jsonb,
  new_program_description_i18n jsonb,
  new_baladiyah_label_i18n jsonb,
  new_restaurant_sop_label_i18n jsonb
)
returns table(
  program_id uuid,
  baladiyah_program_course_id uuid,
  restaurant_sop_program_course_id uuid,
  restaurant_sop_course_id uuid
)
language plpgsql
security definer
set search_path = ''
as $$
declare organization_ok boolean; baladiyah_course public.training_courses%rowtype;
  sop_course public.training_courses%rowtype; saved_program public.training_programs%rowtype;
  baladiyah_entry public.training_program_courses%rowtype; sop_entry public.training_program_courses%rowtype;
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'Training program access denied' using errcode = '42501';
  end if;
  select organization.active into organization_ok from public.organizations organization
  where organization.id = target_organization_id;
  if organization_ok is distinct from true then
    raise exception 'Training organization is unavailable' using errcode = 'P0002';
  end if;
  if not private.training_media_locales_complete(new_program_title_i18n)
    or not private.training_media_locales_complete(new_program_description_i18n)
    or not private.training_media_locales_complete(new_baladiyah_label_i18n)
    or not private.training_media_locales_complete(new_restaurant_sop_label_i18n) then
    raise exception 'Training program translations are incomplete' using errcode = '22023';
  end if;
  select course.* into baladiyah_course from public.training_courses course
  where course.organization_id = target_organization_id
    and course.course_key = 'baladiyah-food-safety-hygiene';
  if baladiyah_course.id is null or baladiyah_course.status <> 'active' then
    raise exception 'Baladiyah course identity is unavailable' using errcode = '55000';
  end if;
  select course.* into sop_course from public.training_courses course
  where course.organization_id = target_organization_id and course.course_key = 'restaurant-sop';
  if sop_course.id is null then
    insert into public.training_courses(organization_id,course_key,status,created_by,updated_by)
    values(target_organization_id,'restaurant-sop','active',actor_user_id,actor_user_id)
    returning * into sop_course;
  elsif sop_course.status <> 'active' then
    raise exception 'Restaurant SOP course identity conflicts with the requested program' using errcode = '55000';
  end if;
  select program.* into saved_program from public.training_programs program
  where program.organization_id = target_organization_id and program.program_key = 'restaurant-training';
  if saved_program.id is null then
    insert into public.training_programs(
      organization_id,program_key,status,title_i18n,description_i18n,created_by,updated_by
    ) values(
      target_organization_id,'restaurant-training','draft',new_program_title_i18n,new_program_description_i18n,actor_user_id,actor_user_id
    ) returning * into saved_program;
  elsif saved_program.title_i18n <> new_program_title_i18n
    or saved_program.description_i18n <> new_program_description_i18n
    or saved_program.status not in ('draft','active') then
    raise exception 'Restaurant Training program conflicts with existing content' using errcode = '55000';
  end if;
  select entry.* into baladiyah_entry from public.training_program_courses entry
  where entry.program_id = saved_program.id and entry.course_id = baladiyah_course.id;
  if baladiyah_entry.id is null then
    insert into public.training_program_courses(
      organization_id,program_id,course_id,position,label_i18n,required,created_by,updated_by
    ) values(
      target_organization_id,saved_program.id,baladiyah_course.id,1,new_baladiyah_label_i18n,true,actor_user_id,actor_user_id
    ) returning * into baladiyah_entry;
  elsif baladiyah_entry.position <> 1 or not baladiyah_entry.required
    or baladiyah_entry.prerequisite_program_course_id is not null
    or baladiyah_entry.label_i18n <> new_baladiyah_label_i18n then
    raise exception 'Baladiyah program registration conflicts with existing content' using errcode = '55000';
  end if;
  select entry.* into sop_entry from public.training_program_courses entry
  where entry.program_id = saved_program.id and entry.course_id = sop_course.id;
  if sop_entry.id is null then
    insert into public.training_program_courses(
      organization_id,program_id,course_id,position,label_i18n,required,prerequisite_program_course_id,created_by,updated_by
    ) values(
      target_organization_id,saved_program.id,sop_course.id,2,new_restaurant_sop_label_i18n,true,baladiyah_entry.id,actor_user_id,actor_user_id
    ) returning * into sop_entry;
  elsif sop_entry.position <> 2 or not sop_entry.required
    or sop_entry.prerequisite_program_course_id <> baladiyah_entry.id
    or sop_entry.label_i18n <> new_restaurant_sop_label_i18n then
    raise exception 'Restaurant SOP program registration conflicts with existing content' using errcode = '55000';
  end if;
  if (select count(*) from public.training_program_courses entry where entry.program_id = saved_program.id) <> 2 then
    raise exception 'Restaurant Training program contains unexpected courses' using errcode = '55000';
  end if;
  return query select saved_program.id,baladiyah_entry.id,sop_entry.id,sop_course.id;
end;
$$;

revoke all on function private.training_program_course_order_guard() from public,anon,authenticated,service_role;
revoke all on function private.training_enrollment_program_course_guard() from public,anon,authenticated,service_role;
revoke all on function private.training_program_prerequisite_satisfied(uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function private.assert_training_program_course_eligible(uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.initialize_training_program_enrollment(uuid,uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.get_training_program_status(uuid,uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.provision_internal_admin_restaurant_training_program(uuid,uuid,jsonb,jsonb,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.initialize_training_program_enrollment(uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.get_training_program_status(uuid,uuid,uuid,text) to service_role;
grant execute on function public.provision_internal_admin_restaurant_training_program(uuid,uuid,jsonb,jsonb,jsonb,jsonb) to service_role;

comment on table public.training_programs is 'Organization-scoped ordered internal-learning program definitions.';
comment on table public.training_program_courses is 'Courses in a Training program and their authoritative prerequisite chain.';
comment on column public.training_enrollments.program_course_id is 'Optional immutable program scope; NULL preserves Phase 3 historical enrollments.';
