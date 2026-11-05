begin;
select plan(98);

-- 1. Contract & Schema Assertions
select has_column('public','branches','cold_storage_0200_notification_required',
  'branches table has cold_storage_0200_notification_required column');
select has_column('public','branches','foh_opening_included',
  'branches table has foh_opening_included column');
select has_function('private','seed_daily_report_module_applicability',
  array['uuid','uuid','date'],'seed_daily_report_module_applicability helper exists');
select has_function('private','incomplete_branch_tasks_completion_at',
  array['uuid','uuid','date','timestamp with time zone'],'incomplete_branch_tasks_completion_at helper exists');
select ok((select procedure.prosecdef from pg_proc procedure
  where procedure.oid='private.seed_daily_report_module_applicability(uuid,uuid,date)'::regprocedure),
  'private.seed_daily_report_module_applicability is SECURITY DEFINER');
select ok((select procedure.prosecdef from pg_proc procedure
  where procedure.oid='private.incomplete_branch_tasks_completion_at(uuid,uuid,date,timestamptz)'::regprocedure),
  'private.incomplete_branch_tasks_completion_at is SECURITY DEFINER');
select ok(has_function_privilege('postgres',
  'private.cold_storage_closed_slots_for(uuid,date,timestamptz)','execute'),
  'private.cold_storage_closed_slots_for contract is intact and operational');

-- 2. Fixture Setup: Target Org & Branches
insert into public.organizations(id,name,slug,active)
values
  ('a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','Burger Hunch Org','burger-hunch',true),
  ('b0000000-0000-4000-8000-000000000002','Isolated Other Org','other-org',true)
on conflict (id) do nothing;

insert into public.branches(id,organization_id,name,code,timezone,active)
values
  ('03acf21e-fbca-48d0-955f-5e783d43c23e','a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1',
    'Bakery Riyadh','BAK-RUH','Asia/Riyadh',true),
  ('4fafc3dc-269b-4864-8625-5d7a66d39c50','a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1',
    'Central Kitchen','CK-RUH','Asia/Riyadh',true),
  ('dea33e25-4732-4dcf-96db-010ad917c16c','a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1',
    'Burger Hunch and Molt Dubai','BH-DXB','Asia/Dubai',true),
  ('82321e25-25f2-490a-a933-7c15e11c6428','a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1',
    'Burger Hunch Unaiza','BH-UNZ','Asia/Riyadh',true),
  ('b1111111-0000-4000-8000-000000000001','a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1',
    'Control Standard Branch','BH-CTRL','Asia/Riyadh',true),
  ('b2222222-0000-4000-8000-000000000001','b0000000-0000-4000-8000-000000000002',
    'Other Org Branch','OTH-BR','Asia/Riyadh',true)
on conflict (id) do nothing;

-- Clean existing test rows
delete from public.daily_report_module_applicability
where branch_id in (
  '03acf21e-fbca-48d0-955f-5e783d43c23e','4fafc3dc-269b-4864-8625-5d7a66d39c50',
  'dea33e25-4732-4dcf-96db-010ad917c16c','82321e25-25f2-490a-a933-7c15e11c6428',
  'b1111111-0000-4000-8000-000000000001','b2222222-0000-4000-8000-000000000001'
);
delete from public.daily_report_branch_lifecycle
where branch_id in (
  '03acf21e-fbca-48d0-955f-5e783d43c23e','4fafc3dc-269b-4864-8625-5d7a66d39c50',
  'dea33e25-4732-4dcf-96db-010ad917c16c','82321e25-25f2-490a-a933-7c15e11c6428',
  'b1111111-0000-4000-8000-000000000001','b2222222-0000-4000-8000-000000000001'
);

-- Setup Lifecycles from 2026-10-27
insert into public.daily_report_branch_lifecycle(
  organization_id,branch_id,effective_from_business_date,active,timezone
) values
  ('a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','03acf21e-fbca-48d0-955f-5e783d43c23e','2026-10-27',true,'Asia/Riyadh'),
  ('a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','4fafc3dc-269b-4864-8625-5d7a66d39c50','2026-10-27',true,'Asia/Riyadh'),
  ('a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','dea33e25-4732-4dcf-96db-010ad917c16c','2026-10-27',true,'Asia/Dubai'),
  ('a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','82321e25-25f2-490a-a933-7c15e11c6428','2026-10-27',true,'Asia/Riyadh'),
  ('a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','b1111111-0000-4000-8000-000000000001','2026-10-27',true,'Asia/Riyadh'),
  ('b0000000-0000-4000-8000-000000000002','b2222222-0000-4000-8000-000000000001','2026-10-27',true,'Asia/Riyadh');

-- Initial baseline seeding (simulating original 2026-10-27 seed before this migration)
select private.seed_daily_report_module_applicability('a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','03acf21e-fbca-48d0-955f-5e783d43c23e','2026-10-27');
select private.seed_daily_report_module_applicability('a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','4fafc3dc-269b-4864-8625-5d7a66d39c50','2026-10-27');
select private.seed_daily_report_module_applicability('a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','dea33e25-4732-4dcf-96db-010ad917c16c','2026-10-27');
select private.seed_daily_report_module_applicability('a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','82321e25-25f2-490a-a933-7c15e11c6428','2026-10-27');
select private.seed_daily_report_module_applicability('a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','b1111111-0000-4000-8000-000000000001','2026-10-27');
select private.seed_daily_report_module_applicability('b0000000-0000-4000-8000-000000000002','b2222222-0000-4000-8000-000000000001','2026-10-27');

-- Apply Migration Steps
update public.branches
set sales_tracking_percentage_included = false,
    oil_tracking_percentage_included = false
where organization_id = 'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1'::uuid
  and id in ('03acf21e-fbca-48d0-955f-5e783d43c23e'::uuid,'4fafc3dc-269b-4864-8625-5d7a66d39c50'::uuid);

update public.branches
set foh_opening_included = false
where organization_id = 'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1'::uuid
  and id = '4fafc3dc-269b-4864-8625-5d7a66d39c50'::uuid;

