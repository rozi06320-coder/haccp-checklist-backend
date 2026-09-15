-- Migration: 20260916120000_monthly_evaluation_batch_completion.sql
-- Description: Canonical Monthly Evaluation Factor Catalog and Atomic Batch Finalization

-- 1. Canonical Factor Reference Catalog Table
create table if not exists public.operational_staff_monthly_evaluation_factors (
  factor_key text primary key,
  section text not null,
  factor_label text not null,
  display_order integer not null unique,
  created_at timestamptz not null default clock_timestamp(),
  constraint operational_staff_monthly_factors_order_check check (display_order between 1 and 30),
  constraint operational_staff_monthly_factors_key_check check (factor_key = pg_catalog.btrim(factor_key) and length(factor_key) between 1 and 120),
  constraint operational_staff_monthly_factors_section_check check (section = pg_catalog.btrim(section) and length(section) between 1 and 80),
  constraint operational_staff_monthly_factors_label_check check (factor_label = pg_catalog.btrim(factor_label) and length(factor_label) between 1 and 160)
);

-- Seed exactly the canonical 30 factors
insert into public.operational_staff_monthly_evaluation_factors(factor_key, section, factor_label, display_order)
values
  -- Section 1: Performance (1..10)
  ('performance_strong_initiative', 'Performance', 'Strong initiative', 1),
  ('performance_works_well_with_others', 'Performance', 'Works well with others', 2),
  ('performance_leadership', 'Performance', 'Leadership', 3),
  ('performance_stays_focused', 'Performance', 'Stays focused', 4),
  ('performance_takes_instruction', 'Performance', 'Takes instruction', 5),
  ('performance_prioritizes_tasks', 'Performance', 'Prioritizes tasks', 6),
  ('performance_dependable', 'Performance', 'Dependable', 7),
  ('performance_arrives_on_time', 'Performance', 'Arrives on time', 8),
  ('performance_work_quality', 'Performance', 'Work quality', 9),
  ('performance_communication_with_team', 'Performance', 'Communication with team', 10),

  -- Section 2: Job Knowledge (11..20)
  ('job_knowledge_communication_skill', 'Job Knowledge', 'Communication skill', 11),
  ('job_knowledge_menu_knowledge', 'Job Knowledge', 'Menu knowledge', 12),
  ('job_knowledge_customer_relations', 'Job Knowledge', 'Customer relations', 13),
  ('job_knowledge_order_taking_steps', 'Job Knowledge', 'Order taking steps', 14),
  ('job_knowledge_hospitality', 'Job Knowledge', 'Hospitality', 15),
  ('job_knowledge_friendly_to_customer', 'Job Knowledge', 'Friendly to customer', 16),
  ('job_knowledge_upselling', 'Job Knowledge', 'Upselling', 17),
  ('job_knowledge_problem_solving', 'Job Knowledge', 'Problem solving', 18),
  ('job_knowledge_respectful_with_customers', 'Job Knowledge', 'Respectful with customers', 19),
  ('job_knowledge_customer_appreciation', 'Job Knowledge', 'Customer appreciation', 20),

  -- Section 3: Productivity (21..25)
  ('productivity_food_packaging_knowledge', 'Productivity', 'Food packaging knowledge', 21),
  ('productivity_utensils_handling', 'Productivity', 'Utensils handling', 22),
  ('productivity_cleaning_arranging_cashier_area', 'Productivity', 'Cleaning/arranging cashier area', 23),
  ('productivity_pos_knowledge', 'Productivity', 'POS knowledge', 24),
  ('productivity_operating_pos_printers_notifier', 'Productivity', 'Operating POS/printers/notifier', 25),

  -- Section 4: Skills (26..30)
  ('skills_communication_skills', 'Skills', 'Communication skills', 26),
  ('skills_customer_service_skills', 'Skills', 'Customer service skills', 27),
  ('skills_upselling_merchandising', 'Skills', 'Upselling/merchandising', 28),
  ('skills_team_skills', 'Skills', 'Team skills', 29),
  ('skills_leadership_skills', 'Skills', 'Leadership skills', 30)
