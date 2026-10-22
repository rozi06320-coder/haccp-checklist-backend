begin;
select plan(25);

-- Test 8: Privilege checks & function security properties
select has_function('public','authorize_organization_manager_push_delivery',array['uuid','uuid'],
  'authorize_organization_manager_push_delivery exists');
select ok(has_function_privilege('service_role','public.authorize_organization_manager_push_delivery(uuid,uuid)','execute'),
  'service_role has execute privilege');
select ok(not has_function_privilege('authenticated','public.authorize_organization_manager_push_delivery(uuid,uuid)','execute'),
  'authenticated has no execute privilege');
select ok(not has_function_privilege('anon','public.authorize_organization_manager_push_delivery(uuid,uuid)','execute'),
  'anon has no execute privilege');

-- Test 9: Function contract & security definer properties
select ok((select prosecdef from pg_proc where oid='public.authorize_organization_manager_push_delivery(uuid,uuid)'::regprocedure),
  'function is security definer');
select ok((select coalesce(array_to_string(proconfig,','),'') like '%search_path=""%'
  from pg_proc where oid='public.authorize_organization_manager_push_delivery(uuid,uuid)'::regprocedure),
  'function has empty search_path');

-- Fixtures
insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values
  ('00000000-0000-0000-0000-000000000000','15000000-0000-4000-8000-000000000001','authenticated','authenticated','mgr1@test.invalid','{}','{}',now(),now()),
  ('00000000-0000-0000-0000-000000000000','15000000-0000-4000-8000-000000000002','authenticated','authenticated','mgr2@test.invalid','{}','{}',now(),now()),
  ('00000000-0000-0000-0000-000000000003','15000000-0000-4000-8000-000000000003','authenticated','authenticated','mgr3@test.invalid','{}','{}',now(),now()),
  ('00000000-0000-0000-0000-000000000004','15000000-0000-4000-8000-000000000004','authenticated','authenticated','spv1@test.invalid','{}','{}',now(),now());

update public.profiles set full_name='Manager One',must_change_password=false,disabled_at=null
where id='15000000-0000-4000-8000-000000000001';
update public.profiles set full_name='Manager Two',must_change_password=false,disabled_at=null
where id='15000000-0000-4000-8000-000000000002';
update public.profiles set full_name='Manager Inactive',must_change_password=false,disabled_at=null
where id='15000000-0000-4000-8000-000000000003';
update public.profiles set full_name='Supervisor One',must_change_password=false,disabled_at=null
where id='15000000-0000-4000-8000-000000000004';

insert into public.organizations(id,name,slug,active) values
  ('25000000-0000-4000-8000-000000000001','Hardening Org 1','hardening-org-1',true),
  ('25000000-0000-4000-8000-000000000002','Hardening Org 2','hardening-org-2',true);

insert into public.branches(id,organization_id,name,code,timezone) values
  ('35000000-0000-4000-8000-000000000001','25000000-0000-4000-8000-000000000001','Hardening Branch 1','HB01','Asia/Riyadh');

insert into public.branch_memberships(branch_id,user_id,role,active) values
  ('35000000-0000-4000-8000-000000000001','15000000-0000-4000-8000-000000000004','branch_manager',true);

insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id,company_name) values
  ('55000000-0000-4000-8000-000000000001','25000000-0000-4000-8000-000000000001','35000000-0000-4000-8000-000000000001','15000000-0000-4000-8000-000000000004','Team 1');

insert into public.organization_memberships(organization_id,user_id,role,active) values
  ('25000000-0000-4000-8000-000000000001','15000000-0000-4000-8000-000000000001','organization_manager',true),
  ('25000000-0000-4000-8000-000000000002','15000000-0000-4000-8000-000000000002','organization_manager',true),
  ('25000000-0000-4000-8000-000000000001','15000000-0000-4000-8000-000000000003','organization_manager',false);

