-- Annual Evaluation Phase B: new subjects are Supervisors and Training Supervisors.
-- Historical employee evaluations remain readable and valid.

alter table public.annual_evaluations
  drop constraint if exists annual_evaluations_staff_scope_fkey;

alter table public.annual_evaluations
  add constraint annual_evaluations_staff_identity_fkey
  foreign key(operational_staff_id) references public.operational_staff(id) on delete restrict;

alter table public.annual_evaluations
  drop constraint if exists annual_evaluations_subject_check;

alter table public.annual_evaluations
  add constraint annual_evaluations_subject_check check(
    (subject_type='supervisor' and supervisor_user_id is not null and operational_staff_id is null)
    or (subject_type in('training_supervisor','employee') and supervisor_user_id is null and operational_staff_id is not null)
  );

create unique index annual_evaluations_training_supervisor_year_key
  on public.annual_evaluations(organization_id,operational_staff_id,evaluation_year)
  where subject_type='training_supervisor';

create function private.annual_operational_roles_snapshot(candidate text[])
returns text language sql immutable security invoker set search_path='' as $$
  select coalesce(pg_catalog.string_agg(
    case role
      when 'kitchen' then 'Kitchen'
      when 'dispatcher' then 'Order Dispatcher'
      when 'production' then 'Production'
      when 'front_of_house' then 'Front of house'
      when 'cleaner' then 'Cleaner'
      when 'cashier' then 'Cashier'
      else role
    end, ', ' order by ordinality
  ), 'Operational Staff')
  from pg_catalog.unnest(coalesce(candidate, array[]::text[])) with ordinality as roles(role, ordinality)
$$;