update public.branches
set cold_storage_0200_notification_required = false
where organization_id = 'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1'::uuid
  and id in ('dea33e25-4732-4dcf-96db-010ad917c16c'::uuid,'82321e25-25f2-490a-a933-7c15e11c6428'::uuid);

-- Execute Section 3 Transition (Corrects open rows directly from effective_from_business_date)
do $migration_transition$
declare
  v_target record;
  v_current record;
  v_effective_date date;
begin
  for v_target in
    select b.id as branch_id, b.organization_id, b.timezone, m.module_key
    from public.branches b
    cross join (values ('sales_tracking'), ('oil_tracking')) as m(module_key)
    where b.organization_id = 'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1'::uuid
      and b.id in (
        '03acf21e-fbca-48d0-955f-5e783d43c23e'::uuid,
        '4fafc3dc-269b-4864-8625-5d7a66d39c50'::uuid
      )
    union all
    select b.id as branch_id, b.organization_id, b.timezone, 'foh_opening' as module_key
    from public.branches b
    where b.organization_id = 'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1'::uuid
      and b.id = '4fafc3dc-269b-4864-8625-5d7a66d39c50'::uuid
  loop
    select * into v_current
    from public.daily_report_module_applicability
    where branch_id = v_target.branch_id
      and organization_id = v_target.organization_id
      and module_key = v_target.module_key
      and effective_to_business_date is null;

    if v_current.id is not null then
      v_effective_date := v_current.effective_from_business_date;
    else
      v_effective_date := private.phase4a_business_date_at(v_target.timezone, pg_catalog.statement_timestamp());
    end if;

    perform private.record_daily_report_module_applicability(
      v_target.organization_id,
      v_target.branch_id,
      v_target.module_key,
      false,
      v_effective_date,
      null
    );
  end loop;
end
$migration_transition$;

-- 3. Assertions: Branch Table Exemption Flags
select is((select sales_tracking_percentage_included from public.branches where id='03acf21e-fbca-48d0-955f-5e783d43c23e'),
  false,'Bakery Riyadh sales_tracking_percentage_included is false');
select is((select oil_tracking_percentage_included from public.branches where id='03acf21e-fbca-48d0-955f-5e783d43c23e'),
  false,'Bakery Riyadh oil_tracking_percentage_included is false');
select is((select foh_opening_included from public.branches where id='03acf21e-fbca-48d0-955f-5e783d43c23e'),
  true,'Bakery Riyadh foh_opening_included remains default true');
select is((select cold_storage_0200_notification_required from public.branches where id='03acf21e-fbca-48d0-955f-5e783d43c23e'),
  true,'Bakery Riyadh cold_storage_0200_notification_required remains default true');

select is((select sales_tracking_percentage_included from public.branches where id='4fafc3dc-269b-4864-8625-5d7a66d39c50'),
  false,'Central Kitchen sales_tracking_percentage_included is false');
select is((select oil_tracking_percentage_included from public.branches where id='4fafc3dc-269b-4864-8625-5d7a66d39c50'),
  false,'Central Kitchen oil_tracking_percentage_included is false');
select is((select foh_opening_included from public.branches where id='4fafc3dc-269b-4864-8625-5d7a66d39c50'),
  false,'Central Kitchen foh_opening_included is false');
select is((select cold_storage_0200_notification_required from public.branches where id='4fafc3dc-269b-4864-8625-5d7a66d39c50'),
  true,'Central Kitchen cold_storage_0200_notification_required remains default true');

select is((select cold_storage_0200_notification_required from public.branches where id='dea33e25-4732-4dcf-96db-010ad917c16c'),
  false,'Molt Dubai cold_storage_0200_notification_required is false');
select is((select sales_tracking_percentage_included from public.branches where id='dea33e25-4732-4dcf-96db-010ad917c16c'),
  true,'Molt Dubai sales_tracking_percentage_included remains true');
select is((select oil_tracking_percentage_included from public.branches where id='dea33e25-4732-4dcf-96db-010ad917c16c'),
  true,'Molt Dubai oil_tracking_percentage_included remains true');
select is((select foh_opening_included from public.branches where id='dea33e25-4732-4dcf-96db-010ad917c16c'),
  true,'Molt Dubai foh_opening_included remains true');

select is((select cold_storage_0200_notification_required from public.branches where id='82321e25-25f2-490a-a933-7c15e11c6428'),
  false,'Burger Hunch Unaiza cold_storage_0200_notification_required is false');
select is((select sales_tracking_percentage_included from public.branches where id='82321e25-25f2-490a-a933-7c15e11c6428'),
  true,'Burger Hunch Unaiza sales_tracking_percentage_included remains true');
select is((select oil_tracking_percentage_included from public.branches where id='82321e25-25f2-490a-a933-7c15e11c6428'),
  true,'Burger Hunch Unaiza oil_tracking_percentage_included remains true');
select is((select foh_opening_included from public.branches where id='82321e25-25f2-490a-a933-7c15e11c6428'),
  true,'Burger Hunch Unaiza foh_opening_included remains true');

select is((select cold_storage_0200_notification_required from public.branches where id='b1111111-0000-4000-8000-000000000001'),
  true,'Control standard branch cold_storage_0200_notification_required is true');
select is((select foh_opening_included from public.branches where id='b1111111-0000-4000-8000-000000000001'),
  true,'Control standard branch foh_opening_included is true');

-- 4. Date-Effective Applicability Assertions
-- Historical date: 2026-10-27 (the inception date)
select is((select required from public.daily_report_module_applicability
  where branch_id='03acf21e-fbca-48d0-955f-5e783d43c23e' and module_key='sales_tracking'
    and effective_from_business_date<='2026-10-27' and (effective_to_business_date is null or effective_to_business_date>'2026-10-27')),
  false,'Bakery Riyadh sales_tracking is exempt from inception 2026-10-27');
select is((select required from public.daily_report_module_applicability
  where branch_id='03acf21e-fbca-48d0-955f-5e783d43c23e' and module_key='oil_tracking'
    and effective_from_business_date<='2026-10-27' and (effective_to_business_date is null or effective_to_business_date>'2026-10-27')),
  false,'Bakery Riyadh oil_tracking is exempt from inception 2026-10-27');

