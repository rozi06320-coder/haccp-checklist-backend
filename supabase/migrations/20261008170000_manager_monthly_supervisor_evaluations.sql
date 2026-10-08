-- Manager-owned monthly evaluations for active Supervisors and Training Supervisors.
-- Branch attribution is resolved server-side and is never part of evaluation identity.

create table public.manager_monthly_supervisor_evaluation_templates (
  version integer primary key,
  name text not null,
  active boolean not null default true,
  effective_from date not null,
  effective_to date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint manager_monthly_supervisor_templates_version_check check(version > 0),
  constraint manager_monthly_supervisor_templates_name_check check(
    name = pg_catalog.btrim(name) and pg_catalog.length(name) between 1 and 120
  ),
  constraint manager_monthly_supervisor_templates_dates_check check(
    effective_from = pg_catalog.date_trunc('month', effective_from)::date
    and (effective_to is null or (
      effective_to = pg_catalog.date_trunc('month', effective_to)::date
      and effective_to >= effective_from
    ))
  )
);

create table public.manager_monthly_supervisor_evaluation_criteria (
  id uuid primary key default gen_random_uuid(),
  template_version integer not null references public.manager_monthly_supervisor_evaluation_templates(version) on delete restrict,
  criterion_key text not null,
  title_en text not null,
  title_ar text not null,
  weight numeric(8,2) not null,
  max_score numeric(8,2) not null,
  display_order integer not null,
  active boolean not null default true,
  effective_from date not null,
  effective_to date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint manager_monthly_supervisor_criteria_template_key unique(template_version, criterion_key),
  constraint manager_monthly_supervisor_criteria_template_order unique(template_version, display_order),
  constraint manager_monthly_supervisor_criteria_key_check check(
    criterion_key = pg_catalog.btrim(criterion_key)
    and criterion_key ~ '^[a-z0-9]+(?:_[a-z0-9]+)*$'
    and pg_catalog.length(criterion_key) between 1 and 80
  ),
  constraint manager_monthly_supervisor_criteria_titles_check check(
    title_en = pg_catalog.btrim(title_en) and pg_catalog.length(title_en) between 1 and 160
    and title_ar = pg_catalog.btrim(title_ar) and pg_catalog.length(title_ar) between 1 and 160
  ),
  constraint manager_monthly_supervisor_criteria_weight_check check(weight > 0),
  constraint manager_monthly_supervisor_criteria_max_check check(max_score > 0),
  constraint manager_monthly_supervisor_criteria_order_check check(display_order > 0),
  constraint manager_monthly_supervisor_criteria_dates_check check(
    effective_from = pg_catalog.date_trunc('month', effective_from)::date
    and (effective_to is null or (
      effective_to = pg_catalog.date_trunc('month', effective_to)::date
      and effective_to >= effective_from
    ))
  )
);

insert into public.manager_monthly_supervisor_evaluation_templates(version,name,active,effective_from)
values(1,'Manager Monthly Supervisor Evaluation',true,date '2026-10-01');

insert into public.manager_monthly_supervisor_evaluation_criteria(
  template_version,criterion_key,title_en,title_ar,weight,max_score,display_order,active,effective_from
) values
  (1,'leadership','Leadership','القيادة',1,5,1,true,date '2026-10-01'),
  (1,'team_management','Team Management','إدارة الفريق',1,5,2,true,date '2026-10-01'),
  (1,'communication','Communication','التواصل',1,5,3,true,date '2026-10-01'),
  (1,'operational_control','Operational Control','الرقابة التشغيلية',1,5,4,true,date '2026-10-01'),
  (1,'hygiene_food_safety','Hygiene & Food Safety','النظافة وسلامة الغذاء',1,5,5,true,date '2026-10-01'),
  (1,'cash_sales_control','Cash & Sales Control','الرقابة على النقد والمبيعات',1,5,6,true,date '2026-10-01'),
  (1,'compliance_documentation','Compliance & Documentation','الامتثال والتوثيق',1,5,7,true,date '2026-10-01'),
  (1,'problem_solving','Problem Solving','حل المشكلات',1,5,8,true,date '2026-10-01'),
  (1,'staff_development','Staff Development','تطوير الموظفين',1,5,9,true,date '2026-10-01'),
  (1,'attendance_reliability','Attendance & Reliability','الحضور والموثوقية',1,5,10,true,date '2026-10-01');