create or replace function public.get_managed_annual_evaluation_workspace(
  p_actor_user_id uuid,p_organization_id uuid,p_evaluation_year integer,p_branch_id uuid default null,
  p_subject_type text default null,p_subject_id uuid default null,p_state text default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare current_id uuid;
begin
  if not private.actor_manages_active_organization(p_actor_user_id,p_organization_id)
    or p_evaluation_year not between 2000 and 2200
    or (p_subject_type is not null and p_subject_type not in('supervisor','training_supervisor','employee'))
    or (p_state is not null and p_state not in('draft','submitted'))
    or ((p_subject_type is null)<>(p_subject_id is null))
    or (p_branch_id is not null and not exists(select 1 from public.branches branch where branch.id=p_branch_id and branch.organization_id=p_organization_id and branch.active))
  then raise exception 'annual evaluation access denied' using errcode='42501'; end if;
  if p_subject_id is not null then
    select evaluation.id into current_id from public.annual_evaluations evaluation
    where evaluation.organization_id=p_organization_id and evaluation.evaluation_year=p_evaluation_year
      and (p_branch_id is null or evaluation.branch_id=p_branch_id or (p_subject_type='training_supervisor' and evaluation.subject_type='training_supervisor'))
      and ((p_subject_type='supervisor' and evaluation.subject_type='supervisor' and evaluation.supervisor_user_id=p_subject_id)
        or (p_subject_type='training_supervisor' and evaluation.subject_type='training_supervisor' and evaluation.operational_staff_id=p_subject_id)
        or (p_subject_type='employee' and evaluation.subject_type='employee' and evaluation.operational_staff_id=p_subject_id))
    order by evaluation.updated_at desc
    limit 1;
  end if;
  return pg_catalog.jsonb_build_object(
    'subjects',coalesce((
      select pg_catalog.jsonb_agg(subject order by subject->>'branch_name',subject->>'subject_name') from(
        select pg_catalog.jsonb_build_object('subject_type','supervisor','subject_id',membership.user_id,
          'supervisor_user_id',membership.user_id,'operational_staff_id',null,'subject_name',coalesce(profile.full_name,'Supervisor'),
          'staff_code',null,'role','Supervisor','branch_id',branch.id,'branch_name',branch.name)subject
        from public.branch_memberships membership join public.branches branch on branch.id=membership.branch_id
        join public.organizations organization on organization.id=branch.organization_id
        join public.profiles profile on profile.id=membership.user_id
        where branch.organization_id=p_organization_id and branch.active and organization.active
          and membership.role='branch_manager' and membership.active
          and profile.disabled_at is null and (p_branch_id is null or branch.id=p_branch_id)
        union all
        select pg_catalog.jsonb_build_object('subject_type','training_supervisor','subject_id',staff.id,
          'supervisor_user_id',null,'operational_staff_id',staff.id,'subject_name',staff.display_name,
          'staff_code',staff.staff_code,'role',private.annual_operational_roles_snapshot(assignment.operational_roles),
          'branch_id',branch.id,'branch_name',branch.name)subject
        from public.operational_staff_supervisor_training training
        join public.operational_staff staff on staff.id=training.operational_staff_id and staff.organization_id=training.organization_id
        join public.branches branch on branch.id=staff.branch_id and branch.organization_id=staff.organization_id
        join public.organizations organization on organization.id=staff.organization_id
        join public.operational_staff_assignments assignment on assignment.operational_staff_id=staff.id and assignment.active
        where training.organization_id=p_organization_id and training.status='training'
          and staff.employment_status='active' and branch.active and organization.active
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

create or replace function public.save_managed_annual_evaluation_draft(
  p_actor_user_id uuid,p_organization_id uuid,p_branch_id uuid,p_evaluation_year integer,p_subject_type text,
  p_supervisor_user_id uuid,p_operational_staff_id uuid,p_expected_revision bigint,p_scores jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare evaluation public.annual_evaluations%rowtype;actor_name text;subject_name text;subject_role text;staff_code text;branch_name text;subject_id uuid;
begin
  if not private.actor_manages_active_organization(p_actor_user_id,p_organization_id)or p_evaluation_year not between 2000 and 2200
    or p_subject_type not in('supervisor','training_supervisor','employee')or p_expected_revision<0
    or (p_subject_type='supervisor'and(p_supervisor_user_id is null or p_operational_staff_id is not null))
    or (p_subject_type in('training_supervisor','employee')and(p_operational_staff_id is null or p_supervisor_user_id is not null))
  then raise exception 'annual evaluation access denied'using errcode='42501';end if;
  perform 1 from private.annual_evaluation_scores(p_scores);
  select profile.full_name into actor_name from public.profiles profile where profile.id=p_actor_user_id and profile.disabled_at is null;
  select branch.name into branch_name from public.branches branch where branch.id=p_branch_id and branch.organization_id=p_organization_id and branch.active;
  if p_subject_type='supervisor'then
    select coalesce(profile.full_name,'Supervisor'),'Supervisor'into subject_name,subject_role
    from public.branch_memberships membership join public.profiles profile on profile.id=membership.user_id
    where membership.branch_id=p_branch_id and membership.user_id=p_supervisor_user_id and membership.role='branch_manager'and membership.active and profile.disabled_at is null;
    subject_id:=p_supervisor_user_id;
  elsif p_subject_type='training_supervisor'then
    select existing.* into evaluation from public.annual_evaluations existing
    where existing.organization_id=p_organization_id and existing.evaluation_year=p_evaluation_year
      and existing.subject_type='training_supervisor' and existing.operational_staff_id=p_operational_staff_id
    for update;
    if evaluation.id is null then
      select staff.display_name,private.annual_operational_roles_snapshot(assignment.operational_roles),staff.staff_code
        into subject_name,subject_role,staff_code
      from public.operational_staff_supervisor_training training
      join public.operational_staff staff on staff.id=training.operational_staff_id and staff.organization_id=training.organization_id
      join public.branches branch on branch.id=staff.branch_id and branch.organization_id=staff.organization_id
      join public.organizations organization on organization.id=staff.organization_id
      join public.operational_staff_assignments assignment on assignment.operational_staff_id=staff.id and assignment.active
      where training.organization_id=p_organization_id and training.operational_staff_id=p_operational_staff_id
        and training.status='training' and staff.employment_status='active' and branch.active and organization.active
        and branch.id=p_branch_id;
    else
      subject_name:=evaluation.subject_name_snapshot;subject_role:=evaluation.subject_role_snapshot;staff_code:=evaluation.subject_staff_code_snapshot;
    end if;
    subject_id:=p_operational_staff_id;
  else
    select existing.* into evaluation from public.annual_evaluations existing
    where existing.organization_id=p_organization_id and existing.branch_id=p_branch_id and existing.evaluation_year=p_evaluation_year
      and existing.subject_type='employee' and existing.operational_staff_id=p_operational_staff_id
    for update;
    if evaluation.id is null then raise exception 'annual evaluation access denied'using errcode='42501';end if;
    subject_name:=evaluation.subject_name_snapshot;subject_role:=evaluation.subject_role_snapshot;staff_code:=evaluation.subject_staff_code_snapshot;
    subject_id:=p_operational_staff_id;
  end if;
  if actor_name is null or branch_name is null or subject_name is null then raise exception 'annual evaluation access denied'using errcode='42501';end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_organization_id::text||':'||case when p_subject_type='training_supervisor' then '' else p_branch_id::text end||':'||p_subject_type||':'||subject_id::text||':'||p_evaluation_year::text,0));
  if p_subject_type<>'employee'then
    select*into evaluation from public.annual_evaluations existing where existing.organization_id=p_organization_id
      and existing.evaluation_year=p_evaluation_year
      and ((p_subject_type='supervisor'and existing.branch_id=p_branch_id and existing.supervisor_user_id=p_supervisor_user_id)
        or(p_subject_type='training_supervisor'and existing.subject_type='training_supervisor'and existing.operational_staff_id=p_operational_staff_id))
    for update;
  end if;
  if evaluation.id is null then
    if p_subject_type='employee' or p_expected_revision<>0 then raise exception 'annual evaluation changed'using errcode='40001';end if;
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

revoke all on function private.annual_operational_roles_snapshot(text[]) from public,anon,authenticated,service_role;