select is((select required from public.daily_report_module_applicability
  where branch_id='4fafc3dc-269b-4864-8625-5d7a66d39c50' and module_key='sales_tracking'
    and effective_from_business_date<='2026-10-27' and (effective_to_business_date is null or effective_to_business_date>'2026-10-27')),
  false,'Central Kitchen sales_tracking is exempt from inception 2026-10-27');
select is((select required from public.daily_report_module_applicability
  where branch_id='4fafc3dc-269b-4864-8625-5d7a66d39c50' and module_key='oil_tracking'
    and effective_from_business_date<='2026-10-27' and (effective_to_business_date is null or effective_to_business_date>'2026-10-27')),
  false,'Central Kitchen oil_tracking is exempt from inception 2026-10-27');
select is((select required from public.daily_report_module_applicability
  where branch_id='4fafc3dc-269b-4864-8625-5d7a66d39c50' and module_key='foh_opening'
    and effective_from_business_date<='2026-10-27' and (effective_to_business_date is null or effective_to_business_date>'2026-10-27')),
  false,'Central Kitchen foh_opening is exempt from inception 2026-10-27');

-- Current/Future date: 2026-11-05
select is((select required from public.daily_report_module_applicability
  where branch_id='03acf21e-fbca-48d0-955f-5e783d43c23e' and module_key='sales_tracking'
    and effective_from_business_date<='2026-11-05' and (effective_to_business_date is null or effective_to_business_date>'2026-11-05')),
  false,'Bakery Riyadh sales_tracking remains exempt on 2026-11-05');
select is((select required from public.daily_report_module_applicability
  where branch_id='4fafc3dc-269b-4864-8625-5d7a66d39c50' and module_key='foh_opening'
    and effective_from_business_date<='2026-11-05' and (effective_to_business_date is null or effective_to_business_date>'2026-11-05')),
  false,'Central Kitchen foh_opening remains exempt on 2026-11-05');

-- Non-exempt modules on Central Kitchen
select is((select required from public.daily_report_module_applicability
  where branch_id='4fafc3dc-269b-4864-8625-5d7a66d39c50' and module_key='kitchen_opening'
    and effective_from_business_date<='2026-11-05' and (effective_to_business_date is null or effective_to_business_date>'2026-11-05')),
  true,'Central Kitchen kitchen_opening is required');
select is((select required from public.daily_report_module_applicability
  where branch_id='4fafc3dc-269b-4864-8625-5d7a66d39c50' and module_key='cold_storage'
    and effective_from_business_date<='2026-11-05' and (effective_to_business_date is null or effective_to_business_date>'2026-11-05')),
  true,'Central Kitchen cold_storage is required');

-- Exactly 1 active row per module
select is((select count(*)::integer from public.daily_report_module_applicability
  where branch_id='03acf21e-fbca-48d0-955f-5e783d43c23e' and effective_to_business_date is null),
  7,'Bakery Riyadh has exactly 7 active applicability rows');
select is((select count(*)::integer from public.daily_report_module_applicability
  where branch_id='4fafc3dc-269b-4864-8625-5d7a66d39c50' and effective_to_business_date is null),
  7,'Central Kitchen has exactly 7 active applicability rows');
select is((select count(*)::integer from public.daily_report_module_applicability
  where branch_id='dea33e25-4732-4dcf-96db-010ad917c16c' and effective_to_business_date is null),
  7,'Molt Dubai has exactly 7 active applicability rows');
select is((select count(*)::integer from public.daily_report_module_applicability
  where branch_id='82321e25-25f2-490a-a933-7c15e11c6428' and effective_to_business_date is null),
  7,'Burger Hunch Unaiza has exactly 7 active applicability rows');

-- Exactly 1 row returned for historical date 2026-10-28
select is((select count(*)::integer from public.daily_report_module_applicability
  where branch_id='03acf21e-fbca-48d0-955f-5e783d43c23e'
    and effective_from_business_date<='2026-10-28' and (effective_to_business_date is null or effective_to_business_date>'2026-10-28')),
  7,'Bakery Riyadh returns exactly 1 row per module for historical date 2026-10-28');

-- 5. Future Seeding Idempotency & Tenant Safety
insert into public.branches(id,organization_id,name,code,timezone,sales_tracking_percentage_included,oil_tracking_percentage_included,foh_opening_included)
values ('b3333333-0000-4000-8000-000000000001','a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','Future Branch','BH-FUT','Asia/Riyadh',false,false,false)
on conflict (id) do nothing;

select private.seed_daily_report_module_applicability('a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','b3333333-0000-4000-8000-000000000001','2026-11-10');
select is((select required from public.daily_report_module_applicability
  where branch_id='b3333333-0000-4000-8000-000000000001' and module_key='sales_tracking'),
  false,'Future seed honors sales_tracking_percentage_included=false');
select is((select required from public.daily_report_module_applicability
  where branch_id='b3333333-0000-4000-8000-000000000001' and module_key='foh_opening'),
  false,'Future seed honors foh_opening_included=false');
select is((select required from public.daily_report_module_applicability
  where branch_id='b3333333-0000-4000-8000-000000000001' and module_key='kitchen_opening'),
  true,'Future seed keeps kitchen_opening=true');

-- Cross-tenant seed attempt fails
select throws_ok(
  $$select private.seed_daily_report_module_applicability('b0000000-0000-4000-8000-000000000002','b3333333-0000-4000-8000-000000000001','2026-11-10')$$,
  '22023','branch not found for organization',
  'Cross-tenant seed attempt fails closed');

-- 6. Sales Tracking Status Producer RPC Tests (Historical Catch-up & Current)
-- Historical catch-up on 2026-10-28
select is(private.organization_manager_sales_tracking_status(
  'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','03acf21e-fbca-48d0-955f-5e783d43c23e','2026-10-28','2026-10-29 01:00:00+00'),
  'satisfied','Bakery Riyadh sales_tracking on historical catch-up date 2026-10-28 is satisfied');

