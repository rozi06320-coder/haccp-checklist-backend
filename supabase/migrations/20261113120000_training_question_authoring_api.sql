-- Internal Admin Question Draft authoring API.
-- Browser roles never receive table privileges; all mutations are atomic RPCs.

create table public.training_question_authoring_requests (
  actor_user_id uuid not null references auth.users(id) on delete restrict,
  organization_id uuid not null,
  action_key uuid not null,
  action text not null check (action in ('create','update','delete','replace_options')),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  response jsonb not null check (jsonb_typeof(response) = 'object'),
  created_at timestamptz not null default statement_timestamp(),
  primary key (actor_user_id, action_key)
);

alter table public.training_question_authoring_requests enable row level security;
revoke all on table public.training_question_authoring_requests from public, anon, authenticated, service_role;

create or replace function private.training_question_authoring_options_valid(
  target_options jsonb,
  target_correct_key text
)
returns boolean language sql stable security definer set search_path = '' as $$
  select pg_catalog.jsonb_typeof(target_options) = 'array'
    and pg_catalog.jsonb_array_length(target_options) between 2 and 20
    and (select count(*) from pg_catalog.jsonb_array_elements(target_options) option
         where pg_catalog.jsonb_typeof(option) = 'object'
           and (select count(*) from pg_catalog.jsonb_object_keys(option)) = 3
           and option ? 'option_key' and option ? 'position' and option ? 'label_i18n') = pg_catalog.jsonb_array_length(target_options)
    and (select count(*) from pg_catalog.jsonb_array_elements(target_options) option
         where option->>'option_key' = target_correct_key) = 1;
$$;

create or replace function private.training_question_authoring_response(
  question public.training_question_drafts
)
returns jsonb language sql stable security definer set search_path = '' as $$
  select pg_catalog.jsonb_build_object(
    'id', question.id,
    'organization_id', question.organization_id,
    'course_version_id', question.course_version_id,
    'lesson_id', question.lesson_id,
    'stable_key', question.stable_key,
    'position', question.position,
    'prompt_i18n', question.prompt_i18n,
    'explanation_i18n', question.explanation_i18n,
    'correct_option_key', question.correct_option_key,
    'revision', question.revision,
    'created_at', question.created_at,
    'updated_at', question.updated_at,
    'options', coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id', option.id, 'option_key', option.option_key, 'position', option.position,
      'label_i18n', option.label_i18n, 'created_at', option.created_at, 'updated_at', option.updated_at
    ) order by option.position, option.id)
    from public.training_question_draft_options option where option.question_id = question.id), '[]'::jsonb)
  );
$$;

create or replace function public.list_internal_admin_training_question_drafts(
  actor_user_id uuid,
  target_organization_id uuid,
  target_course_id uuid,
  target_course_version_id uuid,
  target_lesson_id uuid
)
returns setof jsonb language plpgsql stable security definer set search_path = '' as $$
declare version public.training_course_versions%rowtype; question public.training_question_drafts%rowtype;
begin
  version := private.assert_internal_admin_training_draft(actor_user_id,target_organization_id,target_course_id,target_course_version_id);
  if not exists (select 1 from public.training_lessons lesson where lesson.id=target_lesson_id
    and lesson.organization_id=target_organization_id and lesson.course_version_id=target_course_version_id and lesson.lesson_type='quiz') then
    raise exception 'quiz lesson not found' using errcode='P0002';
  end if;
  for question in select * from public.training_question_drafts draft
    where draft.organization_id=target_organization_id and draft.course_version_id=target_course_version_id and draft.lesson_id=target_lesson_id
    order by draft.position, draft.id loop
    return next private.training_question_authoring_response(question);
  end loop;
  return;
end;
$$;

