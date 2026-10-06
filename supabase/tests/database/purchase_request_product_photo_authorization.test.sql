begin;
select plan(6);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values
  ('00000000-0000-0000-0000-000000000000','1a000000-0000-4000-8000-000000000001','authenticated','authenticated','photo-auth-supervisor@example.invalid','{}','{}',now(),now());

update public.profiles
set must_change_password = false
where id = '1a000000-0000-4000-8000-000000000001';

insert into public.organizations(id,name,slug)
values ('2a000000-0000-4000-8000-000000000001','Photo Authorization Org','photo-authorization-org');

insert into public.branches(id,organization_id,name,code,timezone) values
  ('3a000000-0000-4000-8000-000000000001','2a000000-0000-4000-8000-000000000001','Photo Authorization Branch A','PAA','Asia/Riyadh'),
  ('3a000000-0000-4000-8000-000000000002','2a000000-0000-4000-8000-000000000001','Photo Authorization Branch B','PAB','Asia/Riyadh');

insert into public.branch_memberships(branch_id,user_id,role) values
  ('3a000000-0000-4000-8000-000000000001','1a000000-0000-4000-8000-000000000001','branch_manager'),
  ('3a000000-0000-4000-8000-000000000002','1a000000-0000-4000-8000-000000000001','branch_manager');

insert into public.purchase_requests(id,organization_id,branch_id,requested_by,category,status) values
  ('4a000000-0000-4000-8000-000000000001','2a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001','1a000000-0000-4000-8000-000000000001','kitchen','processing'),
  ('4a000000-0000-4000-8000-000000000002','2a000000-0000-4000-8000-000000000001','3a000000-0000-4000-8000-000000000001','1a000000-0000-4000-8000-000000000001','kitchen','submitted');

insert into public.purchase_request_items(id,purchase_request_id,item_name,quantity,unit,sort_order) values
  ('5a000000-0000-4000-8000-000000000001','4a000000-0000-4000-8000-000000000001','Authorized item',1,'box',1),
  ('5a000000-0000-4000-8000-000000000002','4a000000-0000-4000-8000-000000000002','Other request item',1,'box',1);

select has_function(
  'public',
  'authorize_supervisor_purchase_request_item_product_photo',
  array['uuid','uuid','uuid','uuid'],
  'product photo authorization RPC keeps its exact signature'
);

select ok(
  has_function_privilege(
    'service_role',
    'public.authorize_supervisor_purchase_request_item_product_photo(uuid,uuid,uuid,uuid)',
    'execute'
  ),
  'service_role keeps execute access to product photo authorization'
);

select ok(
  not has_function_privilege(
    'authenticated',
    'public.authorize_supervisor_purchase_request_item_product_photo(uuid,uuid,uuid,uuid)',
    'execute'
  ),
  'authenticated cannot execute product photo authorization directly'
);

select results_eq(
  $$
    select organization_id, branch_id, request_id, item_id
    from public.authorize_supervisor_purchase_request_item_product_photo(
      '1a000000-0000-4000-8000-000000000001',
      '3a000000-0000-4000-8000-000000000001',
      '4a000000-0000-4000-8000-000000000001',
      '5a000000-0000-4000-8000-000000000001'
    )
  $$,
  $$
    values (
      '2a000000-0000-4000-8000-000000000001'::uuid,
      '3a000000-0000-4000-8000-000000000001'::uuid,
      '4a000000-0000-4000-8000-000000000001'::uuid,
      '5a000000-0000-4000-8000-000000000001'::uuid
    )
  $$,
  'valid request and item scope executes without an ambiguous-column error'
);

select throws_ok(
  $$
    select *
    from public.authorize_supervisor_purchase_request_item_product_photo(
      '1a000000-0000-4000-8000-000000000001',
      '3a000000-0000-4000-8000-000000000002',
      '4a000000-0000-4000-8000-000000000001',
      '5a000000-0000-4000-8000-000000000001'
    )
  $$,
  '42501',
  'purchase request not found',
  'a request cannot be authorized through the wrong branch'
);

select throws_ok(
  $$
    select *
    from public.authorize_supervisor_purchase_request_item_product_photo(
      '1a000000-0000-4000-8000-000000000001',
      '3a000000-0000-4000-8000-000000000001',
      '4a000000-0000-4000-8000-000000000001',
      '5a000000-0000-4000-8000-000000000002'
    )
  $$,
  '42501',
  'purchase request item not found',
  'an item from another request cannot be authorized'
);

select * from finish();
rollback;
