-- Phase 3C correction: bind every periodic integrity-audit lease and
-- completion to the immutable publication request audience. Capability
-- rotation is permitted only between active capabilities for that same
-- audience; the immutable request remains the environment trust anchor.

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
  perform private.assert_training_verifier_capability(
    target_capability_id,capability_secret,expected_audience
  );
  if worker_instance_id is null or claim_request_id is null then
    raise exception 'Invalid integrity audit claim' using errcode='22023';
  end if;

  select job.* into selected
  from private.training_published_media_integrity_jobs job
  join public.training_publication_media_manifests manifest
    on manifest.id=job.manifest_id
  join public.training_publication_requests publication_request
    on publication_request.id=manifest.publication_request_id
   and publication_request.organization_id=manifest.organization_id
   and publication_request.course_id=manifest.course_id
   and publication_request.course_version_id=manifest.course_version_id
  join public.training_course_versions version
    on version.id=manifest.course_version_id
   and version.organization_id=manifest.organization_id
   and version.course_id=manifest.course_id
  where job.next_due_at<=statement_timestamp()
    and (job.lease_expires_at is null or job.lease_expires_at<=statement_timestamp())
    and publication_request.audience=expected_audience
    and version.status='published'
  order by job.next_due_at,job.manifest_id
  for update of job skip locked
  limit 1;

  if selected.manifest_id is null then return; end if;

  raw_lease:=gen_random_uuid();
  update private.training_published_media_integrity_jobs set
    lease_token_sha256=extensions.digest(pg_catalog.convert_to(raw_lease::text,'UTF8'),'sha256'),
    lease_expires_at=statement_timestamp()+interval '10 minutes',attempt_count=attempt_count+1,
    updated_at=statement_timestamp()
  where training_published_media_integrity_jobs.manifest_id=selected.manifest_id
  returning training_published_media_integrity_jobs.lease_expires_at into selected.lease_expires_at;

  return query
  select item.manifest_id,raw_lease,selected.lease_expires_at,item.media_id,item.sha256,
    item.byte_size,item.width,item.height,item.storage_bucket,item.storage_object_path
  from public.training_publication_media_manifest_items item
  where item.manifest_id=selected.manifest_id
  order by item.module_position,item.lesson_position,item.slot_position;
end;
$$;

