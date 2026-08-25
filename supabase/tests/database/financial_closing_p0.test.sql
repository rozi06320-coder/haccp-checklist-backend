begin;
select plan(31);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
  id || '@financial-closing.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1f100000-0000-4000-8000-000000000001'::uuid,
  '1f100000-0000-4000-8000-000000000002',
  '1f100000-0000-4000-8000-000000000003',
  '1f100000-0000-4000-8000-000000000004'
]) id;

update public.profiles
set full_name = case id
  when '1f100000-0000-4000-8000-000000000001' then 'Financial Supervisor A'
  when '1f100000-0000-4000-8000-000000000002' then 'Financial Supervisor B'
  when '1f100000-0000-4000-8000-000000000003' then 'Financial Manager A'
  else 'Financial Manager B'
end,
must_change_password = false
where id::text like '1f100000-%';

insert into public.organizations(id,name,slug) values
  ('2f100000-0000-4000-8000-000000000001','Financial Closing Org','financial-closing-org'),
  ('2f100000-0000-4000-8000-000000000002','Other Financial Org','other-financial-org');

insert into public.branches(id,organization_id,name,code,city,timezone,active) values
  ('3f100000-0000-4000-8000-000000000001','2f100000-0000-4000-8000-000000000001','Financial Branch A','HUN-RUH-001','Riyadh','Asia/Riyadh',true),
  ('3f100000-0000-4000-8000-000000000002','2f100000-0000-4000-8000-000000000001','Financial Branch B','HUN-RUH-001','Riyadh','Asia/Riyadh',true),
  ('3f100000-0000-4000-8000-000000000003','2f100000-0000-4000-8000-000000000002','Financial Other Branch','OTH-RUH-001','Riyadh','Asia/Riyadh',true);

insert into public.organization_memberships(organization_id,user_id,role) values
  ('2f100000-0000-4000-8000-000000000001','1f100000-0000-4000-8000-000000000003','organization_manager'),
  ('2f100000-0000-4000-8000-000000000002','1f100000-0000-4000-8000-000000000004','organization_manager');

insert into public.branch_memberships(branch_id,user_id,role) values
  ('3f100000-0000-4000-8000-000000000001','1f100000-0000-4000-8000-000000000001','branch_manager'),
  ('3f100000-0000-4000-8000-000000000002','1f100000-0000-4000-8000-000000000002','branch_manager');

insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
  ('4f100000-0000-4000-8000-000000000001','2f100000-0000-4000-8000-000000000001','3f100000-0000-4000-8000-000000000001','1f100000-0000-4000-8000-000000000001'),
  ('4f100000-0000-4000-8000-000000000002','2f100000-0000-4000-8000-000000000001','3f100000-0000-4000-8000-000000000002','1f100000-0000-4000-8000-000000000002');

create temporary table financial_closing_test_keys(item_key text primary key, ordinal int not null) on commit drop;
insert into financial_closing_test_keys(item_key, ordinal) values
  ('sales_closing', 1),
  ('collections', 2),
  ('exceptions', 3),
  ('purchases', 4),
  ('transfers', 5),
  ('production', 6),
  ('waste', 7),
  ('petty_cash', 8),
  ('pending_documents', 9),
  ('exception_escalation', 10);

select has_table('public','financial_closing_reports','financial closing report table exists');
select has_table('public','financial_closing_items','financial closing item table exists');
select has_column('public','financial_closing_reports','branch_code_snapshot','branch code snapshot exists');
select has_column('public','financial_closing_reports','branch_city_snapshot','branch city snapshot exists');
select has_column('public','financial_closing_items','item_key','item key persists stable control key');
select has_column('public','financial_closing_items','follow_up','follow-up persists item exception action');
select ok((select relrowsecurity from pg_class where oid='public.financial_closing_reports'::regclass),'financial closing reports RLS enabled');
select ok((select relrowsecurity from pg_class where oid='public.financial_closing_items'::regclass),'financial closing items RLS enabled');
select ok(not has_function_privilege('authenticated','public.get_financial_closing_current_state(uuid,uuid)','execute'),'authenticated cannot execute current-state RPC');
select ok(has_function_privilege('service_role','public.get_financial_closing_current_state(uuid,uuid)','execute'),'service role can execute current-state RPC');
select ok(not has_function_privilege('authenticated','public.save_financial_closing_draft(uuid,uuid,bigint,jsonb)','execute'),'authenticated cannot execute draft RPC');
select ok(has_function_privilege('service_role','public.save_financial_closing_draft(uuid,uuid,bigint,jsonb)','execute'),'service role can execute draft RPC');
select is(public.get_financial_closing_current_state('1f100000-0000-4000-8000-000000000001','3f100000-0000-4000-8000-000000000001')->>'business_date', private.phase4a_business_date('Asia/Riyadh')::text, 'current-state uses server branch business date');
select is(jsonb_array_length(public.get_financial_closing_current_state('1f100000-0000-4000-8000-000000000001','3f100000-0000-4000-8000-000000000001')->'items'), 10, 'current-state returns exactly 10 fixed controls');

