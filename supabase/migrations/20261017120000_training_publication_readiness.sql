-- Read-only publication readiness for the exact Baladiyah v1 draft.
-- Storage bytes are verified by the backend; this RPC returns database-only facts.

create or replace function public.get_internal_admin_training_publication_readiness(
  actor_user_id uuid,
  target_organization_id uuid,
  target_course_id uuid,
  target_course_version_id uuid
)
returns table(
  course_key text,
  course_title_i18n jsonb,
  version_number integer,
  version_status text,
  revision bigint,
  curriculum_valid boolean,
  instructional_module_count integer,
  instructional_lesson_count integer,
  final_assessment_count integer,
  final_quiz_count integer,
  quiz_question_count integer,
  pass_threshold_bps integer,
  required_image_count integer,
  uploaded_image_count integer,
  submitted_image_count integer,
  approved_image_count integer,
  rejected_image_count integer,
  missing_image_count integer,
  image_metadata_valid boolean,
  image_database_ready boolean,
  locale_structure_complete boolean,
  conflicting_published_version boolean,
  translation_review_status jsonb,
  content_review_status text,
  regulatory_review_status text,
  review_workflow_available boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  target_version public.training_course_versions%rowtype;
  target_course public.training_courses%rowtype;
  slots integer;
  uploaded integer;
  submitted integer;
  approved integer;
  rejected integer;
  metadata_valid boolean;
  media_ready boolean := false;
begin
  perform private.assert_internal_admin_training_draft(
    actor_user_id,
    target_organization_id,
    target_course_id,
    target_course_version_id
  );

  select course.* into strict target_course
  from public.training_courses course
  where course.id = target_course_id
    and course.organization_id = target_organization_id;

  select version.* into strict target_version
  from public.training_course_versions version
  where version.id = target_course_version_id
    and version.course_id = target_course_id
    and version.organization_id = target_organization_id;

  -- Reuse the exact read-only draft contract. It fails closed on curriculum,
  -- locale, quiz, ordering, video, or image-binding drift.
  perform 1
  from public.get_internal_admin_training_draft_preview(
    actor_user_id,
    target_organization_id,
    target_course_id,
    target_course_version_id
  )
  limit 1;

  select count(*)::integer into slots
  from private.training_image_slot_requirements(target_organization_id, target_course_version_id);

  select
    count(asset.id)::integer,
    count(asset.id) filter (where asset.approval_status = 'submitted')::integer,
    count(asset.id) filter (where asset.approval_status = 'approved')::integer,
    count(asset.id) filter (where asset.approval_status = 'rejected')::integer,
    coalesce(bool_and(
      asset.id is null or (
        asset.status = 'ready'
        and asset.media_type = 'image'
        and asset.mime_type = 'image/webp'
        and asset.byte_size > 0
        and asset.width > 0
        and asset.height > 0
        and asset.sha256 ~ '^[0-9a-f]{64}$'
        and private.training_media_locales_complete(asset.alt_i18n)
      )
    ), true)
  into uploaded, submitted, approved, rejected, metadata_valid
  from private.training_image_slot_requirements(target_organization_id, target_course_version_id) slot
  left join public.training_media_assets asset
    on asset.organization_id = target_organization_id
   and asset.course_version_id = target_course_version_id
   and asset.asset_key = slot.asset_key
   and asset.status = 'ready';

  if slots = 40 and approved = 40 and metadata_valid then
    -- Reuse the authoritative database publication validator. Storage object
    -- integrity remains a separate backend check.
    perform 1
    from public.validate_internal_admin_training_media_for_publish(
      actor_user_id,
      target_organization_id,
      target_course_id,
      target_course_version_id
    );
    media_ready := true;
  end if;

  return query
  select
    target_course.course_key,
    target_version.title_i18n,
    target_version.version_number,
    target_version.status,
    target_version.revision,
    true,
    9,
    18,
    1,
    1,
    27,
    8000,
    slots,
    uploaded,
    submitted,
    approved,
    rejected,
    slots - uploaded,
    metadata_valid,
    media_ready,
    true,
    exists (
      select 1
      from public.training_course_versions published
      where published.organization_id = target_organization_id
        and published.course_id = target_course_id
        and published.status = 'published'
        and published.id <> target_course_version_id
    ),
    jsonb_build_object(
      'en','pending','ar','pending','id','pending','hi','pending','fil','pending'
    ),
    'pending',
    'pending',
    false;
end;
$$;

revoke all on function public.get_internal_admin_training_publication_readiness(uuid,uuid,uuid,uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.get_internal_admin_training_publication_readiness(uuid,uuid,uuid,uuid)
  to service_role;

comment on function public.get_internal_admin_training_publication_readiness(uuid,uuid,uuid,uuid) is
  'Returns read-only, database-backed Baladiyah draft publication readiness. Review approvals are pending until an authoritative workflow exists. Service-role only.';
