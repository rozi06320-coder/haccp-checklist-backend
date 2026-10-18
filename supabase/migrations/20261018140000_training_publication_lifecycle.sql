-- Phase 3A: fresh private-object verification handshake, atomic publication,
-- safe retirement, and Restaurant Training Program activation.

alter table public.training_course_versions
  add column publication_fingerprint text;
alter table public.training_course_versions
  add constraint training_course_versions_publication_fingerprint_check
  check(publication_fingerprint is null or publication_fingerprint ~ '^[0-9a-f]{64}$');

create table public.training_storage_verification_runs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  course_id uuid not null,
  course_version_id uuid not null,
  submission_id uuid not null,
  version_revision bigint not null,
  content_fingerprint text not null,
  challenge_nonce uuid not null default gen_random_uuid(),
  requested_by uuid not null references auth.users(id) on delete restrict,
  action_request_id uuid not null,
  requested_at timestamptz not null default statement_timestamp(),
  expires_at timestamptz not null default (statement_timestamp() + interval '10 minutes'),
  verified_at timestamptz,
  consumed_at timestamptz,
  status text not null default 'pending',
  constraint training_storage_verification_runs_version_scope_fkey
    foreign key(course_version_id,organization_id)
    references public.training_course_versions(id,organization_id) on delete restrict,
  constraint training_storage_verification_runs_course_scope_fkey
    foreign key(course_id,organization_id)
    references public.training_courses(id,organization_id) on delete restrict,
  constraint training_storage_verification_runs_submission_scope_fkey
    foreign key(submission_id,organization_id,course_id,course_version_id)
    references public.training_publication_review_submissions(id,organization_id,course_id,course_version_id)
    on delete restrict,
  constraint training_storage_verification_runs_request_key unique(organization_id,action_request_id),
  constraint training_storage_verification_runs_challenge_key unique(challenge_nonce),
  constraint training_storage_verification_runs_revision_check check(version_revision >= 0),
  constraint training_storage_verification_runs_fingerprint_check check(content_fingerprint ~ '^[0-9a-f]{64}$'),
  constraint training_storage_verification_runs_expiry_check check(expires_at > requested_at),
  constraint training_storage_verification_runs_status_check check(status in ('pending','verified','consumed')),
  constraint training_storage_verification_runs_state_check check(
    (status='pending' and verified_at is null and consumed_at is null)
    or (status='verified' and verified_at is not null and consumed_at is null)
    or (status='consumed' and verified_at is not null and consumed_at is not null and consumed_at >= verified_at)
  )
);

create index training_storage_verification_runs_scope_idx
  on public.training_storage_verification_runs(
    organization_id,course_id,course_version_id,status,expires_at
  );

create table public.training_storage_verification_items (
  run_id uuid not null references public.training_storage_verification_runs(id) on delete restrict,
  media_id uuid not null,
  organization_id uuid not null,
  course_version_id uuid not null,
  media_revision integer not null,
  storage_bucket text not null,
  storage_object_path text not null,
  observed_sha256 text not null,
  observed_byte_size integer not null,
  observed_width integer not null,
  observed_height integer not null,
  verified_at timestamptz not null default statement_timestamp(),
  primary key(run_id,media_id),
  constraint training_storage_verification_items_media_scope_fkey
    foreign key(media_id,course_version_id,organization_id)
    references public.training_media_assets(id,course_version_id,organization_id) on delete restrict,
  constraint training_storage_verification_items_revision_check check(media_revision > 0),
  constraint training_storage_verification_items_bucket_check check(storage_bucket='training-media'),
  constraint training_storage_verification_items_sha_check check(observed_sha256 ~ '^[0-9a-f]{64}$'),
  constraint training_storage_verification_items_dimensions_check check(
    observed_byte_size>0 and observed_width>0 and observed_height>0
  )
);

create table public.training_publication_lifecycle_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  course_id uuid,
  course_version_id uuid,
  program_id uuid,
  event_type text not null,
  version_revision bigint,
  content_fingerprint text,
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  action_request_id uuid not null,
  details jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default statement_timestamp(),
  constraint training_publication_lifecycle_events_request_key unique(organization_id,action_request_id),
  constraint training_publication_lifecycle_events_type_check
    check(event_type in ('published','retired','program_activated','program_retired')),
  constraint training_publication_lifecycle_events_fingerprint_check
    check(content_fingerprint is null or content_fingerprint ~ '^[0-9a-f]{64}$'),
  constraint training_publication_lifecycle_events_details_check check(jsonb_typeof(details)='object'),
  constraint training_publication_lifecycle_events_scope_check check(
    (event_type in ('published','retired') and course_id is not null and course_version_id is not null
      and program_id is null and version_revision is not null and content_fingerprint is not null)
    or (event_type in ('program_activated','program_retired') and program_id is not null and course_id is null
      and course_version_id is null and version_revision is null and content_fingerprint is null)
  )
);

create index training_publication_lifecycle_events_scope_idx
  on public.training_publication_lifecycle_events(
    organization_id,course_id,course_version_id,event_type,occurred_at desc
  );