-- Subscriptions for Manager 1
insert into public.push_subscriptions(id,user_id,endpoint,p256dh,auth,user_agent,last_seen_at,disabled_at) values
  ('45000000-0000-4000-8000-000000000001','15000000-0000-4000-8000-000000000001','https://fcm.googleapis.com/fcm/send/token-mgr1','abcdefghijklmnopqrstuvwxyz','authsecret1','Agent1',statement_timestamp(),null),
  ('45000000-0000-4000-8000-000000000002','15000000-0000-4000-8000-000000000001','https://fcm.googleapis.com/fcm/send/token-mgr1-device2','abcdefghijklmnopqrstuvwxyz','authsecret2','Agent2',statement_timestamp(),null);

-- Subscriptions for Manager 2 (Org 2)
insert into public.push_subscriptions(id,user_id,endpoint,p256dh,auth,user_agent,last_seen_at,disabled_at) values
  ('45000000-0000-4000-8000-000000000003','15000000-0000-4000-8000-000000000002','https://fcm.googleapis.com/fcm/send/token-mgr2','abcdefghijklmnopqrstuvwxyz','authsecret3','Agent3',statement_timestamp(),null);

-- Subscriptions for Inactive Manager 3
insert into public.push_subscriptions(id,user_id,endpoint,p256dh,auth,user_agent,last_seen_at,disabled_at) values
  ('45000000-0000-4000-8000-000000000004','15000000-0000-4000-8000-000000000003','https://fcm.googleapis.com/fcm/send/token-mgr3','abcdefghijklmnopqrstuvwxyz','authsecret4','Agent4',statement_timestamp(),null);

-- Ensure producer is OFF initially
update private.organization_manager_push_producer_config set enabled=false, activation_cutoff=null where singleton;

-- 1. Create non-maintenance notification (financial_closing_overdue)
select lives_ok($$select * from public.create_organization_manager_notification(
  '25000000-0000-4000-8000-000000000001',
  '15000000-0000-4000-8000-000000000001',
  'financial_closing_overdue',
  null,
  null,
  'closing-overdue:2026-10-22:HB01'
)$$,'non-maintenance notification creates history and deliveries');

-- Grab delivery for non-maintenance notification on active sub 1
create temporary table non_maint_delivery as
select delivery.id as delivery_id
from public.organization_manager_push_deliveries delivery
join public.organization_manager_notifications notification on notification.id = delivery.notification_id
where notification.occurrence_key = 'closing-overdue:2026-10-22:HB01'
  and delivery.push_subscription_id = '45000000-0000-4000-8000-000000000001';

-- Set to sending with lease token
update public.organization_manager_push_deliveries
set state = 'sending',
    lease_token = '65000000-0000-4000-8000-000000000001',
    leased_by = '95000000-0000-4000-8000-000000000001',
    lease_expires_at = statement_timestamp() + interval '60 seconds'
where id = (select delivery_id from non_maint_delivery);

-- Test 1: Unsupported event authorization denied (MF-1 core test)
create temporary table non_maint_auth_result as
select * from public.authorize_organization_manager_push_delivery(
  (select delivery_id from non_maint_delivery),
  '65000000-0000-4000-8000-000000000001'::uuid
);
select is((select authorized from non_maint_auth_result), false,
  'unsupported event authorization denied');
select is((select terminal_reason from public.organization_manager_push_deliveries
  where id = (select delivery_id from non_maint_delivery)), 'producer_disabled',
  'unsupported event delivery is terminalized as producer_disabled');

-- 2. Maintenance notification while producer gate is OFF
insert into public.maintenance_issues(id,organization_id,branch_id,supervisor_team_id,reported_by,title,category,priority,status)
values ('75000000-0000-4000-8000-000000000001','25000000-0000-4000-8000-000000000001','35000000-0000-4000-8000-000000000001','55000000-0000-4000-8000-000000000001','15000000-0000-4000-8000-000000000004','Maint Issue Off','equipment','normal','new');

select lives_ok($$select * from public.create_organization_manager_notification(
  '25000000-0000-4000-8000-000000000001',
  '15000000-0000-4000-8000-000000000001',
  'maintenance_issue_created',
  'maintenance_issue',
  '75000000-0000-4000-8000-000000000001',
  'maintenance-issue:75000000-0000-4000-8000-000000000001'
)$$,'maintenance notification created with gate OFF');