on conflict (factor_key) do update set
  section = excluded.section,
  factor_label = excluded.factor_label,
  display_order = excluded.display_order;

-- Assert catalog count is exactly 30
do $$
declare factor_count integer;
begin
  select count(*) into factor_count from public.operational_staff_monthly_evaluation_factors;
  if factor_count <> 30 then
    raise exception 'Catalog must contain exactly 30 factors, found %', factor_count;
  end if;
end;
$$;

-- 2. Monthly Evaluation Batch Finalization Table
create table if not exists public.operational_staff_monthly_evaluation_batches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  branch_id uuid not null references public.branches(id) on delete restrict,
  operational_team_id uuid not null references public.branch_operational_teams(id) on delete restrict,
  supervisor_team_id uuid null references public.branch_supervisor_teams(id) on delete restrict,
  evaluation_month date not null,
  total_evaluated_staff integer not null check (total_evaluated_staff > 0),
  completed_by_user_id uuid not null references auth.users(id) on delete restrict,
  completed_at timestamptz not null default clock_timestamp(),
  created_at timestamptz not null default clock_timestamp(),
  constraint operational_staff_monthly_evaluation_batches_team_month_key unique (operational_team_id, evaluation_month),
  constraint operational_staff_monthly_evaluation_batches_month_check check (evaluation_month = date_trunc('month', evaluation_month)::date)
);

-- 3. RLS Policies and Privileges
alter table public.operational_staff_monthly_evaluation_factors enable row level security;
alter table public.operational_staff_monthly_evaluation_batches enable row level security;

revoke all on public.operational_staff_monthly_evaluation_factors from public, anon, authenticated;
revoke all on public.operational_staff_monthly_evaluation_batches from public, anon, authenticated;
grant select on public.operational_staff_monthly_evaluation_factors to service_role;
grant select, insert, update, delete on public.operational_staff_monthly_evaluation_batches to service_role;

