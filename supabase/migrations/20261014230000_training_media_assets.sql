-- Private, version-owned Training images. Browser clients never access this
-- table or bucket directly; service-role backend endpoints call the hardened
-- RPCs below after authenticating the actor.

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('training-media', 'training-media', false, 5242880, array['image/webp'])
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create table public.training_media_assets (
  id uuid primary key,
  organization_id uuid not null references public.organizations(id) on delete restrict,
  course_version_id uuid not null,
  asset_key text not null,
  media_type text not null,
  title_i18n jsonb not null,
  alt_i18n jsonb not null,
  storage_bucket text not null default 'training-media',
  storage_object_path text not null,
  mime_type text not null,
  byte_size integer not null,
  width integer not null,
  height integer not null,
  sha256 text not null,
  source_mime_type text not null,
  source_byte_size integer not null,
  source_sha256 text not null,
  approval_status text not null,
  status text not null default 'ready',
  created_at timestamptz not null default statement_timestamp(),
  created_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default statement_timestamp(),
  updated_by uuid references auth.users(id) on delete set null,
  retired_at timestamptz,
  retired_by uuid references auth.users(id) on delete restrict,
  constraint training_media_assets_id_version_organization_key unique(id, course_version_id, organization_id),
  constraint training_media_assets_version_asset_key_key unique(course_version_id, asset_key),
  constraint training_media_assets_storage_object_key unique(storage_bucket, storage_object_path),
  constraint training_media_assets_version_org_fkey foreign key(course_version_id, organization_id)
    references public.training_course_versions(id, organization_id) on delete restrict,
  constraint training_media_assets_asset_key_check check (
    asset_key = lower(asset_key)
    and asset_key ~ '^[a-z0-9]+(?:[a-z0-9_-]*[a-z0-9])?$'
    and length(asset_key) between 1 and 160
  ),
  constraint training_media_assets_media_type_check check(media_type = 'image'),
  constraint training_media_assets_title_i18n_check check(jsonb_typeof(title_i18n) = 'object'),
  constraint training_media_assets_alt_i18n_check check(jsonb_typeof(alt_i18n) = 'object'),
  constraint training_media_assets_bucket_check check(storage_bucket = 'training-media'),
  constraint training_media_assets_path_check check(
    storage_object_path = btrim(storage_object_path)
    and length(storage_object_path) between 120 and 500
    and storage_object_path !~ '(^|/)\.\.(/|$)'
  ),
  constraint training_media_assets_mime_check check(mime_type = 'image/webp'),
  constraint training_media_assets_sizes_check check(byte_size > 0 and source_byte_size > 0),
  constraint training_media_assets_dimensions_check check(width > 0 and height > 0),
  constraint training_media_assets_sha_check check(
    sha256 ~ '^[0-9a-f]{64}$' and source_sha256 ~ '^[0-9a-f]{64}$'
  ),
  constraint training_media_assets_source_mime_check check(source_mime_type in ('image/jpeg','image/png','image/webp')),
  constraint training_media_assets_approval_check check(approval_status in ('submitted','approved','rejected')),
  constraint training_media_assets_status_check check(status in ('ready','retired')),
  constraint training_media_assets_retired_check check(
    (status = 'ready' and retired_at is null and retired_by is null)
    or (status = 'retired' and retired_at is not null and retired_by is not null)
  )
);

create index training_media_assets_version_status_idx
  on public.training_media_assets(course_version_id, status, approval_status, asset_key);

alter table public.training_media_assets enable row level security;
revoke all on table public.training_media_assets from public, anon, authenticated, service_role;

-- Storage remains service-only. No training-media object policy is created for
-- browser roles; existing policies for unrelated buckets are left untouched.