create table public.manager_monthly_supervisor_evaluations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  supervisor_user_id uuid not null,
  subject_type text not null,
  evaluation_month date not null,
  branch_id uuid not null,
  branch_name_snapshot text not null,
  supervisor_name_snapshot text not null,
  supervisor_role_snapshot text not null,
  evaluator_user_id uuid not null references auth.users(id) on delete restrict,
  evaluator_name_snapshot text not null,
  status text not null default 'draft',
  revision bigint not null default 0,
  template_version integer not null references public.manager_monthly_supervisor_evaluation_templates(version) on delete restrict,
  total_score numeric(10,2),
  max_score numeric(10,2),
  percentage numeric(6,2),
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint manager_monthly_supervisor_evaluations_identity_key unique(organization_id,supervisor_user_id,evaluation_month),
  constraint manager_monthly_supervisor_evaluations_branch_scope_fkey foreign key(branch_id,organization_id)
    references public.branches(id,organization_id) on delete restrict,
  constraint manager_monthly_supervisor_evaluations_subject_type_check check(subject_type in('supervisor','training_supervisor')),
  constraint manager_monthly_supervisor_evaluations_month_check check(
    evaluation_month = pg_catalog.date_trunc('month',evaluation_month)::date
  ),
  constraint manager_monthly_supervisor_evaluations_status_check check(status in('draft','submitted')),
  constraint manager_monthly_supervisor_evaluations_revision_check check(revision >= 0),
  constraint manager_monthly_supervisor_evaluations_snapshots_check check(
    branch_name_snapshot = pg_catalog.btrim(branch_name_snapshot) and pg_catalog.length(branch_name_snapshot) between 1 and 120
    and supervisor_name_snapshot = pg_catalog.btrim(supervisor_name_snapshot) and pg_catalog.length(supervisor_name_snapshot) between 1 and 120
    and supervisor_role_snapshot = pg_catalog.btrim(supervisor_role_snapshot) and pg_catalog.length(supervisor_role_snapshot) between 1 and 80
    and evaluator_name_snapshot = pg_catalog.btrim(evaluator_name_snapshot) and pg_catalog.length(evaluator_name_snapshot) between 1 and 120
  ),
  constraint manager_monthly_supervisor_evaluations_result_check check(
    (status='draft' and submitted_at is null and total_score is null and max_score is null and percentage is null)
    or (status='submitted' and submitted_at is not null and total_score is not null and max_score is not null
      and percentage is not null and total_score between 0 and max_score and max_score > 0 and percentage between 0 and 100)
  )
);

create index manager_monthly_supervisor_evaluations_month_status_idx
  on public.manager_monthly_supervisor_evaluations(organization_id,evaluation_month,status);
create index manager_monthly_supervisor_evaluations_branch_month_status_idx
  on public.manager_monthly_supervisor_evaluations(organization_id,branch_id,evaluation_month,status);
create index manager_monthly_supervisor_evaluations_subject_month_idx
  on public.manager_monthly_supervisor_evaluations(supervisor_user_id,evaluation_month desc);

create table public.manager_monthly_supervisor_evaluation_scores (
  id uuid primary key default gen_random_uuid(),
  evaluation_id uuid not null references public.manager_monthly_supervisor_evaluations(id) on delete cascade,
  criterion_key text not null,
  criterion_title_en_snapshot text not null,
  criterion_title_ar_snapshot text not null,
  max_score_snapshot numeric(8,2) not null,
  weight_snapshot numeric(8,2) not null,
  rating integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint manager_monthly_supervisor_evaluation_scores_key unique(evaluation_id,criterion_key),
  constraint manager_monthly_supervisor_evaluation_scores_rating_check check(rating is null or rating between 1 and 5),
  constraint manager_monthly_supervisor_evaluation_scores_key_check check(
    criterion_key = pg_catalog.btrim(criterion_key) and pg_catalog.length(criterion_key) between 1 and 80
  ),
  constraint manager_monthly_supervisor_evaluation_scores_snapshot_check check(
    criterion_title_en_snapshot = pg_catalog.btrim(criterion_title_en_snapshot)
      and pg_catalog.length(criterion_title_en_snapshot) between 1 and 160
    and criterion_title_ar_snapshot = pg_catalog.btrim(criterion_title_ar_snapshot)
      and pg_catalog.length(criterion_title_ar_snapshot) between 1 and 160
    and max_score_snapshot > 0 and weight_snapshot > 0
  )
);

create trigger manager_monthly_supervisor_templates_set_updated_at before update
on public.manager_monthly_supervisor_evaluation_templates for each row execute function private.set_updated_at();
create trigger manager_monthly_supervisor_criteria_set_updated_at before update
on public.manager_monthly_supervisor_evaluation_criteria for each row execute function private.set_updated_at();
create trigger manager_monthly_supervisor_evaluations_set_updated_at before update
on public.manager_monthly_supervisor_evaluations for each row execute function private.set_updated_at();
create trigger manager_monthly_supervisor_scores_set_updated_at before update
on public.manager_monthly_supervisor_evaluation_scores for each row execute function private.set_updated_at();

