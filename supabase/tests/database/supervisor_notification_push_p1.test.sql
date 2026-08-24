begin;
select plan(46);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
  id || '@supervisor-push.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1f210000-0000-4000-8000-000000000001'::uuid,
  '1f210000-0000-4000-8000-000000000002',
  '1f210000-0000-4000-8000-000000000003',
  '1f210000-0000-4000-8000-000000000004',
  '1f210000-0000-4000-8000-000000000005'
]) id;

update public.profiles
set full_name = 'Supervisor Push ' || right(id::text, 1),
    must_change_password = false
where id::text like '1f210000-%';

insert into public.organizations(id,name,slug) values
  ('2f210000-0000-4000-8000-000000000001','Supervisor Push Org','supervisor-push-org'),
  ('2f210000-0000-4000-8000-000000000002','Other Supervisor Push Org','other-supervisor-push-org');

insert into public.branches(id,organization_id,name,code,city,timezone,active) values
  ('3f210000-0000-4000-8000-000000000001','2f210000-0000-4000-8000-000000000001','Push Branch A','PSH-RUH-001','Riyadh','Asia/Riyadh',true),
  ('3f210000-0000-4000-8000-000000000002','2f210000-0000-4000-8000-000000000001','Push Branch B','PSH-JED-002','Jeddah','Asia/Riyadh',true),
  ('3f210000-0000-4000-8000-000000000003','2f210000-0000-4000-8000-000000000002','Other Push Branch','OPS-RUH-001','Riyadh','Asia/Riyadh',true);

insert into public.branch_memberships(branch_id,user_id,role) values
  ('3f210000-0000-4000-8000-000000000001','1f210000-0000-4000-8000-000000000001','branch_manager'),
  ('3f210000-0000-4000-8000-000000000001','1f210000-0000-4000-8000-000000000002','branch_manager'),
  ('3f210000-0000-4000-8000-000000000002','1f210000-0000-4000-8000-000000000003','branch_manager'),
  ('3f210000-0000-4000-8000-000000000003','1f210000-0000-4000-8000-000000000004','branch_manager');

insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
  ('4f210000-0000-4000-8000-000000000001','2f210000-0000-4000-8000-000000000001','3f210000-0000-4000-8000-000000000001','1f210000-0000-4000-8000-000000000001'),
  ('4f210000-0000-4000-8000-000000000002','2f210000-0000-4000-8000-000000000001','3f210000-0000-4000-8000-000000000001','1f210000-0000-4000-8000-000000000002'),
  ('4f210000-0000-4000-8000-000000000003','2f210000-0000-4000-8000-000000000001','3f210000-0000-4000-8000-000000000002','1f210000-0000-4000-8000-000000000003'),
  ('4f210000-0000-4000-8000-000000000004','2f210000-0000-4000-8000-000000000002','3f210000-0000-4000-8000-000000000003','1f210000-0000-4000-8000-000000000004');

select ok(not exists (
  select 1 from information_schema.columns
  where table_schema='public' and table_name='notifications' and column_name='push_sent_at'
),'notifications do not track successful push globally');
select ok(not exists (
  select 1 from information_schema.columns
  where table_schema='public' and table_name='notifications' and column_name='push_last_attempt_at'
),'notifications do not track push attempts globally');
select has_table('public','supervisor_notification_push_deliveries','subscription-level Supervisor push delivery table exists');
select has_column('public','supervisor_notification_push_deliveries','notification_id','delivery table stores notification id');
select has_column('public','supervisor_notification_push_deliveries','push_subscription_id','delivery table stores push subscription id');
select has_column('public','supervisor_notification_push_deliveries','sent_at','delivery table tracks successful send per subscription');
select ok(exists (
  select 1 from pg_indexes
  where schemaname='public' and indexname='supervisor_notification_push_deliveries_pending_idx'
),'pending delivery index exists');
select ok(has_function_privilege('service_role','public.register_supervisor_push_subscription(uuid,text,text,text,text)','execute'),'service role can register Supervisor push subscriptions');
select ok(not has_function_privilege('authenticated','public.register_supervisor_push_subscription(uuid,text,text,text,text)','execute'),'authenticated cannot directly register Supervisor push subscriptions');
select ok(has_function_privilege('service_role','public.list_supervisor_notification_push_deliveries(timestamptz)','execute'),'service role can list due Supervisor push deliveries');
select ok(has_function_privilege('service_role','public.mark_supervisor_notification_push_attempted(uuid,uuid,text)','execute'),'service role can record a subscription push attempt');
select ok(has_function_privilege('service_role','public.mark_supervisor_notification_push_sent(uuid,uuid,text)','execute'),'service role can mark one subscription delivery sent');

