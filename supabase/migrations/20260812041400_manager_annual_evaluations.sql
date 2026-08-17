-- Manager-owned annual evaluations for active branch supervisors and operational employees.

create table public.annual_evaluations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null,
  evaluation_year integer not null,
  subject_type text not null,
  supervisor_user_id uuid references auth.users(id) on delete restrict,
  operational_staff_id uuid,
  state text not null default 'draft',
  evaluator_user_id uuid not null references auth.users(id) on delete restrict,
  evaluator_name_snapshot text not null,
  subject_name_snapshot text not null,
  subject_role_snapshot text not null,
  subject_staff_code_snapshot text,
  branch_name_snapshot text not null,
  total_score integer,
  revision bigint not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  submitted_at timestamptz,
  constraint annual_evaluations_id_scope_key unique(id,organization_id,branch_id),
  constraint annual_evaluations_branch_scope_fkey foreign key(branch_id,organization_id)
    references public.branches(id,organization_id) on delete restrict,
  constraint annual_evaluations_staff_scope_fkey foreign key(operational_staff_id,branch_id,organization_id)
    references public.operational_staff(id,branch_id,organization_id) on delete restrict,
  constraint annual_evaluations_year_check check(evaluation_year between 2000 and 2200),
  constraint annual_evaluations_subject_check check(
    (subject_type='supervisor' and supervisor_user_id is not null and operational_staff_id is null)
    or (subject_type='employee' and supervisor_user_id is null and operational_staff_id is not null)
  ),
  constraint annual_evaluations_state_check check(state in('draft','submitted')),
  constraint annual_evaluations_total_check check(total_score is null or total_score between 20 and 100),
  constraint annual_evaluations_submission_check check(
    (state='draft' and submitted_at is null)
    or (state='submitted' and submitted_at is not null and total_score is not null)
  ),
  constraint annual_evaluations_snapshot_check check(
    evaluator_name_snapshot=pg_catalog.btrim(evaluator_name_snapshot) and pg_catalog.length(evaluator_name_snapshot) between 1 and 120
    and subject_name_snapshot=pg_catalog.btrim(subject_name_snapshot) and pg_catalog.length(subject_name_snapshot) between 1 and 120
    and subject_role_snapshot=pg_catalog.btrim(subject_role_snapshot) and pg_catalog.length(subject_role_snapshot) between 1 and 160
    and branch_name_snapshot=pg_catalog.btrim(branch_name_snapshot) and pg_catalog.length(branch_name_snapshot) between 1 and 120
    and (subject_staff_code_snapshot is null or (subject_staff_code_snapshot=pg_catalog.btrim(subject_staff_code_snapshot) and pg_catalog.length(subject_staff_code_snapshot) between 1 and 32))
  )
);

create unique index annual_evaluations_supervisor_year_key
  on public.annual_evaluations(organization_id,branch_id,supervisor_user_id,evaluation_year)
  where subject_type='supervisor';
create unique index annual_evaluations_employee_year_key
  on public.annual_evaluations(organization_id,branch_id,operational_staff_id,evaluation_year)
  where subject_type='employee';
create index annual_evaluations_history_idx
  on public.annual_evaluations(organization_id,evaluation_year desc,branch_id,state,updated_at desc);

create table public.annual_evaluation_scores (
  evaluation_id uuid not null references public.annual_evaluations(id) on delete cascade,
  criterion_key text not null,
  score smallint not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key(evaluation_id,criterion_key),
  constraint annual_evaluation_scores_key_check check(criterion_key in(
    'work_rules_procedures','work_methods','required_standard','required_time','work_pressure','discipline',
    'initiative_creativity','works_without_supervision','work_improvement','accepts_direction','cooperation',
    'greater_responsibility','sound_decisions','adaptability','company_loyalty','company_property',
    'company_policies','respect','appearance','personal_behaviour'
  )),
  constraint annual_evaluation_scores_score_check check(score between 1 and 5)
);

alter table public.annual_evaluations enable row level security;
alter table public.annual_evaluation_scores enable row level security;
revoke all on public.annual_evaluations,public.annual_evaluation_scores from public,anon,authenticated,service_role;