alter table public.training_storage_verification_runs enable row level security;
alter table public.training_storage_verification_items enable row level security;
alter table public.training_publication_lifecycle_events enable row level security;
revoke all on table public.training_storage_verification_runs from public,anon,authenticated,service_role;
revoke all on table public.training_storage_verification_items from public,anon,authenticated,service_role;
revoke all on table public.training_publication_lifecycle_events from public,anon,authenticated,service_role;

create trigger training_storage_verification_items_immutability
before update or delete on public.training_storage_verification_items
for each row execute function private.reject_training_audit_mutation();
create trigger training_publication_lifecycle_events_immutability
before update or delete on public.training_publication_lifecycle_events
for each row execute function private.reject_training_audit_mutation();

create or replace function private.enforce_training_course_version_immutability()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status='retired' then
    raise exception 'Retired Training course versions are immutable' using errcode='55000';
  end if;
  if old.status='published' then
    if tg_op='DELETE' then
      raise exception 'Published Training course versions are immutable' using errcode='55000';
    end if;
    if new.status='retired'
      and new.id=old.id and new.organization_id=old.organization_id
      and new.course_id=old.course_id and new.version_number=old.version_number
      and new.default_locale=old.default_locale and new.supported_locales=old.supported_locales
      and new.title_i18n=old.title_i18n and new.description_i18n=old.description_i18n
      and new.content_schema_version=old.content_schema_version and new.revision=old.revision
      and new.content_hash is not distinct from old.content_hash
      and new.publication_fingerprint is not distinct from old.publication_fingerprint
      and new.created_at=old.created_at and new.created_by is not distinct from old.created_by
      and new.published_at=old.published_at and new.published_by=old.published_by
      and new.retired_at is not null and new.retired_by is not null then
      return new;
    end if;
    raise exception 'Published Training course version content is immutable' using errcode='55000';
  end if;
  return case when tg_op='DELETE' then old else new end;
end;
$$;

create or replace function private.enforce_training_enrollment_published_version()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare locked_version public.training_course_versions%rowtype;
  program_status text;
begin
  locked_version := private.lock_training_course_version(
    new.organization_id,new.course_version_id,'published'
  );
  if locked_version.course_id<>new.course_id then
    raise exception 'Published Training course is unavailable' using errcode='55000';
  end if;
  if new.program_course_id is not null then
    select program.status into program_status
    from public.training_program_courses entry
    join public.training_programs program
      on program.id=entry.program_id and program.organization_id=entry.organization_id
    where entry.id=new.program_course_id and entry.organization_id=new.organization_id
      and entry.course_id=new.course_id
    for update of program;
    if program_status is distinct from 'active' then
      raise exception 'Training program course is unavailable' using errcode='55000';
    end if;
  end if;
  return new;
end;
$$;

create trigger training_enrollments_02_published_version_lock
before insert on public.training_enrollments
for each row execute function private.enforce_training_enrollment_published_version();

