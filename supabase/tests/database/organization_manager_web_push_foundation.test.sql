begin;
select plan(33);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',
  id||'@manager-push.invalid','{}','{}',now(),now()
from unnest(array[
  '13000000-0000-4000-8000-000000000001'::uuid,
  '13000000-0000-4000-8000-000000000002',
  '13000000-0000-4000-8000-000000000003',
  '13000000-0000-4000-8000-000000000004'
]) id;

update public.profiles set full_name='Manager Push',must_change_password=false
where id::text like'13000000-%';
update public.profiles set must_change_password=true
where id='13000000-0000-4000-8000-000000000003';

insert into public.organizations(id,name,slug,active) values
  ('23000000-0000-4000-8000-000000000001','Manager Push Org','manager-push-org',true),
  ('23000000-0000-4000-8000-000000000002','Other Push Org','other-manager-push-org',true),
  ('23000000-0000-4000-8000-000000000003','Inactive Push Org','inactive-manager-push-org',false);

insert into public.organization_memberships(organization_id,user_id,role,active) values
  ('23000000-0000-4000-8000-000000000001','13000000-0000-4000-8000-000000000001','organization_manager',true),
  ('23000000-0000-4000-8000-000000000002','13000000-0000-4000-8000-000000000002','organization_manager',true),
  ('23000000-0000-4000-8000-000000000001','13000000-0000-4000-8000-000000000003','organization_manager',true),
  ('23000000-0000-4000-8000-000000000003','13000000-0000-4000-8000-000000000004','organization_manager',true);

select has_table('public','organization_manager_notifications','manager notification history exists');
select has_table('public','organization_manager_push_deliveries','durable manager queue exists');
select col_is_pk('public','organization_manager_notifications','id','notification identifiers are primary keys');
select ok((select relrowsecurity from pg_class where oid='public.organization_manager_notifications'::regclass),'history has RLS');
select ok((select relrowsecurity from pg_class where oid='public.organization_manager_push_deliveries'::regclass),'queue has RLS');
select ok(not has_table_privilege('authenticated','public.organization_manager_notifications','select'),'authenticated cannot read history directly');
select ok(not has_table_privilege('service_role','public.organization_manager_push_deliveries','select'),'service role cannot bypass queue RPCs directly');
select ok(has_function_privilege('service_role','public.register_organization_manager_push_subscription(uuid,uuid,text,text,text,text)','execute'),'service role can broker registration');
select ok(not has_function_privilege('authenticated','public.register_organization_manager_push_subscription(uuid,uuid,text,text,text,text)','execute'),'authenticated cannot call registration directly');
select ok(has_function_privilege('service_role','public.claim_organization_manager_push_deliveries(uuid,integer,integer)','execute'),'service role can claim queue work');
select ok(not has_function_privilege('anon','public.claim_organization_manager_push_deliveries(uuid,integer,integer)','execute'),'anon cannot claim queue work');

select lives_ok($$select * from public.register_organization_manager_push_subscription(
  '13000000-0000-4000-8000-000000000001','23000000-0000-4000-8000-000000000001',
  'https://fcm.googleapis.com/fcm/send/manager-device','abcdefghijklmnopqrstuvwxyz','authsecret','Chrome'
)$$,'active manager registers a provider endpoint');
select throws_ok($$select * from public.register_organization_manager_push_subscription(
  '13000000-0000-4000-8000-000000000002','23000000-0000-4000-8000-000000000002',
  'https://fcm.googleapis.com/fcm/send/manager-device','abcdefghijklmnopqrstuvwxyz','authsecret','Chrome'
)$$,'23505','push subscription belongs to another account','subscription ownership cannot transfer across managers');
select throws_ok($$select * from public.register_organization_manager_push_subscription(
  '13000000-0000-4000-8000-000000000001','23000000-0000-4000-8000-000000000002',
  'https://fcm.googleapis.com/fcm/send/cross-org','abcdefghijklmnopqrstuvwxyz','authsecret','Chrome'
)$$,'42501','manager notification access denied','cross-organization registration is denied');
select throws_ok($$select * from public.register_organization_manager_push_subscription(
  '13000000-0000-4000-8000-000000000003','23000000-0000-4000-8000-000000000001',
  'https://fcm.googleapis.com/fcm/send/forced','abcdefghijklmnopqrstuvwxyz','authsecret','Chrome'
)$$,'42501','manager notification access denied','forced-change manager is denied');
select throws_ok($$select * from public.register_organization_manager_push_subscription(
  '13000000-0000-4000-8000-000000000004','23000000-0000-4000-8000-000000000003',
  'https://fcm.googleapis.com/fcm/send/inactive','abcdefghijklmnopqrstuvwxyz','authsecret','Chrome'
)$$,'42501','manager notification access denied','inactive organization is denied');
select throws_ok($$select * from public.register_organization_manager_push_subscription(
  '13000000-0000-4000-8000-000000000001','23000000-0000-4000-8000-000000000001',
  'https://127.0.0.1/internal','abcdefghijklmnopqrstuvwxyz','authsecret','Chrome'
)$$,'22023','invalid manager push subscription','loopback endpoint is denied in SQL');
select throws_ok($$select * from public.register_organization_manager_push_subscription(
  '13000000-0000-4000-8000-000000000001','23000000-0000-4000-8000-000000000001',
  'https://fcm.googleapis.com.evil.invalid/push','abcdefghijklmnopqrstuvwxyz','authsecret','Chrome'
)$$,'22023','invalid manager push subscription','provider lookalike is denied in SQL');

