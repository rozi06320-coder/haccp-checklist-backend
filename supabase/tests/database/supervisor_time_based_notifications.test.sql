begin;
select plan(25);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
  id || '@supervisor-notifications.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1f200000-0000-4000-8000-000000000001'::uuid,
  '1f200000-0000-4000-8000-000000000002',
  '1f200000-0000-4000-8000-000000000003',
  '1f200000-0000-4000-8000-000000000004'
]) id;

update public.profiles
set full_name = case id
  when '1f200000-0000-4000-8000-000000000001' then 'Notification Supervisor A'
  when '1f200000-0000-4000-8000-000000000002' then 'Notification Supervisor B'
  when '1f200000-0000-4000-8000-000000000003' then 'Other Branch Supervisor'
  else 'Other Org Supervisor'
end,
must_change_password = false
where id::text like '1f200000-%';

insert into public.organizations(id,name,slug) values
  ('2f200000-0000-4000-8000-000000000001','Supervisor Notifications Org','supervisor-notifications-org'),
  ('2f200000-0000-4000-8000-000000000002','Other Notifications Org','other-supervisor-notifications-org');

insert into public.branches(id,organization_id,name,code,city,timezone,active) values
  ('3f200000-0000-4000-8000-000000000001','2f200000-0000-4000-8000-000000000001','Notification Branch A','NOT-RUH-001','Riyadh','Asia/Riyadh',true),
  ('3f200000-0000-4000-8000-000000000002','2f200000-0000-4000-8000-000000000001','Notification Branch B','NOT-JED-002','Jeddah','Asia/Riyadh',true),
  ('3f200000-0000-4000-8000-000000000003','2f200000-0000-4000-8000-000000000002','Other Notification Branch','OTH-RUH-001','Riyadh','Asia/Riyadh',true);

insert into public.branch_memberships(branch_id,user_id,role) values
  ('3f200000-0000-4000-8000-000000000001','1f200000-0000-4000-8000-000000000001','branch_manager'),
  ('3f200000-0000-4000-8000-000000000001','1f200000-0000-4000-8000-000000000002','branch_manager'),
  ('3f200000-0000-4000-8000-000000000002','1f200000-0000-4000-8000-000000000003','branch_manager'),
  ('3f200000-0000-4000-8000-000000000003','1f200000-0000-4000-8000-000000000004','branch_manager');

insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
  ('4f200000-0000-4000-8000-000000000001','2f200000-0000-4000-8000-000000000001','3f200000-0000-4000-8000-000000000001','1f200000-0000-4000-8000-000000000001'),
  ('4f200000-0000-4000-8000-000000000002','2f200000-0000-4000-8000-000000000001','3f200000-0000-4000-8000-000000000001','1f200000-0000-4000-8000-000000000002'),
  ('4f200000-0000-4000-8000-000000000003','2f200000-0000-4000-8000-000000000001','3f200000-0000-4000-8000-000000000002','1f200000-0000-4000-8000-000000000003'),
  ('4f200000-0000-4000-8000-000000000004','2f200000-0000-4000-8000-000000000002','3f200000-0000-4000-8000-000000000003','1f200000-0000-4000-8000-000000000004');

select has_table('public','notification_rules','notification rules table exists');
select has_table('public','notifications','notifications table exists');
select ok((select relrowsecurity from pg_class where oid='public.notification_rules'::regclass),'notification rules RLS enabled');
select ok((select relrowsecurity from pg_class where oid='public.notifications'::regclass),'notifications RLS enabled');
select ok(not has_table_privilege('authenticated','public.notifications','insert'),'authenticated cannot insert notifications directly');
select ok(has_function_privilege('service_role','public.evaluate_supervisor_notifications(uuid,timestamptz)','execute'),'service role can evaluate supervisor notifications');
select ok(not has_function_privilege('authenticated','public.evaluate_supervisor_notifications(uuid,timestamptz)','execute'),'authenticated cannot evaluate notification RPC directly');

select is((select count(*)::int from public.notification_rules where rule_key in (
  'oil_tracking_1800',
  'cold_storage_2000',
  'financial_closing_2200',
  'financial_closing_2300',
  'financial_closing_0200_overdue'
)),5,'five default supervisor reminder rules exist');
select is((select severity from public.notification_rules where rule_key='financial_closing_0200_overdue'),'urgent','02:00 Financial Closing reminder is urgent');

set local role service_role;
select is((select count(*)::int from public.evaluate_supervisor_notifications(
  '1f200000-0000-4000-8000-000000000001',
  '2026-08-24 18:59:00+00'
) where rule_key='financial_closing_2200'),0,'21:59 branch-local time does not create 22:00 Financial Closing reminder');
reset role;

