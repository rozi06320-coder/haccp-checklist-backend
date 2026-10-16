-- Phase 3B: published-course enrollment and explicit instructional lesson
-- progress. The application feature gate remains disabled by default; this
-- migration neither publishes content nor creates learner records.

alter table public.training_course_versions
  add constraint training_course_versions_id_course_organization_key
  unique(id, course_id, organization_id);

create table public.training_enrollments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  employee_id uuid not null,
  course_id uuid not null,
  course_version_id uuid not null,
  status text not null default 'active',
  branch_id_at_enrollment uuid not null,
  branch_name_at_enrollment text not null,
  operational_team_id_at_enrollment uuid not null,
  operational_team_name_at_enrollment text not null,
  identity_method text not null default 'branch_pin_employee_code',
  compliance_identity_verified boolean not null default false,
  enrolled_at timestamptz not null default statement_timestamp(),
  started_at timestamptz,
  last_accessed_lesson_id uuid,
  last_accessed_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint training_enrollments_id_scope_key
    unique(id, organization_id, employee_id, course_version_id),
  constraint training_enrollments_employee_version_key
    unique(organization_id, employee_id, course_version_id),
  constraint training_enrollments_employee_org_fkey
    foreign key(employee_id, organization_id)
    references public.operational_staff(id, organization_id) on delete restrict,
  constraint training_enrollments_course_org_fkey
    foreign key(course_id, organization_id)
    references public.training_courses(id, organization_id) on delete restrict,
  constraint training_enrollments_version_course_org_fkey
    foreign key(course_version_id, course_id, organization_id)
    references public.training_course_versions(id, course_id, organization_id) on delete restrict,
  constraint training_enrollments_branch_org_fkey
    foreign key(branch_id_at_enrollment, organization_id)
    references public.branches(id, organization_id) on delete restrict,
  constraint training_enrollments_team_scope_fkey
    foreign key(operational_team_id_at_enrollment, branch_id_at_enrollment, organization_id)
    references public.branch_operational_teams(id, branch_id, organization_id) on delete restrict,
  constraint training_enrollments_last_lesson_scope_fkey
    foreign key(last_accessed_lesson_id, course_version_id, organization_id)
    references public.training_lessons(id, course_version_id, organization_id) on delete restrict,
  constraint training_enrollments_status_check
    check(status in ('active','withdrawn')),
  constraint training_enrollments_identity_check
    check(identity_method = 'branch_pin_employee_code' and not compliance_identity_verified),
  constraint training_enrollments_snapshot_check
    check(length(btrim(branch_name_at_enrollment)) between 1 and 240
      and length(btrim(operational_team_name_at_enrollment)) between 1 and 240),
  constraint training_enrollments_access_check
    check((last_accessed_lesson_id is null and last_accessed_at is null)
      or (last_accessed_lesson_id is not null and last_accessed_at is not null)),
  constraint training_enrollments_started_check
    check(started_at is null or started_at >= enrolled_at)
);

create table public.training_lesson_progress (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  enrollment_id uuid not null,
  employee_id uuid not null,
  course_version_id uuid not null,
  lesson_id uuid not null,
  status text not null default 'in_progress',
  started_at timestamptz not null default statement_timestamp(),
  completed_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint training_lesson_progress_enrollment_lesson_key unique(enrollment_id, lesson_id),
  constraint training_lesson_progress_enrollment_scope_fkey
    foreign key(enrollment_id, organization_id, employee_id, course_version_id)
    references public.training_enrollments(id, organization_id, employee_id, course_version_id)
    on delete restrict,
  constraint training_lesson_progress_lesson_scope_fkey
    foreign key(lesson_id, course_version_id, organization_id)
    references public.training_lessons(id, course_version_id, organization_id)
    on delete restrict,
  constraint training_lesson_progress_status_check check(status in ('in_progress','completed')),
  constraint training_lesson_progress_completion_check check(
    (status = 'in_progress' and completed_at is null)
    or (status = 'completed' and completed_at is not null and completed_at >= started_at)
  )
);

create index training_enrollments_employee_status_idx
  on public.training_enrollments(organization_id, employee_id, status, enrolled_at desc);
create index training_enrollments_version_status_idx
  on public.training_enrollments(organization_id, course_version_id, status);
create index training_lesson_progress_enrollment_status_idx
  on public.training_lesson_progress(enrollment_id, status, lesson_id);
create index training_lesson_progress_employee_version_idx
  on public.training_lesson_progress(organization_id, employee_id, course_version_id, status);

