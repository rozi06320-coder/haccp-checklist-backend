-- Normalize the approved Baladiyah draft's forty curriculum-declared image
-- requirements into explicit learner bindings, then expose only those slots to
-- the Internal Admin media workflow. No media is created and the version stays
-- draft.

create or replace function private.training_image_slot_requirements(
  target_organization_id uuid,
  target_course_version_id uuid
)
returns table(
  module_id uuid,
  module_key text,
  module_position integer,
  module_title_i18n jsonb,
  lesson_id uuid,
  lesson_key text,
  lesson_position integer,
  lesson_title_i18n jsonb,
  asset_key text,
  placement text,
  purpose_i18n jsonb,
  expected_alt_i18n jsonb,
  slot_position integer
)
language sql
stable
security definer
set search_path = ''
as $$
  with requirements as (
    select
      module.id as module_id,
      module.stable_key as module_key,
      module.position as module_position,
      module.title_i18n as module_title_i18n,
      lesson.id as lesson_id,
      lesson.stable_key as lesson_key,
      lesson.position as lesson_position,
      lesson.title_i18n as lesson_title_i18n,
      requirement.value ->> 'asset_key' as asset_key,
      requirement.value ->> 'placement' as placement,
      requirement.value -> 'alt_i18n' as expected_alt_i18n,
      row_number() over (
        partition by module.id, lesson.id
        order by requirement.ordinality
      )::integer as slot_position
    from public.training_modules module
    cross join lateral jsonb_array_elements(module.metadata -> 'photo_requirements')
      with ordinality requirement(value, ordinality)
    join public.training_lessons lesson
      on lesson.module_id = module.id
     and lesson.course_version_id = module.course_version_id
     and lesson.organization_id = module.organization_id
     and lesson.stable_key = requirement.value ->> 'lesson_key'
    where module.organization_id = target_organization_id
      and module.course_version_id = target_course_version_id
  )
  select
    requirements.module_id,
    requirements.module_key,
    requirements.module_position,
    requirements.module_title_i18n,
    requirements.lesson_id,
    requirements.lesson_key,
    requirements.lesson_position,
    requirements.lesson_title_i18n,
    requirements.asset_key,
    requirements.placement,
    requirements.expected_alt_i18n as purpose_i18n,
    requirements.expected_alt_i18n,
    requirements.slot_position
  from requirements
  order by requirements.module_position, requirements.lesson_position, requirements.slot_position;
$$;