select lives_ok($$
  select public.save_financial_closing_draft(
    '1f100000-0000-4000-8000-000000000001',
    '3f100000-0000-4000-8000-000000000001',
    0,
    '[{"item_key":"sales_closing","status":null,"reason":"","follow_up":""}]'::jsonb
  )
$$, 'incomplete draft is accepted');
select is((select count(*) from public.financial_closing_reports where branch_id='3f100000-0000-4000-8000-000000000001'), 1::bigint, 'one logical report exists for branch business date');

select lives_ok($$
  select public.save_financial_closing_draft(
    '1f100000-0000-4000-8000-000000000001',
    '3f100000-0000-4000-8000-000000000001',
    1,
    (select jsonb_agg(jsonb_build_object('item_key', item_key, 'status', 'completed', 'reason', '', 'follow_up', '') order by ordinal) from financial_closing_test_keys)
  )
$$, 'repeated draft updates same report');
select is((select count(*) from public.financial_closing_reports where branch_id='3f100000-0000-4000-8000-000000000001'), 1::bigint, 'repeated draft does not duplicate branch/date report');

select throws_ok($$
  select public.submit_financial_closing(
    '1f100000-0000-4000-8000-000000000001',
    '3f100000-0000-4000-8000-000000000001',
    2,
    '[{"item_key":"sales_closing","status":"completed","reason":"","follow_up":""}]'::jsonb
  )
$$, '22023', 'financial closing status required', 'final submit requires all statuses');
select throws_ok($$
  select public.submit_financial_closing(
    '1f100000-0000-4000-8000-000000000001',
    '3f100000-0000-4000-8000-000000000001',
    2,
    (select jsonb_agg(jsonb_build_object('item_key', item_key, 'status', case when item_key='exceptions' then 'not_completed' else 'completed' end, 'reason', '', 'follow_up', '') order by ordinal) from financial_closing_test_keys)
  )
$$, '22023', 'financial closing follow-up required', 'Not Completed requires reason and follow-up');
select lives_ok($$
  select public.submit_financial_closing(
    '1f100000-0000-4000-8000-000000000001',
    '3f100000-0000-4000-8000-000000000001',
    2,
    (select jsonb_agg(jsonb_build_object(
      'item_key', item_key,
      'status', case when item_key='exceptions' then 'not_completed' when item_key in ('waste','petty_cash') then 'not_applicable' else 'completed' end,
      'reason', case when item_key='exceptions' then 'Card variance reviewed' else '' end,
      'follow_up', case when item_key='exceptions' then 'Finance to reconcile tomorrow' else '' end
    ) order by ordinal) from financial_closing_test_keys)
  )
$$, 'valid final submission succeeds with Not Completed exception recorded');
select is(public.get_financial_closing_current_state('1f100000-0000-4000-8000-000000000001','3f100000-0000-4000-8000-000000000001')->>'state', 'submitted', 'final state is submitted');
select is(public.get_financial_closing_current_state('1f100000-0000-4000-8000-000000000001','3f100000-0000-4000-8000-000000000001')->>'completion', '87.5', 'N/A is excluded from completion denominator');
select lives_ok($$
  select public.submit_financial_closing(
    '1f100000-0000-4000-8000-000000000002',
    '3f100000-0000-4000-8000-000000000002',
    0,
    (select jsonb_agg(jsonb_build_object('item_key', item_key, 'status', 'completed', 'reason', '', 'follow_up', '') order by ordinal) from financial_closing_test_keys)
  )
$$, 'same-code second branch Financial Closing submission succeeds');
select is((select count(*) from public.financial_closing_reports where organization_id='2f100000-0000-4000-8000-000000000001' and branch_code_snapshot='HUN-RUH-001'), 2::bigint, 'Financial Closing keeps separate report rows with the same branch code');
select is((select count(distinct branch_id) from public.financial_closing_reports where organization_id='2f100000-0000-4000-8000-000000000001' and branch_code_snapshot='HUN-RUH-001'), 2::bigint, 'Financial Closing ownership remains branch_id scoped for duplicate codes');
select throws_ok($$
  select public.save_financial_closing_draft(
    '1f100000-0000-4000-8000-000000000001',
    '3f100000-0000-4000-8000-000000000001',
    3,
    '[]'::jsonb
  )
$$, '55000', 'financial closing already submitted', 'submitted report cannot be modified');

update public.branches set code='HUN-RUH-999', name='Changed Branch Name', city='Changed City' where id='3f100000-0000-4000-8000-000000000001';
select is((select branch_code_snapshot from public.financial_closing_reports where branch_id='3f100000-0000-4000-8000-000000000001'), 'HUN-RUH-001', 'submitted branch code snapshot remains immutable');
select is(jsonb_array_length(public.list_managed_financial_closing_reports('1f100000-0000-4000-8000-000000000003','2f100000-0000-4000-8000-000000000001')->'reports'), 2, 'manager sees same-code Financial Closing reports as separate branch_id-scoped rows');
select throws_ok($$select public.list_managed_financial_closing_reports('1f100000-0000-4000-8000-000000000004','2f100000-0000-4000-8000-000000000001')$$, '42501', 'financial closing report access denied', 'other organization manager is denied');
select throws_ok($$select public.get_financial_closing_current_state('1f100000-0000-4000-8000-000000000001','3f100000-0000-4000-8000-000000000002')$$, '42501', 'financial closing access denied', 'supervisor cannot read another branch current state');

select * from finish();
rollback;
