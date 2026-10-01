begin;
select plan(16);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email, '{}', '{}', now(), now()
from (values
  ('1e000000-0000-4000-8000-000000000001'::uuid, 'push-supervisor@example.invalid'),
  ('1e000000-0000-4000-8000-000000000002'::uuid, 'push-buyer@example.invalid'),
  ('1e000000-0000-4000-8000-000000000003'::uuid, 'push-inactive@example.invalid'),
  ('1e000000-0000-4000-8000-000000000004'::uuid, 'push-disabled@example.invalid'),
  ('1e000000-0000-4000-8000-000000000005'::uuid, 'push-password@example.invalid'),
  ('1e000000-0000-4000-8000-000000000006'::uuid, 'push-other-org@example.invalid')
) user_data(id,email);

update public.profiles
set full_name = 'Push Test User', must_change_password = false
where id::text like '1e000000-%';
update public.profiles set disabled_at = now() where id = '1e000000-0000-4000-8000-000000000004';
update public.profiles set must_change_password = true where id = '1e000000-0000-4000-8000-000000000005';

insert into public.organizations(id,name,slug) values
 ('2e000000-0000-4000-8000-000000000001','Push Org','push-org'),
 ('2e000000-0000-4000-8000-000000000002','Other Push Org','other-push-org');
insert into public.branches(id,organization_id,name,code,timezone) values
 ('3e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','Push Branch','PUSH','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role) values
 ('3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000001','branch_manager');
insert into public.purchasing_memberships(organization_id,user_id,active) values
 ('2e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000002',true),
 ('2e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000003',false),
 ('2e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000004',true),
 ('2e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000005',true),
 ('2e000000-0000-4000-8000-000000000002','1e000000-0000-4000-8000-000000000006',true);

select ok(to_regclass('public.purchase_request_creation_idempotency') is not null,'Purchase Request idempotency table exists');
select ok(has_function_privilege('service_role','public.create_supervisor_purchase_request(uuid,uuid,uuid,text,text,text,jsonb)','execute'),'service role executes idempotent create RPC');
select ok(not has_function_privilege('authenticated','public.create_supervisor_purchase_request(uuid,uuid,uuid,text,text,text,jsonb)','execute'),'authenticated cannot execute create RPC directly');
select ok(not has_table_privilege('authenticated','public.purchase_request_creation_idempotency','select'),'authenticated cannot read idempotency rows');

select lives_ok($$select * from public.register_purchasing_push_subscription(
 '1e000000-0000-4000-8000-000000000002','https://push.example/buyer','abcdefghijklmnopqrstuvwxyz','authsecret','Browser'
)$$,'active Purchasing user registers existing push subscription model');
select throws_ok($$select * from public.register_purchasing_push_subscription(
 '1e000000-0000-4000-8000-000000000001','https://push.example/supervisor','abcdefghijklmnopqrstuvwxyz','authsecret','Browser'
)$$,'42501','purchasing push access denied','Supervisor without Purchasing membership cannot register');

create temporary table push_request_result as
select public.create_supervisor_purchase_request(
 '1e000000-0000-4000-8000-000000000001',
 '3e000000-0000-4000-8000-000000000001',
 '4e000000-0000-4000-8000-000000000001',
 repeat('a',64),
 'kitchen',
 null,
 '[{"name":"Gloves","quantity":1,"unit":"box","notes":null}]'::jsonb
) as payload;

select is((select payload->>'created' from push_request_result),'true','first execution reports created true');
select is((select count(*) from public.purchase_requests where branch_id='3e000000-0000-4000-8000-000000000001'),1::bigint,'first execution creates one request');
select is(public.create_supervisor_purchase_request(
 '1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001',
 '4e000000-0000-4000-8000-000000000001',repeat('a',64),'kitchen',null,
 '[{"name":"Gloves","quantity":1,"unit":"box","notes":null}]'::jsonb
)->>'created','false','same key and hash reports replay');
select is((select count(*) from public.purchase_requests where branch_id='3e000000-0000-4000-8000-000000000001'),1::bigint,'replay does not duplicate request');
select throws_ok($$select public.create_supervisor_purchase_request(
 '1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001',
 '4e000000-0000-4000-8000-000000000001',repeat('b',64),'kitchen',null,
 '[{"name":"Gloves","quantity":2,"unit":"box","notes":null}]'::jsonb
)$$,'23505','purchase request idempotency conflict','changed payload conflicts');

insert into public.push_subscriptions(user_id,endpoint,p256dh,auth,disabled_at) values
 ('1e000000-0000-4000-8000-000000000003','https://push.example/inactive','abcdefghijklmnopqrstuvwxyz','authsecret',null),
 ('1e000000-0000-4000-8000-000000000004','https://push.example/disabled','abcdefghijklmnopqrstuvwxyz','authsecret',null),
 ('1e000000-0000-4000-8000-000000000005','https://push.example/password','abcdefghijklmnopqrstuvwxyz','authsecret',null),
 ('1e000000-0000-4000-8000-000000000006','https://push.example/other','abcdefghijklmnopqrstuvwxyz','authsecret',null),
 ('1e000000-0000-4000-8000-000000000002','https://push.example/old-disabled','abcdefghijklmnopqrstuvwxyz','authsecret',now());

select is((select count(*) from public.list_purchase_request_push_subscriptions(
 (select (payload->'purchase_request'->>'id')::uuid from push_request_result)
)),1::bigint,'only eligible active same-organization subscription is selected');
select is((select user_id from public.list_purchase_request_push_subscriptions(
 (select (payload->'purchase_request'->>'id')::uuid from push_request_result)
)),'1e000000-0000-4000-8000-000000000002'::uuid,'recipient is the active Purchasing member');
select is((select organization_id from public.list_purchase_request_push_subscriptions(
 (select (payload->'purchase_request'->>'id')::uuid from push_request_result)
)),'2e000000-0000-4000-8000-000000000001'::uuid,'recipient lookup remains organization-scoped');
select is((select count(*) from public.purchase_request_creation_idempotency),1::bigint,'one idempotency response is retained');
select ok((select response_json ? 'purchase_request' from public.purchase_request_creation_idempotency),'original response is retained for replay');

select * from finish();
rollback;