create trigger annual_evaluations_set_updated_at before update on public.annual_evaluations
for each row execute function private.set_updated_at();
create trigger annual_evaluation_scores_set_updated_at before update on public.annual_evaluation_scores
for each row execute function private.set_updated_at();

create function private.annual_evaluation_scores(payload jsonb)
returns table(criterion_key text,score smallint)
language plpgsql security invoker set search_path='' as $$
declare item jsonb; clean_key text; raw_score text;
begin
  if payload is null or pg_catalog.jsonb_typeof(payload)<>'array' or pg_catalog.jsonb_array_length(payload)>20
  then raise exception 'invalid annual evaluation scores' using errcode='22023'; end if;
  if (select count(*) from pg_catalog.jsonb_array_elements(payload))
    <> (select count(distinct value->>'criterion_key') from pg_catalog.jsonb_array_elements(payload))
  then raise exception 'duplicate annual evaluation criterion' using errcode='23505'; end if;
  for item in select value from pg_catalog.jsonb_array_elements(payload) loop
    if (select count(*) from pg_catalog.jsonb_object_keys(item))<>2 then
      raise exception 'invalid annual evaluation scores' using errcode='22023';
    end if;
    clean_key:=item->>'criterion_key'; raw_score:=item->>'score';
    if clean_key is null or clean_key not in(
      'work_rules_procedures','work_methods','required_standard','required_time','work_pressure','discipline',
      'initiative_creativity','works_without_supervision','work_improvement','accepts_direction','cooperation',
      'greater_responsibility','sound_decisions','adaptability','company_loyalty','company_property',
      'company_policies','respect','appearance','personal_behaviour'
    ) or raw_score is null or raw_score!~'^[1-5]$'
    then raise exception 'invalid annual evaluation score' using errcode='22023'; end if;
    criterion_key:=clean_key;score:=raw_score::smallint;return next;
  end loop;
end $$;

create function private.annual_evaluation_json(target_id uuid)
returns jsonb language sql stable security invoker set search_path='' as $$
select pg_catalog.jsonb_build_object(
  'id',evaluation.id,'organization_id',evaluation.organization_id,'branch_id',evaluation.branch_id,
  'evaluation_year',evaluation.evaluation_year,'subject_type',evaluation.subject_type,
  'supervisor_user_id',evaluation.supervisor_user_id,'operational_staff_id',evaluation.operational_staff_id,
  'state',evaluation.state,'revision',evaluation.revision,'evaluator_user_id',evaluation.evaluator_user_id,
  'evaluator_name_snapshot',evaluation.evaluator_name_snapshot,'subject_name_snapshot',evaluation.subject_name_snapshot,
  'subject_role_snapshot',evaluation.subject_role_snapshot,'subject_staff_code_snapshot',evaluation.subject_staff_code_snapshot,
  'branch_name_snapshot',evaluation.branch_name_snapshot,'total_score',evaluation.total_score,
  'created_at',evaluation.created_at,'updated_at',evaluation.updated_at,'submitted_at',evaluation.submitted_at,
  'scores',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('criterion_key',score.criterion_key,'score',score.score)
    order by pg_catalog.array_position(array[
      'work_rules_procedures','work_methods','required_standard','required_time','work_pressure','discipline',
      'initiative_creativity','works_without_supervision','work_improvement','accepts_direction','cooperation',
      'greater_responsibility','sound_decisions','adaptability','company_loyalty','company_property',
      'company_policies','respect','appearance','personal_behaviour'
    ],score.criterion_key)) from public.annual_evaluation_scores score where score.evaluation_id=evaluation.id),'[]'::jsonb)
) from public.annual_evaluations evaluation where evaluation.id=target_id
$$;

create function private.prevent_submitted_annual_evaluation_mutation()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if old.state='submitted' then raise exception 'submitted annual evaluation is immutable' using errcode='55000'; end if;
  if tg_op='DELETE' then return old; end if;return new;
end $$;
create function private.prevent_submitted_annual_score_mutation()
returns trigger language plpgsql security definer set search_path='' as $$
declare target_evaluation_id uuid:=case when tg_op='DELETE'then old.evaluation_id else new.evaluation_id end;
begin
  if exists(select 1 from public.annual_evaluations evaluation where evaluation.id=target_evaluation_id and evaluation.state='submitted')
  then raise exception 'submitted annual evaluation is immutable' using errcode='55000'; end if;
  if tg_op='DELETE' then return old; end if;return new;
