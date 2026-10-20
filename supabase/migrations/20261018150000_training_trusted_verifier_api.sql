-- Phase 3B: authenticated publication orchestration and a least-privilege
-- verifier capability broker. No PostgreSQL LOGIN or database/service-role
-- credential is issued to the worker. Publication remains fail-closed until an
-- independently immutable publication object store is integrated.

create table private.training_verifier_capabilities (
  id uuid primary key,
  secret_sha256 bytea not null,
  audience text not null,
  active boolean not null default true,
  expires_at timestamptz not null,
  created_at timestamptz not null default statement_timestamp(),
  constraint training_verifier_capabilities_hash_check check(octet_length(secret_sha256)=32),
  constraint training_verifier_capabilities_audience_check
    check(audience~'^[a-z0-9][a-z0-9._:/-]{2,127}$'),
  constraint training_verifier_capabilities_expiry_check check(expires_at>created_at)
);
revoke all on table private.training_verifier_capabilities from public,anon,authenticated,service_role;

create or replace function public.training_verifier_storage_claim_is_active()
returns boolean language plpgsql stable security definer set search_path='' as $$
declare capability_id uuid; claim_audience text;
begin
  if auth.jwt()->>'training_storage_verifier'<>'true'
    or auth.jwt()->>'training_verifier_capability_id' is null then return false; end if;
  capability_id:=(auth.jwt()->>'training_verifier_capability_id')::uuid;
  claim_audience:=auth.jwt()->>'training_verifier_audience';
  return exists(select 1 from private.training_verifier_capabilities capability
    where capability.id=capability_id and capability.audience=claim_audience
      and capability.active and statement_timestamp()<capability.expires_at);
exception when invalid_text_representation then return false;
end;
$$;
revoke all on function public.training_verifier_storage_claim_is_active() from public,anon,authenticated,service_role;
grant execute on function public.training_verifier_storage_claim_is_active() to authenticated;

-- The worker's independently provisioned, short-lived JWT receives read-only
-- access to the mutable review bucket. It has no INSERT/UPDATE/DELETE policy and
-- carries neither a Supabase service key nor JWT signing material.
create policy training_verifier_source_object_read on storage.objects
for select to authenticated
using (
  bucket_id='training-media'
  and public.training_verifier_storage_claim_is_active()
);

create table public.training_publication_requests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  course_id uuid not null,
  course_version_id uuid not null,
  submission_id uuid not null,
  verification_run_id uuid not null,
  version_revision bigint not null,
  content_fingerprint text not null,
  requested_by uuid not null references auth.users(id) on delete restrict,
  action_request_id uuid not null,
  protocol_version integer not null,
  audience text not null,
  signing_key_id text not null,
  authorization_envelope jsonb not null,
  authorization_signature text not null,
  requested_at timestamptz not null default statement_timestamp(),
  constraint training_publication_requests_version_scope_fkey foreign key(course_version_id,organization_id)
    references public.training_course_versions(id,organization_id) on delete restrict,
  constraint training_publication_requests_course_scope_fkey foreign key(course_id,organization_id)
    references public.training_courses(id,organization_id) on delete restrict,
  constraint training_publication_requests_submission_scope_fkey
    foreign key(submission_id,organization_id,course_id,course_version_id)
    references public.training_publication_review_submissions(id,organization_id,course_id,course_version_id) on delete restrict,
  constraint training_publication_requests_verification_run_fkey foreign key(verification_run_id)
    references public.training_storage_verification_runs(id) on delete restrict,
  constraint training_publication_requests_action_key unique(organization_id,action_request_id),
  constraint training_publication_requests_run_key unique(verification_run_id),
  constraint training_publication_requests_revision_check check(version_revision>=0),
  constraint training_publication_requests_fingerprint_check check(content_fingerprint~'^[0-9a-f]{64}$'),
  constraint training_publication_requests_protocol_check check(protocol_version=1),
  constraint training_publication_requests_audience_check check(audience~'^[a-z0-9][a-z0-9._:/-]{2,127}$'),
  constraint training_publication_requests_key_check check(signing_key_id~'^[A-Za-z0-9._-]{1,64}$'),
  constraint training_publication_requests_signature_check
    check(length(authorization_signature)=88 and authorization_signature~'^[A-Za-z0-9+/]{86}==$')
);

