begin;
select plan(9);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email, '{}', '{}', now(), now()
from (values
  ('1c000000-0000-4000-8000-000000000001'::uuid, 'internal-admin@example.invalid'),
  ('1c000000-0000-4000-8000-000000000002'::uuid, 'disabled-admin@example.invalid'),
  ('1c000000-0000-4000-8000-000000000003'::uuid, 'pending-admin@example.invalid'),
  ('1c000000-0000-4000-8000-000000000004'::uuid, 'inactive-admin@example.invalid'),
  ('1c000000-0000-4000-8000-000000000005'::uuid, 'regular-user@example.invalid')
) users(id,email);

update public.profiles
set full_name = case id
    when '1c000000-0000-4000-8000-000000000001' then 'Active Internal Admin'
    when '1c000000-0000-4000-8000-000000000002' then 'Disabled Internal Admin'
    when '1c000000-0000-4000-8000-000000000003' then 'Pending Internal Admin'
    when '1c000000-0000-4000-8000-000000000004' then 'Inactive Internal Admin'
    else 'Regular User'
  end,
  must_change_password = id = '1c000000-0000-4000-8000-000000000003',
  disabled_at = case when id = '1c000000-0000-4000-8000-000000000002' then now() else null end
where id::text like '1c000000-%';

insert into public.internal_admin_memberships(user_id,active,created_by,updated_by) values
 ('1c000000-0000-4000-8000-000000000001',true,null,null),
 ('1c000000-0000-4000-8000-000000000002',true,'1c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000001'),
 ('1c000000-0000-4000-8000-000000000003',true,'1c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000001'),
 ('1c000000-0000-4000-8000-000000000004',false,'1c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000001');

select ok(not has_table_privilege('anon','public.internal_admin_memberships','select'),'anon cannot select internal admin memberships');
select ok(has_table_privilege('authenticated','public.internal_admin_memberships','select'),'authenticated can select through RLS');
select ok(not has_table_privilege('authenticated','public.internal_admin_memberships','insert'),'authenticated cannot insert internal admin memberships directly');
select ok(has_function_privilege('authenticated','private.is_internal_admin(uuid)','execute'),'authenticated can execute helper');

select is(private.is_internal_admin('1c000000-0000-4000-8000-000000000001'),true,'active internal admin recognized');
select is(private.is_internal_admin('1c000000-0000-4000-8000-000000000002'),false,'disabled profile denied');
select is(private.is_internal_admin('1c000000-0000-4000-8000-000000000003'),false,'must change password profile denied');
select is(private.is_internal_admin('1c000000-0000-4000-8000-000000000004'),false,'inactive membership denied');
select is(private.is_internal_admin('1c000000-0000-4000-8000-000000000005'),false,'non-member denied');

select * from finish();
rollback;