set local role service_role;
select lives_ok($$select * from public.evaluate_supervisor_notifications(
  '1f200000-0000-4000-8000-000000000001',
  '2026-08-24 19:00:00+00'
)$$,'22:00 branch-local evaluation succeeds');
reset role;
select is((select count(*)::int from public.notifications n join public.notification_rules r on r.id=n.rule_id where r.rule_key='financial_closing_2200' and n.branch_id='3f200000-0000-4000-8000-000000000001' and n.business_date='2026-08-24'),2,'both active Supervisors in same branch receive branch-shared reminder');

set local role service_role;
select lives_ok($$select * from public.evaluate_supervisor_notifications(
  '1f200000-0000-4000-8000-000000000001',
  '2026-08-24 19:05:00+00'
)$$,'repeat evaluation succeeds');
reset role;
select is((select count(*)::int from public.notifications n join public.notification_rules r on r.id=n.rule_id where r.rule_key='financial_closing_2200' and n.branch_id='3f200000-0000-4000-8000-000000000001' and n.business_date='2026-08-24'),2,'repeat evaluation dedupes per recipient branch date rule');

insert into public.financial_closing_reports(
  organization_id,branch_id,business_date,state,revision,branch_name_snapshot,branch_code_snapshot,branch_city_snapshot,submitted_by_user_id,submitted_by_name_snapshot,submitted_at
) values(
  '2f200000-0000-4000-8000-000000000001','3f200000-0000-4000-8000-000000000001','2026-08-24','submitted',1,'Notification Branch A','NOT-RUH-001','Riyadh','1f200000-0000-4000-8000-000000000001','Notification Supervisor A','2026-08-24 19:03:00+00'
);

set local role service_role;
select lives_ok($$select * from public.evaluate_supervisor_notifications(
  '1f200000-0000-4000-8000-000000000001',
  '2026-08-24 19:06:00+00'
)$$,'submitted Financial Closing resolves existing reminders');
reset role;
select is((select count(*)::int from public.notifications n join public.notification_rules r on r.id=n.rule_id where r.rule_key='financial_closing_2200' and n.resolved_at is not null and n.branch_id='3f200000-0000-4000-8000-000000000001'),2,'existing Financial Closing reminders are marked resolved after submission');

set local role service_role;
select lives_ok($$select * from public.evaluate_supervisor_notifications(
  '1f200000-0000-4000-8000-000000000003',
  '2026-08-24 20:00:00+00'
)$$,'23:00 branch-local evaluation succeeds');
reset role;
select is((select count(*)::int from public.notifications n join public.notification_rules r on r.id=n.rule_id where r.rule_key='financial_closing_2300' and n.branch_id='3f200000-0000-4000-8000-000000000002' and n.business_date='2026-08-24'),1,'23:00 unresolved Financial Closing creates separate urgent notification');

set local role service_role;
select lives_ok($$select * from public.evaluate_supervisor_notifications(
  '1f200000-0000-4000-8000-000000000003',
  '2026-08-24 23:00:00+00'
)$$,'02:00 next-calendar-day evaluation succeeds');
reset role;
select is((select count(*)::int from public.notifications n join public.notification_rules r on r.id=n.rule_id where r.rule_key='financial_closing_0200_overdue' and n.branch_id='3f200000-0000-4000-8000-000000000002' and n.business_date='2026-08-24'),1,'02:00 overdue reminder attaches to prior unresolved business date');
select is((select count(*)::int from public.notifications n join public.notification_rules r on r.id=n.rule_id where r.rule_key='financial_closing_0200_overdue' and n.branch_id='3f200000-0000-4000-8000-000000000001' and n.business_date='2026-08-24'),0,'prior closing submitted before 02:00 does not create overdue reminder');

select is((select count(*)::int from public.notifications where branch_id='3f200000-0000-4000-8000-000000000003' and organization_id='2f200000-0000-4000-8000-000000000002'),0,'another organization is excluded from actor branch evaluation');

update public.notifications
set id = '5f200000-0000-4000-8000-000000000001'
where id = (
  select n.id
  from public.notifications n
  join public.notification_rules r on r.id=n.rule_id
  where r.rule_key='financial_closing_2300'
    and n.recipient_user_id='1f200000-0000-4000-8000-000000000003'
  limit 1
);

set local role service_role;
select lives_ok($$select * from public.mark_supervisor_notification_read(
  '1f200000-0000-4000-8000-000000000003',
  '5f200000-0000-4000-8000-000000000001'
)$$,'recipient can mark own notification read');
reset role;
select ok((select read_at is not null from public.notifications where id='5f200000-0000-4000-8000-000000000001'),'read_at is set independently from resolved_at');

select throws_ok($$select * from public.mark_supervisor_notification_read(
  '1f200000-0000-4000-8000-000000000001',
  '5f200000-0000-4000-8000-000000000001'
)$$,'42501','notification not found','another Supervisor cannot mark a different user notification read');

select * from finish();
rollback;