select is(private.organization_manager_sales_tracking_status(
  'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','4fafc3dc-269b-4864-8625-5d7a66d39c50','2026-10-28','2026-10-29 01:00:00+00'),
  'satisfied','Central Kitchen sales_tracking on historical catch-up date 2026-10-28 is satisfied');

-- Current closed date 2026-11-03
select is(private.organization_manager_sales_tracking_status(
  'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','03acf21e-fbca-48d0-955f-5e783d43c23e','2026-11-03','2026-11-04 01:00:00+00'),
  'satisfied','Bakery Riyadh sales_tracking on 2026-11-03 is satisfied');

select is(private.organization_manager_sales_tracking_status(
  'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','4fafc3dc-269b-4864-8625-5d7a66d39c50','2026-11-03','2026-11-04 01:00:00+00'),
  'satisfied','Central Kitchen sales_tracking on 2026-11-03 is satisfied');

select is(private.organization_manager_sales_tracking_status(
  'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','dea33e25-4732-4dcf-96db-010ad917c16c','2026-11-03','2026-11-04 00:00:00+00'),
  'missing','Molt Dubai unsubmitted sales_tracking on 2026-11-03 evaluates to missing');

select is(private.organization_manager_sales_tracking_status(
  'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','b1111111-0000-4000-8000-000000000001','2026-11-03','2026-11-04 01:00:00+00'),
  'missing','Control branch unsubmitted sales_tracking on 2026-11-03 evaluates to missing');

-- 7. Incomplete Tasks Evaluation Tests (Historical Catch-up & Current)
-- Historical catch-up on 2026-10-28
select is((select module_state from private.incomplete_branch_tasks_completion_at(
  'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','03acf21e-fbca-48d0-955f-5e783d43c23e',
  '2026-10-28','2026-10-29 01:00:00+00') where module_key='oil_tracking'),
  'not_required','Bakery Riyadh oil_tracking on historical date is not_required');

select is((select module_state from private.incomplete_branch_tasks_completion_at(
  'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','4fafc3dc-269b-4864-8625-5d7a66d39c50',
  '2026-10-28','2026-10-29 01:00:00+00') where module_key='oil_tracking'),
  'not_required','Central Kitchen oil_tracking on historical date is not_required');

select is((select module_state from private.incomplete_branch_tasks_completion_at(
  'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','4fafc3dc-269b-4864-8625-5d7a66d39c50',
  '2026-10-28','2026-10-29 01:00:00+00') where module_key='foh_opening'),
  'not_required','Central Kitchen foh_opening on historical date is not_required');

-- Current closed date 2026-11-03
select is((select module_state from private.incomplete_branch_tasks_completion_at(
  'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','03acf21e-fbca-48d0-955f-5e783d43c23e',
  '2026-11-03','2026-11-04 01:00:00+00') where module_key='oil_tracking'),
  'not_required','Bakery Riyadh oil_tracking on 2026-11-03 is not_required');

select is((select module_state from private.incomplete_branch_tasks_completion_at(
  'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','4fafc3dc-269b-4864-8625-5d7a66d39c50',
  '2026-11-03','2026-11-04 01:00:00+00') where module_key='oil_tracking'),
  'not_required','Central Kitchen oil_tracking on 2026-11-03 is not_required');

select is((select module_state from private.incomplete_branch_tasks_completion_at(
  'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','4fafc3dc-269b-4864-8625-5d7a66d39c50',
  '2026-11-03','2026-11-04 01:00:00+00') where module_key='foh_opening'),
  'not_required','Central Kitchen foh_opening on 2026-11-03 is not_required');

select is((select module_state from private.incomplete_branch_tasks_completion_at(
  'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','b1111111-0000-4000-8000-000000000001',
  '2026-11-03','2026-11-04 01:00:00+00') where module_key='foh_opening'),
  'incomplete','Control branch unsubmitted foh_opening evaluates to incomplete');

-- 8. Cold Storage Tests (Zero Submissions, Molt Dubai, Unaiza, and Control)
insert into auth.users(id,email)
values ('fa000000-0000-4000-8000-000000000001','sup@example.com')
on conflict (id) do nothing;
insert into public.profiles(id,full_name)
values ('fa000000-0000-4000-8000-000000000001','Test Supervisor')
on conflict (id) do nothing;

insert into public.branch_cold_storage_equipment(id,organization_id,branch_id,name,equipment_type,active,created_by,created_at)
values
  ('4f000000-0000-4000-8000-000000000001','a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','4fafc3dc-269b-4864-8625-5d7a66d39c50','Walk-in Chiller Central Kitchen','refrigerator',true,'fa000000-0000-4000-8000-000000000001','2026-10-27 00:00:00+00'),
  ('de000000-0000-4000-8000-000000000001','a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','dea33e25-4732-4dcf-96db-010ad917c16c','Walk-in Chiller Dubai','refrigerator',true,'fa000000-0000-4000-8000-000000000001','2026-10-27 00:00:00+00'),
  ('82000000-0000-4000-8000-000000000001','a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','82321e25-25f2-490a-a933-7c15e11c6428','Walk-in Chiller Unaiza','refrigerator',true,'fa000000-0000-4000-8000-000000000001','2026-10-27 00:00:00+00'),
  ('b1000000-0000-4000-8000-000000000001','a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','b1111111-0000-4000-8000-000000000001','Walk-in Chiller Control','refrigerator',true,'fa000000-0000-4000-8000-000000000001','2026-10-27 00:00:00+00')
on conflict (id) do nothing;

-- Scenario A1: No Cold Storage submission when equipment exists -> INCOMPLETE
select is((select module_state from private.incomplete_branch_tasks_completion_at(
  'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','dea33e25-4732-4dcf-96db-010ad917c16c',
  '2026-11-03','2026-11-04 00:00:00+00') where module_key='cold_storage'),
  'incomplete','Cold storage with zero submissions and active equipment evaluates to incomplete');

