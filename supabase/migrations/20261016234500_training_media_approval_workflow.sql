-- Auditable, optimistic-concurrency-protected review for curriculum-bound
-- Training images. Storage bytes remain write-once and are verified by the
-- service before an approval transition.

alter table public.training_media_assets
  add column reviewed_at timestamptz,
  add column reviewed_by uuid references auth.users(id) on delete restrict,
  add column rejection_reason text,
  add column revision integer not null default 1;

alter table public.training_media_assets
  add constraint training_media_assets_revision_check check (revision > 0),
  add constraint training_media_assets_rejection_reason_check check (
    rejection_reason is null
    or (rejection_reason = btrim(rejection_reason) and length(rejection_reason) between 1 and 500)
  );

-- No application review workflow existed before this migration. Any
-- out-of-band decision has no trustworthy reviewer audit trail, so return it
-- to Submitted instead of silently treating it as reviewed.
update public.training_media_assets
set approval_status = 'submitted',
    reviewed_at = null,
    reviewed_by = null,
    rejection_reason = null
where approval_status <> 'submitted';

alter table public.training_media_assets
  add constraint training_media_assets_review_state_check check (
    (approval_status = 'submitted'
      and reviewed_at is null and reviewed_by is null and rejection_reason is null)
    or
    (approval_status = 'approved'
      and reviewed_at is not null and reviewed_by is not null and rejection_reason is null)
    or
    (approval_status = 'rejected'
      and reviewed_at is not null and reviewed_by is not null and rejection_reason is not null)
  );

create or replace function public.replace_internal_admin_training_media(
  actor_user_id uuid, target_organization_id uuid, target_course_id uuid,
  target_course_version_id uuid, target_media_id uuid, new_storage_object_path text,
  new_title_i18n jsonb, new_alt_i18n jsonb,
  new_byte_size integer, new_width integer, new_height integer, new_sha256 text,
  new_source_mime_type text, new_source_byte_size integer, new_source_sha256 text
)
returns table(id uuid, old_storage_object_path text, storage_object_path text)
language plpgsql security definer set search_path = '' as $$
declare selected public.training_media_assets%rowtype;
begin
  perform private.assert_internal_admin_training_draft(actor_user_id,target_organization_id,target_course_id,target_course_version_id);
  if not private.training_media_path_is_valid(new_storage_object_path,target_organization_id,target_course_id,target_course_version_id,target_media_id)
    or not private.training_media_locales_complete(new_title_i18n)
    or not private.training_media_locales_complete(new_alt_i18n) then
    raise exception 'Invalid Training media' using errcode = '22023';
  end if;
  select asset.* into selected from public.training_media_assets asset
  where asset.id=target_media_id and asset.organization_id=target_organization_id
    and asset.course_version_id=target_course_version_id and asset.status='ready' for update;
  if selected.id is null then raise exception 'Training media not found' using errcode='P0002'; end if;
  perform private.assert_training_image_slot(target_organization_id,target_course_version_id,selected.asset_key);
  return query update public.training_media_assets asset set
    storage_object_path=new_storage_object_path,title_i18n=new_title_i18n,alt_i18n=new_alt_i18n,
    mime_type='image/webp',byte_size=new_byte_size,
    width=new_width,height=new_height,sha256=new_sha256,source_mime_type=new_source_mime_type,
    source_byte_size=new_source_byte_size,source_sha256=new_source_sha256,
    approval_status='submitted',reviewed_at=null,reviewed_by=null,rejection_reason=null,
    revision=asset.revision+1,updated_by=actor_user_id
  where asset.id=selected.id
  returning asset.id,selected.storage_object_path,asset.storage_object_path;
end;
$$;

create or replace function public.update_internal_admin_training_media_metadata(
  actor_user_id uuid, target_organization_id uuid, target_course_id uuid,
  target_course_version_id uuid, target_media_id uuid, new_title_i18n jsonb, new_alt_i18n jsonb
)
returns setof public.training_media_assets
language plpgsql security definer set search_path = '' as $$
declare selected public.training_media_assets%rowtype;
begin
  perform private.assert_internal_admin_training_draft(actor_user_id,target_organization_id,target_course_id,target_course_version_id);
  if not private.training_media_locales_complete(new_title_i18n) or not private.training_media_locales_complete(new_alt_i18n) then
    raise exception 'Invalid Training media metadata' using errcode='22023';
  end if;
  select asset.* into selected from public.training_media_assets asset
  where asset.id=target_media_id and asset.organization_id=target_organization_id
    and asset.course_version_id=target_course_version_id and asset.status='ready' for update;
  if selected.id is null then raise exception 'Training media not found' using errcode='P0002'; end if;
  perform private.assert_training_image_slot(target_organization_id,target_course_version_id,selected.asset_key);
  return query update public.training_media_assets asset set
    title_i18n=new_title_i18n,alt_i18n=new_alt_i18n,
    approval_status='submitted',reviewed_at=null,reviewed_by=null,rejection_reason=null,
    revision=asset.revision+1,updated_by=actor_user_id
  where asset.id=selected.id
  returning asset.*;
end;
$$;