create or replace function public.complete_training_published_media_integrity_audit(
  target_capability_id uuid,capability_secret text,expected_audience text,target_manifest_id uuid,
  target_lease_token uuid,audit_status text,observed_objects jsonb,failure_code text,completion_request_id uuid
)
returns table(integrity_run_id uuid,status text,checked_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare job private.training_published_media_integrity_jobs%rowtype;
  saved public.training_published_media_integrity_runs%rowtype;
  observed_count integer; next_seconds integer;
begin
  perform private.assert_training_verifier_capability(
    target_capability_id,capability_secret,expected_audience
  );

  select target.* into job
  from private.training_published_media_integrity_jobs target
  join public.training_publication_media_manifests manifest
    on manifest.id=target.manifest_id
  join public.training_publication_requests publication_request
    on publication_request.id=manifest.publication_request_id
   and publication_request.organization_id=manifest.organization_id
   and publication_request.course_id=manifest.course_id
   and publication_request.course_version_id=manifest.course_version_id
  where target.manifest_id=target_manifest_id
    and publication_request.audience=expected_audience
  for update of target;

  -- Missing and cross-audience targets deliberately share one sanitized error.
  if job.manifest_id is null then
    raise exception 'Training verifier access denied' using errcode='42501';
  end if;
  if target_lease_token is null or job.lease_expires_at is null
    or statement_timestamp()>=job.lease_expires_at
    or job.lease_token_sha256<>extensions.digest(
      pg_catalog.convert_to(target_lease_token::text,'UTF8'),'sha256'
    )
    or audit_status not in('passed','failed') or jsonb_typeof(observed_objects)<>'array'
    or completion_request_id is null
    or (audit_status='passed' and failure_code is not null)
    or (audit_status='failed' and failure_code not in(
      'published_media_missing','published_media_mismatch','published_media_unavailable'
    ))
  then
    raise exception 'Training published media integrity completion is invalid or stale'
      using errcode='55000';
  end if;

  select count(*)::integer into observed_count
  from jsonb_to_recordset(observed_objects)
    as observed(media_id uuid,sha256 text,byte_size integer,width integer,height integer);
  if observed_count>40 or (audit_status='passed' and (observed_count<>40
    or (select count(distinct media_id) from jsonb_to_recordset(observed_objects)
      as observed(media_id uuid,sha256 text,byte_size integer,width integer,height integer))<>40
    or exists(select 1 from public.training_publication_media_manifest_items item
      left join jsonb_to_recordset(observed_objects) as observed(
        media_id uuid,sha256 text,byte_size integer,width integer,height integer
      ) on observed.media_id=item.media_id
      where item.manifest_id=target_manifest_id and (
        observed.media_id is null or observed.sha256<>item.sha256
        or observed.byte_size<>item.byte_size or observed.width<>item.width
        or observed.height<>item.height
      ))))
  then
    raise exception 'Training published media integrity evidence does not match'
      using errcode='55000';
  end if;

  insert into public.training_published_media_integrity_runs(
    manifest_id,verifier_capability_id,completion_request_id,status,failure_code,checked_object_count
  ) values(
    target_manifest_id,target_capability_id,completion_request_id,
    audit_status,failure_code,observed_count
  ) returning * into saved;
  insert into public.training_published_media_integrity_items(
    integrity_run_id,manifest_id,media_id,observed_sha256,
    observed_byte_size,observed_width,observed_height
  )
  select saved.id,target_manifest_id,observed.media_id,observed.sha256,
    observed.byte_size,observed.width,observed.height
  from jsonb_to_recordset(observed_objects) as observed(
    media_id uuid,sha256 text,byte_size integer,width integer,height integer
  );

  select case when audit_status='passed'
    then config.integrity_freshness_seconds else config.integrity_retry_seconds end
  into next_seconds
  from private.training_published_media_configuration config
  where config.singleton;
  update private.training_published_media_integrity_jobs set
    lease_token_sha256=null,lease_expires_at=null,
    next_due_at=statement_timestamp()+pg_catalog.make_interval(secs=>next_seconds),
    updated_at=statement_timestamp()
  where manifest_id=target_manifest_id;

  return query select saved.id,saved.status,saved.checked_at;
exception when unique_violation then
  raise exception 'Training integrity completion was already recorded' using errcode='55000';
end;
$$;

-- CREATE OR REPLACE preserves signatures, but restating the ACL keeps the
-- verifier broker boundary explicit and protects installations with legacy
-- default function privileges.
revoke all on function public.claim_training_published_media_integrity_audit(
  uuid,text,text,uuid,uuid
) from public,anon,authenticated,service_role;
revoke all on function public.complete_training_published_media_integrity_audit(
  uuid,text,text,uuid,uuid,text,jsonb,text,uuid
) from public,anon,authenticated,service_role;
grant execute on function public.claim_training_published_media_integrity_audit(
  uuid,text,text,uuid,uuid
) to anon;
grant execute on function public.complete_training_published_media_integrity_audit(
  uuid,text,text,uuid,uuid,text,jsonb,text,uuid
) to anon;

comment on function public.claim_training_published_media_integrity_audit(
  uuid,text,text,uuid,uuid
) is 'Claims only published-media integrity jobs whose immutable publication request audience matches the active verifier capability audience.';
comment on function public.complete_training_published_media_integrity_audit(
  uuid,text,text,uuid,uuid,text,jsonb,text,uuid
) is 'Completes an integrity lease only when capability, expected audience, and immutable publication request audience match; same-audience capability rotation is permitted.';