-- Scenario A2: No Cold Storage submission when NO equipment exists on branch -> UNKNOWN
select is((select module_state from private.incomplete_branch_tasks_completion_at(
  'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','03acf21e-fbca-48d0-955f-5e783d43c23e',
  '2026-11-03','2026-11-04 01:00:00+00') where module_key='cold_storage'),
  'unknown','Cold storage with zero submissions and zero equipment evaluates to unknown');

-- Scenario B: Molt Dubai draft submission with 12:00 and 20:00 submitted, 02:00 omitted
insert into public.cold_storage_submissions(id,organization_id,branch_id,supervisor_user_id,business_date,state,branch_name_snapshot,supervisor_name_snapshot,team_name_snapshot)
values ('de000000-0000-4000-8000-000000000002','a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','dea33e25-4732-4dcf-96db-010ad917c16c','fa000000-0000-4000-8000-000000000001','2026-11-03','draft','Dubai','Supervisor','Team A');

insert into public.cold_storage_equipment(id,submission_id,master_equipment_id,organization_id,branch_id,equipment_id,equipment_name,equipment_type,active)
values ('de000000-0000-4000-8000-000000000003','de000000-0000-4000-8000-000000000002','de000000-0000-4000-8000-000000000001','a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','dea33e25-4732-4dcf-96db-010ad917c16c','EQ1','Walk-in Chiller Dubai','refrigerator',true);

insert into public.cold_storage_readings(submission_id,equipment_id,slot,temperature_c,status,submitted_at)
values
  ('de000000-0000-4000-8000-000000000002','EQ1','12:00',4.0,'pass','2026-11-03 12:30:00+00'),
  ('de000000-0000-4000-8000-000000000002','EQ1','20:00',4.2,'pass','2026-11-03 20:30:00+00');

select is((select module_state from private.incomplete_branch_tasks_completion_at(
  'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','dea33e25-4732-4dcf-96db-010ad917c16c',
  '2026-11-03','2026-11-04 00:00:00+00') where module_key='cold_storage'),
  'completed','Molt Dubai cold_storage with 12:00 and 20:00 completed and 02:00 omitted evaluates to completed');

-- Control branch identical draft missing 02:00 evaluates to incomplete
insert into public.cold_storage_submissions(id,organization_id,branch_id,supervisor_user_id,business_date,state,branch_name_snapshot,supervisor_name_snapshot,team_name_snapshot)
values ('b1000000-0000-4000-8000-000000000002','a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','b1111111-0000-4000-8000-000000000001','fa000000-0000-4000-8000-000000000001','2026-11-03','draft','Control','Supervisor','Team A');

insert into public.cold_storage_equipment(id,submission_id,master_equipment_id,organization_id,branch_id,equipment_id,equipment_name,equipment_type,active)
values ('b1000000-0000-4000-8000-000000000003','b1000000-0000-4000-8000-000000000002','b1000000-0000-4000-8000-000000000001','a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','b1111111-0000-4000-8000-000000000001','EQ1','Walk-in Chiller Control','refrigerator',true);

insert into public.cold_storage_readings(submission_id,equipment_id,slot,temperature_c,status,submitted_at)
values
  ('b1000000-0000-4000-8000-000000000002','EQ1','12:00',4.0,'pass','2026-11-03 12:30:00+00'),
  ('b1000000-0000-4000-8000-000000000002','EQ1','20:00',4.2,'pass','2026-11-03 20:30:00+00');

select is((select module_state from private.incomplete_branch_tasks_completion_at(
  'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','b1111111-0000-4000-8000-000000000001',
  '2026-11-03','2026-11-04 01:00:00+00') where module_key='cold_storage'),
  'incomplete','Control standard branch with draft missing 02:00 evaluates to incomplete');

-- Scenario C: Molt Dubai optional valid 02:00 reading is accepted
insert into public.cold_storage_readings(submission_id,equipment_id,slot,temperature_c,status,submitted_at)
values ('de000000-0000-4000-8000-000000000002','EQ1','02:00',3.9,'pass','2026-11-04 02:15:00+00');

select is((select module_state from private.incomplete_branch_tasks_completion_at(
  'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','dea33e25-4732-4dcf-96db-010ad917c16c',
  '2026-11-03','2026-11-04 04:00:00+00') where module_key='cold_storage'),
  'completed','Molt Dubai cold_storage with valid optional 02:00 reading evaluates to completed');

-- Scenario D: Burger Hunch Unaiza draft with 12:00 & 20:00
insert into public.cold_storage_submissions(id,organization_id,branch_id,supervisor_user_id,business_date,state,branch_name_snapshot,supervisor_name_snapshot,team_name_snapshot)
values ('82000000-0000-4000-8000-000000000002','a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','82321e25-25f2-490a-a933-7c15e11c6428','fa000000-0000-4000-8000-000000000001','2026-11-03','draft','Unaiza','Supervisor','Team A');

insert into public.cold_storage_equipment(id,submission_id,master_equipment_id,organization_id,branch_id,equipment_id,equipment_name,equipment_type,active)
values ('82000000-0000-4000-8000-000000000003','82000000-0000-4000-8000-000000000002','82000000-0000-4000-8000-000000000001','a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','82321e25-25f2-490a-a933-7c15e11c6428','EQ1','Walk-in Chiller Unaiza','refrigerator',true);

insert into public.cold_storage_readings(submission_id,equipment_id,slot,temperature_c,status,submitted_at)
values
  ('82000000-0000-4000-8000-000000000002','EQ1','12:00',4.0,'pass','2026-11-03 12:30:00+00'),
  ('82000000-0000-4000-8000-000000000002','EQ1','20:00',4.2,'pass','2026-11-03 20:30:00+00');

select is((select module_state from private.incomplete_branch_tasks_completion_at(
  'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','82321e25-25f2-490a-a933-7c15e11c6428',
  '2026-11-03','2026-11-04 01:00:00+00') where module_key='cold_storage'),
  'completed','Unaiza cold_storage with 12:00 and 20:00 completed and 02:00 omitted evaluates to completed');

