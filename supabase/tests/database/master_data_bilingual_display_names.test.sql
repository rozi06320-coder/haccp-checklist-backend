begin;
select plan(9);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values
  ('00000000-0000-0000-0000-000000000000','2a400000-0000-4000-8000-000000000001','authenticated','authenticated','bilingual-admin@example.invalid','{}','{}',now(),now()),
  ('00000000-0000-0000-0000-000000000000','2a400000-0000-4000-8000-000000000002','authenticated','authenticated','bilingual-manager@example.invalid','{}','{}',now(),now());

update public.profiles
set full_name = case id
    when '2a400000-0000-4000-8000-000000000001' then 'Internal Admin'
    else 'Manager Name'
  end,
  full_name_ar = case id
    when '2a400000-0000-4000-8000-000000000002' then 'اسم المدير'
    else null
  end,
  must_change_password = false
where id::text like '2a400000-%';

insert into public.internal_admin_memberships(user_id, active)
values ('2a400000-0000-4000-8000-000000000001', true);

select has_column('public', 'organizations', 'name_ar', 'organizations has optional Arabic display name');
select has_column('public', 'branches', 'name_ar', 'branches has optional Arabic display name');
select has_column('public', 'profiles', 'full_name_ar', 'profiles has optional Arabic full name');

select is(
  (select name_ar from public.create_internal_admin_organization('2a400000-0000-4000-8000-000000000001','  Burger   Hunch  ','  برجر   هنش  ')),
  'برجر هنش',
  'organization Arabic name is normalized when provided'
);

select is(
  (select name_ar from public.create_internal_admin_organization('2a400000-0000-4000-8000-000000000001','Fallback Only Org','')),
  null,
  'blank organization Arabic name becomes null'
);

insert into public.organization_memberships(organization_id, user_id, role, active)
select id, '2a400000-0000-4000-8000-000000000002', 'organization_manager', true
from public.organizations
where name = 'Burger Hunch';

select is(
  (select name_ar from public.create_managed_branch(
    '2a400000-0000-4000-8000-000000000002',
    (select id from public.organizations where name = 'Burger Hunch'),
    '  Riyadh   Branch  ',
    'Asia/Riyadh',
    true,
    '  فرع   الرياض  '
  )),
  'فرع الرياض',
  'branch Arabic name is normalized when provided'
);

select is(
  (select name_ar from public.create_managed_branch(
    '2a400000-0000-4000-8000-000000000002',
    (select id from public.organizations where name = 'Burger Hunch'),
    'English Only Branch',
    'Asia/Riyadh',
    true,
    null
  )),
  null,
  'branch Arabic name is optional'
);

select is(
  (select organization.name_ar from public.list_internal_admin_organizations('2a400000-0000-4000-8000-000000000001') organization where organization.name = 'Burger Hunch'),
  'برجر هنش',
  'Internal Admin organization list returns Arabic display name'
);

select is(
  (select branch.name_ar from public.list_internal_admin_branches(
    '2a400000-0000-4000-8000-000000000001',
    (select id from public.organizations where name = 'Burger Hunch')
  ) branch where branch.name = 'Riyadh Branch'),
  'فرع الرياض',
  'Internal Admin branch list returns Arabic display name'
);

select * from finish();
rollback;