create or replace function private.training_submission_is_publishable(
  target_submission_id uuid,
  target_organization_id uuid,
  target_course_id uuid,
  target_course_version_id uuid,
  expected_revision bigint,
  expected_content_fingerprint text
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with required(review_type,locale) as (
    values ('content'::text,null::text),('internal_regulatory',null),
      ('translation','en'),('translation','ar'),('translation','id'),
      ('translation','hi'),('translation','fil')
  )
  select exists(
    select 1 from public.training_publication_review_submissions submission
    where submission.id=target_submission_id
      and submission.organization_id=target_organization_id
      and submission.course_id=target_course_id
      and submission.course_version_id=target_course_version_id
      and submission.version_revision=expected_revision
      and submission.content_fingerprint=expected_content_fingerprint
  ) and not exists(
    select 1 from required
    left join lateral(
      select event.decision from public.training_publication_review_events event
      where event.submission_id=target_submission_id
        and event.organization_id=target_organization_id
        and event.course_id=target_course_id
        and event.course_version_id=target_course_version_id
        and event.version_revision=expected_revision
        and event.content_fingerprint=expected_content_fingerprint
        and event.review_type=required.review_type
        and event.locale is not distinct from required.locale
      order by event.occurred_at desc,event.id desc limit 1
    ) latest on true
    where latest.decision is distinct from 'approved'
  );
$$;

create or replace function private.training_media_has_current_independent_approval(
  target_organization_id uuid,
  target_course_version_id uuid,
  target_media_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists(
    select 1
    from public.training_media_assets asset
    join public.training_media_review_events event
      on event.organization_id=asset.organization_id
     and event.course_version_id=asset.course_version_id
     and event.media_id=asset.id
     and event.media_revision=asset.revision
     and event.media_fingerprint=private.training_media_asset_fingerprint(
       asset.organization_id,asset.course_version_id,asset.id
     )
     and event.decision='approved'
     and event.actor_user_id is not null
     and event.uploader_user_id is not null
     and event.attribution_reliable
     and cardinality(event.contributor_user_ids)>0
     and not event.actor_user_id=any(event.contributor_user_ids)
    where asset.organization_id=target_organization_id
      and asset.course_version_id=target_course_version_id
      and asset.id=target_media_id
      and asset.status='ready'
      and asset.approval_status='approved'
      and asset.reviewed_by=event.actor_user_id
  );
$$;

create or replace function public.validate_internal_admin_training_media_for_publish(
  actor_user_id uuid,target_organization_id uuid,target_course_id uuid,target_course_version_id uuid
)
returns table(media_hash text,referenced_asset_count integer)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare invalid_key text; media_material text; slot_count integer;
begin
  perform private.assert_internal_admin_training_draft(actor_user_id,target_organization_id,target_course_id,target_course_version_id);
  if not private.training_image_slot_bindings_valid(target_organization_id,target_course_version_id) then
    raise exception 'Training media publication validation failed' using errcode='55000';
  end if;
  select count(*)::integer into slot_count
  from private.training_image_slot_requirements(target_organization_id,target_course_version_id);
  select slot.asset_key into invalid_key
  from private.training_image_slot_requirements(target_organization_id,target_course_version_id) slot
  left join public.training_media_assets asset
    on asset.course_version_id=target_course_version_id and asset.organization_id=target_organization_id
   and asset.asset_key=slot.asset_key and asset.status='ready'
  where asset.id is null or asset.approval_status<>'approved'
     or asset.reviewed_at is null or asset.reviewed_by is null or asset.rejection_reason is not null
     or asset.media_type<>'image' or asset.mime_type<>'image/webp'
     or asset.byte_size<=0 or asset.width<=0 or asset.height<=0 or asset.sha256 !~ '^[0-9a-f]{64}$'
     or not private.training_media_locales_complete(asset.alt_i18n)
     or not private.training_media_has_current_independent_approval(
       target_organization_id,target_course_version_id,asset.id
     )
  order by slot.module_position,slot.lesson_position,slot.slot_position limit 1;
  if invalid_key is not null or slot_count<>40 then
    raise exception 'Training media publication validation failed' using errcode='55000';
  end if;
  select string_agg(
    asset.asset_key||':'||asset.sha256||':'||asset.width||'x'||asset.height||':'||asset.revision,
    '|' order by asset.asset_key
  ) into media_material
  from private.training_image_slot_requirements(target_organization_id,target_course_version_id) slot
  join public.training_media_assets asset
    on asset.course_version_id=target_course_version_id and asset.organization_id=target_organization_id
   and asset.asset_key=slot.asset_key and asset.status='ready' and asset.approval_status='approved';
  return query select pg_catalog.encode(extensions.digest(coalesce(media_material,''),'sha256'),'hex'),slot_count;
end;
$$;

create or replace function public.begin_internal_admin_training_storage_verification(
  actor_user_id uuid,
  target_organization_id uuid,
  target_course_id uuid,
  target_course_version_id uuid,
  target_submission_id uuid,
  expected_revision bigint,
  expected_content_fingerprint text,
  action_request_id uuid
)
returns table(
  verification_run_id uuid,challenge_nonce uuid,expires_at timestamptz,
  media_id uuid,media_revision integer,storage_bucket text,storage_object_path text,
  expected_sha256 text,expected_byte_size integer,expected_width integer,expected_height integer
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  version public.training_course_versions%rowtype;
  current_fingerprint text;
  saved_run public.training_storage_verification_runs%rowtype;
begin
  version := private.assert_internal_admin_training_draft(
    actor_user_id,target_organization_id,target_course_id,target_course_version_id
  );
  perform 1 from public.training_course_versions locked where locked.id=version.id for update;
  current_fingerprint := private.training_publication_content_fingerprint(
    target_organization_id,target_course_id,target_course_version_id
  );
  if action_request_id is null or version.revision<>expected_revision
    or current_fingerprint is distinct from expected_content_fingerprint
    or not private.training_submission_is_publishable(
      target_submission_id,target_organization_id,target_course_id,target_course_version_id,
      expected_revision,current_fingerprint
    ) then
    raise exception 'Training storage verification precondition failed' using errcode='55000';
  end if;
  perform 1 from public.validate_internal_admin_training_media_for_publish(
    actor_user_id,target_organization_id,target_course_id,target_course_version_id
  );
  insert into public.training_storage_verification_runs(
    organization_id,course_id,course_version_id,submission_id,version_revision,
    content_fingerprint,requested_by,action_request_id
  ) values(
    target_organization_id,target_course_id,target_course_version_id,target_submission_id,
    expected_revision,current_fingerprint,actor_user_id,action_request_id
  ) returning * into saved_run;
  return query
  select saved_run.id,saved_run.challenge_nonce,saved_run.expires_at,
    asset.id,asset.revision,asset.storage_bucket,asset.storage_object_path,
    asset.sha256,asset.byte_size,asset.width,asset.height
  from private.training_image_slot_requirements(target_organization_id,target_course_version_id) slot
  join public.training_media_assets asset
    on asset.organization_id=target_organization_id
   and asset.course_version_id=target_course_version_id
   and asset.asset_key=slot.asset_key and asset.status='ready'
  order by slot.module_position,slot.lesson_position,slot.slot_position;
exception when unique_violation then
  raise exception 'Training storage verification request was already used' using errcode='55000';
end;
$$;

create or replace function public.complete_internal_admin_training_storage_verification(
  actor_user_id uuid,
  target_organization_id uuid,
  target_verification_run_id uuid,
  target_challenge_nonce uuid,
  observed_objects jsonb
)
returns table(verification_run_id uuid,verified_at timestamptz,verified_object_count integer)
language plpgsql
security definer
set search_path = ''
as $$
declare
  run public.training_storage_verification_runs%rowtype;
  current_fingerprint text;
  observed_count integer;
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'Training publication access denied' using errcode='42501';
  end if;
  select candidate.* into run from public.training_storage_verification_runs candidate
  where candidate.id=target_verification_run_id and candidate.organization_id=target_organization_id
  for update;
  if run.id is null then raise exception 'Training storage verification not found' using errcode='P0002'; end if;
  if run.requested_by<>actor_user_id or run.challenge_nonce<>target_challenge_nonce
    or run.status<>'pending' or statement_timestamp()>=run.expires_at
    or jsonb_typeof(observed_objects)<>'array' or jsonb_array_length(observed_objects)<>40
    or exists(
      select 1 from jsonb_array_elements(observed_objects) object
      where jsonb_typeof(object)<>'object' or (select count(*) from jsonb_object_keys(object))<>5
    ) then
    raise exception 'Training storage verification is invalid or expired' using errcode='55000';
  end if;
  current_fingerprint := private.training_publication_content_fingerprint(
    run.organization_id,run.course_id,run.course_version_id
  );
  if current_fingerprint is distinct from run.content_fingerprint then
    raise exception 'Training storage verification is stale' using errcode='40001';
  end if;
  select count(*)::integer into observed_count
  from jsonb_to_recordset(observed_objects) as observed(
    media_id uuid,sha256 text,byte_size integer,width integer,height integer
  );
  if observed_count<>40
    or (
      select count(distinct media_id)
      from jsonb_to_recordset(observed_objects) as observed(
        media_id uuid,sha256 text,byte_size integer,width integer,height integer
      )
    )<>40
    or exists(
      select 1
      from private.training_image_slot_requirements(run.organization_id,run.course_version_id) slot
      join public.training_media_assets asset
        on asset.organization_id=run.organization_id and asset.course_version_id=run.course_version_id
       and asset.asset_key=slot.asset_key and asset.status='ready'
      left join jsonb_to_recordset(observed_objects) as observed(
        media_id uuid,sha256 text,byte_size integer,width integer,height integer
      ) on observed.media_id=asset.id
      where observed.media_id is null or observed.sha256 is distinct from asset.sha256
        or observed.byte_size is distinct from asset.byte_size
        or observed.width is distinct from asset.width
        or observed.height is distinct from asset.height
    ) then
    raise exception 'Training storage object evidence does not match' using errcode='55000';
  end if;
  insert into public.training_storage_verification_items(
    run_id,media_id,organization_id,course_version_id,media_revision,storage_bucket,
    storage_object_path,observed_sha256,observed_byte_size,observed_width,observed_height
  )
  select run.id,asset.id,asset.organization_id,asset.course_version_id,asset.revision,
    asset.storage_bucket,asset.storage_object_path,observed.sha256,observed.byte_size,
    observed.width,observed.height
  from private.training_image_slot_requirements(run.organization_id,run.course_version_id) slot
  join public.training_media_assets asset
    on asset.organization_id=run.organization_id and asset.course_version_id=run.course_version_id
   and asset.asset_key=slot.asset_key and asset.status='ready'
  join jsonb_to_recordset(observed_objects) as observed(
    media_id uuid,sha256 text,byte_size integer,width integer,height integer
  ) on observed.media_id=asset.id;
  update public.training_storage_verification_runs target
  set status='verified',verified_at=statement_timestamp()
  where target.id=run.id returning target.verified_at into run.verified_at;
  return query select run.id,run.verified_at,40;
end;
$$;

create or replace function public.publish_internal_admin_training_course_version(
  actor_user_id uuid,
  target_organization_id uuid,
  target_course_id uuid,
  target_course_version_id uuid,
  target_submission_id uuid,
  target_verification_run_id uuid,
  expected_revision bigint,
  expected_content_fingerprint text,
  action_request_id uuid
)
returns setof public.training_course_versions
language plpgsql
security definer
set search_path = ''
as $$
declare
  version public.training_course_versions%rowtype;
  run public.training_storage_verification_runs%rowtype;
  current_fingerprint text;
  saved public.training_course_versions%rowtype;
begin
  version := private.assert_internal_admin_training_draft(
    actor_user_id,target_organization_id,target_course_id,target_course_version_id
  );
  version := private.lock_training_course_version(
    target_organization_id,target_course_version_id,'draft'
  );
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    target_organization_id::text||':'||target_course_id::text,0
  ));
  if version.course_id<>target_course_id then
    raise exception 'Training course version not found' using errcode='P0002';
  end if;
  current_fingerprint := private.training_publication_content_fingerprint(
    target_organization_id,target_course_id,target_course_version_id
  );
  if version.status<>'draft' or version.version_number<>1 or version.revision<>2
    or version.revision<>expected_revision
    or current_fingerprint is distinct from expected_content_fingerprint
    or not private.training_submission_is_publishable(
      target_submission_id,target_organization_id,target_course_id,target_course_version_id,
      expected_revision,current_fingerprint
    ) then
    raise exception 'Training publication approval is missing or stale' using errcode='55000';
  end if;
  -- This exact preview validator enforces the canonical Baladiyah v1/revision 2,
  -- 18 instructional lessons, 27 questions, 8000 bps, five locales, and 40 slots.
  perform 1 from public.get_internal_admin_training_draft_preview(
    actor_user_id,target_organization_id,target_course_id,target_course_version_id
  ) limit 1;
  perform 1 from public.validate_internal_admin_training_media_for_publish(
    actor_user_id,target_organization_id,target_course_id,target_course_version_id
  );
  if exists(
    select 1 from public.training_course_versions conflict
    where conflict.organization_id=target_organization_id and conflict.course_id=target_course_id
      and conflict.status='published' and conflict.id<>target_course_version_id
  ) then
    raise exception 'Another Training course version is already published' using errcode='55000';
  end if;
  select candidate.* into run from public.training_storage_verification_runs candidate
  where candidate.id=target_verification_run_id and candidate.organization_id=target_organization_id
    and candidate.course_id=target_course_id and candidate.course_version_id=target_course_version_id
    and candidate.submission_id=target_submission_id for update;
  if run.id is null or run.status<>'verified' or run.requested_by<>actor_user_id
    or run.version_revision<>expected_revision or run.content_fingerprint<>current_fingerprint
    or run.verified_at < statement_timestamp()-interval '5 minutes'
    or statement_timestamp()>=run.expires_at
    or (select count(*) from public.training_storage_verification_items item where item.run_id=run.id)<>40
    or exists(
      select 1 from public.training_storage_verification_items item
      join public.training_media_assets asset
        on asset.id=item.media_id and asset.organization_id=item.organization_id
       and asset.course_version_id=item.course_version_id
      where item.run_id=run.id and (
        item.media_revision<>asset.revision or item.storage_bucket<>asset.storage_bucket
        or item.storage_object_path<>asset.storage_object_path
        or item.observed_sha256<>asset.sha256 or item.observed_byte_size<>asset.byte_size
        or item.observed_width<>asset.width or item.observed_height<>asset.height
      )
    ) then
    raise exception 'Training storage verification is missing, stale, or invalid' using errcode='55000';
  end if;
  update public.training_storage_verification_runs target
  set status='consumed',consumed_at=statement_timestamp() where target.id=run.id;
  update public.training_course_versions target
  set status='published',published_at=statement_timestamp(),published_by=actor_user_id,
      publication_fingerprint=current_fingerprint
  where target.id=version.id returning target.* into saved;
  insert into public.training_publication_lifecycle_events(
    organization_id,course_id,course_version_id,event_type,version_revision,
    content_fingerprint,actor_user_id,action_request_id,details
  ) values(
    target_organization_id,target_course_id,target_course_version_id,'published',
    expected_revision,current_fingerprint,actor_user_id,action_request_id,
    jsonb_build_object('submission_id',target_submission_id,'storage_verification_run_id',run.id)
  );
  return next saved;
exception when unique_violation then
  raise exception 'Training publication action was already recorded or conflicts' using errcode='55000';
end;
$$;

create or replace function public.retire_internal_admin_training_course_version(
  actor_user_id uuid,
  target_organization_id uuid,
  target_course_id uuid,
  target_course_version_id uuid,
  retirement_reason text,
  action_request_id uuid
)
returns setof public.training_course_versions
language plpgsql
security definer
set search_path = ''
as $$
declare
  version public.training_course_versions%rowtype;
  normalized_reason text := nullif(btrim(retirement_reason),'');
  saved public.training_course_versions%rowtype;
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'Training publication access denied' using errcode='42501';
  end if;
  if action_request_id is null or normalized_reason is null or length(normalized_reason)>1000 then
    raise exception 'Invalid Training retirement' using errcode='22023';
  end if;
  version := private.lock_training_course_version(
    target_organization_id,target_course_version_id,'published'
  );
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    target_organization_id::text||':'||target_course_id::text,0
  ));
  if version.course_id<>target_course_id then
    raise exception 'Training course version not found' using errcode='P0002';
  end if;
  if version.publication_fingerprint is null then
    raise exception 'Training course version is not published' using errcode='55000';
  end if;
  if exists(
    select 1 from public.training_program_courses entry
    join public.training_programs program on program.id=entry.program_id and program.organization_id=entry.organization_id
    where entry.organization_id=target_organization_id and entry.course_id=target_course_id
      and program.status='active'
  ) then
    raise exception 'An active Training program still requires this course' using errcode='55000';
  end if;
  if exists(
    select 1 from public.training_enrollments enrollment
    where enrollment.organization_id=target_organization_id
      and enrollment.course_version_id=target_course_version_id and enrollment.status='active'
      and not exists(
        select 1 from public.training_course_completions completion
        where completion.organization_id=enrollment.organization_id
          and completion.enrollment_id=enrollment.id
          and completion.course_version_id=enrollment.course_version_id
      )
  ) then
    raise exception 'Incomplete learner progress blocks Training retirement' using errcode='55000';
  end if;
  update public.training_course_versions target
  set status='retired',retired_at=statement_timestamp(),retired_by=actor_user_id
  where target.id=version.id returning target.* into saved;
  insert into public.training_publication_lifecycle_events(
    organization_id,course_id,course_version_id,event_type,version_revision,
    content_fingerprint,actor_user_id,action_request_id,details
  ) values(
    target_organization_id,target_course_id,target_course_version_id,'retired',version.revision,
    version.publication_fingerprint,actor_user_id,action_request_id,
    jsonb_build_object('reason',normalized_reason)
  );
  return next saved;