create table public.training_verifier_jobs (
  publication_request_id uuid primary key references public.training_publication_requests(id) on delete restrict,
  state text not null default 'queued',
  attempt_count integer not null default 0,
  max_attempts integer not null default 3,
  available_at timestamptz not null default statement_timestamp(),
  lease_token_sha256 bytea,
  lease_expires_at timestamptz,
  last_failure_code text,
  completed_at timestamptz,
  constraint training_verifier_jobs_state_check check(state in('queued','leased','terminal_failed','publication_blocked','published')),
  constraint training_verifier_jobs_attempts_check check(attempt_count>=0 and max_attempts between 1 and 5 and attempt_count<=max_attempts),
  constraint training_verifier_jobs_lease_check check(
    (state='leased' and lease_token_sha256 is not null and octet_length(lease_token_sha256)=32 and lease_expires_at is not null and completed_at is null)
    or (state<>'leased' and lease_token_sha256 is null and lease_expires_at is null)
  ),
  constraint training_verifier_jobs_completion_check check(
    (state in('terminal_failed','publication_blocked','published'))=(completed_at is not null)
  ),
  constraint training_verifier_jobs_failure_check check(last_failure_code is null or last_failure_code in(
    'source_verification_rejected','source_verification_unavailable','verification_run_expired',
    'publication_request_stale','worker_lease_expired','retry_limit_exhausted','immutable_store_unconfigured'
  ))
);

create table public.training_verifier_events (
  id uuid primary key default gen_random_uuid(),
  publication_request_id uuid not null references public.training_publication_requests(id) on delete restrict,
  event_type text not null,
  correlation_id uuid not null,
  attempt_number integer not null,
  capability_id uuid,
  failure_code text,
  details jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default statement_timestamp(),
  constraint training_verifier_events_type_check check(event_type in(
    'queued','claimed','lease_expired','retry_scheduled','terminal_failure','source_verified_publication_blocked','published'
  )),
  constraint training_verifier_events_attempt_check check(attempt_number>=0),
  constraint training_verifier_events_failure_check check(failure_code is null or failure_code in(
    'source_verification_rejected','source_verification_unavailable','verification_run_expired',
    'publication_request_stale','worker_lease_expired','retry_limit_exhausted','immutable_store_unconfigured'
  )),
  constraint training_verifier_events_details_check check(jsonb_typeof(details)='object'),
  constraint training_verifier_events_replay_key unique(publication_request_id,event_type,correlation_id)
);

create table private.training_verifier_source_observations (
  publication_request_id uuid not null references public.training_publication_requests(id) on delete restrict,
  media_id uuid not null,
  media_revision integer not null,
  storage_bucket text not null,
  storage_object_path text not null,
  observed_sha256 text not null,
  observed_byte_size integer not null,
  observed_width integer not null,
  observed_height integer not null,
  observed_at timestamptz not null default statement_timestamp(),
  primary key(publication_request_id,media_id),
  constraint training_verifier_source_observations_sha_check check(observed_sha256~'^[0-9a-f]{64}$'),
  constraint training_verifier_source_observations_values_check check(
    media_revision>0 and storage_bucket='training-media' and observed_byte_size>0 and observed_width>0 and observed_height>0
  )
);

create index training_verifier_jobs_poll_idx on public.training_verifier_jobs(available_at,publication_request_id)
  where state in('queued','leased');
create index training_verifier_events_request_idx on public.training_verifier_events(publication_request_id,occurred_at,id);

alter table public.training_publication_requests enable row level security;
alter table public.training_verifier_jobs enable row level security;
alter table public.training_verifier_events enable row level security;
revoke all on table public.training_publication_requests from public,anon,authenticated,service_role;
revoke all on table public.training_verifier_jobs from public,anon,authenticated,service_role;
revoke all on table public.training_verifier_events from public,anon,authenticated,service_role;
revoke all on table private.training_verifier_source_observations from public,anon,authenticated,service_role;