create or replace function private.assert_internal_admin_training_draft(
  actor_user_id uuid,
  target_organization_id uuid,
  target_course_id uuid,
  target_course_version_id uuid
)
returns public.training_course_versions
language plpgsql
security definer
set search_path = ''
as $$
declare selected_version public.training_course_versions%rowtype;
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'Training media access denied' using errcode = '42501';
  end if;
  select version.* into selected_version
  from public.training_course_versions version
  join public.training_courses course
    on course.id = version.course_id and course.organization_id = version.organization_id
  where version.id = target_course_version_id
    and version.organization_id = target_organization_id
    and version.course_id = target_course_id
    and course.status = 'active';
  if selected_version.id is null then
    raise exception 'Training course version not found' using errcode = 'P0002';
  end if;
  if selected_version.status <> 'draft' then
    raise exception 'Training course version is immutable' using errcode = '55000';
  end if;
  return selected_version;
end;
$$;

create or replace function private.training_media_path_is_valid(
  object_path text,
  target_organization_id uuid,
  target_course_id uuid,
  target_course_version_id uuid,
  target_media_id uuid
)
returns boolean
language sql
immutable
security definer
set search_path = ''
as $$
  select object_path ~ (
    '^organizations/' || target_organization_id::text ||
    '/courses/' || target_course_id::text ||
    '/versions/' || target_course_version_id::text ||
    '/assets/' || target_media_id::text ||
    '/[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.webp$'
  );
$$;

create or replace function private.training_media_locales_complete(value jsonb)
returns boolean language sql immutable security definer set search_path = '' as $$
  select jsonb_typeof(value) = 'object'
    and (select pg_catalog.bool_and(jsonb_typeof(value -> locale) = 'string' and length(btrim(value ->> locale)) > 0)
         from unnest(array['en','ar','id','hi','fil']) locale);
$$;

create or replace function private.training_lesson_references_asset(content jsonb, target_asset_key text)
returns boolean language sql immutable security definer set search_path = '' as $$
  select exists(
    select 1 from jsonb_path_query(content, '$.**.asset_key') found
    where found = to_jsonb(target_asset_key)
  );
$$;

create or replace function private.enforce_training_media_draft()
returns trigger language plpgsql security definer set search_path = '' as $$
declare version_status text;
begin
  select version.status into version_status
  from public.training_course_versions version
  where version.id = coalesce(old.course_version_id, new.course_version_id)
    and version.organization_id = coalesce(old.organization_id, new.organization_id);
  if version_status is not null and version_status <> 'draft' then
    raise exception 'Published or retired Training media is immutable' using errcode = '55000';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create trigger training_media_assets_10_draft_guard
before insert or update or delete on public.training_media_assets
for each row execute function private.enforce_training_media_draft();
create trigger training_media_assets_90_set_updated_at
before update on public.training_media_assets
for each row execute function private.set_updated_at();