alter table public.manager_monthly_supervisor_evaluation_templates enable row level security;
alter table public.manager_monthly_supervisor_evaluation_criteria enable row level security;
alter table public.manager_monthly_supervisor_evaluations enable row level security;
alter table public.manager_monthly_supervisor_evaluation_scores enable row level security;

revoke all on public.manager_monthly_supervisor_evaluation_templates,
  public.manager_monthly_supervisor_evaluation_criteria,
  public.manager_monthly_supervisor_evaluations,
  public.manager_monthly_supervisor_evaluation_scores
from public,anon,authenticated,service_role;
grant select on public.manager_monthly_supervisor_evaluation_templates,
  public.manager_monthly_supervisor_evaluation_criteria,
  public.manager_monthly_supervisor_evaluations,
  public.manager_monthly_supervisor_evaluation_scores
to service_role;

create function private.prevent_submitted_manager_monthly_supervisor_evaluation_mutation()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if old.status='submitted' then
    raise exception 'submitted monthly supervisor evaluation is immutable' using errcode='55000';
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;

create function private.prevent_submitted_manager_monthly_supervisor_score_mutation()
returns trigger language plpgsql security definer set search_path='' as $$
declare target_evaluation_id uuid:=case when tg_op='DELETE' then old.evaluation_id else new.evaluation_id end;
begin
  if exists(
    select 1 from public.manager_monthly_supervisor_evaluations evaluation
    where evaluation.id=target_evaluation_id and evaluation.status='submitted'
  ) then
    raise exception 'submitted monthly supervisor evaluation is immutable' using errcode='55000';
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;

create trigger manager_monthly_supervisor_evaluations_submitted_immutable
before update or delete on public.manager_monthly_supervisor_evaluations
for each row execute function private.prevent_submitted_manager_monthly_supervisor_evaluation_mutation();
create trigger manager_monthly_supervisor_scores_submitted_immutable
before insert or update or delete on public.manager_monthly_supervisor_evaluation_scores
for each row execute function private.prevent_submitted_manager_monthly_supervisor_score_mutation();