exception when unique_violation then
  raise exception 'Training retirement action was already recorded' using errcode='55000';
end;
$$;

create or replace function public.activate_internal_admin_restaurant_training_program(
  actor_user_id uuid,
  target_organization_id uuid,
  target_program_id uuid,
  action_request_id uuid
)
returns setof public.training_programs
language plpgsql
security definer
set search_path = ''
as $$
declare
  program public.training_programs%rowtype;
  baladiyah_entry public.training_program_courses%rowtype;
  sop_entry public.training_program_courses%rowtype;
  baladiyah_version public.training_course_versions%rowtype;
  saved public.training_programs%rowtype;
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'Training program access denied' using errcode='42501';
  end if;
  if action_request_id is null then raise exception 'Invalid Training program activation' using errcode='22023'; end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    target_organization_id::text||':restaurant-training',0
  ));
  select candidate.* into program from public.training_programs candidate
  where candidate.id=target_program_id and candidate.organization_id=target_organization_id for update;
  if program.id is null then raise exception 'Training program not found' using errcode='P0002'; end if;
  if program.program_key<>'restaurant-training' or program.status<>'draft'
    or (select count(*) from public.training_program_courses entry where entry.program_id=program.id)<>2 then
    raise exception 'Restaurant Training program structure is invalid' using errcode='55000';
  end if;
  select entry.* into baladiyah_entry
  from public.training_program_courses entry join public.training_courses course
    on course.id=entry.course_id and course.organization_id=entry.organization_id
  where entry.program_id=program.id and entry.organization_id=target_organization_id
    and entry.position=1 and entry.required and entry.prerequisite_program_course_id is null
    and course.course_key='baladiyah-food-safety-hygiene' and course.status='active';
  select entry.* into sop_entry
  from public.training_program_courses entry join public.training_courses course
    on course.id=entry.course_id and course.organization_id=entry.organization_id
  where entry.program_id=program.id and entry.organization_id=target_organization_id
    and entry.position=2 and entry.required and course.course_key='restaurant-sop' and course.status='active';
  if baladiyah_entry.id is null or sop_entry.id is null
    or sop_entry.prerequisite_program_course_id<>baladiyah_entry.id then
    raise exception 'Restaurant Training program structure is invalid' using errcode='55000';
  end if;
  select version.* into baladiyah_version from public.training_course_versions version
  where version.organization_id=target_organization_id and version.course_id=baladiyah_entry.course_id
    and version.status='published';
  if baladiyah_version.id is null or baladiyah_version.publication_fingerprint is null then
    raise exception 'Published Baladiyah Training is required' using errcode='55000';
  end if;
  if exists(
    select 1 from public.training_course_versions version
    where version.organization_id=target_organization_id and version.course_id=sop_entry.course_id
      and version.status='published'
  ) then
    raise exception 'Restaurant SOP must remain unpublished until its curriculum is ready' using errcode='55000';
  end if;
  update public.training_programs target set status='active',updated_by=actor_user_id
  where target.id=program.id returning target.* into saved;
  insert into public.training_publication_lifecycle_events(
    organization_id,program_id,event_type,actor_user_id,action_request_id,details
  ) values(
    target_organization_id,program.id,'program_activated',actor_user_id,action_request_id,
    jsonb_build_object(
      'baladiyah_program_course_id',baladiyah_entry.id,
      'baladiyah_course_version_id',baladiyah_version.id,
      'restaurant_sop_program_course_id',sop_entry.id,
      'restaurant_sop_course_id',sop_entry.course_id
    )
  );
  return next saved;