create temporary table maint_off_delivery as
select delivery.id as delivery_id
from public.organization_manager_push_deliveries delivery
join public.organization_manager_notifications notification on notification.id = delivery.notification_id
where notification.occurrence_key = 'maintenance-issue:75000000-0000-4000-8000-000000000001'
  and delivery.push_subscription_id = '45000000-0000-4000-8000-000000000001';

update public.organization_manager_push_deliveries
set state = 'sending',
    lease_token = '65000000-0000-4000-8000-000000000002',
    leased_by = '95000000-0000-4000-8000-000000000001',
    lease_expires_at = statement_timestamp() + interval '60 seconds'
where id = (select delivery_id from maint_off_delivery);

-- Test 2: Maintenance delivery denied while producer gate is OFF
create temporary table maint_off_auth_result as
select * from public.authorize_organization_manager_push_delivery(
  (select delivery_id from maint_off_delivery),
  '65000000-0000-4000-8000-000000000002'::uuid
);
select is((select authorized from maint_off_auth_result), false,
  'maintenance delivery denied while producer gate is OFF');
select is((select terminal_reason from public.organization_manager_push_deliveries
  where id = (select delivery_id from maint_off_delivery)), 'producer_disabled',
  'maintenance delivery terminalized as producer_disabled when gate is OFF');

-- 3. Maintenance delivery when producer gate is ON
select lives_ok($$select * from private.configure_organization_manager_push_producer(true, statement_timestamp())$$,
  'activate producer with cutoff');

insert into public.maintenance_issues(id,organization_id,branch_id,supervisor_team_id,reported_by,title,category,priority,status)
values ('75000000-0000-4000-8000-000000000002','25000000-0000-4000-8000-000000000001','35000000-0000-4000-8000-000000000001','55000000-0000-4000-8000-000000000001','15000000-0000-4000-8000-000000000004','Maint Issue On','equipment','normal','new');

select lives_ok($$select * from public.create_organization_manager_notification(
  '25000000-0000-4000-8000-000000000001',
  '15000000-0000-4000-8000-000000000001',
  'maintenance_issue_created',
  'maintenance_issue',
  '75000000-0000-4000-8000-000000000002',
  'maintenance-issue:75000000-0000-4000-8000-000000000002'
)$$,'maintenance notification created with gate ON');

create temporary table maint_on_delivery as
select delivery.id as delivery_id
from public.organization_manager_push_deliveries delivery
join public.organization_manager_notifications notification on notification.id = delivery.notification_id
where notification.occurrence_key = 'maintenance-issue:75000000-0000-4000-8000-000000000002'
  and delivery.push_subscription_id = '45000000-0000-4000-8000-000000000001';

update public.organization_manager_push_deliveries
set state = 'sending',
    lease_token = '65000000-0000-4000-8000-000000000003',
    leased_by = '95000000-0000-4000-8000-000000000001',
    lease_expires_at = statement_timestamp() + interval '60 seconds'
where id = (select delivery_id from maint_on_delivery);

-- Test 3: Valid Maintenance delivery can pass authorization
create temporary table maint_on_auth_result as
select * from public.authorize_organization_manager_push_delivery(
  (select delivery_id from maint_on_delivery),
  '65000000-0000-4000-8000-000000000003'::uuid
);
select is((select authorized from maint_on_auth_result), true,
  'valid maintenance delivery passes authorization when producer gate is ON');
select is((select length(topic) from maint_on_auth_result), 32,
  'topic is 32-character hex identifier');

-- Test 4: Revoked/inactive manager denied
-- Create notification for Manager 3 (inactive in Org 1)
update public.organization_memberships set active=true where user_id='15000000-0000-4000-8000-000000000003';
select lives_ok($$select * from public.create_organization_manager_notification(
  '25000000-0000-4000-8000-000000000001',
  '15000000-0000-4000-8000-000000000003',
  'maintenance_issue_created',
  'maintenance_issue',
  '75000000-0000-4000-8000-000000000002',
  'maintenance-issue:revoked-mgr'
)$$,'notification created for manager before revocation');
update public.organization_memberships set active=false where user_id='15000000-0000-4000-8000-000000000003';

create temporary table revoked_delivery as
select delivery.id as delivery_id
from public.organization_manager_push_deliveries delivery
join public.organization_manager_notifications notification on notification.id = delivery.notification_id
where notification.occurrence_key = 'maintenance-issue:revoked-mgr'
  and delivery.push_subscription_id = '45000000-0000-4000-8000-000000000004';