-- The identifier column intentionally holds the canonical subject UUID. For a promoted
-- Supervisor it is auth.users.id; for an active Training Supervisor it is operational_staff.id.
create function private.managed_monthly_supervisor_subjects(
  target_organization_id uuid,
  requested_month date
) returns table(
  subject_id uuid,
  subject_type text,
  supervisor_name text,
  supervisor_role text,
  branch_id uuid,
  branch_name text,
  eligible boolean,
  ineligibility_reason text
)
language sql stable security definer set search_path='' as $$
with bounds as (
  select requested_month as month_start,(requested_month+interval '1 month')::date as month_end
),
supervisor_candidates as (
  select membership.user_id subject_id,'supervisor'::text subject_type,
    coalesce(profile.full_name,'Supervisor') supervisor_name,'Supervisor'::text supervisor_role
  from public.branch_memberships membership
  join public.branches branch on branch.id=membership.branch_id and branch.organization_id=target_organization_id and branch.active
  join public.organizations organization on organization.id=branch.organization_id and organization.active
  join public.profiles profile on profile.id=membership.user_id and profile.disabled_at is null
  where membership.role='branch_manager' and membership.active
  group by membership.user_id,profile.full_name
),
supervisor_history as (
  select candidate.subject_id,pg_catalog.count(distinct assignment.branch_id)::integer branch_count,
    case when pg_catalog.count(distinct assignment.branch_id)=1
      then (pg_catalog.array_agg(distinct assignment.branch_id))[1]
      else null end branch_id
  from supervisor_candidates candidate cross join bounds
  left join public.branch_operational_team_supervisors assignment
    on assignment.organization_id=target_organization_id and assignment.supervisor_user_id=candidate.subject_id
    and assignment.valid_from<bounds.month_end and coalesce(assignment.valid_to,bounds.month_end)>=bounds.month_start
  group by candidate.subject_id
),
supervisor_current as (
  select candidate.subject_id,pg_catalog.count(distinct membership.branch_id)::integer branch_count,
    case when pg_catalog.count(distinct membership.branch_id)=1
      then (pg_catalog.array_agg(distinct membership.branch_id))[1]
      else null end branch_id,
    not exists(
      select 1 from public.account_management_audit_logs audit cross join bounds
      where audit.organization_id=target_organization_id and audit.target_user_id=candidate.subject_id
        and audit.action='branch_assignment_added' and audit.details ? 'from_branch_id'
        and audit.created_at>=bounds.month_start and audit.created_at<bounds.month_end
    ) no_transfer_in_month
  from supervisor_candidates candidate
  join public.branch_memberships membership on membership.user_id=candidate.subject_id and membership.role='branch_manager' and membership.active
  join public.branches branch on branch.id=membership.branch_id and branch.organization_id=target_organization_id and branch.active
  group by candidate.subject_id
),
resolved_supervisors as (
  select candidate.*,case
      when history.branch_count=1 then history.branch_id
      when history.branch_count=0 and requested_month=pg_catalog.date_trunc('month',current_date)::date
        and current_scope.branch_count=1 and current_scope.no_transfer_in_month then current_scope.branch_id
      else null end resolved_branch_id,
    case
      when history.branch_count>1 then 'ambiguous_branch_history'
      when history.branch_count=0 and requested_month<>pg_catalog.date_trunc('month',current_date)::date then 'historical_branch_unavailable'
      when history.branch_count=0 and (current_scope.branch_count<>1 or not current_scope.no_transfer_in_month) then 'ambiguous_branch_history'
      else null end reason
  from supervisor_candidates candidate
  join supervisor_history history on history.subject_id=candidate.subject_id
  join supervisor_current current_scope on current_scope.subject_id=candidate.subject_id
),
training_candidates as (
  select staff.id subject_id,'training_supervisor'::text subject_type,staff.display_name supervisor_name,
    'Training Supervisor'::text supervisor_role
  from public.operational_staff_supervisor_training training
  join public.operational_staff staff on staff.id=training.operational_staff_id
    and staff.organization_id=training.organization_id and staff.employment_status='active'
  join public.organizations organization on organization.id=staff.organization_id and organization.active
  where training.organization_id=target_organization_id and training.status='training'
),
training_history as (
  select candidate.subject_id,pg_catalog.count(distinct assignment.branch_id)::integer branch_count,
    case when pg_catalog.count(distinct assignment.branch_id)=1
      then (pg_catalog.array_agg(distinct assignment.branch_id))[1]
      else null end branch_id
  from training_candidates candidate cross join bounds
  left join public.operational_staff_assignments assignment
    on assignment.organization_id=target_organization_id and assignment.operational_staff_id=candidate.subject_id
    and assignment.valid_from<bounds.month_end and coalesce(assignment.valid_to,bounds.month_end)>=bounds.month_start
  group by candidate.subject_id
),
resolved_training as (
  select candidate.*,case when history.branch_count=1 then history.branch_id else null end resolved_branch_id,
    case when history.branch_count>1 then 'ambiguous_branch_history' else 'historical_branch_unavailable' end reason
  from training_candidates candidate join training_history history on history.subject_id=candidate.subject_id
)
select resolved.subject_id,resolved.subject_type,resolved.supervisor_name,resolved.supervisor_role,
  case when branch.id is null then null else resolved.resolved_branch_id end,branch.name,branch.id is not null,
  case when branch.id is null then coalesce(resolved.reason,'historical_branch_unavailable') else null end
from (
  select subject_id,subject_type,supervisor_name,supervisor_role,resolved_branch_id,reason from resolved_supervisors
  union all
  select subject_id,subject_type,supervisor_name,supervisor_role,resolved_branch_id,reason from resolved_training
) resolved
left join public.branches branch on branch.id=resolved.resolved_branch_id and branch.organization_id=target_organization_id and branch.active
order by pg_catalog.lower(resolved.supervisor_name),resolved.subject_type,resolved.subject_id
$$;

create function private.manager_monthly_supervisor_template_version(requested_month date)
returns integer language sql stable security definer set search_path='' as $$
  select template.version
  from public.manager_monthly_supervisor_evaluation_templates template
  where template.active and template.effective_from<=requested_month
    and (template.effective_to is null or template.effective_to>=requested_month)
  order by template.version desc limit 1
$$;