select lives_ok($$select * from public.register_supervisor_push_subscription(
  '1f210000-0000-4000-8000-000000000001','https://push.example/sup-a','abcdefghijklmnopqrstuvwxyz','authsecret-a','Chrome'
)$$,'active Branch A Supervisor registers push');
select lives_ok($$select * from public.register_supervisor_push_subscription(
  '1f210000-0000-4000-8000-000000000002','https://push.example/sup-b','abcdefghijklmnopqrstuvwxyz','authsecret-b','Chrome'
)$$,'second Branch A Supervisor registers push');
select lives_ok($$select * from public.register_supervisor_push_subscription(
  '1f210000-0000-4000-8000-000000000003','https://push.example/branch-b-mac','abcdefghijklmnopqrstuvwxyz','authsecret-c','Chrome'
)$$,'Branch B Supervisor registers Mac push');
select lives_ok($$select * from public.register_supervisor_push_subscription(
  '1f210000-0000-4000-8000-000000000003','https://push.example/branch-b-phone','abcdefghijklmnopqrstuvwxyz','authsecret-c2','Safari'
)$$,'Branch B Supervisor registers phone push');
select lives_ok($$select * from public.register_supervisor_push_subscription(
  '1f210000-0000-4000-8000-000000000003','https://push.example/branch-b-expired','abcdefghijklmnopqrstuvwxyz','authsecret-c3','Safari'
)$$,'Branch B Supervisor registers an expired push endpoint');
select ok(public.disable_push_subscription_delivery(
  (select id from public.push_subscriptions where endpoint='https://push.example/branch-b-expired'),
  'https://push.example/branch-b-expired'
),'expired subscription cleanup disables one endpoint');
select lives_ok($$select * from public.register_supervisor_push_subscription(
  '1f210000-0000-4000-8000-000000000004','https://push.example/other-org','abcdefghijklmnopqrstuvwxyz','authsecret-other','Chrome'
)$$,'other-organization Supervisor can register their own push');
select throws_ok($$select * from public.register_supervisor_push_subscription(
  '1f210000-0000-4000-8000-000000000005','https://push.example/not-supervisor','abcdefghijklmnopqrstuvwxyz','authsecret-d','Chrome'
)$$,'42501','supervisor push access denied','non-Supervisor cannot register push');

insert into public.push_subscriptions(user_id,endpoint,p256dh,auth)
values('1f210000-0000-4000-8000-000000000005','https://push.example/forced-unauthorized','abcdefghijklmnopqrstuvwxyz','authsecret-e');

select is((select count(*)::int from public.list_supervisor_notification_push_deliveries('2026-08-24 14:59:00+00') where rule_key='oil_tracking_1800'),0,'17:59 branch-local has no 18:00 Oil push delivery');
select is((select count(*)::int from public.list_supervisor_notification_push_deliveries('2026-08-24 15:00:00+00') where rule_key='oil_tracking_1800' and branch_id='3f210000-0000-4000-8000-000000000001'),2,'18:00 Oil push targets both Branch A Supervisors');
select is((select count(*)::int from public.list_supervisor_notification_push_deliveries('2026-08-24 17:00:00+00') where rule_key='cold_storage_2000' and branch_id='3f210000-0000-4000-8000-000000000001'),2,'20:00 Cold Storage push targets Branch A Supervisors');
select is((select count(*)::int from public.list_supervisor_notification_push_deliveries('2026-08-24 19:00:00+00') where rule_key='financial_closing_2200' and branch_id='3f210000-0000-4000-8000-000000000001'),2,'22:00 Financial Closing warning targets Branch A Supervisors');

insert into public.financial_closing_reports(
  organization_id,branch_id,business_date,state,revision,branch_name_snapshot,branch_code_snapshot,branch_city_snapshot,submitted_by_user_id,submitted_by_name_snapshot,submitted_at
) values(
  '2f210000-0000-4000-8000-000000000001','3f210000-0000-4000-8000-000000000001','2026-08-24','submitted',1,'Push Branch A','PSH-RUH-001','Riyadh','1f210000-0000-4000-8000-000000000001','Supervisor Push 1','2026-08-24 19:30:00+00'
);
select is((select count(*)::int from public.list_supervisor_notification_push_deliveries('2026-08-24 20:00:00+00') where rule_key='financial_closing_2300' and branch_id='3f210000-0000-4000-8000-000000000001'),0,'completed Financial Closing prevents later 23:00 urgent push');
select is((select count(*)::int from public.notifications n join public.notification_rules r on r.id=n.rule_id where r.rule_key='financial_closing_2200' and n.branch_id='3f210000-0000-4000-8000-000000000001' and n.resolved_at is not null),2,'completed checklist resolves existing warning notifications');