create or replace function public.list_internal_admin_training_draft_versions(
  actor_user_id uuid, target_organization_id uuid
)
returns table(course_id uuid, course_key text, course_version_id uuid, version_number integer,
  title_i18n jsonb, supported_locales text[], status text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'Training media access denied' using errcode = '42501';
  end if;
  return query select course.id, course.course_key, version.id, version.version_number,
    version.title_i18n, version.supported_locales, version.status
  from public.training_courses course
  join public.training_course_versions version on version.course_id = course.id and version.organization_id = course.organization_id
  where course.organization_id = target_organization_id and course.status = 'active' and version.status = 'draft'
  order by pg_catalog.lower(coalesce(version.title_i18n->>'en', course.course_key)), course.id;
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
declare old_path text;
begin
  perform private.assert_internal_admin_training_draft(actor_user_id,target_organization_id,target_course_id,target_course_version_id);
  if not private.training_media_path_is_valid(new_storage_object_path,target_organization_id,target_course_id,target_course_version_id,target_media_id)
    or not private.training_media_locales_complete(new_title_i18n)
    or not private.training_media_locales_complete(new_alt_i18n) then
    raise exception 'Invalid Training media' using errcode = '22023';
  end if;
  select asset.storage_object_path into old_path from public.training_media_assets asset
  where asset.id=target_media_id and asset.organization_id=target_organization_id
    and asset.course_version_id=target_course_version_id and asset.status='ready' for update;
  if old_path is null then raise exception 'Training media not found' using errcode='P0002'; end if;
  return query update public.training_media_assets asset set
    storage_object_path=new_storage_object_path,title_i18n=new_title_i18n,alt_i18n=new_alt_i18n,
    mime_type='image/webp',byte_size=new_byte_size,
    width=new_width,height=new_height,sha256=new_sha256,source_mime_type=new_source_mime_type,
    source_byte_size=new_source_byte_size,source_sha256=new_source_sha256,
    approval_status='submitted',updated_by=actor_user_id
  where asset.id=target_media_id and asset.organization_id=target_organization_id
    and asset.course_version_id=target_course_version_id
  returning asset.id,old_path,asset.storage_object_path;
end;
$$;

create or replace function public.update_internal_admin_training_media_metadata(
  actor_user_id uuid, target_organization_id uuid, target_course_id uuid,
  target_course_version_id uuid, target_media_id uuid, new_title_i18n jsonb, new_alt_i18n jsonb
)
returns setof public.training_media_assets
language plpgsql security definer set search_path = '' as $$
begin
  perform private.assert_internal_admin_training_draft(actor_user_id,target_organization_id,target_course_id,target_course_version_id);
  if not private.training_media_locales_complete(new_title_i18n) or not private.training_media_locales_complete(new_alt_i18n) then
    raise exception 'Invalid Training media metadata' using errcode='22023';
  end if;
  return query update public.training_media_assets asset set title_i18n=new_title_i18n,
    alt_i18n=new_alt_i18n,approval_status='submitted',updated_by=actor_user_id
  where asset.id=target_media_id and asset.organization_id=target_organization_id
    and asset.course_version_id=target_course_version_id and asset.status='ready'
  returning asset.*;
  if not found then raise exception 'Training media not found' using errcode='P0002'; end if;
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

create or replace function public.list_internal_admin_training_media(
  actor_user_id uuid, target_organization_id uuid, target_course_id uuid, target_course_version_id uuid
)
returns table(id uuid,asset_key text,media_type text,title_i18n jsonb,alt_i18n jsonb,mime_type text,
  byte_size integer,width integer,height integer,approval_status text,status text,created_at timestamptz,updated_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.assert_internal_admin_training_draft(actor_user_id,target_organization_id,target_course_id,target_course_version_id);
  return query select asset.id,asset.asset_key,asset.media_type,asset.title_i18n,asset.alt_i18n,asset.mime_type,
    asset.byte_size,asset.width,asset.height,asset.approval_status,asset.status,asset.created_at,asset.updated_at
  from public.training_media_assets asset where asset.organization_id=target_organization_id
    and asset.course_version_id=target_course_version_id order by asset.created_at,asset.id;
end;
$$;

create or replace function public.authorize_internal_admin_training_media_read(
  actor_user_id uuid,target_organization_id uuid,target_course_id uuid,target_course_version_id uuid,target_media_id uuid
)
returns table(storage_bucket text,storage_object_path text,mime_type text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_internal_admin(actor_user_id) then raise exception 'Training media access denied' using errcode='42501'; end if;
  return query select asset.storage_bucket,asset.storage_object_path,asset.mime_type
  from public.training_media_assets asset
  join public.training_course_versions version on version.id=asset.course_version_id and version.organization_id=asset.organization_id
  where asset.id=target_media_id and asset.organization_id=target_organization_id
    and asset.course_version_id=target_course_version_id and version.course_id=target_course_id and asset.status='ready';
  if not found then raise exception 'Training media not found' using errcode='P0002'; end if;
end;
$$;

create or replace function public.authorize_training_learner_media_read(
  target_session_id uuid,target_organization_id uuid,target_course_id uuid,target_course_version_id uuid,target_media_id uuid
)
returns table(storage_bucket text,storage_object_path text,mime_type text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not exists(select 1 from public.training_learner_sessions session_row
    where session_row.id=target_session_id and session_row.organization_id=target_organization_id
      and session_row.revoked_at is null and session_row.expires_at>statement_timestamp()) then
    raise exception 'Training learner access denied' using errcode='42501';
  end if;
  return query select asset.storage_bucket,asset.storage_object_path,asset.mime_type
  from public.training_media_assets asset
  join public.training_course_versions version on version.id=asset.course_version_id and version.organization_id=asset.organization_id
  where asset.id=target_media_id and asset.organization_id=target_organization_id
    and asset.course_version_id=target_course_version_id and version.course_id=target_course_id
    and version.status='published' and asset.status='ready' and asset.approval_status='approved';
  if not found then raise exception 'Training media not found' using errcode='P0002'; end if;
end;
$$;

create or replace function public.validate_internal_admin_training_media_for_publish(
 actor_user_id uuid,target_organization_id uuid,target_course_id uuid,target_course_version_id uuid
)
returns table(media_hash text,referenced_asset_count integer)
language plpgsql stable security definer set search_path = '' as $$
declare missing_key text; media_material text; reference_count integer;
begin
  perform private.assert_internal_admin_training_draft(actor_user_id,target_organization_id,target_course_id,target_course_version_id);
  select referenced.key into missing_key from (
    select distinct trim(both '"' from media_reference.value::text) as key
    from public.training_lessons lesson cross join lateral jsonb_path_query(lesson.content_i18n,'$.**.asset_key') media_reference(value)
    where lesson.organization_id=target_organization_id and lesson.course_version_id=target_course_version_id
  ) referenced left join public.training_media_assets asset
    on asset.course_version_id=target_course_version_id and asset.organization_id=target_organization_id
      and asset.asset_key=referenced.key and asset.status='ready' and asset.approval_status='approved'
      and asset.mime_type='image/webp' and private.training_media_locales_complete(asset.alt_i18n)
  where asset.id is null limit 1;
  if missing_key is not null then raise exception 'Training media publication validation failed' using errcode='55000'; end if;
  select count(distinct trim(both '"' from media_reference.value::text))::integer into reference_count
  from public.training_lessons lesson cross join lateral jsonb_path_query(lesson.content_i18n,'$.**.asset_key') media_reference(value)
  where lesson.organization_id=target_organization_id and lesson.course_version_id=target_course_version_id;
  select string_agg(asset.asset_key||':'||asset.sha256||':'||asset.width||'x'||asset.height,'|' order by asset.asset_key)
    into media_material from public.training_media_assets asset where asset.organization_id=target_organization_id
      and asset.course_version_id=target_course_version_id and asset.status='ready' and asset.approval_status='approved';
  return query select pg_catalog.encode(extensions.digest(coalesce(media_material,''),'sha256'),'hex'),coalesce(reference_count,0);
end;
$$;

create or replace function private.training_version_content_hash(
  target_organization_id uuid,target_course_version_id uuid
)
returns text language sql stable security definer set search_path = '' as $$
  select pg_catalog.encode(extensions.digest(
    concat_ws('|',
      version.version_number::text,version.default_locale,array_to_string(version.supported_locales,','),
      version.title_i18n::text,version.description_i18n::text,version.content_schema_version::text,
      coalesce((select string_agg(module.stable_key||':'||module.position||':'||module.title_i18n::text||':'||module.description_i18n::text||':'||module.metadata::text,'|' order by module.position,module.id)
        from public.training_modules module where module.organization_id=target_organization_id and module.course_version_id=target_course_version_id),''),
      coalesce((select string_agg(lesson.stable_key||':'||lesson.position||':'||lesson.lesson_type||':'||lesson.required||':'||lesson.title_i18n::text||':'||lesson.objective_i18n::text||':'||lesson.content_i18n::text||':'||lesson.metadata::text,'|' order by module.position,lesson.position,lesson.id)
        from public.training_lessons lesson join public.training_modules module on module.id=lesson.module_id and module.course_version_id=lesson.course_version_id and module.organization_id=lesson.organization_id
        where lesson.organization_id=target_organization_id and lesson.course_version_id=target_course_version_id),''),
      coalesce((select string_agg(asset.asset_key||':'||asset.sha256||':'||asset.byte_size||':'||asset.width||'x'||asset.height||':'||asset.title_i18n::text||':'||asset.alt_i18n::text,'|' order by asset.asset_key)
        from public.training_media_assets asset where asset.organization_id=target_organization_id and asset.course_version_id=target_course_version_id and asset.status='ready' and asset.approval_status='approved'),'')
    ),'sha256'),'hex')
  from public.training_course_versions version
  where version.id=target_course_version_id and version.organization_id=target_organization_id;
$$;

create or replace function private.enforce_training_media_publication()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.status='draft' and new.status='published' then
    perform public.validate_internal_admin_training_media_for_publish(new.published_by,new.organization_id,new.course_id,new.id);
    new.content_hash:=private.training_version_content_hash(new.organization_id,new.id);
  end if;
  return new;
end;
$$;
create trigger training_course_versions_05_media_publication
before update on public.training_course_versions
for each row execute function private.enforce_training_media_publication();

revoke all on function private.assert_internal_admin_training_draft(uuid,uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function private.training_media_path_is_valid(text,uuid,uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function private.training_media_locales_complete(jsonb) from public,anon,authenticated;
revoke all on function private.training_lesson_references_asset(jsonb,text) from public,anon,authenticated;
revoke all on function private.enforce_training_media_draft() from public,anon,authenticated;
revoke all on function private.training_version_content_hash(uuid,uuid) from public,anon,authenticated;
revoke all on function private.enforce_training_media_publication() from public,anon,authenticated;
grant execute on function private.assert_internal_admin_training_draft(uuid,uuid,uuid,uuid) to service_role;
grant execute on function private.training_media_path_is_valid(text,uuid,uuid,uuid,uuid) to service_role;
grant execute on function private.training_media_locales_complete(jsonb) to service_role;
grant execute on function private.training_lesson_references_asset(jsonb,text) to service_role;
grant execute on function private.enforce_training_media_draft() to service_role;
grant execute on function private.training_version_content_hash(uuid,uuid) to service_role;
grant execute on function private.enforce_training_media_publication() to service_role;

revoke all on function public.list_internal_admin_training_draft_versions(uuid,uuid) from public,anon,authenticated;
revoke all on function public.register_internal_admin_training_media(uuid,uuid,uuid,uuid,uuid,text,jsonb,jsonb,text,integer,integer,integer,text,text,integer,text) from public,anon,authenticated;
revoke all on function public.replace_internal_admin_training_media(uuid,uuid,uuid,uuid,uuid,text,jsonb,jsonb,integer,integer,integer,text,text,integer,text) from public,anon,authenticated;
revoke all on function public.update_internal_admin_training_media_metadata(uuid,uuid,uuid,uuid,uuid,jsonb,jsonb) from public,anon,authenticated;
revoke all on function public.retire_internal_admin_training_media(uuid,uuid,uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.list_internal_admin_training_media(uuid,uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.authorize_internal_admin_training_media_read(uuid,uuid,uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.authorize_training_learner_media_read(uuid,uuid,uuid,uuid,uuid) from public,anon,authenticated;
revoke all on function public.validate_internal_admin_training_media_for_publish(uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.list_internal_admin_training_draft_versions(uuid,uuid) to service_role;
grant execute on function public.register_internal_admin_training_media(uuid,uuid,uuid,uuid,uuid,text,jsonb,jsonb,text,integer,integer,integer,text,text,integer,text) to service_role;
grant execute on function public.replace_internal_admin_training_media(uuid,uuid,uuid,uuid,uuid,text,jsonb,jsonb,integer,integer,integer,text,text,integer,text) to service_role;
grant execute on function public.update_internal_admin_training_media_metadata(uuid,uuid,uuid,uuid,uuid,jsonb,jsonb) to service_role;
grant execute on function public.retire_internal_admin_training_media(uuid,uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.list_internal_admin_training_media(uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.authorize_internal_admin_training_media_read(uuid,uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.authorize_training_learner_media_read(uuid,uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.validate_internal_admin_training_media_for_publish(uuid,uuid,uuid,uuid) to service_role;

comment on table public.training_media_assets is 'Private immutable-on-publish Training image metadata. Physical object paths never enter learner/admin DTOs.';