create or replace function public.create_internal_admin_training_question_draft(
  actor_user_id uuid, target_organization_id uuid, target_course_id uuid, target_course_version_id uuid,
  target_lesson_id uuid, action_key uuid, request_hash text, stable_key text, p_position integer,
  prompt_i18n jsonb, explanation_i18n jsonb, correct_option_key text, options jsonb
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare version public.training_course_versions%rowtype; question public.training_question_drafts%rowtype; prior public.training_question_authoring_requests%rowtype; option jsonb; response jsonb;
begin
  if create_internal_admin_training_question_draft.request_hash !~ '^[0-9a-f]{64}$' or not private.training_question_authoring_options_valid(create_internal_admin_training_question_draft.options,create_internal_admin_training_question_draft.correct_option_key) then raise exception 'invalid question payload' using errcode='22023'; end if;
  version := private.assert_internal_admin_training_draft(create_internal_admin_training_question_draft.actor_user_id,create_internal_admin_training_question_draft.target_organization_id,create_internal_admin_training_question_draft.target_course_id,create_internal_admin_training_question_draft.target_course_version_id);
  select * into prior from public.training_question_authoring_requests requests where requests.actor_user_id=create_internal_admin_training_question_draft.actor_user_id and requests.action_key=create_internal_admin_training_question_draft.action_key for update;
  if prior.actor_user_id is not null then
    if prior.request_hash<>create_internal_admin_training_question_draft.request_hash or prior.action<>'create' then raise exception 'idempotency conflict' using errcode='23505'; end if;
    return prior.response;
  end if;
  if not exists (select 1 from public.training_lessons lesson where lesson.id=create_internal_admin_training_question_draft.target_lesson_id and lesson.organization_id=create_internal_admin_training_question_draft.target_organization_id and lesson.course_version_id=create_internal_admin_training_question_draft.target_course_version_id and lesson.lesson_type='quiz') then raise exception 'quiz lesson not found' using errcode='P0002'; end if;
  begin
    insert into public.training_question_drafts(organization_id,course_version_id,lesson_id,stable_key,position,prompt_i18n,explanation_i18n,correct_option_key,created_by,updated_by)
    values(create_internal_admin_training_question_draft.target_organization_id,create_internal_admin_training_question_draft.target_course_version_id,create_internal_admin_training_question_draft.target_lesson_id,create_internal_admin_training_question_draft.stable_key,create_internal_admin_training_question_draft.p_position,create_internal_admin_training_question_draft.prompt_i18n,create_internal_admin_training_question_draft.explanation_i18n,create_internal_admin_training_question_draft.correct_option_key,create_internal_admin_training_question_draft.actor_user_id,create_internal_admin_training_question_draft.actor_user_id) returning * into question;
    for option in select value from pg_catalog.jsonb_array_elements(create_internal_admin_training_question_draft.options) loop
      insert into public.training_question_draft_options(organization_id,course_version_id,lesson_id,question_id,option_key,position,label_i18n,created_by,updated_by)
      values(create_internal_admin_training_question_draft.target_organization_id,create_internal_admin_training_question_draft.target_course_version_id,create_internal_admin_training_question_draft.target_lesson_id,question.id,option->>'option_key',(option->>'position')::integer,option->'label_i18n',create_internal_admin_training_question_draft.actor_user_id,create_internal_admin_training_question_draft.actor_user_id);
    end loop;
    response := private.training_question_authoring_response(question);
    insert into public.training_question_authoring_requests values(create_internal_admin_training_question_draft.actor_user_id,create_internal_admin_training_question_draft.target_organization_id,create_internal_admin_training_question_draft.action_key,'create',create_internal_admin_training_question_draft.request_hash,response);
  exception when unique_violation then
    raise exception 'question authoring conflict' using errcode='23505';
  end;
  return response;
end;
$$;

create or replace function public.update_internal_admin_training_question_draft(
  actor_user_id uuid, target_organization_id uuid, target_course_id uuid, target_course_version_id uuid,
  target_lesson_id uuid, target_question_id uuid, expected_revision bigint, action_key uuid, request_hash text,
  stable_key text, p_position integer, prompt_i18n jsonb, explanation_i18n jsonb, correct_option_key text, options jsonb
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare version public.training_course_versions%rowtype; question public.training_question_drafts%rowtype; prior public.training_question_authoring_requests%rowtype; option jsonb; response jsonb;
begin
  if update_internal_admin_training_question_draft.request_hash !~ '^[0-9a-f]{64}$' or not private.training_question_authoring_options_valid(update_internal_admin_training_question_draft.options,update_internal_admin_training_question_draft.correct_option_key) then raise exception 'invalid question payload' using errcode='22023'; end if;
  version := private.assert_internal_admin_training_draft(update_internal_admin_training_question_draft.actor_user_id,update_internal_admin_training_question_draft.target_organization_id,update_internal_admin_training_question_draft.target_course_id,update_internal_admin_training_question_draft.target_course_version_id);
  select * into prior from public.training_question_authoring_requests requests where requests.actor_user_id=update_internal_admin_training_question_draft.actor_user_id and requests.action_key=update_internal_admin_training_question_draft.action_key for update;
  if prior.actor_user_id is not null then
    if prior.request_hash<>update_internal_admin_training_question_draft.request_hash or prior.action<>'update' then raise exception 'idempotency conflict' using errcode='23505'; end if;
    return prior.response;
  end if;
  select * into strict question from public.training_question_drafts draft where draft.id=update_internal_admin_training_question_draft.target_question_id and draft.organization_id=update_internal_admin_training_question_draft.target_organization_id and draft.course_version_id=update_internal_admin_training_question_draft.target_course_version_id and draft.lesson_id=update_internal_admin_training_question_draft.target_lesson_id for update;
  if question.revision<>update_internal_admin_training_question_draft.expected_revision then raise exception 'question revision is stale' using errcode='40001'; end if;
  update public.training_question_drafts set stable_key=update_internal_admin_training_question_draft.stable_key,position=update_internal_admin_training_question_draft.p_position,prompt_i18n=update_internal_admin_training_question_draft.prompt_i18n,explanation_i18n=update_internal_admin_training_question_draft.explanation_i18n,correct_option_key=update_internal_admin_training_question_draft.correct_option_key,revision=question.revision+1,updated_by=update_internal_admin_training_question_draft.actor_user_id,updated_at=statement_timestamp() where id=question.id returning * into question;
  delete from public.training_question_draft_options as draft_option where draft_option.question_id=question.id;
  for option in select value from pg_catalog.jsonb_array_elements(update_internal_admin_training_question_draft.options) loop
    insert into public.training_question_draft_options(organization_id,course_version_id,lesson_id,question_id,option_key,position,label_i18n,created_by,updated_by)
    values(update_internal_admin_training_question_draft.target_organization_id,update_internal_admin_training_question_draft.target_course_version_id,update_internal_admin_training_question_draft.target_lesson_id,question.id,option->>'option_key',(option->>'position')::integer,option->'label_i18n',update_internal_admin_training_question_draft.actor_user_id,update_internal_admin_training_question_draft.actor_user_id);
  end loop;
  response := private.training_question_authoring_response(question);
  insert into public.training_question_authoring_requests values(update_internal_admin_training_question_draft.actor_user_id,update_internal_admin_training_question_draft.target_organization_id,update_internal_admin_training_question_draft.action_key,'update',update_internal_admin_training_question_draft.request_hash,response);
  return response;
exception when no_data_found then raise exception 'question not found' using errcode='P0002';
end;
$$;

create or replace function public.delete_internal_admin_training_question_draft(
  actor_user_id uuid, target_organization_id uuid, target_course_id uuid, target_course_version_id uuid,
  target_lesson_id uuid, target_question_id uuid, expected_revision bigint, action_key uuid, request_hash text
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare version public.training_course_versions%rowtype; question public.training_question_drafts%rowtype; prior public.training_question_authoring_requests%rowtype; response jsonb;
begin
  if delete_internal_admin_training_question_draft.request_hash !~ '^[0-9a-f]{64}$' then raise exception 'invalid request hash' using errcode='22023'; end if;
  version := private.assert_internal_admin_training_draft(delete_internal_admin_training_question_draft.actor_user_id,delete_internal_admin_training_question_draft.target_organization_id,delete_internal_admin_training_question_draft.target_course_id,delete_internal_admin_training_question_draft.target_course_version_id);
  select * into prior from public.training_question_authoring_requests requests where requests.actor_user_id=delete_internal_admin_training_question_draft.actor_user_id and requests.action_key=delete_internal_admin_training_question_draft.action_key for update;
  if prior.actor_user_id is not null then
    if prior.request_hash<>delete_internal_admin_training_question_draft.request_hash or prior.action<>'delete' then raise exception 'idempotency conflict' using errcode='23505'; end if;
    return prior.response;
  end if;
  select * into strict question from public.training_question_drafts draft where draft.id=delete_internal_admin_training_question_draft.target_question_id and draft.organization_id=delete_internal_admin_training_question_draft.target_organization_id and draft.course_version_id=delete_internal_admin_training_question_draft.target_course_version_id and draft.lesson_id=delete_internal_admin_training_question_draft.target_lesson_id for update;
  if question.revision<>delete_internal_admin_training_question_draft.expected_revision then raise exception 'question revision is stale' using errcode='40001'; end if;
  delete from public.training_question_drafts where id=question.id;
  response := pg_catalog.jsonb_build_object('deleted',true,'id',question.id,'revision',question.revision);
  insert into public.training_question_authoring_requests values(delete_internal_admin_training_question_draft.actor_user_id,delete_internal_admin_training_question_draft.target_organization_id,delete_internal_admin_training_question_draft.action_key,'delete',delete_internal_admin_training_question_draft.request_hash,response);
  return response;
exception when no_data_found then raise exception 'question not found' using errcode='P0002';
end;
$$;

create or replace function public.replace_internal_admin_training_question_options(
  actor_user_id uuid, target_organization_id uuid, target_course_id uuid, target_course_version_id uuid,
  target_lesson_id uuid, target_question_id uuid, expected_revision bigint, action_key uuid, request_hash text,
  correct_option_key text, options jsonb
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare version public.training_course_versions%rowtype; question public.training_question_drafts%rowtype; prior public.training_question_authoring_requests%rowtype; option jsonb; response jsonb;
begin
  if replace_internal_admin_training_question_options.request_hash !~ '^[0-9a-f]{64}$' or not private.training_question_authoring_options_valid(replace_internal_admin_training_question_options.options,replace_internal_admin_training_question_options.correct_option_key) then raise exception 'invalid option payload' using errcode='22023'; end if;
  version := private.assert_internal_admin_training_draft(replace_internal_admin_training_question_options.actor_user_id,replace_internal_admin_training_question_options.target_organization_id,replace_internal_admin_training_question_options.target_course_id,replace_internal_admin_training_question_options.target_course_version_id);
  select * into prior from public.training_question_authoring_requests requests where requests.actor_user_id=replace_internal_admin_training_question_options.actor_user_id and requests.action_key=replace_internal_admin_training_question_options.action_key for update;
  if prior.actor_user_id is not null then
    if prior.request_hash<>replace_internal_admin_training_question_options.request_hash or prior.action<>'replace_options' then raise exception 'idempotency conflict' using errcode='23505'; end if;
    return prior.response;
  end if;
  select * into strict question from public.training_question_drafts draft where draft.id=replace_internal_admin_training_question_options.target_question_id and draft.organization_id=replace_internal_admin_training_question_options.target_organization_id and draft.course_version_id=replace_internal_admin_training_question_options.target_course_version_id and draft.lesson_id=replace_internal_admin_training_question_options.target_lesson_id for update;
  if question.revision<>replace_internal_admin_training_question_options.expected_revision then raise exception 'question revision is stale' using errcode='40001'; end if;
  update public.training_question_drafts set correct_option_key=replace_internal_admin_training_question_options.correct_option_key,revision=question.revision+1,updated_by=replace_internal_admin_training_question_options.actor_user_id,updated_at=statement_timestamp() where id=question.id returning * into question;
  delete from public.training_question_draft_options as draft_option where draft_option.question_id=question.id;
  for option in select value from pg_catalog.jsonb_array_elements(replace_internal_admin_training_question_options.options) loop
    insert into public.training_question_draft_options(organization_id,course_version_id,lesson_id,question_id,option_key,position,label_i18n,created_by,updated_by)
    values(replace_internal_admin_training_question_options.target_organization_id,replace_internal_admin_training_question_options.target_course_version_id,replace_internal_admin_training_question_options.target_lesson_id,question.id,option->>'option_key',(option->>'position')::integer,option->'label_i18n',replace_internal_admin_training_question_options.actor_user_id,replace_internal_admin_training_question_options.actor_user_id);
  end loop;
  response := private.training_question_authoring_response(question);
  insert into public.training_question_authoring_requests values(replace_internal_admin_training_question_options.actor_user_id,replace_internal_admin_training_question_options.target_organization_id,replace_internal_admin_training_question_options.action_key,'replace_options',replace_internal_admin_training_question_options.request_hash,response);
  return response;
exception when no_data_found then raise exception 'question not found' using errcode='P0002';
end;
$$;

revoke all on function public.list_internal_admin_training_question_drafts(uuid,uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;
revoke all on function public.create_internal_admin_training_question_draft(uuid,uuid,uuid,uuid,uuid,uuid,text,text,integer,jsonb,jsonb,text,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.update_internal_admin_training_question_draft(uuid,uuid,uuid,uuid,uuid,uuid,bigint,uuid,text,text,integer,jsonb,jsonb,text,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.delete_internal_admin_training_question_draft(uuid,uuid,uuid,uuid,uuid,uuid,bigint,uuid,text) from public,anon,authenticated,service_role;
revoke all on function public.replace_internal_admin_training_question_options(uuid,uuid,uuid,uuid,uuid,uuid,bigint,uuid,text,text,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.list_internal_admin_training_question_drafts(uuid,uuid,uuid,uuid,uuid) to service_role;
grant execute on function public.create_internal_admin_training_question_draft(uuid,uuid,uuid,uuid,uuid,uuid,text,text,integer,jsonb,jsonb,text,jsonb) to service_role;
grant execute on function public.update_internal_admin_training_question_draft(uuid,uuid,uuid,uuid,uuid,uuid,bigint,uuid,text,text,integer,jsonb,jsonb,text,jsonb) to service_role;
grant execute on function public.delete_internal_admin_training_question_draft(uuid,uuid,uuid,uuid,uuid,uuid,bigint,uuid,text) to service_role;
grant execute on function public.replace_internal_admin_training_question_options(uuid,uuid,uuid,uuid,uuid,uuid,bigint,uuid,text,text,jsonb) to service_role;
