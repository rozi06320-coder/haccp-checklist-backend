begin;
select plan(8);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email, '{}', '{}', now(), now()
from (values
  ('1d400000-0000-4000-8000-000000000001'::uuid, 'internal-admin@example.invalid'),
  ('1d400000-0000-4000-8000-000000000002'::uuid, 'not-admin@example.invalid')
) users(id, email);

update public.profiles set full_name = case id
  when '1d400000-0000-4000-8000-000000000001' then 'Internal Admin'
  else 'Not Admin'
end, must_change_password = false
where id::text like '1d400000-%';

insert into public.internal_admin_memberships(user_id, active)
values ('1d400000-0000-4000-8000-000000000001', true);

select ok(has_function_privilege('service_role','public.create_internal_admin_organization(uuid,text)','execute'),'service role can execute organization creation RPC');
select ok(not has_function_privilege('authenticated','public.create_internal_admin_organization(uuid,text)','execute'),'authenticated cannot execute organization creation RPC');
select is(
  (select name from public.create_internal_admin_organization('1d400000-0000-4000-8000-000000000001','  New   Restaurant Org  ')),
  'New Restaurant Org',
  'internal admin creates normalized organization'
);
select is(
  (select slug from public.organizations where name='New Restaurant Org'),
  'new-restaurant-org',
  'organization slug is generated from name'
);
select ok(
  (select active from public.organizations where name='New Restaurant Org'),
  'created organization is active'
);
select throws_ok($$select * from public.create_internal_admin_organization(
 '1d400000-0000-4000-8000-000000000001',
 'new restaurant org'
)$$,'23505','organization already exists','duplicate organization name is rejected safely');
select throws_ok($$select * from public.create_internal_admin_organization(
 '1d400000-0000-4000-8000-000000000002',
 'Denied Org'
)$$,'22023','invalid organization creation request','non-admin cannot create organization');
select throws_ok($$select * from public.create_internal_admin_organization(
 '1d400000-0000-4000-8000-000000000001',
 '   '
)$$,'22023','invalid organization creation request','empty organization name is rejected');

select * from finish();
rollback;