exception when unique_violation then
  raise exception 'Training program activation was already recorded' using errcode='55000';
end;
$$;

create or replace function public.retire_internal_admin_training_program(
  actor_user_id uuid,
  target_organization_id uuid,
  target_program_id uuid,
  retirement_reason text,
  action_request_id uuid
)
returns setof public.training_programs
language plpgsql
security definer
set search_path = ''
as $$
declare
  program public.training_programs%rowtype;
  normalized_reason text := nullif(btrim(retirement_reason),'');
  saved public.training_programs%rowtype;
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'Training program access denied' using errcode='42501';
  end if;
  if action_request_id is null or normalized_reason is null or length(normalized_reason)>1000 then
    raise exception 'Invalid Training program retirement' using errcode='22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    target_organization_id::text||':restaurant-training',0
  ));
  select candidate.* into program from public.training_programs candidate
  where candidate.id=target_program_id and candidate.organization_id=target_organization_id
  for update;
  if program.id is null then raise exception 'Training program not found' using errcode='P0002'; end if;
  if program.status<>'active' then
    raise exception 'Training program is not active' using errcode='55000';
  end if;
  if exists(
    select 1
    from public.training_program_courses entry
    join public.training_enrollments enrollment
      on enrollment.organization_id=entry.organization_id
     and enrollment.program_course_id=entry.id
     and enrollment.status='active'
    where entry.organization_id=target_organization_id and entry.program_id=program.id
      and not exists(
        select 1 from public.training_course_completions completion
        where completion.organization_id=enrollment.organization_id
          and completion.enrollment_id=enrollment.id
          and completion.course_version_id=enrollment.course_version_id
      )
  ) then
    raise exception 'Incomplete learner progress blocks Training program retirement' using errcode='55000';
  end if;
  update public.training_programs target
  set status='retired',updated_by=actor_user_id
  where target.id=program.id returning target.* into saved;
  insert into public.training_publication_lifecycle_events(
    organization_id,program_id,event_type,actor_user_id,action_request_id,details
  ) values(
    target_organization_id,program.id,'program_retired',actor_user_id,action_request_id,
    jsonb_build_object('reason',normalized_reason)
  );
  return next saved;