create function private.manager_monthly_supervisor_scores(
  payload jsonb,
  target_template_version integer,
  target_evaluation_month date
) returns table(criterion_key text,rating integer)
language plpgsql security definer set search_path='' as $$
declare item jsonb;clean_key text;raw_rating text;
begin
  if payload is null or pg_catalog.jsonb_typeof(payload)<>'array' or pg_catalog.jsonb_array_length(payload)>100 then
    raise exception 'invalid monthly supervisor evaluation scores' using errcode='22023';
  end if;
  if (select count(*) from pg_catalog.jsonb_array_elements(payload))<>
    (select count(distinct value->>'criterion_key') from pg_catalog.jsonb_array_elements(payload)) then
    raise exception 'duplicate monthly supervisor evaluation criterion' using errcode='22023';
  end if;
  for item in select value from pg_catalog.jsonb_array_elements(payload) loop
    if pg_catalog.jsonb_typeof(item)<>'object' then
      raise exception 'invalid monthly supervisor evaluation scores' using errcode='22023';
    end if;
    if (select count(*) from pg_catalog.jsonb_object_keys(item))<>2
      or not(item ? 'criterion_key') or not(item ? 'rating') then
      raise exception 'invalid monthly supervisor evaluation scores' using errcode='22023';
    end if;
    clean_key:=item->>'criterion_key';raw_rating:=item->>'rating';
    if clean_key is null or not exists(
      select 1 from public.manager_monthly_supervisor_evaluation_criteria criterion
      where criterion.template_version=target_template_version and criterion.criterion_key=clean_key and criterion.active
        and criterion.effective_from<=target_evaluation_month
        and (criterion.effective_to is null or criterion.effective_to>=target_evaluation_month)
    ) then raise exception 'unknown monthly supervisor evaluation criterion' using errcode='22023'; end if;
    if pg_catalog.jsonb_typeof(item->'rating')='null' then rating:=null;
    elsif pg_catalog.jsonb_typeof(item->'rating')='number' and raw_rating~'^[1-5]$' then rating:=raw_rating::integer;
    else raise exception 'invalid monthly supervisor evaluation rating' using errcode='22023'; end if;
    criterion_key:=clean_key;return next;
  end loop;
end $$;

create function private.manager_monthly_supervisor_evaluation_json(target_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
select pg_catalog.jsonb_build_object(
  'id',evaluation.id,'organization_id',evaluation.organization_id,
  'supervisor_user_id',evaluation.supervisor_user_id,'subject_type',evaluation.subject_type,
  'evaluation_month',evaluation.evaluation_month,
  'branch',pg_catalog.jsonb_build_object('id',evaluation.branch_id,'name',evaluation.branch_name_snapshot),
  'supervisor',pg_catalog.jsonb_build_object('id',evaluation.supervisor_user_id,'name',evaluation.supervisor_name_snapshot,'role',evaluation.supervisor_role_snapshot,'subject_type',evaluation.subject_type),
  'evaluator',pg_catalog.jsonb_build_object('id',evaluation.evaluator_user_id,'name',evaluation.evaluator_name_snapshot),
  'status',evaluation.status,'revision',evaluation.revision,'template_version',evaluation.template_version,
  'total_score',evaluation.total_score,'max_score',evaluation.max_score,'percentage',evaluation.percentage,
  'created_at',evaluation.created_at,'updated_at',evaluation.updated_at,'submitted_at',evaluation.submitted_at,
  'scores',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'criterion_key',score.criterion_key,'title_en',score.criterion_title_en_snapshot,
    'title_ar',score.criterion_title_ar_snapshot,'max_score',score.max_score_snapshot,
    'weight',score.weight_snapshot,'rating',score.rating
  ) order by criterion.display_order)
  from public.manager_monthly_supervisor_evaluation_scores score
  join public.manager_monthly_supervisor_evaluation_criteria criterion
    on criterion.template_version=evaluation.template_version and criterion.criterion_key=score.criterion_key
  where score.evaluation_id=evaluation.id),'[]'::jsonb)
) from public.manager_monthly_supervisor_evaluations evaluation where evaluation.id=target_id
$$;

