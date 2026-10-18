-- Phase 3A: independently reviewed, fingerprint-bound Training publication
-- approvals. All application access remains behind service-role-only RPCs.

create table public.training_publication_review_submissions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  course_id uuid not null,
  course_version_id uuid not null,
  version_revision bigint not null,
  content_fingerprint text not null,
  submitted_by uuid not null references auth.users(id) on delete restrict,
  submitted_at timestamptz not null default statement_timestamp(),
  action_request_id uuid not null,
  author_identity_basis text not null default 'explicit_admin_attestation',
  constraint training_publication_review_submissions_version_scope_fkey
    foreign key(course_version_id,organization_id)
    references public.training_course_versions(id,organization_id) on delete restrict,
  constraint training_publication_review_submissions_course_scope_fkey
    foreign key(course_id,organization_id)
    references public.training_courses(id,organization_id) on delete restrict,
  constraint training_publication_review_submissions_scope_key
    unique(id,organization_id,course_id,course_version_id),
  constraint training_publication_review_submissions_request_key
    unique(organization_id,action_request_id),
  constraint training_publication_review_submissions_revision_check check(version_revision >= 0),
  constraint training_publication_review_submissions_fingerprint_check
    check(content_fingerprint ~ '^[0-9a-f]{64}$'),
  constraint training_publication_review_submissions_basis_check
    check(author_identity_basis = 'explicit_admin_attestation')
);

create index training_publication_review_submissions_version_idx
  on public.training_publication_review_submissions(
    organization_id,course_id,course_version_id,version_revision,submitted_at desc
  );

create table public.training_content_contributor_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  course_id uuid not null,
  course_version_id uuid not null,
  contributor_user_id uuid not null references auth.users(id) on delete restrict,
  source_table text not null,
  source_id uuid not null,
  contribution_kind text not null,
  occurred_at timestamptz not null default statement_timestamp(),
  constraint training_content_contributor_events_version_scope_fkey
    foreign key(course_version_id,organization_id)
    references public.training_course_versions(id,organization_id) on delete restrict,
  constraint training_content_contributor_events_course_scope_fkey
    foreign key(course_id,organization_id)
    references public.training_courses(id,organization_id) on delete restrict,
  constraint training_content_contributor_events_source_check
    check(source_table in ('training_courses','training_course_versions','training_modules','training_lessons')),
  constraint training_content_contributor_events_kind_check
    check(contribution_kind in ('created','modified','legacy_attestation')),
  constraint training_content_contributor_events_identity_key
    unique(organization_id,course_version_id,contributor_user_id,source_table,source_id,contribution_kind)
);

create index training_content_contributor_events_version_idx
  on public.training_content_contributor_events(organization_id,course_version_id,contributor_user_id);

create table public.training_media_contributor_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  course_version_id uuid not null,
  media_id uuid not null,
  media_revision integer not null,
  contributor_user_id uuid not null references auth.users(id) on delete restrict,
  contribution_kind text not null,
  occurred_at timestamptz not null default statement_timestamp(),
  constraint training_media_contributor_events_media_scope_fkey
    foreign key(media_id,course_version_id,organization_id)
    references public.training_media_assets(id,course_version_id,organization_id) on delete restrict,
  constraint training_media_contributor_events_revision_check check(media_revision > 0),
  constraint training_media_contributor_events_kind_check
    check(contribution_kind in ('created','modified','legacy_attestation')),
  constraint training_media_contributor_events_identity_key
    unique(organization_id,media_id,media_revision,contributor_user_id,contribution_kind)
);

create index training_media_contributor_events_asset_idx
  on public.training_media_contributor_events(organization_id,media_id,media_revision,contributor_user_id);

create table public.training_publication_review_events (
  id uuid primary key default gen_random_uuid(),
  submission_id uuid not null,
  organization_id uuid not null,
  course_id uuid not null,
  course_version_id uuid not null,
  version_revision bigint not null,
  content_fingerprint text not null,
  review_type text not null,
  locale text,
  decision text not null,
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  reason text,
  action_request_id uuid not null,
  occurred_at timestamptz not null default statement_timestamp(),
  constraint training_publication_review_events_submission_scope_fkey
    foreign key(submission_id,organization_id,course_id,course_version_id)
    references public.training_publication_review_submissions(id,organization_id,course_id,course_version_id)
    on delete restrict,
  constraint training_publication_review_events_request_key
    unique(organization_id,action_request_id),
  constraint training_publication_review_events_revision_check check(version_revision >= 0),
  constraint training_publication_review_events_fingerprint_check
    check(content_fingerprint ~ '^[0-9a-f]{64}$'),
  constraint training_publication_review_events_type_check
    check(review_type in ('content','translation','internal_regulatory')),
  constraint training_publication_review_events_locale_check check(
    (review_type = 'translation' and locale in ('en','ar','id','hi','fil'))
    or (review_type <> 'translation' and locale is null)
  ),
  constraint training_publication_review_events_decision_check
    check(decision in ('approved','rejected','revoked')),
  constraint training_publication_review_events_reason_check check(
    reason is null or (reason = btrim(reason) and length(reason) between 1 and 1000)
  ),
  constraint training_publication_review_events_rejection_reason_check check(
    (decision = 'approved' and reason is null)
    or (decision in ('rejected','revoked') and reason is not null)
  )
);