create or replace function private.training_image_slot_bindings_valid(
  target_organization_id uuid,
  target_course_version_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  supported_locales text[];
  raw_requirement_count integer;
  distinct_requirement_count integer;
  resolved_slot_count integer;
  locale_count integer;
  bound_reference_count integer;
begin
  select version.supported_locales
  into supported_locales
  from public.training_course_versions version
  where version.id = target_course_version_id
    and version.organization_id = target_organization_id;

  if supported_locales is null or cardinality(supported_locales) = 0 then
    return false;
  end if;

  if exists (
    select 1
    from public.training_modules module
    where module.organization_id = target_organization_id
      and module.course_version_id = target_course_version_id
      and module.metadata ? 'photo_requirements'
      and jsonb_typeof(module.metadata -> 'photo_requirements') is distinct from 'array'
  ) then
    return false;
  end if;

  select count(*)::integer, count(distinct requirement.value ->> 'asset_key')::integer
  into raw_requirement_count, distinct_requirement_count
  from public.training_modules module
  cross join lateral jsonb_array_elements(module.metadata -> 'photo_requirements') requirement(value)
  where module.organization_id = target_organization_id
    and module.course_version_id = target_course_version_id;

  select count(*)::integer
  into resolved_slot_count
  from private.training_image_slot_requirements(target_organization_id, target_course_version_id);

  if raw_requirement_count <> distinct_requirement_count
    or raw_requirement_count <> resolved_slot_count then
    return false;
  end if;

  select cardinality(supported_locales) into locale_count;

  if exists (
    select 1
    from public.training_lessons lesson
    cross join unnest(supported_locales) locale
    where lesson.organization_id = target_organization_id
      and lesson.course_version_id = target_course_version_id
      and exists (
        select 1
        from private.training_image_slot_requirements(target_organization_id, target_course_version_id) expected
        where expected.lesson_id = lesson.id
      )
      and (
        jsonb_typeof(lesson.content_i18n -> locale) is distinct from 'object'
        or jsonb_typeof(lesson.content_i18n -> locale -> 'image_slots') is distinct from 'array'
      )
  ) then
    return false;
  end if;

  if exists (
    select 1
    from private.training_image_slot_requirements(target_organization_id, target_course_version_id) expected
    join public.training_lessons expected_lesson
      on expected_lesson.id = expected.lesson_id
    cross join unnest(supported_locales) locale
    where (
      select count(*)
      from jsonb_array_elements(expected_lesson.content_i18n -> locale -> 'image_slots') slot(value)
      where slot.value ->> 'asset_key' = expected.asset_key
        and slot.value ->> 'placement' = expected.placement
        and (slot.value ->> 'slot_position')::integer = expected.slot_position
        and jsonb_typeof(slot.value -> 'label') = 'string'
        and length(btrim(slot.value ->> 'label')) > 0
    ) <> 1
  ) then
    return false;
  end if;

  if exists (
    select 1
    from public.training_lessons lesson
    cross join unnest(supported_locales) locale
    cross join lateral jsonb_array_elements(coalesce(lesson.content_i18n -> locale -> 'image_slots', '[]'::jsonb)) slot(value)
    left join private.training_image_slot_requirements(target_organization_id, target_course_version_id) expected
      on expected.lesson_id = lesson.id
     and expected.asset_key = slot.value ->> 'asset_key'
     and expected.placement = slot.value ->> 'placement'
     and expected.slot_position = (slot.value ->> 'slot_position')::integer
    where lesson.organization_id = target_organization_id
      and lesson.course_version_id = target_course_version_id
      and expected.asset_key is null
  ) then
    return false;
  end if;

  if exists (
    select 1
    from public.training_lessons lesson
    cross join unnest(supported_locales) locale
    cross join lateral jsonb_path_query((lesson.content_i18n -> locale) - 'image_slots', '$.**.asset_key') reference(value)
    where lesson.organization_id = target_organization_id
      and lesson.course_version_id = target_course_version_id
  ) then
    return false;
  end if;

  select count(*)::integer
  into bound_reference_count
  from public.training_lessons lesson
  cross join unnest(supported_locales) locale
  cross join lateral jsonb_array_elements(coalesce(lesson.content_i18n -> locale -> 'image_slots', '[]'::jsonb)) slot(value)
  where lesson.organization_id = target_organization_id
    and lesson.course_version_id = target_course_version_id;

  return bound_reference_count = resolved_slot_count * locale_count;
exception
  when data_exception then
    return false;
end;
$$;

create or replace function private.assert_training_image_slot(
  target_organization_id uuid,
  target_course_version_id uuid,
  target_asset_key text
)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare slot_count integer;
begin
  select count(*)::integer
  into slot_count
  from private.training_image_slot_requirements(target_organization_id, target_course_version_id) slot
  where slot.asset_key = target_asset_key;

  if slot_count = 0 then
    raise exception 'Unknown Training image slot' using errcode = '22023';
  end if;
  if slot_count <> 1
    or not private.training_image_slot_bindings_valid(target_organization_id, target_course_version_id) then
    raise exception 'Training image slot contract changed' using errcode = '55000';
  end if;
end;
$$;

create or replace function private.normalize_baladiyah_training_image_slots()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  original_manifest_hash constant text := '4e63cd0f0dbca4bd1e3e4e9b15548d7e19b80c5b7deab1e72c26d8e2c300b15b';
  normalized_manifest_hash constant text := '5d77e1c5d9c127a7a07fb0caf0703b52a0df2b16e0510632ff57bf4c09cf1515';
  target_organization_id uuid;
  target_course_id uuid;
  target_course_version_id uuid;
  current_status text;
  current_content_hash text;
  current_revision bigint;
  lesson_record record;
  locale text;
  locale_content jsonb;
  normalized_content jsonb;
  normalized_items jsonb;
  normalized_slots jsonb;
begin
  select course.organization_id, course.id, version.id, version.status, version.content_hash, version.revision
  into target_organization_id, target_course_id, target_course_version_id,
       current_status, current_content_hash, current_revision
  from public.training_courses course
  join public.training_course_versions version
    on version.course_id = course.id
   and version.organization_id = course.organization_id
  where course.course_key = 'baladiyah-food-safety-hygiene'
    and version.version_number = 1;

  if target_course_version_id is null then
    raise exception 'Baladiyah draft version 1 is missing' using errcode = '55000';
  end if;
  if current_status <> 'draft' then
    raise exception 'Baladiyah version 1 must remain draft for slot normalization' using errcode = '55000';
  end if;
  if (select count(*) from public.training_courses where course_key = 'baladiyah-food-safety-hygiene') <> 1
    or (select count(*) from public.training_course_versions where course_id = target_course_id and version_number = 1) <> 1
    or (select count(*) from public.training_modules where course_version_id = target_course_version_id) <> 9
    or (select count(*) from public.training_lessons where course_version_id = target_course_version_id) <> 27
    or (select count(*) from private.training_image_slot_requirements(target_organization_id, target_course_version_id)) <> 40 then
    raise exception 'Baladiyah draft structure does not match the required image-slot contract' using errcode = '55000';
  end if;

  if current_content_hash = normalized_manifest_hash and current_revision = 1 then
    if not private.training_image_slot_bindings_valid(target_organization_id, target_course_version_id) then
      raise exception 'Baladiyah normalized image-slot bindings have drifted' using errcode = '55000';
    end if;
    return;
  end if;

  if current_content_hash is distinct from original_manifest_hash or current_revision <> 0 then
    raise exception 'Baladiyah draft changed before image-slot normalization' using errcode = '55000';
  end if;

  if exists (
    select 1
    from public.training_lessons lesson
    cross join lateral jsonb_path_query(lesson.content_i18n, '$.**.asset_key') reference(value)
    left join private.training_image_slot_requirements(target_organization_id, target_course_version_id) expected
      on expected.lesson_id = lesson.id
     and expected.asset_key = trim(both '"' from reference.value::text)
    where lesson.organization_id = target_organization_id
      and lesson.course_version_id = target_course_version_id
      and expected.asset_key is null
  ) then
    raise exception 'Baladiyah draft contains an undeclared image binding' using errcode = '55000';
  end if;

  if exists (
    select 1
    from public.training_media_assets asset
    left join private.training_image_slot_requirements(target_organization_id, target_course_version_id) expected
      on expected.asset_key = asset.asset_key
    where asset.organization_id = target_organization_id
      and asset.course_version_id = target_course_version_id
      and (expected.asset_key is null or asset.status = 'retired')
  ) then
    raise exception 'Baladiyah draft media does not match the required image slots' using errcode = '55000';
  end if;

  for lesson_record in
    select lesson.id, lesson.content_i18n
    from public.training_lessons lesson
    where lesson.organization_id = target_organization_id
      and lesson.course_version_id = target_course_version_id
      and exists (
        select 1
        from private.training_image_slot_requirements(target_organization_id, target_course_version_id) expected
        where expected.lesson_id = lesson.id
      )
    order by lesson.module_id, lesson.position
  loop
    normalized_content := lesson_record.content_i18n;
    foreach locale in array array['en','ar','id','hi','fil'] loop
      locale_content := normalized_content -> locale;
      if jsonb_typeof(locale_content) is distinct from 'object' then
        raise exception 'Baladiyah lesson locale content is incomplete' using errcode = '55000';
      end if;

      if jsonb_typeof(locale_content -> 'items') = 'array' then
        select coalesce(jsonb_agg(item.value - 'image' order by item.ordinality), '[]'::jsonb)
        into normalized_items
        from jsonb_array_elements(locale_content -> 'items') with ordinality item(value, ordinality);
        locale_content := jsonb_set(locale_content, '{items}', normalized_items, true);
      end if;

      select jsonb_agg(
        jsonb_build_object(
          'asset_key', expected.asset_key,
          'placement', expected.placement,
          'slot_position', expected.slot_position,
          'label', expected.expected_alt_i18n ->> locale
        )
        order by expected.slot_position
      )
      into normalized_slots
      from private.training_image_slot_requirements(target_organization_id, target_course_version_id) expected
      where expected.lesson_id = lesson_record.id;

      if normalized_slots is null
        or exists (
          select 1
          from jsonb_array_elements(normalized_slots) slot(value)
          where jsonb_typeof(slot.value -> 'label') is distinct from 'string'
             or length(btrim(slot.value ->> 'label')) = 0
        ) then
        raise exception 'Baladiyah image-slot labels are incomplete' using errcode = '55000';
      end if;

      locale_content := jsonb_set(locale_content, '{image_slots}', normalized_slots, true);
      normalized_content := jsonb_set(normalized_content, array[locale], locale_content, true);
    end loop;

    update public.training_lessons
    set content_i18n = normalized_content
    where id = lesson_record.id
      and organization_id = target_organization_id
      and course_version_id = target_course_version_id;
  end loop;

  if not private.training_image_slot_bindings_valid(target_organization_id, target_course_version_id) then
    raise exception 'Baladiyah image-slot normalization failed validation' using errcode = '55000';
  end if;

  update public.training_course_versions
  set revision = 1,
      content_hash = normalized_manifest_hash
  where id = target_course_version_id
    and organization_id = target_organization_id
    and status = 'draft';
end;
$$;

select private.normalize_baladiyah_training_image_slots();

create or replace function public.list_internal_admin_training_image_slots(
  actor_user_id uuid,
  target_organization_id uuid,
  target_course_id uuid,
  target_course_version_id uuid
)
returns table(
  module_id uuid,
  module_key text,
  module_position integer,
  module_title_i18n jsonb,
  lesson_id uuid,
  lesson_key text,
  lesson_position integer,
  lesson_title_i18n jsonb,
  asset_key text,
  placement text,
  purpose_i18n jsonb,
  expected_alt_i18n jsonb,
  media_id uuid,
  media_status text,
  approval_status text,
  width integer,
  height integer,
  preview_available boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.assert_internal_admin_training_draft(
    actor_user_id,
    target_organization_id,
    target_course_id,
    target_course_version_id
  );
  if not private.training_image_slot_bindings_valid(target_organization_id, target_course_version_id) then
    raise exception 'Training image slot contract changed' using errcode = '55000';
  end if;

  return query
  select
    slot.module_id,
    slot.module_key,
    slot.module_position,
    slot.module_title_i18n,
    slot.lesson_id,
    slot.lesson_key,
    slot.lesson_position,
    slot.lesson_title_i18n,
    slot.asset_key,
    slot.placement,
    slot.purpose_i18n,
    slot.expected_alt_i18n,
    asset.id,
    asset.status,
    asset.approval_status,
    asset.width,
    asset.height,
    asset.id is not null
  from private.training_image_slot_requirements(target_organization_id, target_course_version_id) slot
  left join public.training_media_assets asset
    on asset.organization_id = target_organization_id
   and asset.course_version_id = target_course_version_id
   and asset.asset_key = slot.asset_key
   and asset.status = 'ready'
  order by slot.module_position, slot.lesson_position, slot.slot_position;
end;
$$;

create or replace function public.register_internal_admin_training_media(
  actor_user_id uuid, target_organization_id uuid, target_course_id uuid,
  target_course_version_id uuid, target_media_id uuid, target_asset_key text,
  new_title_i18n jsonb, new_alt_i18n jsonb, new_storage_object_path text,
  new_byte_size integer, new_width integer, new_height integer, new_sha256 text,
  new_source_mime_type text, new_source_byte_size integer, new_source_sha256 text
)
returns setof public.training_media_assets
language plpgsql security definer set search_path = '' as $$
begin
  perform private.assert_internal_admin_training_draft(actor_user_id,target_organization_id,target_course_id,target_course_version_id);
  perform private.assert_training_image_slot(target_organization_id,target_course_version_id,target_asset_key);
  if target_media_id is null or not private.training_media_path_is_valid(new_storage_object_path,target_organization_id,target_course_id,target_course_version_id,target_media_id)
    or not private.training_media_locales_complete(new_title_i18n)
    or not private.training_media_locales_complete(new_alt_i18n) then
    raise exception 'Invalid Training media' using errcode = '22023';
  end if;
  return query insert into public.training_media_assets(
    id,organization_id,course_version_id,asset_key,media_type,title_i18n,alt_i18n,
    storage_object_path,mime_type,byte_size,width,height,sha256,source_mime_type,
    source_byte_size,source_sha256,approval_status,status,created_by,updated_by
  ) values(target_media_id,target_organization_id,target_course_version_id,target_asset_key,'image',
    new_title_i18n,new_alt_i18n,new_storage_object_path,'image/webp',new_byte_size,new_width,new_height,
    new_sha256,new_source_mime_type,new_source_byte_size,new_source_sha256,'submitted','ready',actor_user_id,actor_user_id)
  returning *;
end;
$$;

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
    approval_status='submitted',updated_by=actor_user_id
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
  return query update public.training_media_assets asset set title_i18n=new_title_i18n,
    alt_i18n=new_alt_i18n,approval_status='submitted',updated_by=actor_user_id
  where asset.id=selected.id
  returning asset.*;
end;
$$;

create or replace function public.retire_internal_admin_training_media(
  actor_user_id uuid, target_organization_id uuid, target_course_id uuid,
  target_course_version_id uuid, target_media_id uuid
)
returns table(id uuid, retired_storage_object_path text)
language plpgsql security definer set search_path = '' as $$
declare selected public.training_media_assets%rowtype;
begin
  perform private.assert_internal_admin_training_draft(actor_user_id,target_organization_id,target_course_id,target_course_version_id);
  select asset.* into selected from public.training_media_assets asset
  where asset.id=target_media_id and asset.organization_id=target_organization_id
    and asset.course_version_id=target_course_version_id and asset.status='ready' for update;
  if selected.id is null then raise exception 'Training media not found' using errcode='P0002'; end if;
  if exists(
    select 1
    from private.training_image_slot_requirements(target_organization_id,target_course_version_id) slot
    where slot.asset_key=selected.asset_key
  ) then
    raise exception 'Required Training image slots must be replaced, not removed' using errcode='55000';
  end if;
  if exists(select 1 from public.training_lessons lesson where lesson.course_version_id=target_course_version_id
    and lesson.organization_id=target_organization_id
    and private.training_lesson_references_asset(lesson.content_i18n,selected.asset_key)) then
    raise exception 'Training media is referenced by lesson content' using errcode='55000';
  end if;
  return query update public.training_media_assets asset set status='retired',retired_at=statement_timestamp(),
    retired_by=actor_user_id,updated_by=actor_user_id where asset.id=selected.id
  returning asset.id,asset.storage_object_path;
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
     or asset.approval_status <> 'approved'
     or asset.media_type <> 'image'
     or asset.mime_type <> 'image/webp'
     or asset.byte_size <= 0
     or asset.width <= 0
     or asset.height <= 0
     or asset.sha256 !~ '^[0-9a-f]{64}$'
     or not private.training_media_locales_complete(asset.alt_i18n)
  order by slot.module_position,slot.lesson_position,slot.slot_position
  limit 1;
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
   and asset.status='ready'
   and asset.approval_status='approved';

  return query select pg_catalog.encode(extensions.digest(coalesce(media_material,''),'sha256'),'hex'),slot_count;
end;
$$;

revoke all on function private.training_image_slot_requirements(uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function private.training_image_slot_bindings_valid(uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function private.assert_training_image_slot(uuid,uuid,text) from public,anon,authenticated,service_role;
revoke all on function private.normalize_baladiyah_training_image_slots() from public,anon,authenticated,service_role;

revoke all on function public.list_internal_admin_training_image_slots(uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.list_internal_admin_training_image_slots(uuid,uuid,uuid,uuid) to service_role;

-- Keep every replaced public mutation/publication RPC service-role-only.
revoke all on function public.register_internal_admin_training_media(uuid,uuid,uuid,uuid,uuid,text,jsonb,jsonb,text,integer,integer,integer,text,text,integer,text) from public,anon,authenticated;
revoke all on function public.replace_internal_admin_training_media(uuid,uuid,uuid,uuid,uuid,text,jsonb,jsonb,integer,integer,integer,text,text,integer,text) from public,anon,authenticated;
revoke all on function public.update_internal_admin_training_media_metadata(uuid,uuid,uuid,uuid,uuid,jsonb,jsonb) from public,anon,authenticated;
revoke all on function public.retire_internal_admin_training_media(uuid,uuid,uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.validate_internal_admin_training_media_for_publish(uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.register_internal_admin_training_media(uuid,uuid,uuid,uuid,uuid,text,jsonb,jsonb,text,integer,integer,integer,text,text,integer,text) to service_role;
grant execute on function public.replace_internal_admin_training_media(uuid,uuid,uuid,uuid,uuid,text,jsonb,jsonb,integer,integer,integer,text,text,integer,text) to service_role;
grant execute on function public.update_internal_admin_training_media_metadata(uuid,uuid,uuid,uuid,uuid,jsonb,jsonb) to service_role;
grant execute on function public.retire_internal_admin_training_media(uuid,uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.validate_internal_admin_training_media_for_publish(uuid,uuid,uuid,uuid) to service_role;

comment on function public.list_internal_admin_training_image_slots(uuid,uuid,uuid,uuid) is
  'Safe ordered Internal Admin read model for curriculum-declared Training image slots. Storage details and checksums are never returned.';