create function public.get_managed_monthly_supervisor_evaluation_workspace(
  actor_user_id uuid,
  organization_id uuid,
  evaluation_month date
) returns jsonb language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare template_version integer;result jsonb;
begin
  if actor_user_id is null or organization_id is null or evaluation_month is null
    or evaluation_month<>pg_catalog.date_trunc('month',evaluation_month)::date
    or not coalesce(private.actor_manages_active_organization(actor_user_id,organization_id),false)
  then raise exception 'monthly supervisor evaluation access denied' using errcode='42501'; end if;
  template_version:=private.manager_monthly_supervisor_template_version(evaluation_month);
  if template_version is null then raise exception 'monthly supervisor evaluation template unavailable' using errcode='22023'; end if;
  select pg_catalog.jsonb_build_object(
    'evaluation_month',evaluation_month,
    'template',pg_catalog.jsonb_build_object(
      'version',template.version,'name',template.name,'effective_from',template.effective_from,'effective_to',template.effective_to,
      'criteria',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'criterion_key',criterion.criterion_key,'title_en',criterion.title_en,'title_ar',criterion.title_ar,
        'weight',criterion.weight,'max_score',criterion.max_score,'display_order',criterion.display_order,'active',criterion.active
      ) order by criterion.display_order) from public.manager_monthly_supervisor_evaluation_criteria criterion
        where criterion.template_version=template.version and criterion.active
          and criterion.effective_from<=evaluation_month
          and (criterion.effective_to is null or criterion.effective_to>=evaluation_month)),'[]'::jsonb)
    ),
    'subjects',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'supervisor_user_id',subject.subject_id,'subject_type',subject.subject_type,'name',subject.supervisor_name,
      'role',subject.supervisor_role,'branch',case when subject.branch_id is null then null else pg_catalog.jsonb_build_object('id',subject.branch_id,'name',subject.branch_name)end,
      'eligible',subject.eligible,'ineligibility_reason',subject.ineligibility_reason
    ) order by pg_catalog.lower(subject.supervisor_name),subject.subject_id)
      from private.managed_monthly_supervisor_subjects(organization_id,evaluation_month) subject),'[]'::jsonb),
    'evaluations',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',evaluation.id,'supervisor_user_id',evaluation.supervisor_user_id,'subject_type',evaluation.subject_type,
      'supervisor_name',evaluation.supervisor_name_snapshot,'supervisor_role',evaluation.supervisor_role_snapshot,
      'branch',pg_catalog.jsonb_build_object('id',evaluation.branch_id,'name',evaluation.branch_name_snapshot),
      'status',evaluation.status,'revision',evaluation.revision,'total_score',evaluation.total_score,
      'max_score',evaluation.max_score,'percentage',evaluation.percentage,'updated_at',evaluation.updated_at,'submitted_at',evaluation.submitted_at
    ) order by pg_catalog.lower(evaluation.supervisor_name_snapshot),evaluation.id)
      from public.manager_monthly_supervisor_evaluations evaluation
      where evaluation.organization_id=organization_id and evaluation.evaluation_month=evaluation_month),'[]'::jsonb),
    'summary',pg_catalog.jsonb_build_object(
      'supervisors_total',(select count(*) from private.managed_monthly_supervisor_subjects(organization_id,evaluation_month) subject where subject.eligible),
      'evaluated_count',(select count(*) from public.manager_monthly_supervisor_evaluations evaluation
        where evaluation.organization_id=organization_id and evaluation.evaluation_month=evaluation_month
          and evaluation.status='submitted' and exists(
            select 1 from private.managed_monthly_supervisor_subjects(organization_id,evaluation_month) subject
            where subject.eligible and subject.subject_id=evaluation.supervisor_user_id
          )),
      'pending_count',(select count(*) from private.managed_monthly_supervisor_subjects(organization_id,evaluation_month) subject where subject.eligible)-
        (select count(*) from public.manager_monthly_supervisor_evaluations evaluation
          where evaluation.organization_id=organization_id and evaluation.evaluation_month=evaluation_month
            and evaluation.status='submitted' and exists(
              select 1 from private.managed_monthly_supervisor_subjects(organization_id,evaluation_month) subject
              where subject.eligible and subject.subject_id=evaluation.supervisor_user_id
            )),
      'average_percentage',(select pg_catalog.round(avg(evaluation.percentage)::numeric,2)
        from public.manager_monthly_supervisor_evaluations evaluation
        where evaluation.organization_id=organization_id and evaluation.evaluation_month=evaluation_month
          and evaluation.status='submitted' and exists(
            select 1 from private.managed_monthly_supervisor_subjects(organization_id,evaluation_month) subject
            where subject.eligible and subject.subject_id=evaluation.supervisor_user_id
          ))
    )
  ) into result
  from public.manager_monthly_supervisor_evaluation_templates template where template.version=template_version;
  return result;
end $$;