select is((select count(*)::int from public.list_supervisor_notification_push_deliveries('2026-08-24 20:00:00+00') where rule_key='financial_closing_2300' and branch_id='3f210000-0000-4000-8000-000000000002'),2,'23:00 Financial Closing urgent still targets both active Branch B subscriptions');
select is((select count(*)::int from public.list_supervisor_notification_push_deliveries('2026-08-24 23:00:00+00') where rule_key='financial_closing_0200_overdue' and branch_id='3f210000-0000-4000-8000-000000000002' and business_date='2026-08-24'),2,'02:00 overdue push targets prior branch-local business date for both active subscriptions');
select is((select count(*)::int from public.list_supervisor_notification_push_deliveries('2026-08-24 23:00:00+00') where recipient_user_id='1f210000-0000-4000-8000-000000000005'),0,'unauthorized subscription user is not a push recipient');
select is((select count(*)::int from public.list_supervisor_notification_push_deliveries('2026-08-24 23:00:00+00') where recipient_user_id='1f210000-0000-4000-8000-000000000004' and branch_id='3f210000-0000-4000-8000-000000000002'),0,'Supervisor outside the branch is not a Branch B push recipient');

create temporary table overdue_delivery as
select notification_id, subscription_id, endpoint
from public.list_supervisor_notification_push_deliveries('2026-08-24 23:00:00+00')
where rule_key='financial_closing_0200_overdue'
  and branch_id='3f210000-0000-4000-8000-000000000002'
  and business_date='2026-08-24';
select is((select count(*)::int from overdue_delivery),2,'one user with two active subscriptions has two overdue delivery rows');
select ok((select public.mark_supervisor_notification_push_attempted(notification_id, subscription_id, endpoint) from overdue_delivery where endpoint='https://push.example/branch-b-mac'),'first subscription attempt is recorded');
select ok((select public.mark_supervisor_notification_push_sent(notification_id, subscription_id, endpoint) from overdue_delivery where endpoint='https://push.example/branch-b-mac'),'first subscription success is marked independently');
select ok((select public.mark_supervisor_notification_push_attempted(notification_id, subscription_id, endpoint) from overdue_delivery where endpoint='https://push.example/branch-b-phone'),'second subscription failed attempt is recorded without sent_at');

create temporary table retry_delivery as
select notification_id, subscription_id, endpoint
from public.list_supervisor_notification_push_deliveries('2026-08-24 23:05:00+00')
where rule_key='financial_closing_0200_overdue'
  and branch_id='3f210000-0000-4000-8000-000000000002'
  and business_date='2026-08-24';
select is((select count(*)::int from retry_delivery),1,'retry returns only the failed subscription delivery');
select is((select endpoint from retry_delivery),'https://push.example/branch-b-phone','retry targets the failed phone subscription');
select is((select count(*)::int from public.supervisor_notification_push_deliveries where notification_id=(select notification_id from overdue_delivery limit 1)),2,'repeated evaluation creates no duplicate delivery rows');
select is((select count(*)::int from retry_delivery where endpoint='https://push.example/branch-b-mac'),0,'successful first subscription is not resent');
select ok((select public.mark_supervisor_notification_push_attempted(notification_id, subscription_id, endpoint) from retry_delivery),'failed subscription can be attempted again on retry');
select ok((select public.mark_supervisor_notification_push_sent(notification_id, subscription_id, endpoint) from retry_delivery),'failed subscription can later become sent');
select is((select count(*)::int from public.list_supervisor_notification_push_deliveries('2026-08-24 23:10:00+00') where rule_key='financial_closing_0200_overdue' and branch_id='3f210000-0000-4000-8000-000000000002' and business_date='2026-08-24'),0,'eventually both subscriptions are sent and no pending push remains');
select is((select count(*)::int from public.supervisor_notification_push_deliveries where notification_id=(select notification_id from overdue_delivery limit 1)),2,'final repeated scheduler execution still has no duplicate delivery rows');
select is((select count(*)::int from public.supervisor_notification_push_deliveries where notification_id=(select notification_id from overdue_delivery limit 1) and sent_at is not null),2,'both subscription delivery rows are marked sent');
select is((select attempt_count from public.supervisor_notification_push_deliveries delivery join overdue_delivery od on od.notification_id=delivery.notification_id and od.subscription_id=delivery.push_subscription_id where od.endpoint='https://push.example/branch-b-phone'),2,'failed phone subscription records both attempts');
select ok(position('email' in lower(pg_get_functiondef('private.supervisor_notification_recipients(uuid)'::regprocedure))) = 0,'Supervisor reminder recipient resolver does not use manual email lists');
select ok(position('email' in lower(pg_get_functiondef('public.list_supervisor_notification_push_deliveries(timestamptz)'::regprocedure))) = 0,'Supervisor push delivery resolver does not use email routing');

select * from finish();
rollback;