create table public.training_publication_submission_contributors (
  submission_id uuid not null,
  organization_id uuid not null,
  course_id uuid not null,
  course_version_id uuid not null,
  version_revision bigint not null,
  content_fingerprint text not null,
  contributor_user_id uuid not null references auth.users(id) on delete restrict,
  evidence_sources text[] not null,
  recorded_at timestamptz not null default statement_timestamp(),
  primary key(submission_id,contributor_user_id),
  constraint training_publication_submission_contributors_submission_scope_fkey
    foreign key(submission_id,organization_id,course_id,course_version_id)
    references public.training_publication_review_submissions(id,organization_id,course_id,course_version_id)
    on delete restrict,
  constraint training_publication_submission_contributors_revision_check check(version_revision >= 0),
  constraint training_publication_submission_contributors_fingerprint_check
    check(content_fingerprint ~ '^[0-9a-f]{64}$'),
  constraint training_publication_submission_contributors_sources_check
    check(cardinality(evidence_sources) > 0 and array_position(evidence_sources,null) is null)
);

create index training_publication_review_events_submission_idx
  on public.training_publication_review_events(submission_id,review_type,locale,occurred_at desc,id desc);

create table public.training_media_review_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  course_id uuid not null,
  course_version_id uuid not null,
  media_id uuid not null,
  media_revision integer not null,
  media_fingerprint text not null,
  decision text not null,
  actor_user_id uuid references auth.users(id) on delete restrict,
  uploader_user_id uuid references auth.users(id) on delete restrict,
  creator_user_id uuid references auth.users(id) on delete restrict,
  modifier_user_id uuid references auth.users(id) on delete restrict,
  contributor_user_ids uuid[] not null,
  attribution_reliable boolean not null,
  original_reviewed_at timestamptz,
  reason text,
  action_request_id uuid not null,
  occurred_at timestamptz not null default statement_timestamp(),
  constraint training_media_review_events_media_scope_fkey
    foreign key(media_id,course_version_id,organization_id)
    references public.training_media_assets(id,course_version_id,organization_id) on delete restrict,
  constraint training_media_review_events_course_scope_fkey
    foreign key(course_version_id,organization_id)
    references public.training_course_versions(id,organization_id) on delete restrict,
  constraint training_media_review_events_training_course_scope_fkey
    foreign key(course_id,organization_id)
    references public.training_courses(id,organization_id) on delete restrict,
  constraint training_media_review_events_request_key unique(organization_id,action_request_id),
  constraint training_media_review_events_revision_check check(media_revision > 0),
  constraint training_media_review_events_fingerprint_check check(media_fingerprint ~ '^[0-9a-f]{64}$'),
  constraint training_media_review_events_decision_check
    check(decision in ('approved','rejected','invalidated')),
  constraint training_media_review_events_reason_check check(
    reason is null or (reason = btrim(reason) and length(reason) between 1 and 1000)
  ),
  constraint training_media_review_events_decision_reason_check check(
    (decision = 'approved' and reason is null)
    or (decision in ('rejected','invalidated') and reason is not null)
  ),
  constraint training_media_review_events_contributors_check check(
    array_position(contributor_user_ids,null) is null
    and (not attribution_reliable or cardinality(contributor_user_ids)>0)
  )
);

create index training_media_review_events_asset_idx
  on public.training_media_review_events(
    organization_id,course_version_id,media_id,media_revision,occurred_at desc,id desc
  );

alter table public.training_publication_review_submissions enable row level security;
alter table public.training_content_contributor_events enable row level security;
alter table public.training_media_contributor_events enable row level security;
alter table public.training_publication_review_events enable row level security;
alter table public.training_publication_submission_contributors enable row level security;
alter table public.training_media_review_events enable row level security;
revoke all on table public.training_publication_review_submissions from public,anon,authenticated,service_role;
revoke all on table public.training_content_contributor_events from public,anon,authenticated,service_role;
revoke all on table public.training_media_contributor_events from public,anon,authenticated,service_role;
revoke all on table public.training_publication_review_events from public,anon,authenticated,service_role;
revoke all on table public.training_publication_submission_contributors from public,anon,authenticated,service_role;
revoke all on table public.training_media_review_events from public,anon,authenticated,service_role;

create or replace function private.reject_training_audit_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'Training audit records are immutable' using errcode = '55000';
end;
$$;

create trigger training_publication_review_submissions_immutability
before update or delete on public.training_publication_review_submissions
for each row execute function private.reject_training_audit_mutation();
create trigger training_content_contributor_events_immutability
before update or delete on public.training_content_contributor_events
for each row execute function private.reject_training_audit_mutation();
create trigger training_media_contributor_events_immutability
before update or delete on public.training_media_contributor_events
for each row execute function private.reject_training_audit_mutation();
create trigger training_publication_review_events_immutability
before update or delete on public.training_publication_review_events
for each row execute function private.reject_training_audit_mutation();
create trigger training_publication_submission_contributors_immutability
before update or delete on public.training_publication_submission_contributors
for each row execute function private.reject_training_audit_mutation();
create trigger training_media_review_events_immutability
before update or delete on public.training_media_review_events
for each row execute function private.reject_training_audit_mutation();

create or replace function private.lock_training_course_version(
  target_organization_id uuid,
  target_course_version_id uuid,
  required_status text
)
returns public.training_course_versions
language plpgsql
security definer
set search_path = ''
as $$
declare locked_version public.training_course_versions%rowtype;
begin
  if required_status not in ('draft','published') then
    raise exception 'Invalid Training version lock state' using errcode='22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    target_organization_id::text||':'||target_course_version_id::text,0
  ));
  select version.* into locked_version
  from public.training_course_versions version
  where version.id=target_course_version_id
    and version.organization_id=target_organization_id
  for update;
  if locked_version.id is null then
    raise exception 'Training course version not found' using errcode='P0002';
  end if;
  if locked_version.status<>required_status then
    raise exception 'Training course version state changed' using errcode='55000';
  end if;
  return locked_version;
