begin;
select plan(69);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',
  id||'@manager-worker.invalid','{}','{}',now(),now()
from unnest(array[
  '14000000-0000-4000-8000-000000000001'::uuid,
  '14000000-0000-4000-8000-000000000002',
  '14000000-0000-4000-8000-000000000003',
  '14000000-0000-4000-8000-000000000004',
  '14000000-0000-4000-8000-000000000005'
]) id;

update public.profiles set full_name='Manager Worker',must_change_password=false,disabled_at=null
where id::text like'14000000-%';
update public.profiles set disabled_at=now()
where id='14000000-0000-4000-8000-000000000003';
update public.profiles set must_change_password=true
where id='14000000-0000-4000-8000-000000000004';

insert into public.organizations(id,name,slug,active) values
  ('24000000-0000-4000-8000-000000000001','Manager Worker Org','manager-worker-org',true),
  ('24000000-0000-4000-8000-000000000002','Other Manager Worker Org','other-manager-worker-org',true);
insert into public.branches(id,organization_id,name,code,timezone) values
  ('34000000-0000-4000-8000-000000000001','24000000-0000-4000-8000-000000000001','Worker Branch','WORK','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role,active) values
  ('34000000-0000-4000-8000-000000000001','14000000-0000-4000-8000-000000000001','branch_manager',true);
insert into public.organization_memberships(organization_id,user_id,role,active) values
  ('24000000-0000-4000-8000-000000000001','14000000-0000-4000-8000-000000000002','organization_manager',true),
  ('24000000-0000-4000-8000-000000000001','14000000-0000-4000-8000-000000000003','organization_manager',true),
  ('24000000-0000-4000-8000-000000000001','14000000-0000-4000-8000-000000000004','organization_manager',true),
  ('24000000-0000-4000-8000-000000000002','14000000-0000-4000-8000-000000000005','organization_manager',true);
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id,company_name) values
  ('54000000-0000-4000-8000-000000000001','24000000-0000-4000-8000-000000000001',
   '34000000-0000-4000-8000-000000000001','14000000-0000-4000-8000-000000000001','Worker Company');

select has_function('public','authorize_organization_manager_push_delivery',array['uuid','uuid'],'final authorization RPC exists');
select ok(has_function_privilege('service_role','public.authorize_organization_manager_push_delivery(uuid,uuid)','execute'),'service role can authorize a leased delivery');
select ok(not has_function_privilege('authenticated','public.authorize_organization_manager_push_delivery(uuid,uuid)','execute'),'authenticated cannot authorize delivery');
select ok(not has_function_privilege('anon','public.authorize_organization_manager_push_delivery(uuid,uuid)','execute'),'anon cannot authorize delivery');
select ok(has_function_privilege('service_role','public.claim_organization_manager_push_deliveries(uuid,integer,integer)','execute'),'service role retains queue claim access');
select ok(not has_function_privilege('authenticated','public.claim_organization_manager_push_deliveries(uuid,integer,integer)','execute'),'authenticated cannot claim queue work');
select ok(has_function_privilege('service_role','public.complete_organization_manager_push_delivery(uuid,uuid,text,integer)','execute'),'service role retains lease completion access');
select ok(not has_function_privilege('authenticated','public.complete_organization_manager_push_delivery(uuid,uuid,text,integer)','execute'),'authenticated cannot complete queue work');
select ok(not has_function_privilege('service_role','private.browser_push_endpoint_is_allowed(text)','execute'),'service role cannot call the private endpoint validator directly');
select ok((select coalesce(array_to_string(proconfig,','),'') like'%search_path=""%'
  from pg_proc where oid='public.authorize_organization_manager_push_delivery(uuid,uuid)'::regprocedure),'authorization RPC has empty search path');
select ok((select coalesce(array_to_string(proconfig,','),'') like'%search_path=""%'
  from pg_proc where oid='public.complete_organization_manager_push_delivery(uuid,uuid,text,integer)'::regprocedure),'completion RPC retains empty search path');

