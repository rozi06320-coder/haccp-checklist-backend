begin;
select plan(21);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email, '{}', '{}', now(), now()
from (values
  ('1d000000-0000-4000-8000-000000000001'::uuid, 'internal-admin@example.invalid'),
  ('1d000000-0000-4000-8000-000000000002'::uuid, 'manager@example.invalid'),
  ('1d000000-0000-4000-8000-000000000003'::uuid, 'other-manager@example.invalid'),
  ('1d000000-0000-4000-8000-000000000004'::uuid, 'buyer@example.invalid'),
  ('1d000000-0000-4000-8000-000000000005'::uuid, 'supervisor@example.invalid')
) user_data(id,email);

update public.profiles
set full_name = case id
  when '1d000000-0000-4000-8000-000000000001' then 'Internal Admin'
  when '1d000000-0000-4000-8000-000000000002' then 'Manager A'
  when '1d000000-0000-4000-8000-000000000003' then 'Manager B'
  when '1d000000-0000-4000-8000-000000000004' then 'Buyer'
  else 'Supervisor'
end,
must_change_password = false
where id::text like '1d000000-%';

insert into public.internal_admin_memberships(user_id, active)
values ('1d000000-0000-4000-8000-000000000001', true);

insert into public.organizations(id,name,slug) values
 ('2d000000-0000-4000-8000-000000000001','Purchasing Org A','purchasing-org-a'),
 ('2d000000-0000-4000-8000-000000000002','Purchasing Org B','purchasing-org-b');

insert into public.organization_memberships(organization_id,user_id,role) values
 ('2d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000002','organization_manager'),
 ('2d000000-0000-4000-8000-000000000002','1d000000-0000-4000-8000-000000000003','organization_manager');

insert into public.branches(id,organization_id,name,code,timezone) values
 ('3d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','Branch A','A','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role) values
 ('3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000005','branch_manager');

select ok(has_table_privilege('authenticated','public.purchasing_memberships','select'),'authenticated can select Purchasing memberships through RLS');
select ok(not has_table_privilege('authenticated','public.purchasing_memberships','insert'),'authenticated cannot insert Purchasing memberships directly');
select ok(not has_table_privilege('authenticated','public.purchasing_memberships','update'),'authenticated cannot update Purchasing memberships directly');
select ok(has_function_privilege('service_role','public.grant_existing_purchasing_membership(uuid,uuid,text)','execute'),'service role can execute Purchasing grant RPC');
select ok(not has_function_privilege('authenticated','public.grant_existing_purchasing_membership(uuid,uuid,text)','execute'),'authenticated cannot execute Purchasing grant RPC');
select is((select count(*) from information_schema.columns where table_schema='public' and table_name='purchasing_memberships' and column_name='branch_id'),0::bigint,'Purchasing membership is organization-scoped, not branch-scoped');

select throws_ok($$select * from public.grant_existing_purchasing_membership(
 '1d000000-0000-4000-8000-000000000002',
 '2d000000-0000-4000-8000-000000000001',
 ' BUYER@example.invalid '
)$$,'42501','purchasing membership access denied','organization manager cannot grant Purchasing access in managed organization');
select lives_ok($$select * from public.grant_existing_purchasing_membership(
 '1d000000-0000-4000-8000-000000000001',
 '2d000000-0000-4000-8000-000000000001',
 ' BUYER@example.invalid '
)$$,'internal admin grants Purchasing access in target organization');
select is((select count(*) from public.purchasing_memberships where organization_id='2d000000-0000-4000-8000-000000000001' and user_id='1d000000-0000-4000-8000-000000000004' and active),1::bigint,'active Purchasing membership created explicitly');
select is((select count(*) from public.organization_memberships where user_id='1d000000-0000-4000-8000-000000000004'),0::bigint,'Purchasing grant does not create organization manager membership');
select is((select count(*) from public.maintenance_memberships where user_id='1d000000-0000-4000-8000-000000000004'),0::bigint,'Purchasing grant does not create maintenance membership');
select throws_ok($$select * from public.list_managed_purchasing_memberships(
 '1d000000-0000-4000-8000-000000000002',
 '2d000000-0000-4000-8000-000000000001'
)$$,'42501','purchasing membership access denied','organization manager cannot list Purchasing memberships');
select is((select count(*) from public.list_managed_purchasing_memberships('1d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001') where email='buyer@example.invalid' and active),1::bigint,'internal admin lists Purchasing memberships in target organization');
select throws_ok($$select * from public.grant_existing_purchasing_membership(
 '1d000000-0000-4000-8000-000000000003',
 '2d000000-0000-4000-8000-000000000001',
 'buyer@example.invalid'
)$$,'42501','purchasing membership access denied','manager cannot grant Purchasing access in another organization');
select throws_ok($$select * from public.grant_existing_purchasing_membership(
 '1d000000-0000-4000-8000-000000000005',
 '2d000000-0000-4000-8000-000000000001',
 'buyer@example.invalid'
)$$,'42501','purchasing membership access denied','supervisor cannot grant Purchasing access');
select lives_ok($$select * from public.set_purchasing_membership_active(
 '1d000000-0000-4000-8000-000000000001',
 '2d000000-0000-4000-8000-000000000001',
 '1d000000-0000-4000-8000-000000000004',
 false
)$$,'internal admin deactivates Purchasing membership');
select ok(not private.has_active_purchasing_membership('1d000000-0000-4000-8000-000000000004','2d000000-0000-4000-8000-000000000001'),'deactivation immediately removes active Purchasing helper access');
select lives_ok($$select * from public.set_purchasing_membership_active(
 '1d000000-0000-4000-8000-000000000001',
 '2d000000-0000-4000-8000-000000000001',
 '1d000000-0000-4000-8000-000000000004',
 true
)$$,'internal admin reactivates Purchasing membership');
select lives_ok($$select public.finalize_provisioned_purchasing_user(
 '1d000000-0000-4000-8000-000000000001',
 '2d000000-0000-4000-8000-000000000002',
 '1d000000-0000-4000-8000-000000000004',
 'Buyer',
 null
)$$,'internal admin provisions Purchasing user');
select is((select count(*) from public.purchasing_memberships where organization_id='2d000000-0000-4000-8000-000000000002' and user_id='1d000000-0000-4000-8000-000000000004' and active),1::bigint,'internal admin creates explicit Purchasing assignment only for target organization');
select throws_ok($$select public.finalize_provisioned_purchasing_user(
 '1d000000-0000-4000-8000-000000000005',
 '2d000000-0000-4000-8000-000000000001',
 '1d000000-0000-4000-8000-000000000004',
 'Buyer',
 null
)$$,'42501','provisioning denied','non-internal-admin cannot provision Purchasing user');

select * from finish();
rollback;