end;
$$;

create or replace function private.enforce_training_draft_content()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op in ('UPDATE','DELETE') then
    perform private.lock_training_course_version(old.organization_id,old.course_version_id,'draft');
  end if;
  if tg_op in ('INSERT','UPDATE')
    and (tg_op='INSERT' or new.organization_id is distinct from old.organization_id
      or new.course_version_id is distinct from old.course_version_id) then
    perform private.lock_training_course_version(new.organization_id,new.course_version_id,'draft');
  end if;
  return case when tg_op='DELETE' then old else new end;
end;
$$;

create or replace function private.enforce_training_media_draft()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op in ('UPDATE','DELETE') then
    perform private.lock_training_course_version(old.organization_id,old.course_version_id,'draft');
  end if;
  if tg_op in ('INSERT','UPDATE')
    and (tg_op='INSERT' or new.organization_id is distinct from old.organization_id
      or new.course_version_id is distinct from old.course_version_id) then
    perform private.lock_training_course_version(new.organization_id,new.course_version_id,'draft');
  end if;
  return case when tg_op='DELETE' then old else new end;
end;
$$;

create or replace function private.capture_training_content_contributor()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  contributor uuid;
  target_course_id uuid;
  target_version_id uuid;
  target_organization_id uuid;
  target_source_id uuid;
  changed boolean := true;
  version_row record;
begin
  if tg_op='UPDATE' then
    changed := (to_jsonb(new)-array['updated_at','updated_by','status','content_hash','published_at','published_by','retired_at','retired_by','publication_fingerprint'])
      is distinct from
      (to_jsonb(old)-array['updated_at','updated_by','status','content_hash','published_at','published_by','retired_at','retired_by','publication_fingerprint']);
  end if;
  if not changed then return new; end if;
  contributor := case when tg_op='INSERT' then coalesce(new.created_by,new.updated_by) else new.updated_by end;
  if contributor is null then return new; end if;
  target_organization_id := new.organization_id;
  target_source_id := new.id;
  if tg_table_name='training_courses' then
    for version_row in select version.id from public.training_course_versions version
      where version.organization_id=new.organization_id and version.course_id=new.id
    loop
      insert into public.training_content_contributor_events(
        organization_id,course_id,course_version_id,contributor_user_id,
        source_table,source_id,contribution_kind
      ) values(
        new.organization_id,new.id,version_row.id,contributor,tg_table_name,new.id,
        case when tg_op='INSERT' then 'created' else 'modified' end
      ) on conflict do nothing;
    end loop;
    return new;
  elsif tg_table_name='training_course_versions' then
    target_course_id := new.course_id;
    target_version_id := new.id;
  else
    target_version_id := new.course_version_id;
    select version.course_id into target_course_id from public.training_course_versions version
    where version.id=target_version_id and version.organization_id=target_organization_id;
  end if;
  insert into public.training_content_contributor_events(
    organization_id,course_id,course_version_id,contributor_user_id,
    source_table,source_id,contribution_kind
  ) values(
    target_organization_id,target_course_id,target_version_id,contributor,
    tg_table_name,target_source_id,case when tg_op='INSERT' then 'created' else 'modified' end
  ) on conflict do nothing;
  return new;
end;
$$;

create or replace function private.capture_training_media_contributor()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare contributor uuid; changed boolean := true;
begin
  if tg_op='UPDATE' then
    changed := (to_jsonb(new)-array['updated_at','updated_by','approval_status','reviewed_at','reviewed_by','rejection_reason','revision'])
      is distinct from
      (to_jsonb(old)-array['updated_at','updated_by','approval_status','reviewed_at','reviewed_by','rejection_reason','revision']);
  end if;
  if not changed then return new; end if;
  contributor := case when tg_op='INSERT' then coalesce(new.created_by,new.updated_by) else new.updated_by end;
  if contributor is not null then
    insert into public.training_media_contributor_events(
      organization_id,course_version_id,media_id,media_revision,contributor_user_id,contribution_kind
    ) values(
      new.organization_id,new.course_version_id,new.id,new.revision,contributor,
      case when tg_op='INSERT' then 'created' else 'modified' end
    ) on conflict do nothing;
  end if;
  return new;
end;
$$;

create trigger training_courses_80_contributor_history
after insert or update on public.training_courses
for each row execute function private.capture_training_content_contributor();
create trigger training_course_versions_80_contributor_history
after insert or update on public.training_course_versions
for each row execute function private.capture_training_content_contributor();
create trigger training_modules_80_contributor_history
after insert or update on public.training_modules
for each row execute function private.capture_training_content_contributor();
create trigger training_lessons_80_contributor_history
after insert or update on public.training_lessons
for each row execute function private.capture_training_content_contributor();
create trigger training_media_assets_80_contributor_history
after insert or update on public.training_media_assets
for each row execute function private.capture_training_media_contributor();

-- Preserve every reliably known contributor before immutable history starts.
insert into public.training_content_contributor_events(
  organization_id,course_id,course_version_id,contributor_user_id,source_table,source_id,contribution_kind,occurred_at
)
select source.organization_id,source.course_id,source.course_version_id,source.contributor_user_id,
  source.source_table,source.source_id,source.contribution_kind,source.occurred_at