drop function public.list_internal_admin_training_media(uuid,uuid,uuid,uuid);
create function public.list_internal_admin_training_media(
  actor_user_id uuid, target_organization_id uuid, target_course_id uuid, target_course_version_id uuid
)
returns table(id uuid,asset_key text,media_type text,title_i18n jsonb,alt_i18n jsonb,mime_type text,
  byte_size integer,width integer,height integer,approval_status text,status text,created_at timestamptz,updated_at timestamptz,
  revision integer,reviewed_at timestamptz,rejection_reason text)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.assert_internal_admin_training_draft(actor_user_id,target_organization_id,target_course_id,target_course_version_id);
  return query select asset.id,asset.asset_key,asset.media_type,asset.title_i18n,asset.alt_i18n,asset.mime_type,
    asset.byte_size,asset.width,asset.height,asset.approval_status,asset.status,asset.created_at,asset.updated_at,
    asset.revision,asset.reviewed_at,asset.rejection_reason
  from public.training_media_assets asset where asset.organization_id=target_organization_id
    and asset.course_version_id=target_course_version_id order by asset.created_at,asset.id;
end;
$$;

drop function public.list_internal_admin_training_image_slots(uuid,uuid,uuid,uuid);
create function public.list_internal_admin_training_image_slots(
  actor_user_id uuid,
  target_organization_id uuid,
  target_course_id uuid,
  target_course_version_id uuid
)
returns table(
  module_id uuid,module_key text,module_position integer,module_title_i18n jsonb,
  lesson_id uuid,lesson_key text,lesson_position integer,lesson_title_i18n jsonb,
  asset_key text,placement text,purpose_i18n jsonb,expected_alt_i18n jsonb,media_alt_i18n jsonb,
  media_id uuid,media_status text,approval_status text,width integer,height integer,
  preview_available boolean,revision integer,reviewed_at timestamptz,rejection_reason text
)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.assert_internal_admin_training_draft(actor_user_id,target_organization_id,target_course_id,target_course_version_id);
  if not private.training_image_slot_bindings_valid(target_organization_id,target_course_version_id) then
    raise exception 'Training image slot contract changed' using errcode = '55000';
  end if;
  return query
  select slot.module_id,slot.module_key,slot.module_position,slot.module_title_i18n,
    slot.lesson_id,slot.lesson_key,slot.lesson_position,slot.lesson_title_i18n,
    slot.asset_key,slot.placement,slot.purpose_i18n,slot.expected_alt_i18n,asset.alt_i18n,
    asset.id,asset.status,asset.approval_status,asset.width,asset.height,asset.id is not null,
    asset.revision,asset.reviewed_at,asset.rejection_reason
  from private.training_image_slot_requirements(target_organization_id,target_course_version_id) slot
  left join public.training_media_assets asset
    on asset.organization_id=target_organization_id
   and asset.course_version_id=target_course_version_id
   and asset.asset_key=slot.asset_key
   and asset.status='ready'
  order by slot.module_position,slot.lesson_position,slot.slot_position;
end;
$$;

create function public.get_internal_admin_training_media_review_candidate(
  actor_user_id uuid,target_organization_id uuid,target_course_id uuid,
  target_course_version_id uuid,target_media_id uuid
)
returns table(storage_bucket text,storage_object_path text,mime_type text,byte_size integer,
  width integer,height integer,sha256 text,revision integer,approval_status text,status text)
language plpgsql stable security definer set search_path = '' as $$
declare selected public.training_media_assets%rowtype;
begin
  perform private.assert_internal_admin_training_draft(actor_user_id,target_organization_id,target_course_id,target_course_version_id);
  select asset.* into selected
  from public.training_media_assets asset
  where asset.id=target_media_id
    and asset.organization_id=target_organization_id
    and asset.course_version_id=target_course_version_id
    and asset.status='ready';
  if selected.id is null then raise exception 'Training media not found' using errcode='P0002'; end if;
  perform private.assert_training_image_slot(target_organization_id,target_course_version_id,selected.asset_key);
  return query select selected.storage_bucket,selected.storage_object_path,selected.mime_type,
    selected.byte_size,selected.width,selected.height,selected.sha256,selected.revision,
    selected.approval_status,selected.status;
end;
$$;

