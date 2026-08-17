begin;
select plan(26);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email, '{}', '{}', now(), now()
from (values
  ('1a900000-0000-4000-8000-000000000001'::uuid, 'supervisor@push.invalid'),
  ('1a900000-0000-4000-8000-000000000002'::uuid, 'maintenance@push.invalid'),
  ('1a900000-0000-4000-8000-000000000003'::uuid, 'other-maintenance@push.invalid'),
  ('1a900000-0000-4000-8000-000000000004'::uuid, 'manager@push.invalid'),
  ('1a900000-0000-4000-8000-000000000005'::uuid, 'disabled-maintenance@push.invalid'),
  ('1a900000-0000-4000-8000-000000000006'::uuid, 'pending-maintenance@push.invalid'),
  ('1a900000-0000-4000-8000-000000000007'::uuid, 'inactive-maintenance@push.invalid')
) users(id, email);

update public.profiles set full_name = case id
  when '1a900000-0000-4000-8000-000000000001' then 'Push Supervisor'
  when '1a900000-0000-4000-8000-000000000002' then 'Push Maintenance'
  when '1a900000-0000-4000-8000-000000000003' then 'Other Push Maintenance'
  when '1a900000-0000-4000-8000-000000000005' then 'Disabled Push Maintenance'
  when '1a900000-0000-4000-8000-000000000006' then 'Pending Push Maintenance'
  else 'Inactive Push Maintenance'
end,
must_change_password = case when id = '1a900000-0000-4000-8000-000000000006' then true else false end,
disabled_at = case when id = '1a900000-0000-4000-8000-000000000005' then now() else null end
where id::text like '1a900000-%';

insert into public.organizations(id,name,slug) values
 ('2a900000-0000-4000-8000-000000000001','Push Org','push-org'),
 ('2a900000-0000-4000-8000-000000000002','Other Push Org','other-push-org');
insert into public.branches(id,organization_id,name,code,timezone) values
 ('3a900000-0000-4000-8000-000000000001','2a900000-0000-4000-8000-000000000001','Push Branch','PUSH','Asia/Riyadh'),
 ('3a900000-0000-4000-8000-000000000002','2a900000-0000-4000-8000-000000000002','Other Push Branch','OPUSH','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role)
values ('3a900000-0000-4000-8000-000000000001','1a900000-0000-4000-8000-000000000001','branch_manager');
insert into public.organization_memberships(organization_id,user_id,role)
values ('2a900000-0000-4000-8000-000000000001','1a900000-0000-4000-8000-000000000004','organization_manager');
insert into public.maintenance_memberships(organization_id,user_id,active,created_by,updated_by) values
 ('2a900000-0000-4000-8000-000000000001','1a900000-0000-4000-8000-000000000002',true,'1a900000-0000-4000-8000-000000000004','1a900000-0000-4000-8000-000000000004'),
 ('2a900000-0000-4000-8000-000000000002','1a900000-0000-4000-8000-000000000003',true,'1a900000-0000-4000-8000-000000000004','1a900000-0000-4000-8000-000000000004'),
 ('2a900000-0000-4000-8000-000000000001','1a900000-0000-4000-8000-000000000005',true,'1a900000-0000-4000-8000-000000000004','1a900000-0000-4000-8000-000000000004'),
 ('2a900000-0000-4000-8000-000000000001','1a900000-0000-4000-8000-000000000006',true,'1a900000-0000-4000-8000-000000000004','1a900000-0000-4000-8000-000000000004'),
 ('2a900000-0000-4000-8000-000000000001','1a900000-0000-4000-8000-000000000007',false,'1a900000-0000-4000-8000-000000000004','1a900000-0000-4000-8000-000000000004');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id,company_name)
values('5a900000-0000-4000-8000-000000000001','2a900000-0000-4000-8000-000000000001','3a900000-0000-4000-8000-000000000001','1a900000-0000-4000-8000-000000000001','Push Company');

select has_table('public','push_subscriptions','push subscriptions table exists');
select ok(not has_table_privilege('authenticated','public.push_subscriptions','insert'),'authenticated cannot insert push subscriptions directly');
select ok(not has_table_privilege('authenticated','public.push_subscriptions','select'),'authenticated cannot select push subscriptions directly');
select ok(has_function_privilege('service_role','public.register_maintenance_push_subscription(uuid,text,text,text,text)','execute'),'service role can register push subscriptions through RPC');
select ok(not has_function_privilege('authenticated','public.register_maintenance_push_subscription(uuid,text,text,text,text)','execute'),'authenticated cannot execute push registration RPC directly');
select ok((select bool_and(coalesce(array_to_string(proconfig,','),'') like '%search_path=""%') from pg_proc where oid=any(array[
 'public.register_maintenance_push_subscription(uuid,text,text,text,text)'::regprocedure,
 'public.disable_maintenance_push_subscription(uuid,text)'::regprocedure,
 'public.list_maintenance_issue_push_subscriptions(uuid)'::regprocedure,
 'public.disable_push_subscription_delivery(uuid,text)'::regprocedure
])),'push RPCs use empty search_path');