create function public.get_managed_monthly_supervisor_evaluation_detail(
  actor_user_id uuid,organization_id uuid,evaluation_id uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare result jsonb;
begin
  if actor_user_id is null or organization_id is null or evaluation_id is null
    or not coalesce(private.actor_manages_active_organization(actor_user_id,organization_id),false)
  then raise exception 'monthly supervisor evaluation access denied' using errcode='42501'; end if;
  select private.manager_monthly_supervisor_evaluation_json(evaluation.id) into result
  from public.manager_monthly_supervisor_evaluations evaluation
  where evaluation.id=evaluation_id and evaluation.organization_id=organization_id;
  if result is null then raise exception 'monthly supervisor evaluation access denied' using errcode='42501'; end if;
  return result;
end $$;

create function public.save_managed_monthly_supervisor_evaluation_draft(
  actor_user_id uuid,
  organization_id uuid,
  supervisor_user_id uuid,
  evaluation_month date,
  expected_revision bigint,
  scores jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare evaluation public.manager_monthly_supervisor_evaluations%rowtype;subject record;actor_name text;target_template_version integer;
begin
  if actor_user_id is null or organization_id is null or supervisor_user_id is null
    or evaluation_month is null or evaluation_month<>pg_catalog.date_trunc('month',evaluation_month)::date
    or expected_revision is null or expected_revision<0
    or not coalesce(private.actor_manages_active_organization(actor_user_id,organization_id),false)
  then raise exception 'monthly supervisor evaluation access denied' using errcode='42501'; end if;
  if not exists(select 1 from private.managed_monthly_supervisor_subjects(organization_id,evaluation_month) candidate where candidate.subject_id=supervisor_user_id)
  then raise exception 'monthly supervisor evaluation access denied' using errcode='42501'; end if;
  select * into subject from private.managed_monthly_supervisor_subjects(organization_id,evaluation_month) candidate
    where candidate.subject_id=supervisor_user_id;
  if not subject.eligible then raise exception 'monthly supervisor evaluation scope changed' using errcode='23514'; end if;
  select profile.full_name into actor_name from public.profiles profile where profile.id=actor_user_id and profile.disabled_at is null;
  if actor_name is null then raise exception 'monthly supervisor evaluation access denied' using errcode='42501'; end if;
  target_template_version:=private.manager_monthly_supervisor_template_version(evaluation_month);
  if target_template_version is null then raise exception 'monthly supervisor evaluation template unavailable' using errcode='22023'; end if;
  perform 1 from private.manager_monthly_supervisor_scores(scores,target_template_version,evaluation_month);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(organization_id::text||':'||supervisor_user_id::text||':'||evaluation_month::text,0));
  select existing.* into evaluation from public.manager_monthly_supervisor_evaluations existing
  where existing.organization_id=organization_id and existing.supervisor_user_id=supervisor_user_id
    and existing.evaluation_month=evaluation_month for update;
  if evaluation.id is null then
    if expected_revision<>0 then raise exception 'monthly supervisor evaluation changed' using errcode='40001'; end if;
    insert into public.manager_monthly_supervisor_evaluations(
      organization_id,supervisor_user_id,subject_type,evaluation_month,branch_id,branch_name_snapshot,
      supervisor_name_snapshot,supervisor_role_snapshot,evaluator_user_id,evaluator_name_snapshot,revision,template_version
    ) values(
      organization_id,supervisor_user_id,subject.subject_type,evaluation_month,subject.branch_id,subject.branch_name,
      subject.supervisor_name,subject.supervisor_role,actor_user_id,actor_name,1,target_template_version
    ) returning * into evaluation;
  else
    if evaluation.status='submitted' then raise exception 'monthly supervisor evaluation submitted' using errcode='55000'; end if;
    if evaluation.revision<>expected_revision then raise exception 'monthly supervisor evaluation changed' using errcode='40001'; end if;
    update public.manager_monthly_supervisor_evaluations set evaluator_user_id=actor_user_id,evaluator_name_snapshot=actor_name,
      branch_id=subject.branch_id,branch_name_snapshot=subject.branch_name,supervisor_name_snapshot=subject.supervisor_name,
      supervisor_role_snapshot=subject.supervisor_role,subject_type=subject.subject_type,revision=revision+1
    where id=evaluation.id returning * into evaluation;
  end if;
  delete from public.manager_monthly_supervisor_evaluation_scores where evaluation_id=evaluation.id;
  insert into public.manager_monthly_supervisor_evaluation_scores(
    evaluation_id,criterion_key,criterion_title_en_snapshot,criterion_title_ar_snapshot,max_score_snapshot,weight_snapshot,rating
  ) select evaluation.id,criterion.criterion_key,criterion.title_en,criterion.title_ar,criterion.max_score,criterion.weight,parsed.rating
    from private.manager_monthly_supervisor_scores(scores,evaluation.template_version,evaluation.evaluation_month) parsed
    join public.manager_monthly_supervisor_evaluation_criteria criterion
      on criterion.template_version=evaluation.template_version and criterion.criterion_key=parsed.criterion_key
      and criterion.active and criterion.effective_from<=evaluation.evaluation_month
      and (criterion.effective_to is null or criterion.effective_to>=evaluation.evaluation_month);
  return private.manager_monthly_supervisor_evaluation_json(evaluation.id);
end $$;

create function public.submit_managed_monthly_supervisor_evaluation(
  actor_user_id uuid,
  organization_id uuid,
  evaluation_id uuid,
  expected_revision bigint
) returns jsonb language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare evaluation public.manager_monthly_supervisor_evaluations%rowtype;subject record;actor_name text;
  expected_count integer;score_count integer;computed_total numeric;computed_max numeric;computed_percentage numeric;
begin
  if actor_user_id is null or organization_id is null or evaluation_id is null
    or expected_revision is null or expected_revision<0
    or not coalesce(private.actor_manages_active_organization(actor_user_id,organization_id),false)
  then raise exception 'monthly supervisor evaluation access denied' using errcode='42501'; end if;
  select existing.* into evaluation from public.manager_monthly_supervisor_evaluations existing
  where existing.id=evaluation_id and existing.organization_id=organization_id for update;
  if evaluation.id is null then raise exception 'monthly supervisor evaluation access denied' using errcode='42501'; end if;
  if evaluation.status='submitted' then return private.manager_monthly_supervisor_evaluation_json(evaluation.id); end if;
  if evaluation.revision<>expected_revision then raise exception 'monthly supervisor evaluation changed' using errcode='40001'; end if;
  select * into subject from private.managed_monthly_supervisor_subjects(organization_id,evaluation.evaluation_month) candidate
    where candidate.subject_id=evaluation.supervisor_user_id;
  if subject.subject_id is null then raise exception 'monthly supervisor evaluation access denied' using errcode='42501'; end if;
  if not subject.eligible or subject.branch_id<>evaluation.branch_id or subject.subject_type<>evaluation.subject_type
  then raise exception 'monthly supervisor evaluation scope changed' using errcode='23514'; end if;
  select count(*) into expected_count from public.manager_monthly_supervisor_evaluation_criteria criterion
    where criterion.template_version=evaluation.template_version and criterion.active
      and criterion.effective_from<=evaluation.evaluation_month
      and (criterion.effective_to is null or criterion.effective_to>=evaluation.evaluation_month);
  select count(*),sum(score.rating),sum(score.max_score_snapshot)
    into score_count,computed_total,computed_max
  from public.manager_monthly_supervisor_evaluation_scores score where score.evaluation_id=evaluation.id and score.rating is not null;
  if score_count<>expected_count or exists(
    select 1 from public.manager_monthly_supervisor_evaluation_criteria criterion
    where criterion.template_version=evaluation.template_version and criterion.active
      and criterion.effective_from<=evaluation.evaluation_month
      and (criterion.effective_to is null or criterion.effective_to>=evaluation.evaluation_month) and not exists(
      select 1 from public.manager_monthly_supervisor_evaluation_scores score
      where score.evaluation_id=evaluation.id and score.criterion_key=criterion.criterion_key and score.rating is not null
    )
  ) then raise exception 'monthly supervisor evaluation incomplete' using errcode='22023'; end if;
  computed_percentage:=pg_catalog.round((computed_total/computed_max*100)::numeric,2);
  select profile.full_name into actor_name from public.profiles profile where profile.id=actor_user_id and profile.disabled_at is null;
  if actor_name is null then raise exception 'monthly supervisor evaluation access denied' using errcode='42501'; end if;
  update public.manager_monthly_supervisor_evaluations set status='submitted',evaluator_user_id=actor_user_id,
    evaluator_name_snapshot=actor_name,total_score=computed_total,max_score=computed_max,percentage=computed_percentage,
    submitted_at=now(),revision=revision+1 where id=evaluation.id returning * into evaluation;
  return private.manager_monthly_supervisor_evaluation_json(evaluation.id);
end $$;

revoke all on function private.prevent_submitted_manager_monthly_supervisor_evaluation_mutation(),
  private.prevent_submitted_manager_monthly_supervisor_score_mutation(),
  private.managed_monthly_supervisor_subjects(uuid,date),
  private.manager_monthly_supervisor_template_version(date),
  private.manager_monthly_supervisor_scores(jsonb,integer,date),
  private.manager_monthly_supervisor_evaluation_json(uuid)
from public,anon,authenticated,service_role;

revoke all on function public.get_managed_monthly_supervisor_evaluation_workspace(uuid,uuid,date),
  public.get_managed_monthly_supervisor_evaluation_detail(uuid,uuid,uuid),
  public.save_managed_monthly_supervisor_evaluation_draft(uuid,uuid,uuid,date,bigint,jsonb),
  public.submit_managed_monthly_supervisor_evaluation(uuid,uuid,uuid,bigint)
from public,anon,authenticated;
grant execute on function public.get_managed_monthly_supervisor_evaluation_workspace(uuid,uuid,date),
  public.get_managed_monthly_supervisor_evaluation_detail(uuid,uuid,uuid),
  public.save_managed_monthly_supervisor_evaluation_draft(uuid,uuid,uuid,date,bigint,jsonb),
  public.submit_managed_monthly_supervisor_evaluation(uuid,uuid,uuid,bigint)
to service_role;