-- Scenario E: Missing 12:00 for Unaiza
delete from public.cold_storage_readings where submission_id='82000000-0000-4000-8000-000000000002' and slot='12:00';
select is((select module_state from private.incomplete_branch_tasks_completion_at(
  'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','82321e25-25f2-490a-a933-7c15e11c6428',
  '2026-11-03','2026-11-04 01:00:00+00') where module_key='cold_storage'),
  'incomplete','Unaiza with missing 12:00 remains incomplete');

-- Scenario F: Submitted incomplete data (state=submitted but reading missing)
update public.cold_storage_submissions set state='submitted' where id='82000000-0000-4000-8000-000000000002';
select is((select module_state from private.incomplete_branch_tasks_completion_at(
  'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','82321e25-25f2-490a-a933-7c15e11c6428',
  '2026-11-03','2026-11-04 01:00:00+00') where module_key='cold_storage'),
  'unknown','Corrupted submission (state=submitted but required reading missing) evaluates to unknown');

-- Scenario G: Historical catch-up date 2026-10-28 for Molt Dubai with 12:00 and 20:00 in draft
insert into public.cold_storage_submissions(id,organization_id,branch_id,supervisor_user_id,business_date,state,branch_name_snapshot,supervisor_name_snapshot,team_name_snapshot)
values ('de000000-0000-4000-8000-000000000004','a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','dea33e25-4732-4dcf-96db-010ad917c16c','fa000000-0000-4000-8000-000000000001','2026-10-28','draft','Dubai','Supervisor','Team A');

insert into public.cold_storage_equipment(id,submission_id,master_equipment_id,organization_id,branch_id,equipment_id,equipment_name,equipment_type,active)
values ('de000000-0000-4000-8000-000000000005','de000000-0000-4000-8000-000000000004','de000000-0000-4000-8000-000000000001','a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','dea33e25-4732-4dcf-96db-010ad917c16c','EQ1','Walk-in Chiller Dubai','refrigerator',true);

insert into public.cold_storage_readings(submission_id,equipment_id,slot,temperature_c,status,submitted_at)
values
  ('de000000-0000-4000-8000-000000000004','EQ1','12:00',4.0,'pass','2026-10-28 12:30:00+00'),
  ('de000000-0000-4000-8000-000000000004','EQ1','20:00',4.2,'pass','2026-10-28 20:30:00+00');

select is((select module_state from private.incomplete_branch_tasks_completion_at(
  'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','dea33e25-4732-4dcf-96db-010ad917c16c',
  '2026-10-28','2026-10-29 00:00:00+00') where module_key='cold_storage'),
  'completed','Molt Dubai historical 2026-10-28 cold storage in draft evaluates to completed');


-- 9. Cutoff & Boundary Checks
select throws_ok(
  $$select * from private.incomplete_branch_tasks_completion_at(
    'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','03acf21e-fbca-48d0-955f-5e783d43c23e',
    '2026-11-03','2026-11-04 00:59:59+00')$$,
  '55000','branch business date is not complete',
  '03:59:59 branch-local blocks evaluation');

select lives_ok(
  $$select * from private.incomplete_branch_tasks_completion_at(
    'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','03acf21e-fbca-48d0-955f-5e783d43c23e',
    '2026-11-03','2026-11-04 01:00:00+00')$$,
  '04:00:00 branch-local permits evaluation');

-- Authoritatively closed branch lifecycle
update public.daily_report_branch_lifecycle set active=false
where branch_id='03acf21e-fbca-48d0-955f-5e783d43c23e' and effective_from_business_date='2026-10-27';

select is((select count(*)::integer from private.incomplete_branch_tasks_completion_at(
  'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','03acf21e-fbca-48d0-955f-5e783d43c23e',
  '2026-11-03','2026-11-04 01:00:00+00') where module_state='not_required'),
  6,'Authoritatively closed branch returns all 6 checklist modules as not_required');

-- Restore Bakery Riyadh active lifecycle for subsequent producer tests
update public.daily_report_branch_lifecycle set active=true
where branch_id='03acf21e-fbca-48d0-955f-5e783d43c23e' and effective_from_business_date='2026-10-27';

-- Organization Isolation
select throws_ok(
  $$select * from private.incomplete_branch_tasks_completion_at(
    'b0000000-0000-4000-8000-000000000002','03acf21e-fbca-48d0-955f-5e783d43c23e',
    '2026-11-03','2026-11-04 01:00:00+00')$$,
  '22023','incomplete branch task lifecycle is missing or ambiguous',
  'Querying branch under wrong organization fails closed');

-- Setup Manager user for producer notification recipients and dashboard projection tests
insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000',
  'fa111111-0000-4000-8000-000000000001','authenticated','authenticated',
  'haccp-mgr@test.com','{}','{}',now(),now())
on conflict (id) do nothing;

update public.profiles
set full_name='HACCP Test Manager',must_change_password=false,disabled_at=null
where id='fa111111-0000-4000-8000-000000000001';

insert into public.organization_memberships(organization_id,user_id,role,active)
values('a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','fa111111-0000-4000-8000-000000000001','organization_manager',true)
on conflict do nothing;

-- 10. End-to-End Producer Lease Evaluation Integration (Historical Catch-up & Current)
-- Historical catch-up evaluation on 2026-10-28
insert into private.organization_manager_notification_evaluation_jobs(
  id,notification_category,organization_id,branch_id,business_date,state,attempt_count,
  lease_token,leased_by,lease_expires_at,completed_at
) values
  ('ee000000-0000-4000-8000-000000000010','sales_tracking_missing',
    'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','03acf21e-fbca-48d0-955f-5e783d43c23e',
    '2026-10-28','running',1,
    'ff000000-0000-4000-8000-000000000010','fa000000-0000-4000-8000-000000000001',statement_timestamp()+interval '5 minutes',null),
  ('ee000000-0000-4000-8000-000000000011','sales_tracking_missing',
    'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','4fafc3dc-269b-4864-8625-5d7a66d39c50',
    '2026-10-28','running',1,
    'ff000000-0000-4000-8000-000000000011','fa000000-0000-4000-8000-000000000001',statement_timestamp()+interval '5 minutes',null);