select ok(private.browser_push_endpoint_is_allowed('https://fcm.googleapis.com/fcm/send/token'),'FCM is accepted');
select ok(private.browser_push_endpoint_is_allowed('https://updates.push.services.mozilla.com/wpush/v2/token'),'Mozilla is accepted');
select ok(private.browser_push_endpoint_is_allowed('https://web.push.apple.com/QHtoken'),'Apple is accepted');
select ok(private.browser_push_endpoint_is_allowed('https://wns2-am3p.notify.windows.com/w/?token=value'),'Windows is accepted');
select ok(not private.browser_push_endpoint_is_allowed('https://127.0.0.1/private'),'IP targets are rejected');
select ok(not private.browser_push_endpoint_is_allowed('https://fcm.googleapis.com.evil.invalid/push'),'provider lookalikes are rejected');
select ok(not private.browser_push_endpoint_is_allowed('https://fcm.googleapis.com/'),'root-only provider paths are rejected');
select ok(not private.browser_push_endpoint_is_allowed('https://FCM.GOOGLEAPIS.COM/fcm/send/token'),'noncanonical uppercase hosts are rejected');
select ok(not private.browser_push_endpoint_is_allowed('https://fcm.googleapis.com:443/fcm/send/token'),'explicit ports are rejected');
select ok(not private.browser_push_endpoint_is_allowed('https://-bad.push.apple.com/token'),'malformed provider labels are rejected');
select ok(not private.browser_push_endpoint_is_allowed('https://fcm.googleapis.com/bad\path'),'backslashes are rejected');

select lives_ok($$select * from public.register_organization_manager_push_subscription(
  '14000000-0000-4000-8000-000000000002','24000000-0000-4000-8000-000000000001',
  'https://fcm.googleapis.com/fcm/send/worker-one','abcdefghijklmnopqrstuvwxyz','authsecret-one','Chrome')$$,
  'manager registers first device');
select lives_ok($$select * from public.register_organization_manager_push_subscription(
  '14000000-0000-4000-8000-000000000002','24000000-0000-4000-8000-000000000001',
  'https://web.push.apple.com/worker-two','zyxwvutsrqponmlkjihgfedcba','authsecret-two','Safari')$$,
  'manager registers second device');

select has_table('private','organization_manager_push_producer_config','database producer gate exists');
select is((select enabled from private.organization_manager_push_producer_config where singleton),false,
  'migration leaves the database producer disabled');
select ok(not has_function_privilege('service_role','private.configure_organization_manager_push_producer(boolean,timestamptz)','execute'),
  'ordinary service role cannot activate the database producer');
select lives_ok($$select * from public.create_supervisor_maintenance_issue_v2(
  '14000000-0000-4000-8000-000000000001','34000000-0000-4000-8000-000000000001',
  jsonb_build_object('issue_id','74000000-0000-4000-8000-000000000000','idempotency_key','84000000-0000-4000-8000-000000000000',
    'title','Producer disabled issue','category','equipment','priority','normal'))$$,'maintenance creation works while producer is disabled');
select is((select count(*)::integer from public.organization_manager_notifications
  where source_id='74000000-0000-4000-8000-000000000000'),0,'disabled producer accumulates no manager backlog');
select lives_ok($$select * from private.configure_organization_manager_push_producer(true,statement_timestamp())$$,
  'database owner explicitly activates the producer with a cutoff');
select is((select enabled from private.organization_manager_push_producer_config where singleton),true,
  'producer is enabled only after explicit owner activation');

select lives_ok($$select * from public.create_supervisor_maintenance_issue_v2(
  '14000000-0000-4000-8000-000000000001','34000000-0000-4000-8000-000000000001',
  jsonb_build_object('issue_id','74000000-0000-4000-8000-000000000001','idempotency_key','84000000-0000-4000-8000-000000000001',
    'title','Worker issue','category','equipment','priority','normal'))$$,'maintenance issue and notification commit together');
select is((select count(*)::integer from public.organization_manager_notifications
  where source_id='74000000-0000-4000-8000-000000000001'),1,'one notification history row is created');
select is((select recipient_user_id from public.organization_manager_notifications
  where source_id='74000000-0000-4000-8000-000000000001'),'14000000-0000-4000-8000-000000000002'::uuid,'only eligible same-organization manager receives history');
select is((select count(*)::integer from public.organization_manager_push_deliveries delivery
  join public.organization_manager_notifications notification on notification.id=delivery.notification_id
  where notification.source_id='74000000-0000-4000-8000-000000000001'),2,'both manager devices receive durable delivery rows');
select is((select occurrence_key from public.organization_manager_notifications
  where source_id='74000000-0000-4000-8000-000000000001'),'maintenance-issue:74000000-0000-4000-8000-000000000001','occurrence key is stable');
select is((select count(*)::integer from public.organization_manager_notifications
  where organization_id='24000000-0000-4000-8000-000000000002'),0,'other organization receives no history');