-- 4. Catalog Read RPC
create or replace function public.list_operational_staff_monthly_evaluation_factors()
returns table(
  factor_key text,
  section text,
  factor_label text,
  display_order integer
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  select f.factor_key, f.section, f.factor_label, f.display_order
  from public.operational_staff_monthly_evaluation_factors f
  order by f.display_order;
end;
$$;

revoke all on function public.list_operational_staff_monthly_evaluation_factors() from public, anon, authenticated;
grant execute on function public.list_operational_staff_monthly_evaluation_factors() to service_role;

-- 5. Batch Read RPC
create or replace function public.get_operational_staff_monthly_evaluation_batch(
  actor_user_id uuid,
  target_branch_id uuid,
  target_operational_team_id uuid,
  requested_month date
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_team public.branch_operational_teams%rowtype;
  batch_row public.operational_staff_monthly_evaluation_batches%rowtype;
begin
  if requested_month is null or requested_month <> date_trunc('month', requested_month)::date then
    raise exception 'invalid evaluation month' using errcode = '22023';
  end if;

  select * into target_team
  from public.branch_operational_teams
  where id = target_operational_team_id and branch_id = target_branch_id;

  if target_team.id is null then
    raise exception 'operational team not found for branch' using errcode = '42501';
  end if;

  if not private.actor_can_write_operational_team(actor_user_id, target_branch_id, target_operational_team_id) then
    raise exception 'monthly evaluation access denied' using errcode = '42501';
  end if;

  select * into batch_row
  from public.operational_staff_monthly_evaluation_batches
  where operational_team_id = target_operational_team_id
    and evaluation_month = requested_month;

  if batch_row.id is null then
    return null;
  end if;

  return jsonb_build_object(
    'id', batch_row.id,
    'organization_id', batch_row.organization_id,
    'branch_id', batch_row.branch_id,
    'operational_team_id', batch_row.operational_team_id,
    'supervisor_team_id', batch_row.supervisor_team_id,
    'evaluation_month', batch_row.evaluation_month,
    'total_evaluated_staff', batch_row.total_evaluated_staff,
    'completed_by_user_id', batch_row.completed_by_user_id,
    'completed_at', batch_row.completed_at,
    'created_at', batch_row.created_at
  );
end;
$$;

revoke all on function public.get_operational_staff_monthly_evaluation_batch(uuid, uuid, uuid, date) from public, anon, authenticated;
grant execute on function public.get_operational_staff_monthly_evaluation_batch(uuid, uuid, uuid, date) to service_role;

-- 6. Batch Finalization RPC
create or replace function public.finalize_operational_staff_monthly_evaluations(
  actor_user_id uuid,
  target_branch_id uuid,
  target_operational_team_id uuid,
  target_month date
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_team public.branch_operational_teams%rowtype;
  eligible_staff_ids uuid[];
  locked_eval_ids uuid[];
  missing_staff_ids uuid[];
  new_batch public.operational_staff_monthly_evaluation_batches%rowtype;
begin
  -- 1. Validate target_month is first day of Gregorian month
  if target_month is null or target_month <> date_trunc('month', target_month)::date then
    raise exception 'invalid evaluation month' using errcode = '22023';
  end if;

  -- 2 & 3. Resolve operational team and ensure it belongs to target branch
  select * into target_team
  from public.branch_operational_teams
  where id = target_operational_team_id and branch_id = target_branch_id;

  if target_team.id is null then
    raise exception 'operational team not found for branch' using errcode = '42501';
  end if;

  -- 4. Authorize actor for exact operational team
  if not private.actor_can_write_operational_team(actor_user_id, target_branch_id, target_operational_team_id) then
    raise exception 'monthly evaluation access denied' using errcode = '42501';
  end if;

  -- 5. Transaction advisory lock on operational_team_id + month
  perform pg_advisory_xact_lock(hashtext('finalize_monthly_eval:' || target_operational_team_id::text || ':' || target_month::text));

  -- 6. Reject if batch already exists (conflict / already finalized)
  if exists (
    select 1 from public.operational_staff_monthly_evaluation_batches
    where operational_team_id = target_operational_team_id and evaluation_month = target_month
  ) then
    raise exception 'monthly evaluation batch already finalized' using errcode = '23505';
  end if;

  -- 7. Resolve authoritative eligible staff using assignments + active staff
  select coalesce(array_agg(distinct s.id order by s.id), '{}'::uuid[])
  into eligible_staff_ids
  from public.operational_staff s
  join public.operational_staff_assignments a
    on a.operational_staff_id = s.id
  where s.branch_id = target_branch_id
    and s.organization_id = target_team.organization_id
    and s.employment_status = 'active'
    and a.branch_id = target_branch_id
    and a.operational_team_id = target_operational_team_id
    and a.active = true;

  -- 8. Require eligible staff count > 0
  if cardinality(eligible_staff_ids) = 0 then
    raise exception 'no active eligible staff found for team' using errcode = '22023';
  end if;

  -- 9. Lock required evaluation rows safely
  select coalesce(array_agg(sub.id order by sub.id), '{}'::uuid[])
  into locked_eval_ids
  from (
    select e.id
    from public.operational_staff_monthly_evaluations e
    where e.operational_staff_id = any(eligible_staff_ids)
      and e.evaluation_month = target_month
      and e.branch_id = target_branch_id
    for update
  ) sub;

  -- 10. Require evaluation row for every eligible employee for target month
  select coalesce(array_agg(s_id), '{}'::uuid[])
  into missing_staff_ids
  from unnest(eligible_staff_ids) s_id
  where not exists (
    select 1 from public.operational_staff_monthly_evaluations e
    where e.operational_staff_id = s_id
      and e.evaluation_month = target_month
      and e.branch_id = target_branch_id
  );

  if cardinality(missing_staff_ids) > 0 then
    raise exception 'incomplete team monthly evaluations: missing evaluation row for eligible staff' using errcode = '22023';
  end if;

  -- 11-15. Validate all 30 canonical factors from physical scores table
  -- Every factor in catalog must exist with valid section and rating 1..5
  if exists (
    select 1
    from unnest(locked_eval_ids) eval_id
    cross join public.operational_staff_monthly_evaluation_factors f
    left join public.operational_staff_monthly_evaluation_scores sc
      on sc.evaluation_id = eval_id
      and sc.factor_key = f.factor_key
    where sc.id is null
      or sc.rating is null
      or sc.rating < 1
      or sc.rating > 5
      or sc.section <> f.section
  ) then
    raise exception 'incomplete or invalid monthly evaluation factors' using errcode = '22023';
  end if;

  -- No unexpected score factors may exist outside the canonical catalog
  if exists (
    select 1
    from public.operational_staff_monthly_evaluation_scores sc
    where sc.evaluation_id = any(locked_eval_ids)
      and not exists (
        select 1 from public.operational_staff_monthly_evaluation_factors f
        where f.factor_key = sc.factor_key
          and f.section = sc.section
      )
  ) then
    raise exception 'unexpected monthly evaluation factors found' using errcode = '22023';
  end if;

  -- 16-18. Update all eligible evaluation rows to completed and recompute average_score from normalized physical scores
  update public.operational_staff_monthly_evaluations e
  set status = 'completed',
      average_score = (
        select round(avg(sc.rating)::numeric, 2)
        from public.operational_staff_monthly_evaluation_scores sc
        where sc.evaluation_id = e.id
      ),
      updated_at = clock_timestamp()
  where e.id = any(locked_eval_ids);

  -- 19. Insert one batch row
  insert into public.operational_staff_monthly_evaluation_batches (
    organization_id,
    branch_id,
    operational_team_id,
    supervisor_team_id,
    evaluation_month,
    total_evaluated_staff,
    completed_by_user_id,
    completed_at,
    created_at
  )
  values (
    target_team.organization_id,
    target_branch_id,
    target_operational_team_id,
    target_team.legacy_supervisor_team_id,
    target_month,
    cardinality(eligible_staff_ids),
    actor_user_id,
    clock_timestamp(),
    clock_timestamp()
  )
  returning * into new_batch;

  -- 20. Return normalized batch + evaluation summary
  return jsonb_build_object(
    'batch', jsonb_build_object(
      'id', new_batch.id,
      'organization_id', new_batch.organization_id,
      'branch_id', new_batch.branch_id,
      'operational_team_id', new_batch.operational_team_id,
      'supervisor_team_id', new_batch.supervisor_team_id,
      'evaluation_month', new_batch.evaluation_month,
      'total_evaluated_staff', new_batch.total_evaluated_staff,
      'completed_by_user_id', new_batch.completed_by_user_id,
      'completed_at', new_batch.completed_at,
      'created_at', new_batch.created_at
    ),
    'evaluated_staff_ids', eligible_staff_ids,
    'evaluation_ids', locked_eval_ids
  );
end;
$$;

revoke all on function public.finalize_operational_staff_monthly_evaluations(uuid, uuid, uuid, date) from public, anon, authenticated;
grant execute on function public.finalize_operational_staff_monthly_evaluations(uuid, uuid, uuid, date) to service_role;

-- Harden service-role grants on previous monthly evaluation RPCs
revoke all on function public.list_operational_staff_monthly_evaluations(uuid, uuid, date) from public, anon, authenticated;
revoke all on function public.save_operational_staff_monthly_evaluation(uuid, uuid, uuid, date, text, jsonb, text) from public, anon, authenticated;
grant execute on function public.list_operational_staff_monthly_evaluations(uuid, uuid, date) to service_role;
grant execute on function public.save_operational_staff_monthly_evaluation(uuid, uuid, uuid, date, text, jsonb, text) to service_role;

-- Service-role table access for monthly evaluation backend maintenance
grant select, insert, update, delete on public.operational_staff_monthly_evaluations to service_role;
grant select, insert, update, delete on public.operational_staff_monthly_evaluation_scores to service_role;