create function public.review_internal_admin_training_media(
  actor_user_id uuid,target_organization_id uuid,target_course_id uuid,
  target_course_version_id uuid,target_media_id uuid,expected_revision integer,
  review_decision text,new_rejection_reason text default null
)
returns table(id uuid,approval_status text,reviewed_at timestamptz,rejection_reason text,revision integer,updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare selected public.training_media_assets%rowtype;
declare normalized_reason text;
begin
  perform private.assert_internal_admin_training_draft(actor_user_id,target_organization_id,target_course_id,target_course_version_id);
  if expected_revision is null or expected_revision < 1 or review_decision not in ('approved','rejected') then
    raise exception 'Invalid Training media review' using errcode='22023';
  end if;
  normalized_reason := nullif(btrim(new_rejection_reason),'');
  if (review_decision='approved' and normalized_reason is not null)
    or (review_decision='rejected' and (normalized_reason is null or length(normalized_reason)>500)) then
    raise exception 'Invalid Training media review' using errcode='22023';
  end if;
  select asset.* into selected
  from public.training_media_assets asset
  where asset.id=target_media_id
    and asset.organization_id=target_organization_id
    and asset.course_version_id=target_course_version_id
    and asset.status='ready'
  for update;
  if selected.id is null then raise exception 'Training media not found' using errcode='P0002'; end if;
  perform private.assert_training_image_slot(target_organization_id,target_course_version_id,selected.asset_key);
  if selected.revision<>expected_revision then
    raise exception 'Training media review is stale' using errcode='40001';
  end if;
  if selected.approval_status<>'submitted' then
    raise exception 'Training media has already been reviewed' using errcode='55000';
  end if;
  if selected.media_type<>'image' or selected.mime_type<>'image/webp'
    or selected.byte_size<=0 or selected.width<=0 or selected.height<=0
    or selected.sha256 !~ '^[0-9a-f]{64}$'
    or not private.training_media_path_is_valid(selected.storage_object_path,target_organization_id,target_course_id,target_course_version_id,target_media_id)
    or not private.training_media_locales_complete(selected.title_i18n)
    or not private.training_media_locales_complete(selected.alt_i18n) then
    raise exception 'Invalid Training media' using errcode='22023';
  end if;
  return query update public.training_media_assets asset set
    approval_status=review_decision,
    reviewed_at=statement_timestamp(),
    reviewed_by=actor_user_id,
    rejection_reason=case when review_decision='rejected' then normalized_reason else null end,
    revision=asset.revision+1,
    updated_by=actor_user_id
  where asset.id=selected.id
  returning asset.id,asset.approval_status,asset.reviewed_at,asset.rejection_reason,asset.revision,asset.updated_at;
end;
$$;

create or replace function public.validate_internal_admin_training_media_for_publish(
 actor_user_id uuid,target_organization_id uuid,target_course_id uuid,target_course_version_id uuid
)
returns table(media_hash text,referenced_asset_count integer)
language plpgsql stable security definer set search_path = '' as $$
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
    on asset.course_version_id=target_course_version_id
   and asset.organization_id=target_organization_id
   and asset.asset_key=slot.asset_key
   and asset.status='ready'
  where asset.id is null
     or asset.approval_status<>'approved'
     or asset.reviewed_at is null
     or asset.reviewed_by is null
     or asset.rejection_reason is not null
     or asset.media_type<>'image'
     or asset.mime_type<>'image/webp'
     or asset.byte_size<=0 or asset.width<=0 or asset.height<=0
     or asset.sha256 !~ '^[0-9a-f]{64}$'
     or not private.training_media_locales_complete(asset.alt_i18n)
  order by slot.module_position,slot.lesson_position,slot.slot_position limit 1;
  if invalid_key is not null then
    raise exception 'Training media publication validation failed' using errcode='55000';
  end if;
  select string_agg(asset.asset_key||':'||asset.sha256||':'||asset.width||'x'||asset.height,'|' order by asset.asset_key)
  into media_material
  from private.training_image_slot_requirements(target_organization_id,target_course_version_id) slot
  join public.training_media_assets asset
    on asset.course_version_id=target_course_version_id
   and asset.organization_id=target_organization_id
   and asset.asset_key=slot.asset_key
   and asset.status='ready' and asset.approval_status='approved';
  return query select pg_catalog.encode(extensions.digest(coalesce(media_material,''),'sha256'),'hex'),slot_count;
end;
$$;

revoke all on function public.list_internal_admin_training_media(uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.list_internal_admin_training_image_slots(uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.get_internal_admin_training_media_review_candidate(uuid,uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.review_internal_admin_training_media(uuid,uuid,uuid,uuid,uuid,integer,text,text) from public,anon,authenticated,service_role;
revoke all on function public.replace_internal_admin_training_media(uuid,uuid,uuid,uuid,uuid,text,jsonb,jsonb,integer,integer,integer,text,text,integer,text) from public,anon,authenticated,service_role;
revoke all on function public.update_internal_admin_training_media_metadata(uuid,uuid,uuid,uuid,uuid,jsonb,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.validate_internal_admin_training_media_for_publish(uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;

grant execute on function public.list_internal_admin_training_media(uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.list_internal_admin_training_image_slots(uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.get_internal_admin_training_media_review_candidate(uuid,uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.review_internal_admin_training_media(uuid,uuid,uuid,uuid,uuid,integer,text,text) to service_role;
grant execute on function public.replace_internal_admin_training_media(uuid,uuid,uuid,uuid,uuid,text,jsonb,jsonb,integer,integer,integer,text,text,integer,text) to service_role;
grant execute on function public.update_internal_admin_training_media_metadata(uuid,uuid,uuid,uuid,uuid,jsonb,jsonb) to service_role;
grant execute on function public.validate_internal_admin_training_media_for_publish(uuid,uuid,uuid,uuid) to service_role;

comment on function public.review_internal_admin_training_media(uuid,uuid,uuid,uuid,uuid,integer,text,text) is
  'Reviews one submitted, curriculum-declared Training image with optimistic concurrency. Service-role only.';