update public.organization_manager_push_deliveries
set state = 'sending',
    lease_token = '65000000-0000-4000-8000-000000000004',
    leased_by = '95000000-0000-4000-8000-000000000001',
    lease_expires_at = statement_timestamp() + interval '60 seconds'
where id = (select delivery_id from revoked_delivery);

select is((select authorized from public.authorize_organization_manager_push_delivery(
  (select delivery_id from revoked_delivery),
  '65000000-0000-4000-8000-000000000004'::uuid
)), false, 'revoked/inactive manager authorization denied');
select is((select terminal_reason from public.organization_manager_push_deliveries
  where id = (select delivery_id from revoked_delivery)), 'recipient_ineligible',
  'revoked manager delivery terminalized as recipient_ineligible');

-- Test 5: Disabled subscription denied (simulates disable race condition after claim)
create temporary table disabled_sub_delivery as
select delivery.id as delivery_id
from public.organization_manager_push_deliveries delivery
join public.organization_manager_notifications notification on notification.id = delivery.notification_id
where notification.occurrence_key = 'maintenance-issue:75000000-0000-4000-8000-000000000002'
  and delivery.push_subscription_id = '45000000-0000-4000-8000-000000000002';

update public.organization_manager_push_deliveries
set state = 'sending',
    lease_token = '65000000-0000-4000-8000-000000000005',
    leased_by = '95000000-0000-4000-8000-000000000001',
    lease_expires_at = statement_timestamp() + interval '60 seconds'
where id = (select delivery_id from disabled_sub_delivery);

-- Manager disables subscription after claim
update public.push_subscriptions set disabled_at = statement_timestamp()
where id = '45000000-0000-4000-8000-000000000002';

select is((select authorized from public.authorize_organization_manager_push_delivery(
  (select delivery_id from disabled_sub_delivery),
  '65000000-0000-4000-8000-000000000005'::uuid
)), false, 'disabled subscription authorization denied');
select is((select terminal_reason from public.organization_manager_push_deliveries
  where id = (select delivery_id from disabled_sub_delivery)), 'subscription_disabled',
  'disabled subscription delivery terminalized as subscription_disabled');

-- Test 6: Expired or incorrect lease token throws 55000
select throws_ok(format('select * from public.authorize_organization_manager_push_delivery(%L, %L)',
  (select delivery_id from maint_on_delivery),
  '00000000-0000-0000-0000-000000000000'::uuid),
  '55000', 'manager push lease is not active',
  'incorrect lease token throws 55000');

-- Test 7: Cross-tenant mismatch denied
-- Notification created for Manager 2 in Org 2
select lives_ok($$select * from public.create_organization_manager_notification(
  '25000000-0000-4000-8000-000000000002',
  '15000000-0000-4000-8000-000000000002',
  'financial_closing_overdue',
  null,
  null,
  'closing-overdue:org2'
)$$,'notification created in Org 2');

create temporary table org2_delivery as
select delivery.id as delivery_id
from public.organization_manager_push_deliveries delivery
join public.organization_manager_notifications notification on notification.id = delivery.notification_id
where notification.occurrence_key = 'closing-overdue:org2'
  and delivery.push_subscription_id = '45000000-0000-4000-8000-000000000003';

update public.organization_manager_push_deliveries
set state = 'sending',
    lease_token = '65000000-0000-4000-8000-000000000007',
    leased_by = '95000000-0000-4000-8000-000000000001',
    lease_expires_at = statement_timestamp() + interval '60 seconds'
where id = (select delivery_id from org2_delivery);

-- Non-maintenance event in Org 2 must be denied
select is((select authorized from public.authorize_organization_manager_push_delivery(
  (select delivery_id from org2_delivery),
  '65000000-0000-4000-8000-000000000007'::uuid
)), false, 'cross-tenant non-maintenance event authorization denied');

-- Test 10: No unrelated notification records modified
select is((select count(*)::integer from public.organization_manager_notifications
  where updated_at <> created_at), 0,
  'no notification history record was modified during authorization');

select * from finish();
rollback;