create trigger training_enrollments_90_set_updated_at
before update on public.training_enrollments
for each row execute function private.set_updated_at();
create trigger training_lesson_progress_90_set_updated_at
before update on public.training_lesson_progress
for each row execute function private.set_updated_at();

alter table public.training_enrollments enable row level security;
alter table public.training_lesson_progress enable row level security;
revoke all on table public.training_enrollments from public, anon, authenticated, service_role;
revoke all on table public.training_lesson_progress from public, anon, authenticated, service_role;

create or replace function private.training_legacy_employee_scope(
  target_organization_id uuid,
  target_branch_id uuid,
  target_employee_id uuid
)
returns table(
  organization_id uuid,
  employee_id uuid,
  branch_id uuid,
  branch_name text,
  operational_team_id uuid,
  operational_team_name text
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    staff.organization_id,
    staff.id,
    branch.id,
    branch.name,
    team.id,
    team.name
  from public.operational_staff staff
  join public.organizations organization
    on organization.id = staff.organization_id and organization.active
  join public.branches branch
    on branch.id = staff.branch_id
   and branch.organization_id = staff.organization_id
   and branch.active
  join public.branch_training_access access
    on access.organization_id = staff.organization_id
   and access.branch_id = staff.branch_id
   and access.enabled
   and access.pin_hash is not null
  join public.operational_staff_assignments assignment
    on assignment.operational_staff_id = staff.id
   and assignment.organization_id = staff.organization_id
   and assignment.branch_id = staff.branch_id
   and assignment.active
   and assignment.valid_from <= private.phase4a_business_date(branch.timezone)
   and (assignment.valid_to is null or assignment.valid_to >= private.phase4a_business_date(branch.timezone))
  join public.branch_operational_teams team
    on team.id = assignment.operational_team_id
   and team.organization_id = assignment.organization_id
   and team.branch_id = assignment.branch_id
   and team.active
  where staff.organization_id = target_organization_id
    and staff.branch_id = target_branch_id
    and staff.id = target_employee_id
    and staff.employment_status = 'active';
$$;

create or replace function private.assert_training_progress_actor(
  target_organization_id uuid,
  target_branch_id uuid,
  target_employee_id uuid
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare actor_count integer;
begin
  select count(*)::integer into actor_count
  from private.training_legacy_employee_scope(target_organization_id,target_branch_id,target_employee_id);
  if actor_count <> 1 then
    raise exception 'Training learner scope is invalid' using errcode='42501';
  end if;
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
    on version.id=enrollment.course_version_id
   and version.course_id=enrollment.course_id
   and version.organization_id=enrollment.organization_id
  where enrollment.id=target_enrollment_id
    and enrollment.organization_id=target_organization_id
    and enrollment.employee_id=target_employee_id
    and enrollment.status='active'
    and version.status='published';
  if selected.id is null then
    raise exception 'Training enrollment is unavailable' using errcode='P0002';
  end if;
  return selected;
end;
$$;

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
declare actor record; selected_version record; version_count integer; saved public.training_enrollments%rowtype;
begin
  perform private.assert_training_progress_actor(target_organization_id,target_branch_id,target_employee_id);
  select * into actor from private.training_legacy_employee_scope(target_organization_id,target_branch_id,target_employee_id);
  select count(*)::integer into version_count
  from public.training_courses course
  join public.training_course_versions version
    on version.course_id=course.id and version.organization_id=course.organization_id
  where course.organization_id=target_organization_id
    and course.course_key=target_course_key
    and course.status='active'
    and version.status='published';
  if version_count <> 1 then
    raise exception 'Published Training course is unavailable' using errcode='55000';
  end if;
  select course.id course_id,version.id version_id into selected_version
  from public.training_courses course
  join public.training_course_versions version
    on version.course_id=course.id and version.organization_id=course.organization_id
  where course.organization_id=target_organization_id
    and course.course_key=target_course_key
    and course.status='active' and version.status='published';
  insert into public.training_enrollments(
    organization_id,employee_id,course_id,course_version_id,
    branch_id_at_enrollment,branch_name_at_enrollment,
    operational_team_id_at_enrollment,operational_team_name_at_enrollment
  ) values(
    target_organization_id,target_employee_id,selected_version.course_id,selected_version.version_id,
    actor.branch_id,actor.branch_name,actor.operational_team_id,actor.operational_team_name
  )
  on conflict on constraint training_enrollments_employee_version_key do nothing;
  select * into saved from public.training_enrollments enrollment
  where enrollment.organization_id=target_organization_id
    and enrollment.employee_id=target_employee_id
    and enrollment.course_version_id=selected_version.version_id;
  if saved.status <> 'active' then
    raise exception 'Training enrollment is unavailable' using errcode='55000';
  end if;
  return next saved;
end;
$$;

create or replace function public.start_training_lesson(
  target_organization_id uuid,target_branch_id uuid,target_employee_id uuid,
  target_enrollment_id uuid,target_lesson_id uuid
)
returns setof public.training_lesson_progress
language plpgsql security definer set search_path = '' as $$
declare enrollment public.training_enrollments%rowtype; selected_lesson public.training_lessons%rowtype; saved public.training_lesson_progress%rowtype;
begin
  enrollment:=private.assert_training_progress_enrollment(target_organization_id,target_branch_id,target_employee_id,target_enrollment_id);
  select * into selected_lesson from public.training_lessons lesson
  where lesson.id=target_lesson_id and lesson.organization_id=enrollment.organization_id
    and lesson.course_version_id=enrollment.course_version_id and lesson.required and lesson.lesson_type<>'quiz';
  if selected_lesson.id is null then raise exception 'Training lesson is unavailable' using errcode='P0002'; end if;
  insert into public.training_lesson_progress(organization_id,enrollment_id,employee_id,course_version_id,lesson_id)
  values(enrollment.organization_id,enrollment.id,enrollment.employee_id,enrollment.course_version_id,selected_lesson.id)
  on conflict on constraint training_lesson_progress_enrollment_lesson_key do nothing;
  update public.training_enrollments target set
    started_at=coalesce(target.started_at,statement_timestamp()),
    last_accessed_lesson_id=selected_lesson.id,last_accessed_at=statement_timestamp()
  where target.id=enrollment.id;
  select * into saved from public.training_lesson_progress progress
  where progress.enrollment_id=enrollment.id and progress.lesson_id=selected_lesson.id;
  return next saved;
end;
$$;

create or replace function public.complete_training_lesson(
  target_organization_id uuid,target_branch_id uuid,target_employee_id uuid,
  target_enrollment_id uuid,target_lesson_id uuid
)
returns setof public.training_lesson_progress
language plpgsql security definer set search_path = '' as $$
declare enrollment public.training_enrollments%rowtype; selected_lesson public.training_lessons%rowtype; saved public.training_lesson_progress%rowtype;
begin
  enrollment:=private.assert_training_progress_enrollment(target_organization_id,target_branch_id,target_employee_id,target_enrollment_id);
  select * into selected_lesson from public.training_lessons lesson
  where lesson.id=target_lesson_id and lesson.organization_id=enrollment.organization_id
    and lesson.course_version_id=enrollment.course_version_id and lesson.required and lesson.lesson_type<>'quiz';
  if selected_lesson.id is null then raise exception 'Training lesson is unavailable' using errcode='P0002'; end if;
  insert into public.training_lesson_progress(
    organization_id,enrollment_id,employee_id,course_version_id,lesson_id,status,completed_at
  ) values(
    enrollment.organization_id,enrollment.id,enrollment.employee_id,enrollment.course_version_id,selected_lesson.id,'completed',statement_timestamp()
  ) on conflict on constraint training_lesson_progress_enrollment_lesson_key do update set
    status='completed',completed_at=coalesce(training_lesson_progress.completed_at,excluded.completed_at)
  where training_lesson_progress.status='in_progress';
  update public.training_enrollments target set
    started_at=coalesce(target.started_at,statement_timestamp()),
    last_accessed_lesson_id=selected_lesson.id,last_accessed_at=statement_timestamp()
  where target.id=enrollment.id;
  select * into saved from public.training_lesson_progress progress
  where progress.enrollment_id=enrollment.id and progress.lesson_id=selected_lesson.id;
  return next saved;
end;
$$;

create or replace function public.get_training_enrollment_progress(
  target_organization_id uuid,target_branch_id uuid,target_employee_id uuid,target_enrollment_id uuid
)
returns table(
  enrollment_id uuid,course_id uuid,course_version_id uuid,enrollment_status text,
  enrolled_at timestamptz,started_at timestamptz,last_accessed_lesson_id uuid,last_accessed_at timestamptz,
  required_lesson_count integer,started_lesson_count integer,completed_lesson_count integer,
  resume_lesson_id uuid,final_assessment_unlocked boolean
)
language plpgsql stable security definer set search_path = '' as $$
declare enrollment public.training_enrollments%rowtype;
begin
  enrollment:=private.assert_training_progress_enrollment(target_organization_id,target_branch_id,target_employee_id,target_enrollment_id);
  return query with ordered_lessons as (
    select lesson.id,row_number() over(order by module.position,lesson.position)::integer sequence
    from public.training_modules module join public.training_lessons lesson
      on lesson.module_id=module.id and lesson.course_version_id=module.course_version_id and lesson.organization_id=module.organization_id
    where module.organization_id=enrollment.organization_id and module.course_version_id=enrollment.course_version_id
      and lesson.required and lesson.lesson_type<>'quiz'
  ), counts as (
    select count(*)::integer required_count,
      count(progress.id)::integer started_count,
      count(progress.id) filter(where progress.status='completed')::integer completed_count
    from ordered_lessons ordered left join public.training_lesson_progress progress
      on progress.enrollment_id=enrollment.id and progress.lesson_id=ordered.id
  ), resume as (
    select coalesce(
      (select ordered.id from ordered_lessons ordered left join public.training_lesson_progress progress
        on progress.enrollment_id=enrollment.id and progress.lesson_id=ordered.id
       where progress.status is distinct from 'completed' order by ordered.sequence limit 1),
      enrollment.last_accessed_lesson_id,
      (select ordered.id from ordered_lessons ordered order by ordered.sequence limit 1)
    ) id
  ) select enrollment.id,enrollment.course_id,enrollment.course_version_id,enrollment.status,
    enrollment.enrolled_at,enrollment.started_at,enrollment.last_accessed_lesson_id,enrollment.last_accessed_at,
    counts.required_count,counts.started_count,counts.completed_count,resume.id,
    counts.required_count>0 and counts.completed_count=counts.required_count
  from counts cross join resume;
end;
$$;

create or replace function public.get_training_published_curriculum(
  target_organization_id uuid,target_branch_id uuid,target_employee_id uuid,target_enrollment_id uuid
)
returns table(
  course_id uuid,course_key text,course_version_id uuid,version_number integer,
  version_status text,revision bigint,content_hash text,
  default_locale text,supported_locales text[],course_title_i18n jsonb,course_description_i18n jsonb,
  module_id uuid,module_key text,module_position integer,module_title_i18n jsonb,module_description_i18n jsonb,
  lesson_id uuid,lesson_key text,lesson_position integer,lesson_type text,required boolean,
  lesson_title_i18n jsonb,lesson_objective_i18n jsonb,lesson_content_i18n jsonb,
  question_count integer,pass_threshold_bps integer
)
language plpgsql stable security definer set search_path = '' as $$
declare enrollment public.training_enrollments%rowtype;
begin
  enrollment:=private.assert_training_progress_enrollment(target_organization_id,target_branch_id,target_employee_id,target_enrollment_id);
  if not private.training_image_slot_bindings_valid(enrollment.organization_id,enrollment.course_version_id) then
    raise exception 'Training curriculum is unavailable' using errcode='55000';
  end if;
  return query select course.id,course.course_key,version.id,version.version_number,
    version.status,version.revision,version.content_hash,
    version.default_locale,version.supported_locales,version.title_i18n,version.description_i18n,
    module.id,module.stable_key,module.position,module.title_i18n,module.description_i18n,
    lesson.id,lesson.stable_key,lesson.position,lesson.lesson_type,lesson.required,
    lesson.title_i18n,lesson.objective_i18n,
    case when lesson.lesson_type='quiz' then null else lesson.content_i18n end,
    case when lesson.lesson_type='quiz' then jsonb_array_length(lesson.content_i18n->'en'->'questions') else null end,
    lesson.pass_threshold_bps
  from public.training_courses course join public.training_course_versions version
    on version.course_id=course.id and version.organization_id=course.organization_id
  join public.training_modules module on module.course_version_id=version.id and module.organization_id=version.organization_id
  join public.training_lessons lesson on lesson.module_id=module.id and lesson.course_version_id=version.id and lesson.organization_id=version.organization_id
  where course.id=enrollment.course_id and course.organization_id=enrollment.organization_id
    and version.id=enrollment.course_version_id and version.status='published'
  order by module.position,lesson.position;
end;
$$;

create or replace function public.list_training_lesson_progress(
  target_organization_id uuid,target_branch_id uuid,target_employee_id uuid,target_enrollment_id uuid
)
returns table(
  lesson_id uuid,global_position integer,status text,started_at timestamptz,completed_at timestamptz
)
language plpgsql stable security definer set search_path = '' as $$
declare enrollment public.training_enrollments%rowtype;
begin
  enrollment:=private.assert_training_progress_enrollment(target_organization_id,target_branch_id,target_employee_id,target_enrollment_id);
  return query select lesson.id,row_number() over(order by module.position,lesson.position)::integer,
    coalesce(progress.status,'not_started'),progress.started_at,progress.completed_at
  from public.training_modules module join public.training_lessons lesson
    on lesson.module_id=module.id and lesson.course_version_id=module.course_version_id and lesson.organization_id=module.organization_id
  left join public.training_lesson_progress progress
    on progress.enrollment_id=enrollment.id and progress.lesson_id=lesson.id
  where module.organization_id=enrollment.organization_id and module.course_version_id=enrollment.course_version_id
    and lesson.required and lesson.lesson_type<>'quiz'
  order by module.position,lesson.position;
end;
$$;

create or replace function public.list_training_published_image_bindings(
  target_organization_id uuid,target_branch_id uuid,target_employee_id uuid,target_enrollment_id uuid
)
returns table(
  lesson_id uuid,asset_key text,placement text,slot_position integer,
  expected_alt_i18n jsonb,media_id uuid,width integer,height integer
)
language plpgsql stable security definer set search_path = '' as $$
declare enrollment public.training_enrollments%rowtype;
begin
  enrollment:=private.assert_training_progress_enrollment(target_organization_id,target_branch_id,target_employee_id,target_enrollment_id);
  return query select slot.lesson_id,slot.asset_key,slot.placement,slot.slot_position,
    slot.expected_alt_i18n,asset.id,asset.width,asset.height
  from private.training_image_slot_requirements(enrollment.organization_id,enrollment.course_version_id) slot
  join public.training_media_assets asset
    on asset.organization_id=enrollment.organization_id
   and asset.course_version_id=enrollment.course_version_id
   and asset.asset_key=slot.asset_key
   and asset.status='ready' and asset.approval_status='approved'
   and asset.media_type='image' and asset.mime_type='image/webp'
  order by slot.module_position,slot.lesson_position,slot.slot_position;
end;
$$;

create or replace function public.authorize_legacy_training_media_read(
  target_organization_id uuid,target_branch_id uuid,target_employee_id uuid,
  target_enrollment_id uuid,target_media_id uuid
)
returns table(storage_bucket text,storage_object_path text,mime_type text)
language plpgsql stable security definer set search_path = '' as $$
declare enrollment public.training_enrollments%rowtype;
begin
  enrollment:=private.assert_training_progress_enrollment(target_organization_id,target_branch_id,target_employee_id,target_enrollment_id);
  return query select asset.storage_bucket,asset.storage_object_path,asset.mime_type
  from public.training_media_assets asset
  join private.training_image_slot_requirements(enrollment.organization_id,enrollment.course_version_id) slot
    on slot.asset_key=asset.asset_key
  where asset.id=target_media_id and asset.organization_id=enrollment.organization_id
    and asset.course_version_id=enrollment.course_version_id
    and asset.status='ready' and asset.approval_status='approved'
    and asset.media_type='image' and asset.mime_type='image/webp';
end;
$$;

revoke all on function private.training_legacy_employee_scope(uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function private.assert_training_progress_actor(uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function private.assert_training_progress_enrollment(uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;

revoke all on function public.initialize_training_enrollment(uuid,uuid,uuid,text) from public,anon,authenticated;
revoke all on function public.start_training_lesson(uuid,uuid,uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.complete_training_lesson(uuid,uuid,uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.get_training_enrollment_progress(uuid,uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.get_training_published_curriculum(uuid,uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.list_training_lesson_progress(uuid,uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.list_training_published_image_bindings(uuid,uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.authorize_legacy_training_media_read(uuid,uuid,uuid,uuid,uuid) from public,anon,authenticated;

grant execute on function public.initialize_training_enrollment(uuid,uuid,uuid,text) to service_role;
grant execute on function public.start_training_lesson(uuid,uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.complete_training_lesson(uuid,uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.get_training_enrollment_progress(uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.get_training_published_curriculum(uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.list_training_lesson_progress(uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.list_training_published_image_bindings(uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.authorize_legacy_training_media_read(uuid,uuid,uuid,uuid,uuid) to service_role;

comment on table public.training_enrollments is
  'Employee-owned enrollment pinned to one published course version. Branch/team values are historical snapshots; legacy identity is not compliance verified.';
comment on table public.training_lesson_progress is
  'Authoritative explicit progress for required non-quiz lessons. Absence means not started; completed rows never regress.';