select is((select result from public.produce_organization_manager_notification_evaluation_job(
  'ee000000-0000-4000-8000-000000000010','ff000000-0000-4000-8000-000000000010')),
  'completed','Producer completes historical Bakery Riyadh missing sales catch-up without error');

select is((select created_count from public.produce_organization_manager_notification_evaluation_job(
  'ee000000-0000-4000-8000-000000000010','ff000000-0000-4000-8000-000000000010')),
  0,'Producer produces 0 notifications on historical Bakery Riyadh catch-up scan');

select is((select result from public.produce_organization_manager_notification_evaluation_job(
  'ee000000-0000-4000-8000-000000000011','ff000000-0000-4000-8000-000000000011')),
  'completed','Producer completes historical Central Kitchen missing sales catch-up without error');

select is((select created_count from public.produce_organization_manager_notification_evaluation_job(
  'ee000000-0000-4000-8000-000000000011','ff000000-0000-4000-8000-000000000011')),
  0,'Producer produces 0 notifications on historical Central Kitchen catch-up scan');

-- Current business date evaluation on 2026-11-03
insert into private.organization_manager_notification_evaluation_jobs(
  id,notification_category,organization_id,branch_id,business_date,state,attempt_count,
  lease_token,leased_by,lease_expires_at,completed_at
) values
  ('ee000000-0000-4000-8000-000000000001','sales_tracking_missing',
    'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','03acf21e-fbca-48d0-955f-5e783d43c23e',
    '2026-11-03','running',1,
    'ff000000-0000-4000-8000-000000000001','fa000000-0000-4000-8000-000000000001',statement_timestamp()+interval '5 minutes',null),
  ('ee000000-0000-4000-8000-000000000002','sales_tracking_missing',
    'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','4fafc3dc-269b-4864-8625-5d7a66d39c50',
    '2026-11-03','running',1,
    'ff000000-0000-4000-8000-000000000002','fa000000-0000-4000-8000-000000000001',statement_timestamp()+interval '5 minutes',null),
  ('ee000000-0000-4000-8000-000000000003','incomplete_branch_tasks',
    'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','4fafc3dc-269b-4864-8625-5d7a66d39c50',
    '2026-11-03','running',1,
    'ff000000-0000-4000-8000-000000000003','fa000000-0000-4000-8000-000000000001',statement_timestamp()+interval '5 minutes',null);

select is((select result from public.produce_organization_manager_notification_evaluation_job(
  'ee000000-0000-4000-8000-000000000001','ff000000-0000-4000-8000-000000000001')),
  'completed','Producer completes Bakery Riyadh missing sales evaluation without error');

select is((select created_count from public.produce_organization_manager_notification_evaluation_job(
  'ee000000-0000-4000-8000-000000000001','ff000000-0000-4000-8000-000000000001')),
  0,'Producer produces 0 notifications for Bakery Riyadh exempt sales tracking');

select is((select result from public.produce_organization_manager_notification_evaluation_job(
  'ee000000-0000-4000-8000-000000000002','ff000000-0000-4000-8000-000000000002')),
  'completed','Producer completes Central Kitchen missing sales evaluation without error');

select is((select created_count from public.produce_organization_manager_notification_evaluation_job(
  'ee000000-0000-4000-8000-000000000002','ff000000-0000-4000-8000-000000000002')),
  0,'Producer produces 0 notifications for Central Kitchen exempt sales tracking');

create temporary table test_ck_job_result as
select * from public.produce_organization_manager_notification_evaluation_job(
  'ee000000-0000-4000-8000-000000000003','ff000000-0000-4000-8000-000000000003');

select is((select result from test_ck_job_result),
  'completed','Producer completes Central Kitchen incomplete tasks evaluation without error');

select is((select created_count from test_ck_job_result),
  1,'Producer produces 1 notification for Central Kitchen incomplete branch tasks');

drop table test_ck_job_result;

select is((select category_context->'incomplete_modules'
  from public.organization_manager_notifications
  where organization_id='a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1'
    and branch_id='4fafc3dc-269b-4864-8625-5d7a66d39c50'
    and event_type='incomplete_branch_tasks'
    and business_date='2026-11-03'),
  '["cold_storage", "daily_audit", "kitchen_opening"]'::jsonb,
  'Incomplete tasks notification excludes exempt foh_opening and oil_tracking for Central Kitchen');

-- 11. Maintenance In-App Decoupling & Immediate Projection Tests
-- Disable Web Push producer
select private.configure_organization_manager_push_producer(false);

-- Insert maintenance issue for Bakery Riyadh during business day
insert into public.maintenance_issues(
  id,organization_id,branch_id,title,category,priority,status,
  location_scope,reported_by,created_at,updated_at
) values (
  '15555555-0000-4000-8000-000000000001',
  'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1',
  '03acf21e-fbca-48d0-955f-5e783d43c23e',
  'Oven Door Gasket Broken',
  'equipment',
  'high',
  'new',
  'branch',
  'fa000000-0000-4000-8000-000000000001',
  '2026-11-04 10:00:00+03:00',
  '2026-11-04 10:00:00+03:00'
);

-- Assert in-app notification row was created
select is(
  (select count(*)::integer from public.organization_manager_notifications
   where organization_id='a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1'
     and recipient_user_id='fa111111-0000-4000-8000-000000000001'
     and event_type='maintenance_issue_created'
     and source_id='15555555-0000-4000-8000-000000000001'),
  1,
  'Maintenance issue creates in-app notification even when push producer is disabled'
);

-- Immediate projection in manager dashboard before 04:00 cutoff
select is(
  (select count(*)::integer from public.list_organization_manager_notification_projection(
    'fa111111-0000-4000-8000-000000000001',
    'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1'
  ) where source_id='15555555-0000-4000-8000-000000000001'),
  1,
  'Reported maintenance issue is immediately visible in manager notification projection'
);

select is(
  (select public.count_organization_manager_notification_projection(
    'fa111111-0000-4000-8000-000000000001',
    'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1'
  ) > 0),
  true,
  'Unread projection count reflects newly reported maintenance issue immediately'
);