create trigger training_publication_requests_immutability before update or delete on public.training_publication_requests
for each row execute function private.reject_training_audit_mutation();
create trigger training_verifier_events_immutability before update or delete on public.training_verifier_events
for each row execute function private.reject_training_audit_mutation();
create trigger training_verifier_source_observations_immutability before update or delete on private.training_verifier_source_observations
for each row execute function private.reject_training_audit_mutation();

create or replace function private.assert_training_verifier_capability(
  target_capability_id uuid,capability_secret text,expected_audience text
)
returns void language plpgsql stable security definer set search_path='' as $$
begin
  if target_capability_id is null or capability_secret is null or length(capability_secret)<43
    or length(capability_secret)>256 or expected_audience is null
    or not exists(
      select 1 from private.training_verifier_capabilities capability
      where capability.id=target_capability_id and capability.active
        and statement_timestamp()<capability.expires_at and capability.audience=expected_audience
        and capability.secret_sha256=extensions.digest(pg_catalog.convert_to(capability_secret,'UTF8'),'sha256')
    ) then
    raise exception 'Training verifier access denied' using errcode='42501';
  end if;
end;
$$;
revoke all on function private.assert_training_verifier_capability(uuid,text,text) from public,anon,authenticated,service_role;

create or replace function public.get_internal_admin_training_publication_history(
  actor_user_id uuid,target_organization_id uuid,target_course_id uuid,target_course_version_id uuid
)
returns table(event_id uuid,event_kind text,event_type text,review_type text,locale text,
  decision text,actor_id uuid,reason text,action_request_id uuid,occurred_at timestamptz,
  version_revision bigint,content_fingerprint text,details jsonb)
language plpgsql stable security definer set search_path='' as $$
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'Training publication access denied' using errcode='42501';
  end if;
  if not exists(select 1 from public.training_course_versions version where version.id=target_course_version_id
    and version.organization_id=target_organization_id and version.course_id=target_course_id) then
    raise exception 'Training course version not found' using errcode='P0002';
  end if;
  return query select history.* from (
    select submission.id,'submission'::text,'submitted'::text,null::text,null::text,null::text,
      submission.submitted_by,null::text,submission.action_request_id,submission.submitted_at,
      submission.version_revision,submission.content_fingerprint,jsonb_build_object('submission_id',submission.id)
    from public.training_publication_review_submissions submission where submission.organization_id=target_organization_id
      and submission.course_id=target_course_id and submission.course_version_id=target_course_version_id
    union all
    select event.id,'review','review_decision',event.review_type,event.locale,event.decision,event.actor_user_id,
      event.reason,event.action_request_id,event.occurred_at,event.version_revision,event.content_fingerprint,
      jsonb_build_object('submission_id',event.submission_id)
    from public.training_publication_review_events event where event.organization_id=target_organization_id
      and event.course_id=target_course_id and event.course_version_id=target_course_version_id
    union all
    select event.id,'media_review','media_review',null,null,event.decision,event.actor_user_id,event.reason,
      event.action_request_id,event.occurred_at,null::bigint,event.media_fingerprint,
      jsonb_build_object('media_id',event.media_id,'media_revision',event.media_revision)
    from public.training_media_review_events event where event.organization_id=target_organization_id
      and event.course_id=target_course_id and event.course_version_id=target_course_version_id
    union all
    select event.id,'lifecycle',event.event_type,null,null,null,event.actor_user_id,event.details->>'reason',
      event.action_request_id,event.occurred_at,event.version_revision,event.content_fingerprint,event.details
    from public.training_publication_lifecycle_events event where event.organization_id=target_organization_id
      and event.course_id=target_course_id and event.course_version_id=target_course_version_id
    union all
    select event.id,'verifier',event.event_type,null,null,null,request.requested_by,event.failure_code,
      request.action_request_id,event.occurred_at,request.version_revision,request.content_fingerprint,
      event.details||jsonb_build_object('attempt_number',event.attempt_number)
    from public.training_verifier_events event join public.training_publication_requests request
      on request.id=event.publication_request_id where request.organization_id=target_organization_id
      and request.course_id=target_course_id and request.course_version_id=target_course_version_id
  ) history(event_id,event_kind,event_type,review_type,locale,decision,actor_id,reason,action_request_id,
    occurred_at,version_revision,content_fingerprint,details)
  order by history.occurred_at,history.event_id;