select lives_ok($$select * from public.create_supervisor_maintenance_issue_v2(
  '14000000-0000-4000-8000-000000000001','34000000-0000-4000-8000-000000000001',
  jsonb_build_object('issue_id','74000000-0000-4000-8000-000000000001','idempotency_key','84000000-0000-4000-8000-000000000001',
    'title','Worker issue','category','equipment','priority','normal'))$$,'idempotent maintenance replay succeeds');
select is((select count(*)::integer from public.organization_manager_notifications
  where source_id='74000000-0000-4000-8000-000000000001'),1,'idempotent replay creates no duplicate notification');
select is((select count(*)::integer from public.organization_manager_push_deliveries delivery
  join public.organization_manager_notifications notification on notification.id=delivery.notification_id
  where notification.source_id='74000000-0000-4000-8000-000000000001'),2,'idempotent replay creates no duplicate deliveries');

savepoint maintenance_event_rollback;
select lives_ok($$select * from public.create_supervisor_maintenance_issue_v2(
  '14000000-0000-4000-8000-000000000001','34000000-0000-4000-8000-000000000001',
  jsonb_build_object('issue_id','74000000-0000-4000-8000-000000000004','idempotency_key','84000000-0000-4000-8000-000000000004',
    'title','Rolled back issue','category','equipment','priority','normal'))$$,'rollback fixture creates its issue and queue atomically');
rollback to savepoint maintenance_event_rollback;
select is((select count(*)::integer from public.maintenance_issues
  where id='74000000-0000-4000-8000-000000000004'),0,'maintenance transaction rollback removes the issue');
select is((select count(*)::integer from public.organization_manager_notifications
  where source_id='74000000-0000-4000-8000-000000000004'),0,'maintenance transaction rollback removes notification history and deliveries');

create temporary table worker_claim_one as select * from public.claim_organization_manager_push_deliveries(
  '94000000-0000-4000-8000-000000000001',100,60);
select is((select count(*)::integer from worker_claim_one),2,'first worker claims both device deliveries');
select is((select count(*)::integer from public.claim_organization_manager_push_deliveries(
  '94000000-0000-4000-8000-000000000002',100,60)),0,'second worker cannot claim live leases');
create temporary table worker_authorized as select * from public.authorize_organization_manager_push_delivery(
  (select delivery_id from worker_claim_one order by endpoint limit 1),
  (select lease_token from worker_claim_one order by endpoint limit 1));
select is((select authorized from worker_authorized),true,'final authorization accepts current manager and subscription');
select is((select length(topic) from worker_authorized),32,'stable provider topic is a 32-character notification identifier');

update public.organization_memberships set active=false
where organization_id='24000000-0000-4000-8000-000000000001'
  and user_id='14000000-0000-4000-8000-000000000002';
select is((select authorized from public.authorize_organization_manager_push_delivery(
  (select delivery_id from worker_claim_one order by endpoint desc limit 1),
  (select lease_token from worker_claim_one order by endpoint desc limit 1))),false,'revocation after claim fails final authorization');
select is((select terminal_reason from public.organization_manager_push_deliveries
  where id=(select delivery_id from worker_claim_one order by endpoint desc limit 1)),'recipient_ineligible','revoked claim is terminalized');
select is((select state from public.complete_organization_manager_push_delivery(
  (select delivery_id from worker_claim_one order by endpoint limit 1),
  (select lease_token from worker_claim_one order by endpoint limit 1),'sent',201)),'sent','already authorized delivery completes by lease token');
select lives_ok($$update public.organization_memberships set active=true
  where organization_id='24000000-0000-4000-8000-000000000001'
    and user_id='14000000-0000-4000-8000-000000000002'$$,'manager eligibility is restored for remaining queue tests');

select lives_ok($$select * from public.create_supervisor_maintenance_issue_v2(
  '14000000-0000-4000-8000-000000000001','34000000-0000-4000-8000-000000000001',
  jsonb_build_object('issue_id','74000000-0000-4000-8000-000000000002','idempotency_key','84000000-0000-4000-8000-000000000002',
    'title','Disable race issue','category','equipment','priority','normal'))$$,'second issue creates queue rows');
create temporary table worker_claim_two as select * from public.claim_organization_manager_push_deliveries(
  '94000000-0000-4000-8000-000000000001',100,60);