from (
  select version.organization_id,version.course_id,version.id course_version_id,course.created_by contributor_user_id,
    'training_courses'::text source_table,course.id source_id,'created'::text contribution_kind,course.created_at occurred_at
  from public.training_courses course join public.training_course_versions version
    on version.course_id=course.id and version.organization_id=course.organization_id
  union all
  select version.organization_id,version.course_id,version.id,course.updated_by,'training_courses',course.id,'modified',course.updated_at
  from public.training_courses course join public.training_course_versions version
    on version.course_id=course.id and version.organization_id=course.organization_id
  union all
  select version.organization_id,version.course_id,version.id,version.created_by,'training_course_versions',version.id,'created',version.created_at
  from public.training_course_versions version
  union all
  select version.organization_id,version.course_id,version.id,version.updated_by,'training_course_versions',version.id,'modified',version.updated_at
  from public.training_course_versions version
  union all
  select module.organization_id,version.course_id,module.course_version_id,module.created_by,'training_modules',module.id,'created',module.created_at
  from public.training_modules module join public.training_course_versions version
    on version.id=module.course_version_id and version.organization_id=module.organization_id
  union all
  select module.organization_id,version.course_id,module.course_version_id,module.updated_by,'training_modules',module.id,'modified',module.updated_at
  from public.training_modules module join public.training_course_versions version
    on version.id=module.course_version_id and version.organization_id=module.organization_id
  union all
  select lesson.organization_id,version.course_id,lesson.course_version_id,lesson.created_by,'training_lessons',lesson.id,'created',lesson.created_at
  from public.training_lessons lesson join public.training_course_versions version
    on version.id=lesson.course_version_id and version.organization_id=lesson.organization_id
  union all
  select lesson.organization_id,version.course_id,lesson.course_version_id,lesson.updated_by,'training_lessons',lesson.id,'modified',lesson.updated_at
  from public.training_lessons lesson join public.training_course_versions version
    on version.id=lesson.course_version_id and version.organization_id=lesson.organization_id
) source
where source.contributor_user_id is not null
on conflict do nothing;

insert into public.training_media_contributor_events(
  organization_id,course_version_id,media_id,media_revision,contributor_user_id,contribution_kind,occurred_at
)
select source.organization_id,source.course_version_id,source.media_id,source.media_revision,
  source.contributor_user_id,source.contribution_kind,source.occurred_at
from (
  select asset.organization_id,asset.course_version_id,asset.id media_id,asset.revision media_revision,
    asset.created_by contributor_user_id,'created'::text contribution_kind,asset.created_at occurred_at
  from public.training_media_assets asset
  union all
  select asset.organization_id,asset.course_version_id,asset.id,asset.revision,
    asset.updated_by,'modified',asset.updated_at
  from public.training_media_assets asset
) source
where source.contributor_user_id is not null
on conflict do nothing;

create or replace function private.training_media_asset_fingerprint(
  target_organization_id uuid,
  target_course_version_id uuid,
  target_media_id uuid
)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.encode(extensions.digest(
    jsonb_build_object(
      'organization_id',asset.organization_id,
      'course_version_id',asset.course_version_id,
      'media_id',asset.id,
      'asset_key',asset.asset_key,
      'media_type',asset.media_type,
      'title_i18n',asset.title_i18n,
      'alt_i18n',asset.alt_i18n,
      'storage_bucket',asset.storage_bucket,
      'storage_object_path',asset.storage_object_path,
      'mime_type',asset.mime_type,
      'byte_size',asset.byte_size,
      'width',asset.width,
      'height',asset.height,
      'sha256',asset.sha256,
      'source_mime_type',asset.source_mime_type,
      'source_byte_size',asset.source_byte_size,
      'source_sha256',asset.source_sha256,
      'revision',asset.revision,
      'status',asset.status
    )::text,
    'sha256'
  ),'hex')
  from public.training_media_assets asset
  where asset.organization_id = target_organization_id
    and asset.course_version_id = target_course_version_id
    and asset.id = target_media_id;
$$;