end;
$$;

create or replace function public.get_internal_admin_training_publication_signing_context(
  actor_user_id uuid,target_organization_id uuid,target_course_id uuid,target_course_version_id uuid,
  target_submission_id uuid,target_verification_run_id uuid,expected_revision bigint,
  expected_content_fingerprint text
)
returns table(challenge_nonce uuid,issued_at_epoch_seconds bigint,expires_at_epoch_seconds bigint)
language plpgsql security definer set search_path='' as $$
declare version public.training_course_versions%rowtype; run public.training_storage_verification_runs%rowtype;
begin
  version:=private.assert_internal_admin_training_draft(actor_user_id,target_organization_id,target_course_id,target_course_version_id);
  version:=private.lock_training_course_version(target_organization_id,target_course_version_id,'draft');
  select candidate.* into run from public.training_storage_verification_runs candidate
  where candidate.id=target_verification_run_id and candidate.organization_id=target_organization_id
    and candidate.course_id=target_course_id and candidate.course_version_id=target_course_version_id
    and candidate.submission_id=target_submission_id for update;
  if run.id is null or run.requested_by<>actor_user_id or run.status<>'pending'
    or run.version_revision<>expected_revision or run.content_fingerprint<>expected_content_fingerprint
    or statement_timestamp()>=run.expires_at or version.revision<>expected_revision
    or private.training_publication_content_fingerprint(target_organization_id,target_course_id,target_course_version_id)
      is distinct from expected_content_fingerprint
    or not private.training_submission_is_publishable(target_submission_id,target_organization_id,target_course_id,
      target_course_version_id,expected_revision,expected_content_fingerprint) then
    raise exception 'Training storage verification is missing, stale, or invalid' using errcode='55000';
  end if;
  return query select run.challenge_nonce,extract(epoch from statement_timestamp())::bigint,
    extract(epoch from run.expires_at)::bigint;
end;
$$;