select is((select count(*)::integer from worker_claim_two),2,'second issue device rows are claimed');
select lives_ok($$select * from public.disable_organization_manager_push_subscription(
  '14000000-0000-4000-8000-000000000002','24000000-0000-4000-8000-000000000001',
  'https://fcm.googleapis.com/fcm/send/worker-one')$$,'manager disables a subscription after claim');
select is((select state from public.organization_manager_push_deliveries
  where id=(select delivery_id from worker_claim_two where endpoint='https://fcm.googleapis.com/fcm/send/worker-one')),'terminal','disable terminalizes a sending delivery');
select throws_ok(format('select * from public.authorize_organization_manager_push_delivery(%L,%L)',
  (select delivery_id from worker_claim_two where endpoint='https://fcm.googleapis.com/fcm/send/worker-one'),
  (select lease_token from worker_claim_two where endpoint='https://fcm.googleapis.com/fcm/send/worker-one')),
  '55000','manager push lease is not active','disabled claimed lease cannot be authorized');
select lives_ok(format('update public.organization_manager_push_deliveries set attempt_count=5,lease_expires_at=statement_timestamp()-interval''1 second'' where id=%L',
  (select delivery_id from worker_claim_two where endpoint='https://web.push.apple.com/worker-two')),'fifth attempt lease is expired for recovery');
select is((select count(*)::integer from public.claim_organization_manager_push_deliveries(
  '94000000-0000-4000-8000-000000000002',100,60)),0,'expired fifth attempt is not reclaimed');
select is((select terminal_reason from public.organization_manager_push_deliveries
  where id=(select delivery_id from worker_claim_two where endpoint='https://web.push.apple.com/worker-two')),'retry_exhausted','fifth expired attempt becomes terminal');

select lives_ok($$select * from public.register_organization_manager_push_subscription(
  '14000000-0000-4000-8000-000000000002','24000000-0000-4000-8000-000000000001',
  'https://updates.push.services.mozilla.com/wpush/v2/worker-three','abcdefghijklmnopqrstuvwxzy','authsecret-three','Firefox')$$,
  'manager registers third device');
select lives_ok($$select * from public.create_supervisor_maintenance_issue_v2(
  '14000000-0000-4000-8000-000000000001','34000000-0000-4000-8000-000000000001',
  jsonb_build_object('issue_id','74000000-0000-4000-8000-000000000003','idempotency_key','84000000-0000-4000-8000-000000000003',
    'title','Deleted subscription issue','category','equipment','priority','normal'))$$,'third issue creates delivery rows');
select lives_ok($$delete from public.push_subscriptions
  where endpoint='https://updates.push.services.mozilla.com/wpush/v2/worker-three'$$,'subscription deletion preserves delivery history');
select is((select count(*)::integer from public.organization_manager_push_deliveries delivery
  join public.organization_manager_notifications notification on notification.id=delivery.notification_id
  where notification.source_id='74000000-0000-4000-8000-000000000003'
    and delivery.push_subscription_id is null),1,'deleted subscription leaves a historical null binding');
create temporary table worker_claim_three as select * from public.claim_organization_manager_push_deliveries(
  '94000000-0000-4000-8000-000000000001',100,60);
select is((select count(*)::integer from worker_claim_three),1,'only the remaining active subscription is claimed');
select is((select terminal_reason from public.organization_manager_push_deliveries delivery
  join public.organization_manager_notifications notification on notification.id=delivery.notification_id
  where notification.source_id='74000000-0000-4000-8000-000000000003'
    and delivery.push_subscription_id is null),'subscription_disabled','orphaned delivery is terminalized');
select lives_ok(format('update public.organization_manager_push_deliveries set lease_expires_at=statement_timestamp()-interval''1 second'' where id=%L',
  (select delivery_id from worker_claim_three limit 1)),'active worker lease is expired to simulate a crash before send');
create temporary table worker_reclaim as select * from public.claim_organization_manager_push_deliveries(
  '94000000-0000-4000-8000-000000000002',100,60);
select is((select attempt_count from worker_reclaim),2,'expired lease is recovered as a second at-least-once attempt');
select is((select state from public.complete_organization_manager_push_delivery(
  (select delivery_id from worker_reclaim),(select lease_token from worker_reclaim),'terminal',400)),'terminal','reclaimed delivery can be terminally completed');
select is((select count(*)::integer from public.organization_manager_push_deliveries where state='sending'),0,'no live sending rows remain after test completion');

select * from finish();
rollback;
