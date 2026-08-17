begin;
select plan(13);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email, '{}', '{}', now(), now()
from (values
  ('1a100000-0000-4000-8000-000000000001'::uuid, 'internal-admin@example.invalid'),
  ('1a100000-0000-4000-8000-000000000002'::uuid, 'manager@example.invalid'),
  ('1a100000-0000-4000-8000-000000000003'::uuid, 'not-admin@example.invalid'),
  ('1a100000-0000-4000-8000-000000000004'::uuid, 'other-manager@example.invalid')
) user_data(id,email);

update public.profiles set full_name = case id
  when '1a100000-0000-4000-8000-000000000001' then 'Internal Admin'
  when '1a100000-0000-4000-8000-000000000002' then 'Manager Target'
  when '1a100000-0000-4000-8000-000000000003' then 'Not Admin'
  else 'Other Manager'
end, must_change_password = false
where id::text like '1a100000-%';

insert into public.internal_admin_memberships(user_id, active)
values ('1a100000-0000-4000-8000-000000000001', true);

insert into public.organizations(id,name,slug) values
 ('2a100000-0000-4000-8000-000000000001','Manager Org','manager-org'),
 ('2a100000-0000-4000-8000-000000000002','Other Org','other-org');

select ok(has_function_privilege('service_role','public.finalize_provisioned_organization_manager(uuid,uuid,uuid,text)','execute'),'service role can execute manager finalize RPC');
select ok(not has_function_privilege('authenticated','public.finalize_provisioned_organization_manager(uuid,uuid,uuid,text)','execute'),'authenticated cannot execute manager finalize RPC');
select lives_ok($$select public.finalize_provisioned_organization_manager(
 '1a100000-0000-4000-8000-000000000001',
 '2a100000-0000-4000-8000-000000000001',
 '1a100000-0000-4000-8000-000000000002',
 '  Created   Manager  '
)$$,'internal admin finalizes organization manager');
select is(
  (select count(*) from public.organization_memberships where organization_id='2a100000-0000-4000-8000-000000000001' and user_id='1a100000-0000-4000-8000-000000000002' and role='organization_manager' and active),
  1::bigint,
  'active organization manager membership created'
);
select is(
  (select full_name from public.profiles where id='1a100000-0000-4000-8000-000000000002'),
  'Created Manager',
  'manager profile name normalized'
);
select ok(
  (select must_change_password from public.profiles where id='1a100000-0000-4000-8000-000000000002'),
  'manager must change temporary password'
);
select is(
  (select count(*) from public.list_internal_admin_organization_managers('1a100000-0000-4000-8000-000000000001','2a100000-0000-4000-8000-000000000001') where email='manager@example.invalid' and active),
  1::bigint,
  'internal admin lists manager membership'
);
select throws_ok($$select public.finalize_provisioned_organization_manager(
 '1a100000-0000-4000-8000-000000000003',
 '2a100000-0000-4000-8000-000000000001',
 '1a100000-0000-4000-8000-000000000004',
 'Bad Actor'
)$$,'42501','provisioning denied','non-admin cannot finalize manager');
select lives_ok($$select * from public.deactivate_organization_manager(
 '1a100000-0000-4000-8000-000000000001',
 '2a100000-0000-4000-8000-000000000001',
 '1a100000-0000-4000-8000-000000000002'
)$$,'internal admin deactivates manager membership');
select ok(
  not exists(select 1 from public.organization_memberships where organization_id='2a100000-0000-4000-8000-000000000001' and user_id='1a100000-0000-4000-8000-000000000002' and active),
  'manager membership inactive after deactivation'
);
select ok(
  (select disabled_at is null from public.profiles where id='1a100000-0000-4000-8000-000000000002'),
  'deactivation does not disable auth profile'
);
select throws_ok($$select * from public.deactivate_organization_manager(
 '1a100000-0000-4000-8000-000000000001',
 '2a100000-0000-4000-8000-000000000002',
 '1a100000-0000-4000-8000-000000000002'
)$$,'42501','internal admin access denied','cross-organization manager deactivation denied');
select is(
  (select count(*) from public.list_internal_admin_organization_managers('1a100000-0000-4000-8000-000000000001','2a100000-0000-4000-8000-000000000001') where email='manager@example.invalid' and not active),
  1::bigint,
  'inactive manager remains visible to internal admin'
);

select * from finish();
rollback;