end $$;
create trigger annual_evaluations_submitted_immutable before update or delete on public.annual_evaluations
for each row execute function private.prevent_submitted_annual_evaluation_mutation();
create trigger annual_evaluation_scores_submitted_immutable before insert or update or delete on public.annual_evaluation_scores
for each row execute function private.prevent_submitted_annual_score_mutation();

create function public.get_managed_annual_evaluation_workspace(
  p_actor_user_id uuid,p_organization_id uuid,p_evaluation_year integer,p_branch_id uuid default null,
  p_subject_type text default null,p_subject_id uuid default null,p_state text default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare current_id uuid;
begin
  if not private.actor_manages_active_organization(p_actor_user_id,p_organization_id)
    or p_evaluation_year not between 2000 and 2200
    or (p_subject_type is not null and p_subject_type not in('supervisor','employee'))
    or (p_state is not null and p_state not in('draft','submitted'))
    or ((p_subject_type is null)<>(p_subject_id is null))
    or (p_branch_id is not null and not exists(select 1 from public.branches branch where branch.id=p_branch_id and branch.organization_id=p_organization_id and branch.active))
  then raise exception 'annual evaluation access denied' using errcode='42501'; end if;
  if p_subject_id is not null then
    select evaluation.id into current_id from public.annual_evaluations evaluation
    where evaluation.organization_id=p_organization_id and evaluation.evaluation_year=p_evaluation_year
      and (p_branch_id is null or evaluation.branch_id=p_branch_id)
      and ((p_subject_type='supervisor' and evaluation.supervisor_user_id=p_subject_id)
        or (p_subject_type='employee' and evaluation.operational_staff_id=p_subject_id));
  end if;
  return pg_catalog.jsonb_build_object(
    'subjects',coalesce((
      select pg_catalog.jsonb_agg(subject order by subject->>'branch_name',subject->>'subject_name') from(
        select pg_catalog.jsonb_build_object('subject_type','supervisor','subject_id',membership.user_id,
          'supervisor_user_id',membership.user_id,'operational_staff_id',null,'subject_name',coalesce(profile.full_name,'Supervisor'),
          'staff_code',null,'role','Supervisor','branch_id',branch.id,'branch_name',branch.name)subject
        from public.branch_memberships membership join public.branches branch on branch.id=membership.branch_id
        join public.profiles profile on profile.id=membership.user_id
        where branch.organization_id=p_organization_id and branch.active and membership.role='branch_manager' and membership.active
          and profile.disabled_at is null and (p_branch_id is null or branch.id=p_branch_id)
        union all
        select pg_catalog.jsonb_build_object('subject_type','employee','subject_id',staff.id,
          'supervisor_user_id',null,'operational_staff_id',staff.id,'subject_name',staff.display_name,
          'staff_code',staff.staff_code,'role','Employee','branch_id',branch.id,'branch_name',branch.name)subject
        from public.operational_staff staff join public.branches branch on branch.id=staff.branch_id and branch.organization_id=staff.organization_id
        where staff.organization_id=p_organization_id and branch.active and staff.employment_status='active'
          and (p_branch_id is null or branch.id=p_branch_id)
      )subjects
    ),'[]'::jsonb),
    'evaluations',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',evaluation.id,'branch_id',evaluation.branch_id,'evaluation_year',evaluation.evaluation_year,
      'subject_type',evaluation.subject_type,'subject_id',coalesce(evaluation.supervisor_user_id,evaluation.operational_staff_id),
      'subject_name_snapshot',evaluation.subject_name_snapshot,'subject_role_snapshot',evaluation.subject_role_snapshot,
      'subject_staff_code_snapshot',evaluation.subject_staff_code_snapshot,'branch_name_snapshot',evaluation.branch_name_snapshot,
      'state',evaluation.state,'revision',evaluation.revision,'total_score',evaluation.total_score,
      'evaluator_name_snapshot',evaluation.evaluator_name_snapshot,'updated_at',evaluation.updated_at,'submitted_at',evaluation.submitted_at
    )order by evaluation.evaluation_year desc,evaluation.updated_at desc)from public.annual_evaluations evaluation
      where evaluation.organization_id=p_organization_id and evaluation.evaluation_year=p_evaluation_year
        and (p_branch_id is null or evaluation.branch_id=p_branch_id)
        and (p_subject_type is null or evaluation.subject_type=p_subject_type)
        and (p_subject_id is null or coalesce(evaluation.supervisor_user_id,evaluation.operational_staff_id)=p_subject_id)
        and (p_state is null or evaluation.state=p_state)),'[]'::jsonb),
    'current',case when current_id is null then null else private.annual_evaluation_json(current_id)end
  );
