-- Phase 3C: content-addressed published Training media in the existing
-- Supabase project. The ordinary service-role credential can bypass Storage
-- RLS; this migration deliberately provides application-level prevention and
-- cryptographic detection, not protection from a compromised service-role key.

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('training-published-media','training-published-media',false,5242880,array['image/webp'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

create policy training_verifier_published_object_read on storage.objects
for select to authenticated
using(bucket_id='training-published-media' and public.training_verifier_storage_claim_is_active());

create policy training_verifier_published_object_insert on storage.objects
for insert to authenticated
with check(
  bucket_id='training-published-media'
  and public.training_verifier_storage_claim_is_active()
  and name~'^sha256/[0-9a-f]{2}/[0-9a-f]{64}\.webp$'
  and substring(name from 8 for 2)=substring(name from 11 for 2)
);

alter table public.training_storage_verification_runs alter column expires_at
  set default (statement_timestamp()+interval '30 minutes');

alter table public.training_verifier_jobs drop constraint training_verifier_jobs_failure_check;
alter table public.training_verifier_jobs add constraint training_verifier_jobs_failure_check check(
  last_failure_code is null or last_failure_code in(
    'source_verification_rejected','source_verification_unavailable','destination_verification_rejected',
    'destination_verification_unavailable','verification_run_expired','publication_request_stale',
    'worker_lease_expired','retry_limit_exhausted','immutable_store_unconfigured'
  )
);
alter table public.training_verifier_events drop constraint training_verifier_events_type_check;
alter table public.training_verifier_events add constraint training_verifier_events_type_check check(event_type in(
  'queued','claimed','lease_renewed','lease_expired','retry_scheduled','terminal_failure',
  'source_verified_publication_blocked','published'
));
alter table public.training_verifier_events drop constraint training_verifier_events_failure_check;
alter table public.training_verifier_events add constraint training_verifier_events_failure_check check(
  failure_code is null or failure_code in(
    'source_verification_rejected','source_verification_unavailable','destination_verification_rejected',
    'destination_verification_unavailable','verification_run_expired','publication_request_stale',
    'worker_lease_expired','retry_limit_exhausted','immutable_store_unconfigured'
  )
);

create table private.training_published_media_configuration(
  singleton boolean primary key default true check(singleton),
  integrity_freshness_seconds integer not null default 86400
    check(integrity_freshness_seconds between 300 and 604800),
  integrity_retry_seconds integer not null default 900
    check(integrity_retry_seconds between 60 and 86400)
);
insert into private.training_published_media_configuration(singleton) values(true);
revoke all on table private.training_published_media_configuration from public,anon,authenticated,service_role;

create table public.training_publication_media_manifests(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  course_id uuid not null,
  course_version_id uuid not null,
  submission_id uuid not null,
  verification_run_id uuid not null references public.training_storage_verification_runs(id) on delete restrict,
  publication_request_id uuid not null references public.training_publication_requests(id) on delete restrict,
  version_revision bigint not null,
  content_fingerprint text not null,
  manifest_fingerprint text not null,
  storage_bucket text not null default 'training-published-media',
  object_count integer not null,
  verifier_capability_id uuid not null,
  completion_request_id uuid not null,
  requested_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default statement_timestamp(),
  constraint training_publication_media_manifests_id_scope_key
    unique(id,organization_id,course_id,course_version_id),
  constraint training_publication_media_manifests_version_key unique(course_version_id),
  constraint training_publication_media_manifests_request_key unique(publication_request_id),
  constraint training_publication_media_manifests_completion_key unique(completion_request_id),
  constraint training_publication_media_manifests_version_scope_fkey
    foreign key(course_version_id,organization_id)
    references public.training_course_versions(id,organization_id) on delete restrict,
  constraint training_publication_media_manifests_course_scope_fkey
    foreign key(course_id,organization_id)
    references public.training_courses(id,organization_id) on delete restrict,
  constraint training_publication_media_manifests_submission_scope_fkey
    foreign key(submission_id,organization_id,course_id,course_version_id)
    references public.training_publication_review_submissions(id,organization_id,course_id,course_version_id)
    on delete restrict,
  constraint training_publication_media_manifests_values_check check(
    version_revision>=0 and content_fingerprint~'^[0-9a-f]{64}$'
    and manifest_fingerprint~'^[0-9a-f]{64}$'
    and storage_bucket='training-published-media' and object_count=40
  )
);

create table public.training_publication_media_manifest_items(
  manifest_id uuid not null,
  organization_id uuid not null,
  course_id uuid not null,
  course_version_id uuid not null,
  media_id uuid not null,
  media_revision integer not null,
  module_id uuid not null,
  lesson_id uuid not null,
  module_position integer not null,
  lesson_position integer not null,
  slot_position integer not null,
  asset_key text not null,
  storage_bucket text not null default 'training-published-media',
  storage_object_path text not null,
  sha256 text not null,
  byte_size integer not null,
  width integer not null,
  height integer not null,
  mime_type text not null default 'image/webp',
  verified_at timestamptz not null default statement_timestamp(),
  primary key(manifest_id,asset_key),
  constraint training_publication_media_manifest_items_media_key unique(manifest_id,media_id),
  constraint training_publication_media_manifest_items_slot_key
    unique(manifest_id,module_position,lesson_position,slot_position),
  constraint training_publication_media_manifest_items_manifest_scope_fkey
    foreign key(manifest_id,organization_id,course_id,course_version_id)
    references public.training_publication_media_manifests(id,organization_id,course_id,course_version_id)
    on delete restrict,
  constraint training_publication_media_manifest_items_media_scope_fkey
    foreign key(media_id,course_version_id,organization_id)
    references public.training_media_assets(id,course_version_id,organization_id) on delete restrict,
  constraint training_publication_media_manifest_items_values_check check(
    media_revision>0 and module_position>0 and lesson_position>0 and slot_position>0
    and storage_bucket='training-published-media' and mime_type='image/webp'
    and sha256~'^[0-9a-f]{64}$' and byte_size>0 and byte_size<=5242880 and width>0 and height>0
    and storage_object_path='sha256/'||substring(sha256 from 1 for 2)||'/'||sha256||'.webp'
  )
);

create table public.training_published_media_integrity_runs(
  id uuid primary key default gen_random_uuid(),
  recorded_sequence bigint generated always as identity unique not null,
  manifest_id uuid not null references public.training_publication_media_manifests(id) on delete restrict,
  verifier_capability_id uuid not null,
  completion_request_id uuid not null unique,
  status text not null,
  failure_code text,
  checked_object_count integer not null,
  checked_at timestamptz not null default statement_timestamp(),
  constraint training_published_media_integrity_runs_values_check check(
    status in('passed','failed') and checked_object_count between 0 and 40
    and ((status='passed' and failure_code is null and checked_object_count=40)
      or (status='failed' and failure_code in('published_media_missing','published_media_mismatch','published_media_unavailable')))
  )
);

create index training_published_media_integrity_runs_latest_idx
  on public.training_published_media_integrity_runs(manifest_id,recorded_sequence desc);

create table public.training_published_media_integrity_items(
  integrity_run_id uuid not null references public.training_published_media_integrity_runs(id) on delete restrict,
  manifest_id uuid not null references public.training_publication_media_manifests(id) on delete restrict,
  media_id uuid not null,
  observed_sha256 text not null,
  observed_byte_size integer not null,
  observed_width integer not null,
  observed_height integer not null,
  checked_at timestamptz not null default statement_timestamp(),
  primary key(integrity_run_id,media_id),
  constraint training_published_media_integrity_items_values_check check(
    observed_sha256~'^[0-9a-f]{64}$' and observed_byte_size>0
    and observed_width>0 and observed_height>0
  )
);

create table private.training_published_media_integrity_jobs(
  manifest_id uuid primary key references public.training_publication_media_manifests(id) on delete restrict,
  next_due_at timestamptz not null,
  lease_token_sha256 bytea,
  lease_expires_at timestamptz,
  attempt_count integer not null default 0,
  updated_at timestamptz not null default statement_timestamp(),
  constraint training_published_media_integrity_jobs_lease_check check(
    (lease_token_sha256 is null and lease_expires_at is null)
    or (lease_token_sha256 is not null and octet_length(lease_token_sha256)=32 and lease_expires_at is not null)
  )
);

alter table public.training_course_versions
  add column publication_media_manifest_id uuid references public.training_publication_media_manifests(id) on delete restrict,
  add column publication_media_manifest_fingerprint text;
alter table public.training_course_versions add constraint training_course_versions_media_manifest_fingerprint_check
  check(publication_media_manifest_fingerprint is null or publication_media_manifest_fingerprint~'^[0-9a-f]{64}$');

alter table public.training_publication_media_manifests enable row level security;
alter table public.training_publication_media_manifest_items enable row level security;
alter table public.training_published_media_integrity_runs enable row level security;
alter table public.training_published_media_integrity_items enable row level security;
revoke all on table public.training_publication_media_manifests from public,anon,authenticated,service_role;
revoke all on table public.training_publication_media_manifest_items from public,anon,authenticated,service_role;
revoke all on table public.training_published_media_integrity_runs from public,anon,authenticated,service_role;
revoke all on table public.training_published_media_integrity_items from public,anon,authenticated,service_role;
revoke all on table private.training_published_media_integrity_jobs from public,anon,authenticated,service_role;

create trigger training_publication_media_manifests_immutability before update or delete
on public.training_publication_media_manifests for each row execute function private.reject_training_audit_mutation();
create trigger training_publication_media_manifest_items_immutability before update or delete
on public.training_publication_media_manifest_items for each row execute function private.reject_training_audit_mutation();
create trigger training_published_media_integrity_runs_immutability before update or delete
on public.training_published_media_integrity_runs for each row execute function private.reject_training_audit_mutation();
create trigger training_published_media_integrity_items_immutability before update or delete
on public.training_published_media_integrity_items for each row execute function private.reject_training_audit_mutation();

create or replace function private.training_published_media_manifest_fingerprint(
  target_organization_id uuid,target_course_id uuid,target_course_version_id uuid,
  target_revision bigint,target_content_fingerprint text,manifest_items jsonb
)
returns text language sql immutable security definer set search_path='' as $$
  select pg_catalog.encode(extensions.digest(pg_catalog.convert_to(
    'training-published-media-manifest-v1'||E'\n'||target_organization_id::text||E'\n'||
    target_course_id::text||E'\n'||target_course_version_id::text||E'\n'||target_revision::text||E'\n'||
    target_content_fingerprint||E'\n'||coalesce(string_agg(
      item.media_id::text||':'||item.media_revision::text||':'||item.sha256||':'||item.byte_size::text||':'||
      item.width::text||':'||item.height::text||':'||item.object_path,E'\n' order by item.media_id),'')
    ,'UTF8'),'sha256'),'hex')
  from jsonb_to_recordset(manifest_items) as item(
    media_id uuid,media_revision integer,sha256 text,byte_size integer,width integer,height integer,object_path text
  );
$$;

create or replace function private.enforce_training_publication_manifest_binding()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.publication_media_manifest_id is distinct from old.publication_media_manifest_id
    or new.publication_media_manifest_fingerprint is distinct from old.publication_media_manifest_fingerprint then
    if current_setting('app.training_manifest_binding',true) is distinct from 'phase3c-finalizer' then
      raise exception 'Training publication manifest binding is guarded' using errcode='55000';
    end if;
  end if;
  return new;
end;
$$;
create trigger training_course_versions_01_manifest_binding_guard before update
of publication_media_manifest_id,publication_media_manifest_fingerprint on public.training_course_versions
for each row execute function private.enforce_training_publication_manifest_binding();

create or replace function private.enforce_training_publication_manifest_gate()
returns trigger language plpgsql security definer set search_path='' as $$
declare manifest public.training_publication_media_manifests%rowtype;
begin
  if old.status='draft' and new.status='published' then
    select candidate.* into manifest from public.training_publication_media_manifests candidate
    where candidate.id=new.publication_media_manifest_id and candidate.organization_id=new.organization_id
      and candidate.course_id=new.course_id and candidate.course_version_id=new.id;
    if manifest.id is null or new.publication_media_manifest_fingerprint is distinct from manifest.manifest_fingerprint
      or new.publication_fingerprint is distinct from manifest.content_fingerprint
      or new.revision<>manifest.version_revision
      or (select count(*) from public.training_publication_media_manifest_items item where item.manifest_id=manifest.id)<>40
      or not exists(select 1 from public.training_published_media_integrity_runs audit
        where audit.manifest_id=manifest.id and audit.status='passed' and audit.checked_object_count=40)
    then raise exception 'Training publication media manifest is missing or invalid' using errcode='55000'; end if;
  end if;
  return new;
end;
$$;
create trigger training_course_versions_02_manifest_publication_gate before update of status
on public.training_course_versions for each row execute function private.enforce_training_publication_manifest_gate();

create or replace function public.renew_training_storage_verifier_job_lease(
  target_capability_id uuid,capability_secret text,expected_audience text,
  target_publication_request_id uuid,target_lease_token uuid,renewal_request_id uuid
)
returns table(lease_expires_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare request public.training_publication_requests%rowtype; run public.training_storage_verification_runs%rowtype;
  job public.training_verifier_jobs%rowtype; renewed_until timestamptz;
begin
  perform private.assert_training_verifier_capability(target_capability_id,capability_secret,expected_audience);
  select target.* into request from public.training_publication_requests target where target.id=target_publication_request_id;
  if request.id is null or request.audience<>expected_audience then raise exception 'Training verifier job not found' using errcode='P0002'; end if;
  perform private.lock_training_course_version(request.organization_id,request.course_version_id,'draft');
  select target.* into run from public.training_storage_verification_runs target where target.id=request.verification_run_id for update;
  select target.* into job from public.training_verifier_jobs target where target.publication_request_id=request.id for update;
  if job.state<>'leased' or statement_timestamp()>=job.lease_expires_at or statement_timestamp()>=run.expires_at
    or job.lease_token_sha256<>extensions.digest(pg_catalog.convert_to(target_lease_token::text,'UTF8'),'sha256')
    or renewal_request_id is null then raise exception 'Training verifier lease is invalid or stale' using errcode='55000'; end if;
  renewed_until:=least(run.expires_at,statement_timestamp()+interval '5 minutes');
  update public.training_verifier_jobs set lease_expires_at=renewed_until
    where publication_request_id=request.id;
  insert into public.training_verifier_events(publication_request_id,event_type,correlation_id,attempt_number,
    capability_id,details) values(request.id,'lease_renewed',renewal_request_id,job.attempt_count,target_capability_id,
    jsonb_build_object('lease_expires_at',renewed_until));
  return query select renewed_until;
exception when unique_violation then raise exception 'Training verifier lease renewal was already recorded' using errcode='55000';
end;
$$;

create or replace function public.fail_training_storage_verifier_job(
  target_capability_id uuid,capability_secret text,expected_audience text,
  target_publication_request_id uuid,target_lease_token uuid,failure_code text,
  retryable boolean,failure_request_id uuid
)
returns table(job_state text,attempt_count integer)
language plpgsql security definer set search_path='' as $$
declare request public.training_publication_requests%rowtype; run public.training_storage_verification_runs%rowtype;
  job public.training_verifier_jobs%rowtype; next_state text;
begin
  perform private.assert_training_verifier_capability(target_capability_id,capability_secret,expected_audience);
  select target.* into request from public.training_publication_requests target where target.id=target_publication_request_id;
  if request.id is null or request.audience<>expected_audience then raise exception 'Training verifier job not found' using errcode='P0002'; end if;
  perform private.lock_training_course_version(request.organization_id,request.course_version_id,'draft');
  select target.* into run from public.training_storage_verification_runs target where target.id=request.verification_run_id for update;
  select target.* into job from public.training_verifier_jobs target where target.publication_request_id=request.id for update;
  if job.state<>'leased' or statement_timestamp()>=job.lease_expires_at
    or job.lease_token_sha256<>extensions.digest(pg_catalog.convert_to(target_lease_token::text,'UTF8'),'sha256')
    or failure_code not in('source_verification_rejected','source_verification_unavailable',
      'destination_verification_rejected','destination_verification_unavailable')
    or failure_request_id is null then raise exception 'Training verifier lease is invalid or stale' using errcode='55000'; end if;
  next_state:=case when retryable and job.attempt_count<job.max_attempts and run.status='pending'
    and statement_timestamp()<run.expires_at then 'queued' else 'terminal_failed' end;
  update public.training_verifier_jobs set state=next_state,lease_token_sha256=null,lease_expires_at=null,
    available_at=case when next_state='queued' then statement_timestamp()+pg_catalog.make_interval(secs=>least(30,job.attempt_count*5)) else available_at end,
    last_failure_code=failure_code,completed_at=case when next_state='terminal_failed' then statement_timestamp() else null end
  where publication_request_id=request.id returning * into job;
  insert into public.training_verifier_events(publication_request_id,event_type,correlation_id,attempt_number,
    capability_id,failure_code) values(request.id,case when next_state='queued' then 'retry_scheduled' else 'terminal_failure' end,
    failure_request_id,job.attempt_count,target_capability_id,failure_code);
  return query select job.state,job.attempt_count;
exception when unique_violation then raise exception 'Training verifier failure was already recorded' using errcode='55000';
end;
$$;

create or replace function public.finalize_training_storage_verifier_publication(
  target_capability_id uuid,capability_secret text,expected_audience text,
  target_publication_request_id uuid,target_lease_token uuid,source_observed_objects jsonb,
  published_manifest_items jsonb,expected_manifest_fingerprint text,completion_request_id uuid
)
returns table(job_state text,manifest_id uuid,published_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare request public.training_publication_requests%rowtype; run public.training_storage_verification_runs%rowtype;
  job public.training_verifier_jobs%rowtype; version public.training_course_versions%rowtype;
  saved_manifest public.training_publication_media_manifests%rowtype; saved_version public.training_course_versions%rowtype;
  saved_audit_id uuid:=gen_random_uuid(); calculated_fingerprint text; item_count integer;
begin
  perform private.assert_training_verifier_capability(target_capability_id,capability_secret,expected_audience);
  select target.* into request from public.training_publication_requests target where target.id=target_publication_request_id;
  if request.id is null or request.audience<>expected_audience then raise exception 'Training verifier job not found' using errcode='P0002'; end if;
  version:=private.lock_training_course_version(request.organization_id,request.course_version_id,'draft');
  select target.* into run from public.training_storage_verification_runs target where target.id=request.verification_run_id for update;
  select target.* into job from public.training_verifier_jobs target where target.publication_request_id=request.id for update;
  if version.course_id<>request.course_id or run.id is null or run.status<>'pending'
    or run.organization_id<>request.organization_id or run.course_id<>request.course_id
    or run.course_version_id<>request.course_version_id or run.submission_id<>request.submission_id
    or run.requested_by<>request.requested_by or run.version_revision<>request.version_revision
    or run.content_fingerprint<>request.content_fingerprint or statement_timestamp()>=run.expires_at
    or job.state<>'leased' or statement_timestamp()>=job.lease_expires_at
    or job.lease_token_sha256<>extensions.digest(pg_catalog.convert_to(target_lease_token::text,'UTF8'),'sha256')
    or request.authorization_envelope->>'audience'<>expected_audience
    or request.authorization_envelope->>'actor_user_id'<>request.requested_by::text
    or request.authorization_envelope->>'organization_id'<>request.organization_id::text
    or request.authorization_envelope->>'course_id'<>request.course_id::text
    or request.authorization_envelope->>'course_version_id'<>request.course_version_id::text
    or request.authorization_envelope->>'submission_id'<>request.submission_id::text
    or request.authorization_envelope->>'verification_run_id'<>request.verification_run_id::text
    or request.authorization_envelope->>'challenge_nonce'<>run.challenge_nonce::text
    or request.authorization_envelope->>'expected_content_fingerprint'<>request.content_fingerprint
    or completion_request_id is null or expected_manifest_fingerprint!~'^[0-9a-f]{64}$'
  then raise exception 'Training verifier finalization is invalid or stale' using errcode='55000'; end if;
  if jsonb_typeof(source_observed_objects)<>'array' or jsonb_array_length(source_observed_objects)<>40
    or jsonb_typeof(published_manifest_items)<>'array' or jsonb_array_length(published_manifest_items)<>40
    or exists(select 1 from jsonb_array_elements(published_manifest_items) item
      where jsonb_typeof(item)<>'object' or (select count(*) from jsonb_object_keys(item))<>7)
  then raise exception 'Training publication manifest must contain exactly forty items' using errcode='55000'; end if;
  select count(*)::integer into item_count from jsonb_to_recordset(published_manifest_items) as item(
    media_id uuid,media_revision integer,sha256 text,byte_size integer,width integer,height integer,object_path text);
  if item_count<>40 or (select count(distinct media_id) from jsonb_to_recordset(published_manifest_items) as item(
      media_id uuid,media_revision integer,sha256 text,byte_size integer,width integer,height integer,object_path text))<>40
    or exists(
      select 1 from private.training_image_slot_requirements(request.organization_id,request.course_version_id) slot
      join public.training_media_assets asset on asset.organization_id=request.organization_id
        and asset.course_version_id=request.course_version_id and asset.asset_key=slot.asset_key
        and asset.status='ready' and asset.approval_status='approved'
      left join jsonb_to_recordset(published_manifest_items) as item(
        media_id uuid,media_revision integer,sha256 text,byte_size integer,width integer,height integer,object_path text)
        on item.media_id=asset.id
      where item.media_id is null or item.media_revision<>asset.revision or item.sha256<>asset.sha256
        or item.byte_size<>asset.byte_size or item.width<>asset.width or item.height<>asset.height
        or item.object_path<>'sha256/'||substring(item.sha256 from 1 for 2)||'/'||item.sha256||'.webp'
    )
    or exists(
      select 1 from jsonb_to_recordset(published_manifest_items) as item(
        media_id uuid,media_revision integer,sha256 text,byte_size integer,width integer,height integer,object_path text)
      left join storage.objects object on object.bucket_id='training-published-media' and object.name=item.object_path
      where object.id is null or coalesce(object.metadata->>'mimetype','')<>'image/webp'
        or coalesce(object.metadata->>'size','')!~'^[0-9]+$'
        or case when coalesce(object.metadata->>'size','')~'^[0-9]+$'
          then (object.metadata->>'size')::bigint<>item.byte_size else true end
    )
  then raise exception 'Training publication manifest evidence does not match' using errcode='55000'; end if;
  calculated_fingerprint:=private.training_published_media_manifest_fingerprint(request.organization_id,
    request.course_id,request.course_version_id,request.version_revision,request.content_fingerprint,published_manifest_items);
  if calculated_fingerprint is distinct from expected_manifest_fingerprint then
    raise exception 'Training publication manifest fingerprint does not match' using errcode='55000';
  end if;
  perform 1 from public.complete_internal_admin_training_storage_verification(request.requested_by,
    request.organization_id,run.id,run.challenge_nonce,source_observed_objects);
  insert into public.training_publication_media_manifests(organization_id,course_id,course_version_id,submission_id,
    verification_run_id,publication_request_id,version_revision,content_fingerprint,manifest_fingerprint,
    object_count,verifier_capability_id,completion_request_id,requested_by)
  values(request.organization_id,request.course_id,request.course_version_id,request.submission_id,run.id,request.id,
    request.version_revision,request.content_fingerprint,calculated_fingerprint,40,target_capability_id,
    completion_request_id,request.requested_by) returning * into saved_manifest;
  insert into public.training_publication_media_manifest_items(manifest_id,organization_id,course_id,course_version_id,
    media_id,media_revision,module_id,lesson_id,module_position,lesson_position,slot_position,asset_key,
    storage_object_path,sha256,byte_size,width,height)
  select saved_manifest.id,request.organization_id,request.course_id,request.course_version_id,asset.id,asset.revision,
    slot.module_id,slot.lesson_id,slot.module_position,slot.lesson_position,slot.slot_position,slot.asset_key,
    item.object_path,item.sha256,item.byte_size,item.width,item.height
  from private.training_image_slot_requirements(request.organization_id,request.course_version_id) slot
  join public.training_media_assets asset on asset.organization_id=request.organization_id
    and asset.course_version_id=request.course_version_id and asset.asset_key=slot.asset_key
  join jsonb_to_recordset(published_manifest_items) as item(
    media_id uuid,media_revision integer,sha256 text,byte_size integer,width integer,height integer,object_path text)
    on item.media_id=asset.id;
  insert into public.training_published_media_integrity_runs(id,manifest_id,verifier_capability_id,
    completion_request_id,status,checked_object_count)
  values(saved_audit_id,saved_manifest.id,target_capability_id,completion_request_id,'passed',40);
  insert into public.training_published_media_integrity_items(integrity_run_id,manifest_id,media_id,
    observed_sha256,observed_byte_size,observed_width,observed_height)
  select saved_audit_id,saved_manifest.id,item.media_id,item.sha256,item.byte_size,item.width,item.height
  from jsonb_to_recordset(published_manifest_items) as item(
    media_id uuid,media_revision integer,sha256 text,byte_size integer,width integer,height integer,object_path text);
  insert into private.training_published_media_integrity_jobs(manifest_id,next_due_at)
  select saved_manifest.id,statement_timestamp()+pg_catalog.make_interval(secs=>config.integrity_freshness_seconds)
  from private.training_published_media_configuration config where config.singleton;
  perform set_config('app.training_manifest_binding','phase3c-finalizer',true);
  update public.training_course_versions target set publication_media_manifest_id=saved_manifest.id,
    publication_media_manifest_fingerprint=calculated_fingerprint where target.id=request.course_version_id;
  select published.* into saved_version from public.publish_internal_admin_training_course_version(request.requested_by,
    request.organization_id,request.course_id,request.course_version_id,request.submission_id,run.id,
    request.version_revision,request.content_fingerprint,request.action_request_id) published;
  update public.training_verifier_jobs set state='published',lease_token_sha256=null,lease_expires_at=null,
    last_failure_code=null,completed_at=statement_timestamp() where publication_request_id=request.id;
  insert into public.training_verifier_events(publication_request_id,event_type,correlation_id,attempt_number,
    capability_id,details) values(request.id,'published',completion_request_id,job.attempt_count,target_capability_id,
    jsonb_build_object('manifest_id',saved_manifest.id,'manifest_fingerprint',calculated_fingerprint,'object_count',40));
  return query select 'published'::text,saved_manifest.id,saved_version.published_at;
exception when unique_violation then
  raise exception 'Training verifier publication finalization was already recorded' using errcode='55000';
end;
$$;

create or replace function public.claim_training_published_media_integrity_audit(
  target_capability_id uuid,capability_secret text,expected_audience text,
  worker_instance_id uuid,claim_request_id uuid
)
returns table(manifest_id uuid,lease_token uuid,lease_expires_at timestamptz,media_id uuid,
  expected_sha256 text,expected_byte_size integer,expected_width integer,expected_height integer,
  storage_bucket text,storage_object_path text)
language plpgsql security definer set search_path='' as $$
declare selected private.training_published_media_integrity_jobs%rowtype; raw_lease uuid;
begin
  perform private.assert_training_verifier_capability(target_capability_id,capability_secret,expected_audience);
  if worker_instance_id is null or claim_request_id is null then raise exception 'Invalid integrity audit claim' using errcode='22023'; end if;
  select job.* into selected from private.training_published_media_integrity_jobs job
  join public.training_publication_media_manifests manifest on manifest.id=job.manifest_id
  join public.training_course_versions version on version.id=manifest.course_version_id
  where job.next_due_at<=statement_timestamp()
    and (job.lease_expires_at is null or job.lease_expires_at<=statement_timestamp())
    and version.status='published' order by job.next_due_at,job.manifest_id for update of job skip locked limit 1;
  if selected.manifest_id is null then return; end if;
  raw_lease:=gen_random_uuid();
  update private.training_published_media_integrity_jobs set
    lease_token_sha256=extensions.digest(pg_catalog.convert_to(raw_lease::text,'UTF8'),'sha256'),
    lease_expires_at=statement_timestamp()+interval '10 minutes',attempt_count=attempt_count+1,
    updated_at=statement_timestamp() where training_published_media_integrity_jobs.manifest_id=selected.manifest_id
    returning training_published_media_integrity_jobs.lease_expires_at into selected.lease_expires_at;
  return query select item.manifest_id,raw_lease,selected.lease_expires_at,item.media_id,item.sha256,
    item.byte_size,item.width,item.height,item.storage_bucket,item.storage_object_path
  from public.training_publication_media_manifest_items item where item.manifest_id=selected.manifest_id
  order by item.module_position,item.lesson_position,item.slot_position;
end;
$$;

create or replace function public.complete_training_published_media_integrity_audit(
  target_capability_id uuid,capability_secret text,expected_audience text,target_manifest_id uuid,
  target_lease_token uuid,audit_status text,observed_objects jsonb,failure_code text,completion_request_id uuid
)
returns table(integrity_run_id uuid,status text,checked_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare job private.training_published_media_integrity_jobs%rowtype; saved public.training_published_media_integrity_runs%rowtype;
  observed_count integer; next_seconds integer;
begin
  perform private.assert_training_verifier_capability(target_capability_id,capability_secret,expected_audience);
  select target.* into job from private.training_published_media_integrity_jobs target
    where target.manifest_id=target_manifest_id for update;
  if job.manifest_id is null or job.lease_expires_at is null or statement_timestamp()>=job.lease_expires_at
    or job.lease_token_sha256<>extensions.digest(pg_catalog.convert_to(target_lease_token::text,'UTF8'),'sha256')
    or audit_status not in('passed','failed') or jsonb_typeof(observed_objects)<>'array' or completion_request_id is null
    or (audit_status='passed' and failure_code is not null)
    or (audit_status='failed' and failure_code not in('published_media_missing','published_media_mismatch','published_media_unavailable'))
  then raise exception 'Training published media integrity completion is invalid or stale' using errcode='55000'; end if;
  select count(*)::integer into observed_count from jsonb_to_recordset(observed_objects)
    as observed(media_id uuid,sha256 text,byte_size integer,width integer,height integer);
  if observed_count>40 or (audit_status='passed' and (observed_count<>40
    or (select count(distinct media_id) from jsonb_to_recordset(observed_objects)
      as observed(media_id uuid,sha256 text,byte_size integer,width integer,height integer))<>40
    or exists(select 1 from public.training_publication_media_manifest_items item
      left join jsonb_to_recordset(observed_objects) as observed(
        media_id uuid,sha256 text,byte_size integer,width integer,height integer) on observed.media_id=item.media_id
      where item.manifest_id=target_manifest_id and (observed.media_id is null or observed.sha256<>item.sha256
        or observed.byte_size<>item.byte_size or observed.width<>item.width or observed.height<>item.height))))
  then raise exception 'Training published media integrity evidence does not match' using errcode='55000'; end if;
  insert into public.training_published_media_integrity_runs(manifest_id,verifier_capability_id,completion_request_id,
    status,failure_code,checked_object_count) values(target_manifest_id,target_capability_id,completion_request_id,
    audit_status,failure_code,observed_count) returning * into saved;
  insert into public.training_published_media_integrity_items(integrity_run_id,manifest_id,media_id,
    observed_sha256,observed_byte_size,observed_width,observed_height)
  select saved.id,target_manifest_id,observed.media_id,observed.sha256,observed.byte_size,observed.width,observed.height
  from jsonb_to_recordset(observed_objects) as observed(
    media_id uuid,sha256 text,byte_size integer,width integer,height integer);
  select case when audit_status='passed' then config.integrity_freshness_seconds else config.integrity_retry_seconds end
    into next_seconds from private.training_published_media_configuration config where config.singleton;
  update private.training_published_media_integrity_jobs set lease_token_sha256=null,lease_expires_at=null,
    next_due_at=statement_timestamp()+pg_catalog.make_interval(secs=>next_seconds),updated_at=statement_timestamp()
    where manifest_id=target_manifest_id;
  return query select saved.id,saved.status,saved.checked_at;
exception when unique_violation then raise exception 'Training integrity completion was already recorded' using errcode='55000';
end;
$$;

create or replace function public.authorize_training_published_media_read(
  target_organization_id uuid,target_branch_id uuid,target_employee_id uuid,
  target_enrollment_id uuid,target_media_id uuid
)
returns table(storage_bucket text,storage_object_path text,mime_type text,sha256 text,integrity_checked_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
declare enrollment public.training_enrollments%rowtype;
begin
  enrollment:=private.assert_training_progress_enrollment(target_organization_id,target_branch_id,
    target_employee_id,target_enrollment_id);
  return query
  select item.storage_bucket,item.storage_object_path,item.mime_type,item.sha256,latest.checked_at
  from public.training_course_versions version
  join public.training_publication_media_manifests manifest on manifest.id=version.publication_media_manifest_id
    and manifest.organization_id=version.organization_id and manifest.course_version_id=version.id
  join public.training_publication_media_manifest_items item on item.manifest_id=manifest.id
    and item.organization_id=manifest.organization_id and item.course_version_id=manifest.course_version_id
  cross join private.training_published_media_configuration config
  join lateral(select audit.status,audit.checked_at,audit.id from public.training_published_media_integrity_runs audit
    where audit.manifest_id=manifest.id order by audit.recorded_sequence desc limit 1) latest on true
  where version.id=enrollment.course_version_id and version.organization_id=enrollment.organization_id
    and item.media_id=target_media_id and item.storage_bucket='training-published-media'
    and latest.status='passed'
    and latest.checked_at>=statement_timestamp()-pg_catalog.make_interval(secs=>config.integrity_freshness_seconds)
    and (select count(*) from public.training_published_media_integrity_items evidence
      where evidence.integrity_run_id=latest.id and evidence.manifest_id=manifest.id)=40;
end;
$$;

revoke all on function private.training_published_media_manifest_fingerprint(uuid,uuid,uuid,bigint,text,jsonb) from public,anon,authenticated,service_role;
revoke all on function private.enforce_training_publication_manifest_binding() from public,anon,authenticated,service_role;
revoke all on function private.enforce_training_publication_manifest_gate() from public,anon,authenticated,service_role;
revoke all on function public.renew_training_storage_verifier_job_lease(uuid,text,text,uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.finalize_training_storage_verifier_publication(uuid,text,text,uuid,uuid,jsonb,jsonb,text,uuid) from public,anon,authenticated,service_role;
revoke all on function public.claim_training_published_media_integrity_audit(uuid,text,text,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.complete_training_published_media_integrity_audit(uuid,text,text,uuid,uuid,text,jsonb,text,uuid) from public,anon,authenticated,service_role;
revoke all on function public.authorize_training_published_media_read(uuid,uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;

grant execute on function public.renew_training_storage_verifier_job_lease(uuid,text,text,uuid,uuid,uuid) to anon;
grant execute on function public.finalize_training_storage_verifier_publication(uuid,text,text,uuid,uuid,jsonb,jsonb,text,uuid) to anon;
grant execute on function public.claim_training_published_media_integrity_audit(uuid,text,text,uuid,uuid) to anon;
grant execute on function public.complete_training_published_media_integrity_audit(uuid,text,text,uuid,uuid,text,jsonb,text,uuid) to anon;
grant execute on function public.authorize_training_published_media_read(uuid,uuid,uuid,uuid,uuid) to service_role;

-- Preserve Phase 3A's fail-closed boundary: neither completion nor publication
-- is granted to an application role. They are invoked only inside the guarded
-- verifier finalizer transaction.
revoke all on function public.complete_internal_admin_training_storage_verification(uuid,uuid,uuid,uuid,jsonb)
  from public,anon,authenticated,service_role;
revoke all on function public.publish_internal_admin_training_course_version(uuid,uuid,uuid,uuid,uuid,uuid,bigint,text,uuid)
  from public,anon,authenticated,service_role;

comment on table public.training_publication_media_manifests is
  'Immutable content-addressed published-media manifest. Same-project service-role Storage bypass remains an accepted limitation.';
comment on function public.authorize_training_published_media_read(uuid,uuid,uuid,uuid,uuid) is
  'Authorizes only fresh integrity-checked published manifest media for the validated employee enrollment; never falls back to draft media.';