set local role service_role;
select lives_ok($$select * from public.register_maintenance_push_subscription(
 '1a900000-0000-4000-8000-000000000002',
 'https://push.example/endpoint-a',
 'abcdefghijklmnopqrstuvwxyz',
 'authsecret',
 'Chrome Test'
)$$,'active Maintenance user registers a push subscription');
reset role;

select is((select count(*) from public.push_subscriptions where user_id='1a900000-0000-4000-8000-000000000002' and disabled_at is null),1::bigint,'one active subscription is stored');
select is((select user_agent from public.push_subscriptions where endpoint='https://push.example/endpoint-a'),'Chrome Test','user agent is stored without exposing keys');

set local role service_role;
select lives_ok($$select * from public.register_maintenance_push_subscription(
 '1a900000-0000-4000-8000-000000000002',
 'https://push.example/endpoint-a',
 'zyxwvutsrqponmlkjihgfedcba',
 'newsecret',
 'Chrome Test Updated'
)$$,'same endpoint upserts for same user');
reset role;
select is((select count(*) from public.push_subscriptions where endpoint='https://push.example/endpoint-a'),1::bigint,'endpoint uniqueness prevents duplicate rows');
select is((select p256dh from public.push_subscriptions where endpoint='https://push.example/endpoint-a'),'zyxwvutsrqponmlkjihgfedcba','endpoint keys update on upsert');

select throws_ok($$select * from public.register_maintenance_push_subscription(
 '1a900000-0000-4000-8000-000000000003',
 'https://push.example/endpoint-a',
 'abcdefghijklmnopqrstuvwxyz',
 'authsecret'
)$$,'23505','push subscription endpoint already exists','another user cannot take over endpoint');
select throws_ok($$select * from public.register_maintenance_push_subscription(
 '1a900000-0000-4000-8000-000000000005',
 'https://push.example/disabled',
 'abcdefghijklmnopqrstuvwxyz',
 'authsecret'
)$$,'42501','maintenance push access denied','disabled profile cannot register');
select throws_ok($$select * from public.register_maintenance_push_subscription(
 '1a900000-0000-4000-8000-000000000006',
 'https://push.example/pending',
 'abcdefghijklmnopqrstuvwxyz',
 'authsecret'
)$$,'42501','maintenance push access denied','must-change-password profile cannot register');
select throws_ok($$select * from public.register_maintenance_push_subscription(
 '1a900000-0000-4000-8000-000000000007',
 'https://push.example/inactive',
 'abcdefghijklmnopqrstuvwxyz',
 'authsecret'
)$$,'42501','maintenance push access denied','inactive membership cannot register');
select throws_ok($$select * from public.register_maintenance_push_subscription(
 '1a900000-0000-4000-8000-000000000002',
 'http://push.example/insecure',
 'abcdefghijklmnopqrstuvwxyz',
 'authsecret'
)$$,'22023','invalid push subscription','insecure endpoint is rejected');

set local role service_role;
select lives_ok($$select * from public.create_supervisor_maintenance_issue(
 '1a900000-0000-4000-8000-000000000001',
 '3a900000-0000-4000-8000-000000000001',
 jsonb_build_object('title','  Freezer not cooling  ','category','refrigeration','priority','urgent')
)$$,'supervisor creates issue for push recipient lookup');
reset role;

create temp table push_issue_ids as
select id as issue_id from public.maintenance_issues where organization_id='2a900000-0000-4000-8000-000000000001' order by created_at desc limit 1;
grant select on push_issue_ids to service_role;

select is((select count(*)::int from public.list_maintenance_issue_push_subscriptions((select issue_id from push_issue_ids))),1,'recipient query includes only active same-org Maintenance subscriptions');
select is((select organization_name from public.list_maintenance_issue_push_subscriptions((select issue_id from push_issue_ids)) limit 1),'Push Org','recipient payload includes organization name');
select is((select branch_name from public.list_maintenance_issue_push_subscriptions((select issue_id from push_issue_ids)) limit 1),'Push Branch','recipient payload includes branch name');
select is((select issue_title from public.list_maintenance_issue_push_subscriptions((select issue_id from push_issue_ids)) limit 1),'Freezer not cooling','recipient payload includes normalized issue title');

select ok(public.disable_push_subscription_delivery(
 (select id from public.push_subscriptions where endpoint='https://push.example/endpoint-a'),
 'https://push.example/endpoint-a'
),'delivery cleanup disables the failed endpoint');
select is((select count(*)::int from public.list_maintenance_issue_push_subscriptions((select issue_id from push_issue_ids))),0,'disabled endpoint is removed from recipient query');

set local role service_role;
select lives_ok($$select * from public.register_maintenance_push_subscription(
 '1a900000-0000-4000-8000-000000000002',
 'https://push.example/endpoint-a',
 'abcdefghijklmnopqrstuvwxyz',
 'authsecret'
)$$,'disabled endpoint can be reactivated by owner');
reset role;
select is((select count(*)::int from public.list_maintenance_issue_push_subscriptions((select issue_id from push_issue_ids))),1,'reactivated endpoint returns to recipient query');

select * from finish();
rollback;