end $$;

create function public.get_managed_annual_evaluation_detail(p_actor_user_id uuid,p_organization_id uuid,p_evaluation_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
  if not private.actor_manages_active_organization(p_actor_user_id,p_organization_id)then raise exception 'annual evaluation access denied'using errcode='42501';end if;
  select private.annual_evaluation_json(evaluation.id)into result from public.annual_evaluations evaluation
  where evaluation.id=p_evaluation_id and evaluation.organization_id=p_organization_id;
  if result is null then raise exception 'annual evaluation access denied'using errcode='42501';end if;return result;
end $$;

create function public.save_managed_annual_evaluation_draft(
  p_actor_user_id uuid,p_organization_id uuid,p_branch_id uuid,p_evaluation_year integer,p_subject_type text,
  p_supervisor_user_id uuid,p_operational_staff_id uuid,p_expected_revision bigint,p_scores jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare evaluation public.annual_evaluations%rowtype;actor_name text;subject_name text;subject_role text;staff_code text;branch_name text;subject_id uuid;
begin
  if not private.actor_manages_active_organization(p_actor_user_id,p_organization_id)or p_evaluation_year not between 2000 and 2200
    or p_subject_type not in('supervisor','employee')or p_expected_revision<0
    or (p_subject_type='supervisor'and(p_supervisor_user_id is null or p_operational_staff_id is not null))
    or (p_subject_type='employee'and(p_operational_staff_id is null or p_supervisor_user_id is not null))
  then raise exception 'annual evaluation access denied'using errcode='42501';end if;
  perform 1 from private.annual_evaluation_scores(p_scores);
  select profile.full_name into actor_name from public.profiles profile where profile.id=p_actor_user_id and profile.disabled_at is null;
  select branch.name into branch_name from public.branches branch where branch.id=p_branch_id and branch.organization_id=p_organization_id and branch.active;
  if p_subject_type='supervisor'then
    select coalesce(profile.full_name,'Supervisor'),'Supervisor'into subject_name,subject_role
    from public.branch_memberships membership join public.profiles profile on profile.id=membership.user_id
    where membership.branch_id=p_branch_id and membership.user_id=p_supervisor_user_id and membership.role='branch_manager'and membership.active and profile.disabled_at is null;
    subject_id:=p_supervisor_user_id;
  else
    select staff.display_name,'Employee',staff.staff_code into subject_name,subject_role,staff_code from public.operational_staff staff
    where staff.id=p_operational_staff_id and staff.organization_id=p_organization_id and staff.branch_id=p_branch_id and staff.employment_status='active';
    subject_id:=p_operational_staff_id;
  end if;
  if actor_name is null or branch_name is null or subject_name is null then raise exception 'annual evaluation access denied'using errcode='42501';end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_organization_id::text||':'||p_branch_id::text||':'||p_subject_type||':'||subject_id::text||':'||p_evaluation_year::text,0));
  select*into evaluation from public.annual_evaluations existing where existing.organization_id=p_organization_id and existing.branch_id=p_branch_id
    and existing.evaluation_year=p_evaluation_year and ((p_subject_type='supervisor'and existing.supervisor_user_id=p_supervisor_user_id)or(p_subject_type='employee'and existing.operational_staff_id=p_operational_staff_id))for update;
  if evaluation.id is null then
    if p_expected_revision<>0 then raise exception 'annual evaluation changed'using errcode='40001';end if;
    insert into public.annual_evaluations(organization_id,branch_id,evaluation_year,subject_type,supervisor_user_id,operational_staff_id,
      evaluator_user_id,evaluator_name_snapshot,subject_name_snapshot,subject_role_snapshot,subject_staff_code_snapshot,branch_name_snapshot,revision)
    values(p_organization_id,p_branch_id,p_evaluation_year,p_subject_type,p_supervisor_user_id,p_operational_staff_id,p_actor_user_id,
      actor_name,subject_name,subject_role,staff_code,branch_name,1)returning*into evaluation;
  else
    if evaluation.state='submitted'then raise exception 'annual evaluation submitted'using errcode='55000';end if;
    if evaluation.revision<>p_expected_revision then raise exception 'annual evaluation changed'using errcode='40001';end if;
    update public.annual_evaluations set evaluator_user_id=p_actor_user_id,evaluator_name_snapshot=actor_name,revision=revision+1
      where id=evaluation.id returning*into evaluation;
  end if;
  delete from public.annual_evaluation_scores where evaluation_id=evaluation.id;
  insert into public.annual_evaluation_scores(evaluation_id,criterion_key,score)
    select evaluation.id,parsed.criterion_key,parsed.score from private.annual_evaluation_scores(p_scores)parsed;
  update public.annual_evaluations set total_score=case when(select count(*)from public.annual_evaluation_scores where evaluation_id=evaluation.id)=20
    then(select sum(score)from public.annual_evaluation_scores where evaluation_id=evaluation.id)else null end where id=evaluation.id;
  return private.annual_evaluation_json(evaluation.id);