select lives_ok($$select * from public.create_organization_manager_notification(
  '23000000-0000-4000-8000-000000000001','13000000-0000-4000-8000-000000000001',
  'financial_closing_overdue',null,null,'financial-closing:2026-10-21'
)$$,'scheduled notification is created');
select is((select count(*)::integer from public.organization_manager_notifications),1,'one history row exists');
select is((select count(*)::integer from public.organization_manager_push_deliveries),1,'one device delivery is queued');
select is((select created from public.create_organization_manager_notification(
  '23000000-0000-4000-8000-000000000001','13000000-0000-4000-8000-000000000001',
  'financial_closing_overdue',null,null,'financial-closing:2026-10-21')),false,'duplicate occurrence replays safely');
select is((select count(*)::integer from public.organization_manager_push_deliveries),1,'duplicate occurrence creates no delivery duplicate');
select is((select count(*)::integer from public.list_organization_manager_notifications(
  '13000000-0000-4000-8000-000000000001','23000000-0000-4000-8000-000000000001',null,50)),1,'manager lists own organization history');
select throws_ok($$select * from public.list_organization_manager_notifications(
  '13000000-0000-4000-8000-000000000001','23000000-0000-4000-8000-000000000002',null,50
)$$,'42501','manager notification access denied','cross-organization history is denied');

create temporary table first_claim as select * from public.claim_organization_manager_push_deliveries(
  '73000000-0000-4000-8000-000000000001',10,60);
select is((select count(*)::integer from first_claim),1,'first worker claims one delivery');
select is((select count(*)::integer from public.claim_organization_manager_push_deliveries(
  '73000000-0000-4000-8000-000000000002',10,60)),0,'second worker cannot double-claim a live lease');
select throws_ok(format('select * from public.complete_organization_manager_push_delivery(%L,%L,''sent'',201)',
  (select delivery_id from first_claim),'73000000-0000-4000-8000-000000000099'),
  '55000','manager push lease is not active','wrong lease token cannot complete delivery');

update public.organization_manager_push_deliveries set lease_expires_at=statement_timestamp()-interval'1 second';
create temporary table crash_reclaim as select * from public.claim_organization_manager_push_deliveries(
  '73000000-0000-4000-8000-000000000002',10,60);
select is((select attempt_count from crash_reclaim),2,'expired worker lease is recovered and retried');
select is((select state from public.complete_organization_manager_push_delivery(
  (select delivery_id from crash_reclaim),(select lease_token from crash_reclaim),'terminal',410)),
  'terminal','expired push endpoint becomes terminal');
select ok((select disabled_at is not null from public.push_subscriptions
  where endpoint='https://fcm.googleapis.com/fcm/send/manager-device'),'HTTP 410 disables the endpoint');
select is((select read_at is not null from public.mark_organization_manager_notification_read(
  '13000000-0000-4000-8000-000000000001','23000000-0000-4000-8000-000000000001',
  (select id from public.organization_manager_notifications limit 1))),true,'manager marks own notification read');
select throws_ok($$update public.organization_manager_notifications set event_type='cash_monitoring_submitted'$$,
  '42501','manager notification history is immutable','source history cannot be rewritten');

select * from finish();
rollback;
