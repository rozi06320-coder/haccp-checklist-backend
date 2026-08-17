begin;
select plan(23);

insert into auth.users (instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
('00000000-0000-0000-0000-000000000000','13000000-0000-4000-8000-000000000001','authenticated','authenticated','manager-a@example.invalid','{}','{}',now(),now()),
('00000000-0000-0000-0000-000000000000','13000000-0000-4000-8000-000000000002','authenticated','authenticated','staff-a@example.invalid','{}','{}',now(),now()),
('00000000-0000-0000-0000-000000000000','13000000-0000-4000-8000-000000000003','authenticated','authenticated','branch-a@example.invalid','{}','{}',now(),now()),
('00000000-0000-0000-0000-000000000000','13000000-0000-4000-8000-000000000004','authenticated','authenticated','manager-b@example.invalid','{}','{}',now(),now()),
('00000000-0000-0000-8000-000000000000','13000000-0000-4000-8000-000000000005','authenticated','authenticated','secret-b@example.invalid','{}','{}',now(),now());
update public.profiles set full_name = case id
 when '13000000-0000-4000-8000-000000000001' then 'Manager Alpha'
 when '13000000-0000-4000-8000-000000000002' then 'Searchable Staff'
 when '13000000-0000-4000-8000-000000000003' then 'Branch Lead'
 when '13000000-0000-4000-8000-000000000004' then 'Manager Beta'
 else 'Hidden Person' end;
update public.profiles set must_change_password=true where id='13000000-0000-4000-8000-000000000002';
update public.profiles set disabled_at=now() where id='13000000-0000-4000-8000-000000000003';
insert into public.organizations(id,name,slug) values
('23000000-0000-4000-8000-000000000001','List Org A','list-org-a'),
('23000000-0000-4000-8000-000000000002','List Org B','list-org-b');
insert into public.branches(id,organization_id,name,code,active) values
('33000000-0000-4000-8000-000000000001','23000000-0000-4000-8000-000000000001','Alpha','A',true),
('33000000-0000-4000-8000-000000000002','23000000-0000-4000-8000-000000000001','Beta','B',true),
('33000000-0000-4000-8000-000000000003','23000000-0000-4000-8000-000000000002','Secret','S',true);
insert into public.organization_memberships values
('23000000-0000-4000-8000-000000000001','13000000-0000-4000-8000-000000000001','organization_manager',now(),now()),
('23000000-0000-4000-8000-000000000002','13000000-0000-4000-8000-000000000004','organization_manager',now(),now());
insert into public.branch_memberships(branch_id,user_id,role) values
('33000000-0000-4000-8000-000000000001','13000000-0000-4000-8000-000000000002','staff'),
('33000000-0000-4000-8000-000000000002','13000000-0000-4000-8000-000000000002','staff'),
('33000000-0000-4000-8000-000000000001','13000000-0000-4000-8000-000000000003','branch_manager'),
('33000000-0000-4000-8000-000000000003','13000000-0000-4000-8000-000000000005','staff');

select ok(not has_function_privilege('public','public.list_managed_organization_users(uuid,uuid,integer,integer,text,text,uuid,text)','execute'),'PUBLIC denied');
select ok(not has_function_privilege('anon','public.list_managed_organization_users(uuid,uuid,integer,integer,text,text,uuid,text)','execute'),'anon denied');
select ok(not has_function_privilege('authenticated','public.list_managed_organization_users(uuid,uuid,integer,integer,text,text,uuid,text)','execute'),'authenticated denied');
select ok(has_function_privilege('service_role','public.list_managed_organization_users(uuid,uuid,integer,integer,text,text,uuid,text)','execute'),'service role only');
set local role service_role;
select throws_ok($$select * from public.list_managed_organization_users('13000000-0000-4000-8000-000000000002','23000000-0000-4000-8000-000000000001')$$,'42501','listing denied','staff rejected');
select throws_ok($$select * from public.list_managed_organization_users('13000000-0000-4000-8000-000000000003','23000000-0000-4000-8000-000000000001')$$,'42501','listing denied','branch manager rejected');
select throws_ok($$select * from public.list_managed_organization_users('13000000-0000-4000-8000-000000000001','23000000-0000-4000-8000-000000000002')$$,'42501','listing denied','cross organization rejected');
select is((select count(*) from public.list_managed_organization_users('13000000-0000-4000-8000-000000000001','23000000-0000-4000-8000-000000000001')),2::bigint,'only A users');
select ok(not exists(select 1 from public.list_managed_organization_users('13000000-0000-4000-8000-000000000001','23000000-0000-4000-8000-000000000001') where email='secret-b@example.invalid'),'B email absent');
select is((select count(*) from public.list_managed_organization_users('13000000-0000-4000-8000-000000000001','23000000-0000-4000-8000-000000000001',1,20,'Searchable')),1::bigint,'name search');
select is((select count(*) from public.list_managed_organization_users('13000000-0000-4000-8000-000000000001','23000000-0000-4000-8000-000000000001',1,20,'STAFF-A@EXAMPLE.INVALID')),1::bigint,'email search');
select is((select count(*) from public.list_managed_organization_users('13000000-0000-4000-8000-000000000001','23000000-0000-4000-8000-000000000001',1,20,null,'branch_manager')),1::bigint,'role filter');
select is((select count(*) from public.list_managed_organization_users('13000000-0000-4000-8000-000000000001','23000000-0000-4000-8000-000000000001',1,20,null,null,'33000000-0000-4000-8000-000000000002')),1::bigint,'branch filter');
select is((select count(*) from public.list_managed_organization_users('13000000-0000-4000-8000-000000000001','23000000-0000-4000-8000-000000000001',1,20,null,null,null,'password_change_required')),1::bigint,'password lifecycle');
select is((select count(*) from public.list_managed_organization_users('13000000-0000-4000-8000-000000000001','23000000-0000-4000-8000-000000000001',1,20,null,null,null,'disabled')),1::bigint,'disabled lifecycle');
select throws_ok($$select * from public.list_managed_organization_users('13000000-0000-4000-8000-000000000001','23000000-0000-4000-8000-000000000001',0,20)$$,'22023','invalid listing input','page bounded');
select throws_ok($$select * from public.list_managed_organization_users('13000000-0000-4000-8000-000000000001','23000000-0000-4000-8000-000000000001',1,51)$$,'22023','invalid listing input','page size bounded');
select is((select total_count from public.list_managed_organization_users('13000000-0000-4000-8000-000000000001','23000000-0000-4000-8000-000000000001',1,1)),2::bigint,'total count');
select is((select count(*) from public.list_managed_organization_users('13000000-0000-4000-8000-000000000001','23000000-0000-4000-8000-000000000001',1,1)),1::bigint,'pagination');
select is((select pg_catalog.jsonb_array_length(branches) from public.list_managed_organization_users('13000000-0000-4000-8000-000000000001','23000000-0000-4000-8000-000000000001') where id='13000000-0000-4000-8000-000000000002'),2,'multi branch once');
select is((select id from public.list_managed_organization_users('13000000-0000-4000-8000-000000000001','23000000-0000-4000-8000-000000000001',1,1)), '13000000-0000-4000-8000-000000000003'::uuid,'stable name ordering');
select set_eq($$select column_name from information_schema.columns where table_schema='public' and table_name='list_managed_organization_users'$$,array[]::text[],'no table created for result');
select ok(not has_table_privilege('service_role','auth.users','select'),'no broad auth users grant');
reset role;
select * from finish();
rollback;
