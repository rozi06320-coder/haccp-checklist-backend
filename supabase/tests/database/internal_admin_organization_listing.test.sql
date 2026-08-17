begin;
select plan(7);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email, '{}', '{}', now(), now()
from (values
  ('1d500000-0000-4000-8000-000000000001'::uuid, 'internal-admin-list@example.invalid'),
  ('1d500000-0000-4000-8000-000000000002'::uuid, 'not-admin-list@example.invalid')
) users(id, email);

update public.profiles set full_name = case id
  when '1d500000-0000-4000-8000-000000000001' then 'Internal Admin'
  else 'Not Admin'
end, must_change_password = false
where id::text like '1d500000-%';

insert into public.internal_admin_memberships(user_id, active)
values ('1d500000-0000-4000-8000-000000000001', true);

insert into public.organizations(id, name, slug, active, logo_path)
values
  (
    '2d500000-0000-4000-8000-000000000001',
    'AlKhaleejiah Listing Test',
    'alkhaleejiah-listing-test',
    true,
    null
  ),
  (
    '2d500000-0000-4000-8000-000000000002',
    'Burger Hunch Listing Test',
    'burger-hunch-listing-test',
    true,
    'organizations/2d500000-0000-4000-8000-000000000002/logo/3d500000-0000-4000-8000-000000000001.png'
  );

select ok(
  has_function_privilege('service_role','public.list_internal_admin_organizations(uuid)','execute'),
  'service role can execute organization listing RPC'
);
select ok(
  not has_function_privilege('authenticated','public.list_internal_admin_organizations(uuid)','execute'),
  'authenticated cannot execute organization listing RPC directly'
);
select throws_ok(
  $$select * from public.list_internal_admin_organizations('1d500000-0000-4000-8000-000000000002')$$,
  '42501',
  'organization list access denied',
  'non-admin actor cannot list organizations'
);
select is(
  (select count(*) from public.list_internal_admin_organizations('1d500000-0000-4000-8000-000000000001') where name in ('AlKhaleejiah Listing Test','Burger Hunch Listing Test')),
  2::bigint,
  'internal admin lists existing organizations'
);
select ok(
  (select active from public.list_internal_admin_organizations('1d500000-0000-4000-8000-000000000001') where name='AlKhaleejiah Listing Test'),
  'active flag is returned'
);
select is(
  (select logo_path from public.list_internal_admin_organizations('1d500000-0000-4000-8000-000000000001') where name='AlKhaleejiah Listing Test'),
  null,
  'nullable logo path is returned'
);
select ok(
  ((select logo_path from public.list_internal_admin_organizations('1d500000-0000-4000-8000-000000000001') where name='Burger Hunch Listing Test')
    like 'organizations/2d500000-0000-4000-8000-000000000002/logo/%'),
  'stored logo path is returned'
);

select * from finish();
rollback;