create or replace function private.training_publication_content_fingerprint(
  target_organization_id uuid,
  target_course_id uuid,
  target_course_version_id uuid
)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select pg_catalog.encode(extensions.digest(
    jsonb_build_object(
      'organization_id',version.organization_id,
      'course_id',course.id,
      'course_key',course.course_key,
      'course_version_id',version.id,
      'version_number',version.version_number,
      'version_revision',version.revision,
      'default_locale',version.default_locale,
      'supported_locales',version.supported_locales,
      'title_i18n',version.title_i18n,
      'description_i18n',version.description_i18n,
      'content_schema_version',version.content_schema_version,
      'modules',coalesce((
        select jsonb_agg(jsonb_build_object(
          'id',module.id,
          'stable_key',module.stable_key,
          'position',module.position,
          'category_key',module.category_key,
          'title_i18n',module.title_i18n,
          'description_i18n',module.description_i18n,
          'metadata',module.metadata,
          'lessons',coalesce((
            select jsonb_agg(jsonb_build_object(
              'id',lesson.id,
              'stable_key',lesson.stable_key,
              'position',lesson.position,
              'lesson_type',lesson.lesson_type,
              'required',lesson.required,
              'title_i18n',lesson.title_i18n,
              'objective_i18n',lesson.objective_i18n,
              'content_i18n',lesson.content_i18n,
              'estimated_duration_seconds',lesson.estimated_duration_seconds,
              'minimum_engagement_seconds',lesson.minimum_engagement_seconds,
              'pass_threshold_bps',lesson.pass_threshold_bps,
              'max_attempts',lesson.max_attempts,
              'retry_delay_seconds',lesson.retry_delay_seconds,
              'metadata',lesson.metadata
            ) order by lesson.position,lesson.stable_key,lesson.id)
            from public.training_lessons lesson
            where lesson.organization_id = module.organization_id
              and lesson.course_version_id = module.course_version_id
              and lesson.module_id = module.id
          ),'[]'::jsonb)
        ) order by module.position,module.stable_key,module.id)
        from public.training_modules module
        where module.organization_id = version.organization_id
          and module.course_version_id = version.id
      ),'[]'::jsonb),
      'media',coalesce((
        select jsonb_agg(jsonb_build_object(
          'id',asset.id,
          'asset_key',asset.asset_key,
          'title_i18n',asset.title_i18n,
          'alt_i18n',asset.alt_i18n,
          'storage_bucket',asset.storage_bucket,
          'storage_object_path',asset.storage_object_path,
          'mime_type',asset.mime_type,
          'byte_size',asset.byte_size,
          'width',asset.width,
          'height',asset.height,
          'sha256',asset.sha256,
          'source_mime_type',asset.source_mime_type,
          'source_byte_size',asset.source_byte_size,
          'source_sha256',asset.source_sha256,
          'revision',asset.revision,
          'status',asset.status
        ) order by asset.asset_key,asset.id)
        from public.training_media_assets asset
        where asset.organization_id = version.organization_id
          and asset.course_version_id = version.id
      ),'[]'::jsonb)
    )::text,
    'sha256'
  ),'hex')
  from public.training_courses course
  join public.training_course_versions version
    on version.course_id = course.id
   and version.organization_id = course.organization_id
  where course.organization_id = target_organization_id
    and course.id = target_course_id
    and version.id = target_course_version_id;
$$;