exception when unique_violation then
  raise exception 'Training program retirement was already recorded' using errcode='55000';
end;
$$;

create or replace function private.enforce_active_training_program_structure()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare program_status text;
begin
  select program.status into program_status from public.training_programs program
  where program.id=coalesce(old.program_id,new.program_id)
    and program.organization_id=coalesce(old.organization_id,new.organization_id);
  if program_status in ('active','retired') then
    raise exception 'Active or retired Training program structure is immutable' using errcode='55000';
  end if;
  return case when tg_op='DELETE' then old else new end;
end;
$$;
create trigger training_program_courses_05_active_immutability
before insert or update or delete on public.training_program_courses
for each row execute function private.enforce_active_training_program_structure();

create or replace function public.get_internal_admin_training_publication_readiness(
  actor_user_id uuid,target_organization_id uuid,target_course_id uuid,target_course_version_id uuid
)
returns table(
  course_key text,course_title_i18n jsonb,version_number integer,version_status text,revision bigint,
  curriculum_valid boolean,instructional_module_count integer,instructional_lesson_count integer,
  final_assessment_count integer,final_quiz_count integer,quiz_question_count integer,pass_threshold_bps integer,
  required_image_count integer,uploaded_image_count integer,submitted_image_count integer,
  approved_image_count integer,rejected_image_count integer,missing_image_count integer,
  image_metadata_valid boolean,image_database_ready boolean,locale_structure_complete boolean,
  conflicting_published_version boolean,translation_review_status jsonb,content_review_status text,
  regulatory_review_status text,review_workflow_available boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  target_version public.training_course_versions%rowtype;
  target_course public.training_courses%rowtype;
  current_fingerprint text;
  latest_submission public.training_publication_review_submissions%rowtype;
  slots integer; uploaded integer; submitted integer; approved integer; rejected integer;
  metadata_valid boolean; media_ready boolean := false;
  translations jsonb := '{}'::jsonb; locale_name text; status_name text;
begin
  perform private.assert_internal_admin_training_draft(actor_user_id,target_organization_id,target_course_id,target_course_version_id);
  select course.* into strict target_course from public.training_courses course
  where course.id=target_course_id and course.organization_id=target_organization_id;
  select version.* into strict target_version from public.training_course_versions version
  where version.id=target_course_version_id and version.course_id=target_course_id
    and version.organization_id=target_organization_id;
  perform 1 from public.get_internal_admin_training_draft_preview(
    actor_user_id,target_organization_id,target_course_id,target_course_version_id
  ) limit 1;
  current_fingerprint := private.training_publication_content_fingerprint(
    target_organization_id,target_course_id,target_course_version_id
  );
  select candidate.* into latest_submission from public.training_publication_review_submissions candidate
  where candidate.organization_id=target_organization_id and candidate.course_id=target_course_id
    and candidate.course_version_id=target_course_version_id
    and candidate.version_revision=target_version.revision
    and candidate.content_fingerprint=current_fingerprint
  order by candidate.submitted_at desc,candidate.id desc limit 1;
  select count(*)::integer into slots
  from private.training_image_slot_requirements(target_organization_id,target_course_version_id);
  select count(asset.id)::integer,
    count(asset.id) filter(where asset.approval_status='submitted')::integer,
    count(asset.id) filter(where asset.approval_status='approved')::integer,
    count(asset.id) filter(where asset.approval_status='rejected')::integer,
    coalesce(bool_and(asset.id is null or (
      asset.status='ready' and asset.media_type='image' and asset.mime_type='image/webp'
      and asset.byte_size>0 and asset.width>0 and asset.height>0 and asset.sha256~'^[0-9a-f]{64}$'
      and private.training_media_locales_complete(asset.alt_i18n)
    )),true)
  into uploaded,submitted,approved,rejected,metadata_valid
  from private.training_image_slot_requirements(target_organization_id,target_course_version_id) slot
  left join public.training_media_assets asset
    on asset.organization_id=target_organization_id and asset.course_version_id=target_course_version_id
   and asset.asset_key=slot.asset_key and asset.status='ready';
  if slots=40 and approved=40 and metadata_valid then
    begin
      perform 1 from public.validate_internal_admin_training_media_for_publish(
        actor_user_id,target_organization_id,target_course_id,target_course_version_id
      );
      media_ready := true;
    exception when sqlstate '55000' then media_ready := false;
    end;
  end if;
  foreach locale_name in array array['en','ar','id','hi','fil']::text[] loop
    select coalesce((
      select event.decision from public.training_publication_review_events event
      where event.submission_id=latest_submission.id and event.review_type='translation'
        and event.locale=locale_name order by event.occurred_at desc,event.id desc limit 1
    ),'pending') into status_name;
    translations := translations||jsonb_build_object(locale_name,status_name);
  end loop;
  return query select target_course.course_key,target_version.title_i18n,target_version.version_number,
    target_version.status,target_version.revision,true,9,18,1,1,27,8000,slots,uploaded,submitted,
    approved,rejected,slots-uploaded,metadata_valid,media_ready,true,
    exists(select 1 from public.training_course_versions conflict where conflict.organization_id=target_organization_id
      and conflict.course_id=target_course_id and conflict.status='published' and conflict.id<>target_course_version_id),
    translations,
    coalesce((select event.decision from public.training_publication_review_events event
      where event.submission_id=latest_submission.id and event.review_type='content'
      order by event.occurred_at desc,event.id desc limit 1),'pending'),
    coalesce((select event.decision from public.training_publication_review_events event
      where event.submission_id=latest_submission.id and event.review_type='internal_regulatory'
      order by event.occurred_at desc,event.id desc limit 1),'pending'),true;
end;
$$;

revoke all on function private.training_submission_is_publishable(uuid,uuid,uuid,uuid,bigint,text) from public,anon,authenticated,service_role;
revoke all on function private.training_media_has_current_independent_approval(uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function private.enforce_active_training_program_structure() from public,anon,authenticated,service_role;
revoke all on function private.enforce_training_course_version_immutability() from public,anon,authenticated,service_role;
revoke all on function private.enforce_training_enrollment_published_version() from public,anon,authenticated,service_role;
revoke all on function public.validate_internal_admin_training_media_for_publish(uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.begin_internal_admin_training_storage_verification(uuid,uuid,uuid,uuid,uuid,bigint,text,uuid) from public,anon,authenticated,service_role;
revoke all on function public.complete_internal_admin_training_storage_verification(uuid,uuid,uuid,uuid,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.publish_internal_admin_training_course_version(uuid,uuid,uuid,uuid,uuid,uuid,bigint,text,uuid) from public,anon,authenticated,service_role;
revoke all on function public.retire_internal_admin_training_course_version(uuid,uuid,uuid,uuid,text,uuid) from public,anon,authenticated,service_role;
revoke all on function public.activate_internal_admin_restaurant_training_program(uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.retire_internal_admin_training_program(uuid,uuid,uuid,text,uuid) from public,anon,authenticated,service_role;
revoke all on function public.get_internal_admin_training_publication_readiness(uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function public.validate_internal_admin_training_media_for_publish(uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.begin_internal_admin_training_storage_verification(uuid,uuid,uuid,uuid,uuid,bigint,text,uuid) to service_role;
grant execute on function public.retire_internal_admin_training_course_version(uuid,uuid,uuid,uuid,text,uuid) to service_role;
grant execute on function public.activate_internal_admin_restaurant_training_program(uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.retire_internal_admin_training_program(uuid,uuid,uuid,text,uuid) to service_role;
grant execute on function public.get_internal_admin_training_publication_readiness(uuid,uuid,uuid,uuid) to service_role;

comment on table public.training_storage_verification_runs is
  'Short-lived one-use challenges binding backend byte verification to an exact approved publication fingerprint.';
comment on table public.training_storage_verification_items is
  'Immutable observed Storage byte hashes, sizes, and decoded dimensions for one verification challenge.';
comment on table public.training_publication_lifecycle_events is
  'Immutable publication, course/program retirement, and Restaurant Training activation audit history.';
comment on function public.complete_internal_admin_training_storage_verification(uuid,uuid,uuid,uuid,jsonb) is
  'Reserved for a future distinct trusted verifier. No application role has EXECUTE permission.';
comment on function public.publish_internal_admin_training_course_version(uuid,uuid,uuid,uuid,uuid,uuid,bigint,text,uuid) is
  'Fails closed at the privilege boundary until trusted private-Storage attestation is deployed.';