select is(
  (select count(*)::integer from public.list_organization_manager_notification_projection_cursor(
    'fa111111-0000-4000-8000-000000000001',
    'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1'
  ) where source_id='15555555-0000-4000-8000-000000000001'),
  1,
  'Cursor projection also projects maintenance issue immediately'
);

-- 12. Midnight-to-04:00 Canonical Business Date Calculations
select is(
  private.phase4a_business_date_at('Asia/Riyadh', '2026-11-05 02:00:00+03:00'::timestamptz),
  '2026-11-04'::date,
  'Riyadh 02:00 local time resolves to previous calendar business date'
);

select is(
  private.phase4a_business_date_at('Asia/Riyadh', '2026-11-05 04:00:00+03:00'::timestamptz),
  '2026-11-05'::date,
  'Riyadh 04:00 local time resolves to current calendar business date'
);

select is(
  private.phase4a_business_date_at('Asia/Dubai', '2026-11-05 02:00:00+04:00'::timestamptz),
  '2026-11-04'::date,
  'Dubai 02:00 local time resolves to previous calendar business date'
);

select is(
  private.phase4a_business_date_at('Asia/Dubai', '2026-11-05 04:00:00+04:00'::timestamptz),
  '2026-11-05'::date,
  'Dubai 04:00 local time resolves to current calendar business date'
);

-- Scheduler enqueuing with canonical business date calculation:
-- At 03:30 Riyadh time (00:30 UTC), Riyadh is before 04:00 cutoff; latest closed business date is 2026-11-03.
-- But at 00:30 UTC, Dubai is 04:30 local time (after 04:00 cutoff); latest closed business date is 2026-11-04!
select is(
  (select max(business_date) from public.enqueue_due_organization_manager_notification_evaluation_jobs(
    1, '2026-11-05 00:30:00+00'::timestamptz
  ) where branch_id='03acf21e-fbca-48d0-955f-5e783d43c23e'),
  '2026-11-03'::date,
  'Scheduler evaluates Riyadh latest closed date as 2026-11-03 when local time is 03:30'
);

select is(
  (select max(business_date) from public.enqueue_due_organization_manager_notification_evaluation_jobs(
    1, '2026-11-05 00:30:00+00'::timestamptz
  ) where branch_id='dea33e25-4732-4dcf-96db-010ad917c16c'),
  '2026-11-04'::date,
  'Scheduler evaluates Dubai latest closed date as 2026-11-04 when local time is 04:30'
);

-- 13. Rollback Test Evidence (Preserves pre-migration values and reverses transitions)
update public.branches
set foh_opening_included = true
where organization_id = 'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1'::uuid
  and id = '4fafc3dc-269b-4864-8625-5d7a66d39c50'::uuid;

update public.branches
set cold_storage_0200_notification_required = true
where organization_id = 'a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1'::uuid
  and id in ('dea33e25-4732-4dcf-96db-010ad917c16c'::uuid,'82321e25-25f2-490a-a933-7c15e11c6428'::uuid);

-- Restore module applicability back to required=true
select private.record_daily_report_module_applicability('a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','03acf21e-fbca-48d0-955f-5e783d43c23e','sales_tracking',true,'2026-10-27',null);
select private.record_daily_report_module_applicability('a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','03acf21e-fbca-48d0-955f-5e783d43c23e','oil_tracking',true,'2026-10-27',null);
select private.record_daily_report_module_applicability('a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','4fafc3dc-269b-4864-8625-5d7a66d39c50','sales_tracking',true,'2026-10-27',null);
select private.record_daily_report_module_applicability('a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','4fafc3dc-269b-4864-8625-5d7a66d39c50','oil_tracking',true,'2026-10-27',null);
select private.record_daily_report_module_applicability('a52e6f0b-500f-4e0b-a1fb-81cf9fa381b1','4fafc3dc-269b-4864-8625-5d7a66d39c50','foh_opening',true,'2026-10-27',null);

select is((select sales_tracking_percentage_included from public.branches where id='03acf21e-fbca-48d0-955f-5e783d43c23e'),
  false,'Rollback preserved Bakery Riyadh sales_tracking flag as false (pre-migration value)');
select is((select oil_tracking_percentage_included from public.branches where id='03acf21e-fbca-48d0-955f-5e783d43c23e'),
  false,'Rollback preserved Bakery Riyadh oil_tracking flag as false (pre-migration value)');
select is((select sales_tracking_percentage_included from public.branches where id='4fafc3dc-269b-4864-8625-5d7a66d39c50'),
  false,'Rollback preserved Central Kitchen sales_tracking flag as false (pre-migration value)');
select is((select foh_opening_included from public.branches where id='4fafc3dc-269b-4864-8625-5d7a66d39c50'),
  true,'Rollback restored Central Kitchen foh_opening_included to true');
select is((select cold_storage_0200_notification_required from public.branches where id='dea33e25-4732-4dcf-96db-010ad917c16c'),
  true,'Rollback restored Molt Dubai 0200 notification required flag to true');
select is((select cold_storage_0200_notification_required from public.branches where id='82321e25-25f2-490a-a933-7c15e11c6428'),
  true,'Rollback restored Unaiza 0200 notification required flag to true');
select is((select required from public.daily_report_module_applicability
  where branch_id='03acf21e-fbca-48d0-955f-5e783d43c23e' and module_key='sales_tracking'
    and effective_from_business_date<='2026-10-27' and (effective_to_business_date is null or effective_to_business_date>'2026-10-27')),
  true,'Rollback restored Bakery Riyadh sales_tracking applicability to true');
select is((select required from public.daily_report_module_applicability
  where branch_id='4fafc3dc-269b-4864-8625-5d7a66d39c50' and module_key='foh_opening'
    and effective_from_business_date<='2026-10-27' and (effective_to_business_date is null or effective_to_business_date>'2026-10-27')),
  true,'Rollback restored Central Kitchen foh_opening applicability to true');

select * from finish();
rollback;