create or replace function public.request_internal_admin_training_publication(
  actor_user_id uuid,target_organization_id uuid,target_course_id uuid,target_course_version_id uuid,
  target_submission_id uuid,target_verification_run_id uuid,expected_revision bigint,
  expected_content_fingerprint text,action_request_id uuid,signed_authorization_envelope jsonb,
  authorization_signature text
)
returns table(publication_request_id uuid,verification_run_id uuid,requested_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare version public.training_course_versions%rowtype; run public.training_storage_verification_runs%rowtype;
  saved public.training_publication_requests%rowtype; issued_epoch bigint; expires_epoch bigint; expected_envelope jsonb;
begin
  version:=private.assert_internal_admin_training_draft(actor_user_id,target_organization_id,target_course_id,target_course_version_id);
  version:=private.lock_training_course_version(target_organization_id,target_course_version_id,'draft');
  if version.course_id<>target_course_id or version.revision<>expected_revision
    or private.training_publication_content_fingerprint(target_organization_id,target_course_id,target_course_version_id)
      is distinct from expected_content_fingerprint
    or not private.training_submission_is_publishable(target_submission_id,target_organization_id,target_course_id,
      target_course_version_id,expected_revision,expected_content_fingerprint) then
    raise exception 'Training publication approval is missing or stale' using errcode='55000';
  end if;
  select candidate.* into run from public.training_storage_verification_runs candidate
  where candidate.id=target_verification_run_id and candidate.organization_id=target_organization_id
    and candidate.course_id=target_course_id and candidate.course_version_id=target_course_version_id
    and candidate.submission_id=target_submission_id for update;
  issued_epoch:=(signed_authorization_envelope->>'issued_at_epoch_seconds')::bigint;
  expires_epoch:=(signed_authorization_envelope->>'expires_at_epoch_seconds')::bigint;
  expected_envelope:=jsonb_build_object(
    'protocol_version',1,'audience',signed_authorization_envelope->>'audience',
    'key_id',signed_authorization_envelope->>'key_id','actor_user_id',actor_user_id,
    'organization_id',target_organization_id,'course_id',target_course_id,
    'course_version_id',target_course_version_id,'submission_id',target_submission_id,
    'verification_run_id',target_verification_run_id,'challenge_nonce',run.challenge_nonce,
    'issued_at_epoch_seconds',issued_epoch,'expires_at_epoch_seconds',expires_epoch,
    'expected_revision',expected_revision,'expected_content_fingerprint',expected_content_fingerprint,
    'action_request_id',action_request_id
  );
  if run.id is null or run.requested_by<>actor_user_id or run.status<>'pending'
    or run.version_revision<>expected_revision or run.content_fingerprint<>expected_content_fingerprint
    or statement_timestamp()>=run.expires_at or action_request_id is null
    or jsonb_typeof(signed_authorization_envelope)<>'object'
    or signed_authorization_envelope is distinct from expected_envelope
    or signed_authorization_envelope->>'audience'!~'^[a-z0-9][a-z0-9._:/-]{2,127}$'
    or signed_authorization_envelope->>'key_id'!~'^[A-Za-z0-9._-]{1,64}$'
    or issued_epoch<extract(epoch from statement_timestamp()-interval '60 seconds')::bigint
    or issued_epoch>extract(epoch from statement_timestamp()+interval '15 seconds')::bigint
    or expires_epoch<>extract(epoch from run.expires_at)::bigint or expires_epoch<=issued_epoch
    or authorization_signature is null or authorization_signature!~'^[A-Za-z0-9+/]{86}==$' then
    raise exception 'Invalid Training publication request' using errcode='22023';
  end if;
  insert into public.training_publication_requests(organization_id,course_id,course_version_id,submission_id,
    verification_run_id,version_revision,content_fingerprint,requested_by,action_request_id,protocol_version,
    audience,signing_key_id,authorization_envelope,authorization_signature)
  values(target_organization_id,target_course_id,target_course_version_id,target_submission_id,
    target_verification_run_id,expected_revision,expected_content_fingerprint,actor_user_id,action_request_id,1,
    signed_authorization_envelope->>'audience',signed_authorization_envelope->>'key_id',
    signed_authorization_envelope,authorization_signature) returning * into saved;
  insert into public.training_verifier_jobs(publication_request_id) values(saved.id);
  insert into public.training_verifier_events(publication_request_id,event_type,correlation_id,attempt_number,details)
  values(saved.id,'queued',action_request_id,0,jsonb_build_object('protocol_version',1,'audience',saved.audience,'key_id',saved.signing_key_id));
  return query select saved.id,saved.verification_run_id,saved.requested_at;
exception when unique_violation then
  raise exception 'Training publication request was already recorded' using errcode='55000';
when invalid_text_representation or numeric_value_out_of_range then
  raise exception 'Invalid Training publication request' using errcode='22023';
end;
$$;

create or replace function public.claim_training_storage_verifier_job(
  target_capability_id uuid,capability_secret text,expected_audience text,
  worker_instance_id uuid,claim_request_id uuid
)
returns table(publication_request_id uuid,lease_token uuid,lease_expires_at timestamptz,
  authorization_envelope jsonb,authorization_signature text,media_id uuid,media_revision integer,
  storage_bucket text,storage_object_path text,expected_sha256 text,expected_byte_size integer,
  expected_width integer,expected_height integer)
language plpgsql security definer set search_path='' as $$
declare candidate record; run public.training_storage_verification_runs%rowtype;
  job public.training_verifier_jobs%rowtype; raw_lease uuid;
begin
  perform private.assert_training_verifier_capability(target_capability_id,capability_secret,expected_audience);
  if worker_instance_id is null or claim_request_id is null then raise exception 'Invalid verifier claim' using errcode='22023'; end if;
  for candidate in
    select request.id,request.organization_id,request.course_id,request.course_version_id,
      request.verification_run_id,request.version_revision,request.content_fingerprint
    from public.training_publication_requests request join public.training_verifier_jobs pending
      on pending.publication_request_id=request.id
    where request.audience=expected_audience and pending.available_at<=statement_timestamp()
      and (pending.state='queued' or (pending.state='leased' and pending.lease_expires_at<=statement_timestamp()))
    order by pending.available_at,request.requested_at,request.id limit 10
  loop
    perform private.lock_training_course_version(candidate.organization_id,candidate.course_version_id,'draft');
    select target.* into run from public.training_storage_verification_runs target
      where target.id=candidate.verification_run_id for update;
    select target.* into job from public.training_verifier_jobs target
      where target.publication_request_id=candidate.id for update;
    if run.status<>'pending' or statement_timestamp()>=run.expires_at then
      update public.training_verifier_jobs set state='terminal_failed',lease_token_sha256=null,
        lease_expires_at=null,last_failure_code='verification_run_expired',completed_at=statement_timestamp()
      where training_verifier_jobs.publication_request_id=candidate.id;
      insert into public.training_verifier_events(publication_request_id,event_type,correlation_id,attempt_number,
        capability_id,failure_code) values(candidate.id,'terminal_failure',claim_request_id,job.attempt_count,
        target_capability_id,'verification_run_expired');
      continue;
    end if;
    if run.organization_id<>candidate.organization_id or run.course_version_id<>candidate.course_version_id
      or run.version_revision<>candidate.version_revision or run.content_fingerprint<>candidate.content_fingerprint
      or private.training_publication_content_fingerprint(
        candidate.organization_id,candidate.course_id,candidate.course_version_id
      ) is distinct from run.content_fingerprint then
      update public.training_verifier_jobs set state='terminal_failed',lease_token_sha256=null,
        lease_expires_at=null,last_failure_code='publication_request_stale',completed_at=statement_timestamp()
      where training_verifier_jobs.publication_request_id=candidate.id;
      insert into public.training_verifier_events(publication_request_id,event_type,correlation_id,attempt_number,
        capability_id,failure_code) values(candidate.id,'terminal_failure',claim_request_id,job.attempt_count,
        target_capability_id,'publication_request_stale');
      continue;
    end if;
    if not(job.state='queued' or (job.state='leased' and job.lease_expires_at<=statement_timestamp())) then continue; end if;
    if job.state='leased' then
      insert into public.training_verifier_events(publication_request_id,event_type,correlation_id,attempt_number,
        capability_id,failure_code) values(candidate.id,'lease_expired',claim_request_id,job.attempt_count,
        target_capability_id,'worker_lease_expired');
    end if;
    if job.attempt_count>=job.max_attempts then
      update public.training_verifier_jobs set state='terminal_failed',lease_token_sha256=null,
        lease_expires_at=null,last_failure_code='retry_limit_exhausted',completed_at=statement_timestamp()
      where training_verifier_jobs.publication_request_id=candidate.id;
      insert into public.training_verifier_events(publication_request_id,event_type,correlation_id,attempt_number,
        capability_id,failure_code) values(candidate.id,'terminal_failure',claim_request_id,job.attempt_count,
        target_capability_id,'retry_limit_exhausted');
      continue;
    end if;
    raw_lease:=gen_random_uuid();
    update public.training_verifier_jobs set state='leased',attempt_count=job.attempt_count+1,
      lease_token_sha256=extensions.digest(pg_catalog.convert_to(raw_lease::text,'UTF8'),'sha256'),
      lease_expires_at=statement_timestamp()+interval '3 minutes',last_failure_code=null
    where training_verifier_jobs.publication_request_id=candidate.id returning * into job;
    insert into public.training_verifier_events(publication_request_id,event_type,correlation_id,attempt_number,
      capability_id,details) values(candidate.id,'claimed',claim_request_id,job.attempt_count,target_capability_id,
      jsonb_build_object('worker_instance_id',worker_instance_id,'lease_expires_at',job.lease_expires_at));
    return query select request.id,raw_lease,job.lease_expires_at,request.authorization_envelope,
      request.authorization_signature,asset.id,asset.revision,asset.storage_bucket,asset.storage_object_path,
      asset.sha256,asset.byte_size,asset.width,asset.height
    from public.training_publication_requests request
    join private.training_image_slot_requirements(request.organization_id,request.course_version_id) slot on true
    join public.training_media_assets asset on asset.organization_id=request.organization_id
      and asset.course_version_id=request.course_version_id and asset.asset_key=slot.asset_key and asset.status='ready'
    where request.id=candidate.id order by slot.module_position,slot.lesson_position,slot.slot_position;
    return;
  end loop;
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
    or failure_code not in('source_verification_rejected','source_verification_unavailable')
    or failure_request_id is null then
    raise exception 'Training verifier lease is invalid or stale' using errcode='55000';
  end if;
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

create or replace function public.block_training_storage_verifier_job_after_source_verification(
  target_capability_id uuid,capability_secret text,expected_audience text,
  target_publication_request_id uuid,target_lease_token uuid,observed_objects jsonb,
  completion_request_id uuid
)
returns table(job_state text,verified_object_count integer)
language plpgsql security definer set search_path='' as $$
declare request public.training_publication_requests%rowtype; run public.training_storage_verification_runs%rowtype;
  job public.training_verifier_jobs%rowtype; observed_count integer; manifest_fingerprint text;
begin
  perform private.assert_training_verifier_capability(target_capability_id,capability_secret,expected_audience);
  select target.* into request from public.training_publication_requests target where target.id=target_publication_request_id;
  if request.id is null or request.audience<>expected_audience then raise exception 'Training verifier job not found' using errcode='P0002'; end if;
  perform private.lock_training_course_version(request.organization_id,request.course_version_id,'draft');
  select target.* into run from public.training_storage_verification_runs target where target.id=request.verification_run_id for update;
  select target.* into job from public.training_verifier_jobs target where target.publication_request_id=request.id for update;
  if job.state<>'leased' or statement_timestamp()>=job.lease_expires_at or run.status<>'pending'
    or statement_timestamp()>=run.expires_at
    or job.lease_token_sha256<>extensions.digest(pg_catalog.convert_to(target_lease_token::text,'UTF8'),'sha256')
    or jsonb_typeof(observed_objects)<>'array' or jsonb_array_length(observed_objects)<>40
    or completion_request_id is null then
    raise exception 'Training verifier lease or evidence is invalid or stale' using errcode='55000';
  end if;
  select count(*)::integer into observed_count from jsonb_to_recordset(observed_objects)
    as observed(media_id uuid,sha256 text,byte_size integer,width integer,height integer);
  if observed_count<>40 or (select count(distinct media_id) from jsonb_to_recordset(observed_objects)
      as observed(media_id uuid,sha256 text,byte_size integer,width integer,height integer))<>40
    or exists(select 1 from private.training_image_slot_requirements(request.organization_id,request.course_version_id) slot
      join public.training_media_assets asset on asset.organization_id=request.organization_id
        and asset.course_version_id=request.course_version_id and asset.asset_key=slot.asset_key and asset.status='ready'
      left join jsonb_to_recordset(observed_objects) as observed(media_id uuid,sha256 text,byte_size integer,width integer,height integer)
        on observed.media_id=asset.id
      where observed.media_id is null or observed.sha256 is distinct from asset.sha256
        or observed.byte_size is distinct from asset.byte_size or observed.width is distinct from asset.width
        or observed.height is distinct from asset.height) then
    raise exception 'Training storage object evidence does not match' using errcode='55000';
  end if;
  insert into private.training_verifier_source_observations(publication_request_id,media_id,media_revision,
    storage_bucket,storage_object_path,observed_sha256,observed_byte_size,observed_width,observed_height)
  select request.id,asset.id,asset.revision,asset.storage_bucket,asset.storage_object_path,observed.sha256,
    observed.byte_size,observed.width,observed.height
  from private.training_image_slot_requirements(request.organization_id,request.course_version_id) slot
  join public.training_media_assets asset on asset.organization_id=request.organization_id
    and asset.course_version_id=request.course_version_id and asset.asset_key=slot.asset_key and asset.status='ready'
  join jsonb_to_recordset(observed_objects) as observed(media_id uuid,sha256 text,byte_size integer,width integer,height integer)
    on observed.media_id=asset.id;
  select pg_catalog.encode(extensions.digest(pg_catalog.convert_to(string_agg(
    observed.media_id::text||':'||observed.sha256||':'||observed.byte_size||':'||observed.width||'x'||observed.height,
    '|' order by observed.media_id),'UTF8'),'sha256'),'hex') into manifest_fingerprint
  from jsonb_to_recordset(observed_objects) as observed(media_id uuid,sha256 text,byte_size integer,width integer,height integer);
  update public.training_verifier_jobs set state='publication_blocked',lease_token_sha256=null,lease_expires_at=null,
    last_failure_code='immutable_store_unconfigured',completed_at=statement_timestamp()
  where publication_request_id=request.id;
  insert into public.training_verifier_events(publication_request_id,event_type,correlation_id,attempt_number,
    capability_id,failure_code,details) values(request.id,'source_verified_publication_blocked',completion_request_id,
    job.attempt_count,target_capability_id,'immutable_store_unconfigured',
    jsonb_build_object('verified_object_count',40,'source_manifest_fingerprint',manifest_fingerprint));
  -- Deliberately do not call either Phase 3A completion or publication RPC. The
  -- source bucket is mutable by the ordinary API service credential. A future
  -- forward-only migration may enable publication only after an isolated,
  -- write-once/content-addressed destination and learner read path exist.
  return query select 'publication_blocked'::text,40;
exception when unique_violation then
  raise exception 'Training verifier completion was already recorded' using errcode='55000';
end;
$$;

revoke all on function public.get_internal_admin_training_publication_history(uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.get_internal_admin_training_publication_signing_context(uuid,uuid,uuid,uuid,uuid,uuid,bigint,text) from public,anon,authenticated,service_role;
revoke all on function public.request_internal_admin_training_publication(uuid,uuid,uuid,uuid,uuid,uuid,bigint,text,uuid,jsonb,text) from public,anon,authenticated,service_role;
revoke all on function public.claim_training_storage_verifier_job(uuid,text,text,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.fail_training_storage_verifier_job(uuid,text,text,uuid,uuid,text,boolean,uuid) from public,anon,authenticated,service_role;
revoke all on function public.block_training_storage_verifier_job_after_source_verification(uuid,text,text,uuid,uuid,jsonb,uuid) from public,anon,authenticated,service_role;

grant execute on function public.get_internal_admin_training_publication_history(uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.get_internal_admin_training_publication_signing_context(uuid,uuid,uuid,uuid,uuid,uuid,bigint,text) to service_role;
grant execute on function public.request_internal_admin_training_publication(uuid,uuid,uuid,uuid,uuid,uuid,bigint,text,uuid,jsonb,text) to service_role;
grant execute on function public.claim_training_storage_verifier_job(uuid,text,text,uuid,uuid) to anon;
grant execute on function public.fail_training_storage_verifier_job(uuid,text,text,uuid,uuid,text,boolean,uuid) to anon;
grant execute on function public.block_training_storage_verifier_job_after_source_verification(uuid,text,text,uuid,uuid,jsonb,uuid) to anon;

comment on table private.training_verifier_capabilities is
  'Out-of-band provisioned verifier broker capabilities. Only SHA-256 digests are stored; raw secrets belong only to the isolated worker secret scope.';
comment on table public.training_verifier_events is
  'Append-only sanitized verifier queue history. It never stores credentials, private paths, URLs, tokens, or raw content.';
comment on function public.block_training_storage_verifier_job_after_source_verification(uuid,text,text,uuid,uuid,jsonb,uuid) is
  'Fail-closed Phase 3B boundary: records source verification but cannot complete Phase 3A verification or publish until immutable publication Storage exists.';