end $$;

create function public.submit_managed_annual_evaluation(
  p_actor_user_id uuid,p_organization_id uuid,p_evaluation_id uuid,p_expected_revision bigint
) returns jsonb language plpgsql security definer set search_path='' as $$
declare evaluation public.annual_evaluations%rowtype;actor_name text;score_count integer;score_total integer;
begin
  if not private.actor_manages_active_organization(p_actor_user_id,p_organization_id)then raise exception 'annual evaluation access denied'using errcode='42501';end if;
  select*into evaluation from public.annual_evaluations existing where existing.id=p_evaluation_id and existing.organization_id=p_organization_id for update;
  if evaluation.id is null then raise exception 'annual evaluation access denied'using errcode='42501';end if;
  if evaluation.state='submitted'then return private.annual_evaluation_json(evaluation.id);end if;
  if evaluation.revision<>p_expected_revision then raise exception 'annual evaluation changed'using errcode='40001';end if;
  select count(*),sum(score)into score_count,score_total from public.annual_evaluation_scores where evaluation_id=evaluation.id;
  if score_count<>20 then raise exception 'annual evaluation incomplete'using errcode='23514';end if;
  select profile.full_name into actor_name from public.profiles profile where profile.id=p_actor_user_id and profile.disabled_at is null;
  if actor_name is null then raise exception 'annual evaluation access denied'using errcode='42501';end if;
  update public.annual_evaluations set state='submitted',evaluator_user_id=p_actor_user_id,evaluator_name_snapshot=actor_name,
    total_score=score_total,submitted_at=now(),revision=revision+1 where id=evaluation.id returning*into evaluation;
  return private.annual_evaluation_json(evaluation.id);
end $$;

revoke all on function private.annual_evaluation_scores(jsonb),private.annual_evaluation_json(uuid),
 private.prevent_submitted_annual_evaluation_mutation(),private.prevent_submitted_annual_score_mutation() from public,anon,authenticated,service_role;
revoke all on function public.get_managed_annual_evaluation_workspace(uuid,uuid,integer,uuid,text,uuid,text),
 public.get_managed_annual_evaluation_detail(uuid,uuid,uuid),
 public.save_managed_annual_evaluation_draft(uuid,uuid,uuid,integer,text,uuid,uuid,bigint,jsonb),
 public.submit_managed_annual_evaluation(uuid,uuid,uuid,bigint) from public,anon,authenticated;
grant execute on function public.get_managed_annual_evaluation_workspace(uuid,uuid,integer,uuid,text,uuid,text),
 public.get_managed_annual_evaluation_detail(uuid,uuid,uuid),
 public.save_managed_annual_evaluation_draft(uuid,uuid,uuid,integer,text,uuid,uuid,bigint,jsonb),
 public.submit_managed_annual_evaluation(uuid,uuid,uuid,bigint) to service_role;