create or replace function private.training_actor_modified_version(
  target_actor_user_id uuid,
  target_organization_id uuid,
  target_course_id uuid,
  target_course_version_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists(
    select 1 from public.training_courses course
    where course.organization_id=target_organization_id and course.id=target_course_id
      and target_actor_user_id in (course.created_by,course.updated_by)
    union all
    select 1 from public.training_course_versions version
    where version.organization_id=target_organization_id and version.id=target_course_version_id
      and version.course_id=target_course_id
      and target_actor_user_id in (version.created_by,version.updated_by)
    union all
    select 1 from public.training_modules module
    where module.organization_id=target_organization_id and module.course_version_id=target_course_version_id
      and target_actor_user_id in (module.created_by,module.updated_by)
    union all
    select 1 from public.training_lessons lesson
    where lesson.organization_id=target_organization_id and lesson.course_version_id=target_course_version_id
      and target_actor_user_id in (lesson.created_by,lesson.updated_by)
    union all
    select 1 from public.training_media_assets asset
    where asset.organization_id=target_organization_id and asset.course_version_id=target_course_version_id
      and target_actor_user_id in (asset.created_by,asset.updated_by)
  );
$$;

create or replace function public.submit_internal_admin_training_version_for_review(
  actor_user_id uuid,
  target_organization_id uuid,
  target_course_id uuid,
  target_course_version_id uuid,
  expected_revision bigint,
  expected_content_fingerprint text,
  action_request_id uuid
)
returns setof public.training_publication_review_submissions
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_version public.training_course_versions%rowtype;
  current_fingerprint text;
  saved public.training_publication_review_submissions%rowtype;
begin
  selected_version := private.assert_internal_admin_training_draft(
    actor_user_id,target_organization_id,target_course_id,target_course_version_id
  );
  perform 1 from public.training_course_versions version
  where version.id=selected_version.id for update;
  current_fingerprint := private.training_publication_content_fingerprint(
    target_organization_id,target_course_id,target_course_version_id
  );
  if action_request_id is null or expected_revision is null
    or expected_content_fingerprint !~ '^[0-9a-f]{64}$'
    or selected_version.revision <> expected_revision
    or current_fingerprint is distinct from expected_content_fingerprint then
    raise exception 'Training review submission is stale' using errcode='40001';
  end if;
  -- The submitter explicitly accepts authorship responsibility for any seeded
  -- or legacy content whose original database actor was unavailable.
  insert into public.training_content_contributor_events(
    organization_id,course_id,course_version_id,contributor_user_id,
    source_table,source_id,contribution_kind
  ) values(
    target_organization_id,target_course_id,target_course_version_id,actor_user_id,
    'training_course_versions',target_course_version_id,'legacy_attestation'
  ) on conflict do nothing;
  insert into public.training_publication_review_submissions(
    organization_id,course_id,course_version_id,version_revision,content_fingerprint,
    submitted_by,action_request_id
  ) values(
    target_organization_id,target_course_id,target_course_version_id,selected_version.revision,
    current_fingerprint,actor_user_id,action_request_id
  ) returning * into saved;
  insert into public.training_publication_submission_contributors(
    submission_id,organization_id,course_id,course_version_id,version_revision,
    content_fingerprint,contributor_user_id,evidence_sources
  )
  select saved.id,saved.organization_id,saved.course_id,saved.course_version_id,
    saved.version_revision,saved.content_fingerprint,evidence.contributor_user_id,
    array_agg(distinct evidence.source order by evidence.source)
  from (
    select contributor.contributor_user_id,
      contributor.source_table||':'||contributor.contribution_kind source
    from public.training_content_contributor_events contributor
    where contributor.organization_id=target_organization_id
      and contributor.course_version_id=target_course_version_id
    union all
    select contributor.contributor_user_id,'training_media_assets:'||contributor.contribution_kind
    from public.training_media_contributor_events contributor
    where contributor.organization_id=target_organization_id
      and contributor.course_version_id=target_course_version_id
  ) evidence
  group by evidence.contributor_user_id;
  if not exists(
    select 1 from public.training_publication_submission_contributors contributor
    where contributor.submission_id=saved.id and contributor.contributor_user_id=actor_user_id
  ) then
    raise exception 'Training contributor attribution is incomplete' using errcode='55000';
  end if;
  return next saved;
exception when unique_violation then
  raise exception 'Training review submission was already recorded' using errcode='55000';
end;
$$;

create or replace function public.review_internal_admin_training_version(
  actor_user_id uuid,
  target_organization_id uuid,
  target_course_id uuid,
  target_course_version_id uuid,
  target_submission_id uuid,
  expected_revision bigint,
  expected_content_fingerprint text,
  target_review_type text,
  review_locale text,
  review_decision text,
  review_reason text,
  action_request_id uuid
)
returns setof public.training_publication_review_events
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected_version public.training_course_versions%rowtype;
  submission public.training_publication_review_submissions%rowtype;
  current_fingerprint text;
  normalized_reason text := nullif(btrim(review_reason),'');
  normalized_locale text := nullif(btrim(review_locale),'');
  saved public.training_publication_review_events%rowtype;
begin
  selected_version := private.assert_internal_admin_training_draft(
    actor_user_id,target_organization_id,target_course_id,target_course_version_id
  );
  perform 1 from public.training_course_versions version
  where version.id=selected_version.id for update;
  if target_review_type not in ('content','translation','internal_regulatory')
    or review_decision not in ('approved','rejected')
    or action_request_id is null
    or (target_review_type='translation' and normalized_locale not in ('en','ar','id','hi','fil'))
    or (target_review_type<>'translation' and normalized_locale is not null)
    or (review_decision='approved' and normalized_reason is not null)
    or (review_decision='rejected' and (normalized_reason is null or length(normalized_reason)>1000)) then
    raise exception 'Invalid Training review decision' using errcode='22023';
  end if;
  select candidate.* into submission
  from public.training_publication_review_submissions candidate
  where candidate.id=target_submission_id
    and candidate.organization_id=target_organization_id
    and candidate.course_id=target_course_id
    and candidate.course_version_id=target_course_version_id;
  current_fingerprint := private.training_publication_content_fingerprint(
    target_organization_id,target_course_id,target_course_version_id
  );
  if submission.id is null or selected_version.revision<>expected_revision
    or submission.version_revision<>expected_revision
    or current_fingerprint is distinct from expected_content_fingerprint
    or submission.content_fingerprint is distinct from current_fingerprint then
    raise exception 'Training review decision is stale' using errcode='40001';
  end if;
  if exists(
    select 1 from public.training_publication_submission_contributors contributor
    where contributor.submission_id=submission.id
      and contributor.contributor_user_id=actor_user_id
  ) or private.training_actor_modified_version(
    actor_user_id,target_organization_id,target_course_id,target_course_version_id
  ) then
    raise exception 'Training self-approval is forbidden' using errcode='42501';
  end if;
  if exists(
    select 1 from public.training_publication_review_events event
    where event.submission_id=submission.id
      and event.review_type=target_review_type
      and event.locale is not distinct from normalized_locale
  ) then
    raise exception 'Training review decision was already recorded' using errcode='55000';
  end if;
  insert into public.training_publication_review_events(
    submission_id,organization_id,course_id,course_version_id,version_revision,
    content_fingerprint,review_type,locale,decision,actor_user_id,reason,action_request_id
  ) values(
    submission.id,target_organization_id,target_course_id,target_course_version_id,
    selected_version.revision,current_fingerprint,target_review_type,normalized_locale,
    review_decision,actor_user_id,normalized_reason,action_request_id
  ) returning * into saved;
  return next saved;
exception when unique_violation then
  raise exception 'Training review action was already recorded' using errcode='55000';
end;
$$;

create or replace function public.revoke_internal_admin_training_version_approval(
  actor_user_id uuid,
  target_organization_id uuid,
  target_course_id uuid,
  target_course_version_id uuid,
  target_submission_id uuid,
  target_review_type text,
  review_locale text,
  revocation_reason text,
  action_request_id uuid
)
returns setof public.training_publication_review_events
language plpgsql
security definer
set search_path = ''
as $$
declare
  submission public.training_publication_review_submissions%rowtype;
  latest public.training_publication_review_events%rowtype;
  normalized_locale text := nullif(btrim(review_locale),'');
  normalized_reason text := nullif(btrim(revocation_reason),'');
  current_fingerprint text;
  saved public.training_publication_review_events%rowtype;
begin
  perform private.assert_internal_admin_training_draft(
    actor_user_id,target_organization_id,target_course_id,target_course_version_id
  );
  perform private.lock_training_course_version(
    target_organization_id,target_course_version_id,'draft'
  );
  if action_request_id is null or normalized_reason is null or length(normalized_reason)>1000
    or target_review_type not in ('content','translation','internal_regulatory')
    or (target_review_type='translation' and normalized_locale not in ('en','ar','id','hi','fil'))
    or (target_review_type<>'translation' and normalized_locale is not null) then
    raise exception 'Invalid Training approval revocation' using errcode='22023';
  end if;
  select candidate.* into submission from public.training_publication_review_submissions candidate
  where candidate.id=target_submission_id and candidate.organization_id=target_organization_id
    and candidate.course_id=target_course_id and candidate.course_version_id=target_course_version_id;
  current_fingerprint := private.training_publication_content_fingerprint(
    target_organization_id,target_course_id,target_course_version_id
  );
  if submission.id is null or submission.content_fingerprint is distinct from current_fingerprint then
    raise exception 'Training approval revocation is stale' using errcode='40001';
  end if;
  select event.* into latest from public.training_publication_review_events event
  where event.submission_id=submission.id and event.review_type=target_review_type
    and event.locale is not distinct from normalized_locale
  order by event.occurred_at desc,event.id desc limit 1;
  if latest.id is null or latest.decision<>'approved' then
    raise exception 'Training approval is not active' using errcode='55000';
  end if;
  insert into public.training_publication_review_events(
    submission_id,organization_id,course_id,course_version_id,version_revision,
    content_fingerprint,review_type,locale,decision,actor_user_id,reason,action_request_id
  ) values(
    submission.id,target_organization_id,target_course_id,target_course_version_id,
    submission.version_revision,current_fingerprint,target_review_type,normalized_locale,
    'revoked',actor_user_id,normalized_reason,action_request_id
  ) returning * into saved;
  return next saved;
exception when unique_violation then
  raise exception 'Training review action was already recorded' using errcode='55000';
end;
$$;

-- Preserve the exact legacy decision before independently invalidating draft
-- media. Published and retired media are historical and are never rewritten.
insert into public.training_media_review_events(
  organization_id,course_id,course_version_id,media_id,media_revision,media_fingerprint,
  decision,actor_user_id,uploader_user_id,creator_user_id,modifier_user_id,
  contributor_user_ids,attribution_reliable,original_reviewed_at,
  reason,action_request_id,occurred_at
)
select asset.organization_id,version.course_id,asset.course_version_id,asset.id,asset.revision,
  private.training_media_asset_fingerprint(asset.organization_id,asset.course_version_id,asset.id),
  asset.approval_status,asset.reviewed_by,asset.created_by,asset.created_by,asset.updated_by,
  array(select distinct contributor from unnest(array[asset.created_by,asset.updated_by]) contributor
    where contributor is not null),
  asset.reviewed_by is not null and asset.reviewed_at is not null and asset.created_by is not null,
  asset.reviewed_at,asset.rejection_reason,gen_random_uuid(),coalesce(asset.reviewed_at,asset.updated_at,asset.created_at)
from public.training_media_assets asset
join public.training_course_versions version
  on version.id=asset.course_version_id and version.organization_id=asset.organization_id
where asset.approval_status in ('approved','rejected');

insert into public.training_media_review_events(
  organization_id,course_id,course_version_id,media_id,media_revision,media_fingerprint,
  decision,actor_user_id,uploader_user_id,creator_user_id,modifier_user_id,
  contributor_user_ids,attribution_reliable,original_reviewed_at,
  reason,action_request_id,occurred_at
)
select asset.organization_id,version.course_id,asset.course_version_id,asset.id,asset.revision,
  private.training_media_asset_fingerprint(asset.organization_id,asset.course_version_id,asset.id),
  'invalidated',asset.reviewed_by,asset.created_by,asset.created_by,asset.updated_by,
  array(select distinct contributor from unnest(array[asset.created_by,asset.updated_by]) contributor
    where contributor is not null),
  asset.reviewed_by is not null and asset.reviewed_at is not null and asset.created_by is not null,
  asset.reviewed_at,'Legacy draft decision invalidated because independent approval was not enforced.',
  gen_random_uuid(),statement_timestamp()
from public.training_media_assets asset
join public.training_course_versions version
  on version.id=asset.course_version_id and version.organization_id=asset.organization_id
where asset.approval_status in ('approved','rejected') and version.status='draft';

update public.training_media_assets asset
set approval_status='submitted',reviewed_at=null,reviewed_by=null,rejection_reason=null,
    revision=asset.revision+1
from public.training_course_versions version
where version.id=asset.course_version_id and version.organization_id=asset.organization_id
  and version.status='draft' and asset.approval_status in ('approved','rejected');

create or replace function public.review_internal_admin_training_media(
  actor_user_id uuid,target_organization_id uuid,target_course_id uuid,
  target_course_version_id uuid,target_media_id uuid,expected_revision integer,
  review_decision text,new_rejection_reason text default null
)
returns table(id uuid,approval_status text,reviewed_at timestamptz,rejection_reason text,revision integer,updated_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  selected public.training_media_assets%rowtype;
  saved public.training_media_assets%rowtype;
  normalized_reason text;
  media_fingerprint text;
  uploader_id uuid;
  contributor_ids uuid[];
begin
  perform private.assert_internal_admin_training_draft(actor_user_id,target_organization_id,target_course_id,target_course_version_id);
  if expected_revision is null or expected_revision<1 or review_decision not in ('approved','rejected') then
    raise exception 'Invalid Training media review' using errcode='22023';
  end if;
  normalized_reason := nullif(btrim(new_rejection_reason),'');
  if (review_decision='approved' and normalized_reason is not null)
    or (review_decision='rejected' and (normalized_reason is null or length(normalized_reason)>500)) then
    raise exception 'Invalid Training media review' using errcode='22023';
  end if;
  select asset.* into selected from public.training_media_assets asset
  where asset.id=target_media_id and asset.organization_id=target_organization_id
    and asset.course_version_id=target_course_version_id and asset.status='ready' for update;
  if selected.id is null then raise exception 'Training media not found' using errcode='P0002'; end if;
  perform private.assert_training_image_slot(target_organization_id,target_course_version_id,selected.asset_key);
  if selected.revision<>expected_revision then
    raise exception 'Training media review is stale' using errcode='40001';
  end if;
  if selected.approval_status<>'submitted' then
    raise exception 'Training media has already been reviewed' using errcode='55000';
  end if;
  uploader_id := selected.created_by;
  select array_agg(distinct contributor.contributor_user_id order by contributor.contributor_user_id)
    into contributor_ids
  from public.training_media_contributor_events contributor
  where contributor.organization_id=target_organization_id
    and contributor.course_version_id=target_course_version_id
    and contributor.media_id=target_media_id
    and contributor.media_revision<=selected.revision;
  if review_decision='approved' and (
    contributor_ids is null or cardinality(contributor_ids)=0
    or actor_user_id=any(contributor_ids)
  ) then
    raise exception 'Training media self-approval is forbidden' using errcode='42501';
  end if;
  if selected.media_type<>'image' or selected.mime_type<>'image/webp'
    or selected.byte_size<=0 or selected.width<=0 or selected.height<=0
    or selected.sha256 !~ '^[0-9a-f]{64}$'
    or not private.training_media_path_is_valid(selected.storage_object_path,target_organization_id,target_course_id,target_course_version_id,target_media_id)
    or not private.training_media_locales_complete(selected.title_i18n)
    or not private.training_media_locales_complete(selected.alt_i18n) then
    raise exception 'Invalid Training media' using errcode='22023';
  end if;
  update public.training_media_assets asset set
    approval_status=review_decision,reviewed_at=statement_timestamp(),reviewed_by=actor_user_id,
    rejection_reason=case when review_decision='rejected' then normalized_reason else null end,
    revision=asset.revision+1,updated_by=asset.updated_by
  where asset.id=selected.id
  returning asset.* into saved;
  media_fingerprint := private.training_media_asset_fingerprint(
    target_organization_id,target_course_version_id,target_media_id
  );
  insert into public.training_media_review_events(
    organization_id,course_id,course_version_id,media_id,media_revision,media_fingerprint,
    decision,actor_user_id,uploader_user_id,creator_user_id,modifier_user_id,
    contributor_user_ids,attribution_reliable,original_reviewed_at,
    reason,action_request_id
  ) values(
    target_organization_id,target_course_id,target_course_version_id,target_media_id,
    saved.revision,media_fingerprint,review_decision,actor_user_id,uploader_id,
    selected.created_by,selected.updated_by,coalesce(contributor_ids,array[]::uuid[]),
    contributor_ids is not null and cardinality(contributor_ids)>0,saved.reviewed_at,
    case when review_decision='rejected' then normalized_reason else null end,gen_random_uuid()
  );
  return query select saved.id,saved.approval_status,saved.reviewed_at,saved.rejection_reason,saved.revision,saved.updated_at;
end;
$$;

revoke all on function private.reject_training_audit_mutation() from public,anon,authenticated,service_role;
revoke all on function private.lock_training_course_version(uuid,uuid,text) from public,anon,authenticated,service_role;
revoke all on function private.capture_training_content_contributor() from public,anon,authenticated,service_role;
revoke all on function private.capture_training_media_contributor() from public,anon,authenticated,service_role;
revoke all on function private.enforce_training_draft_content() from public,anon,authenticated,service_role;
revoke all on function private.enforce_training_media_draft() from public,anon,authenticated,service_role;
revoke all on function private.training_media_asset_fingerprint(uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function private.training_publication_content_fingerprint(uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function private.training_actor_modified_version(uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.submit_internal_admin_training_version_for_review(uuid,uuid,uuid,uuid,bigint,text,uuid) from public,anon,authenticated,service_role;
revoke all on function public.review_internal_admin_training_version(uuid,uuid,uuid,uuid,uuid,bigint,text,text,text,text,text,uuid) from public,anon,authenticated,service_role;
revoke all on function public.revoke_internal_admin_training_version_approval(uuid,uuid,uuid,uuid,uuid,text,text,text,uuid) from public,anon,authenticated,service_role;
revoke all on function public.review_internal_admin_training_media(uuid,uuid,uuid,uuid,uuid,integer,text,text) from public,anon,authenticated,service_role;
grant execute on function public.submit_internal_admin_training_version_for_review(uuid,uuid,uuid,uuid,bigint,text,uuid) to service_role;
grant execute on function public.review_internal_admin_training_version(uuid,uuid,uuid,uuid,uuid,bigint,text,text,text,text,text,uuid) to service_role;
grant execute on function public.revoke_internal_admin_training_version_approval(uuid,uuid,uuid,uuid,uuid,text,text,text,uuid) to service_role;
grant execute on function public.review_internal_admin_training_media(uuid,uuid,uuid,uuid,uuid,integer,text,text) to service_role;

comment on table public.training_publication_review_submissions is
  'Immutable explicit author/submission attestations bound to one exact Training version fingerprint.';
comment on table public.training_content_contributor_events is
  'Immutable creator and modifier provenance accumulated for each Training version.';
comment on table public.training_media_contributor_events is
  'Immutable creator and modifier provenance accumulated across each media revision.';
comment on table public.training_publication_submission_contributors is
  'Immutable contributor snapshot bound to the exact submitted publication fingerprint.';
comment on table public.training_publication_review_events is
  'Immutable independent content, five-locale translation, and internal material review decisions.';
comment on table public.training_media_review_events is
  'Immutable per-revision Training media approval, rejection, and legacy invalidation history.';
