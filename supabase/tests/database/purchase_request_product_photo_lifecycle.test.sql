begin;
select plan(26);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values
  ('00000000-0000-0000-0000-000000000000','1f000000-0000-4000-8000-000000000001','authenticated','authenticated','photo-supervisor@example.invalid','{}','{}',now(),now()),
  ('00000000-0000-0000-0000-000000000000','1f000000-0000-4000-8000-000000000002','authenticated','authenticated','photo-foreign-supervisor@example.invalid','{}','{}',now(),now()),
  ('00000000-0000-0000-0000-000000000000','1f000000-0000-4000-8000-000000000003','authenticated','authenticated','photo-purchasing@example.invalid','{}','{}',now(),now());

update public.profiles
set must_change_password = false
where id::text like '1f000000-%';

insert into public.organizations(id,name,slug) values
  ('2f000000-0000-4000-8000-000000000001','Photo Lifecycle Org A','photo-lifecycle-org-a'),
  ('2f000000-0000-4000-8000-000000000002','Photo Lifecycle Org B','photo-lifecycle-org-b');

insert into public.branches(id,organization_id,name,code,timezone) values
  ('3f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','Photo Lifecycle Branch A','PLA','Asia/Riyadh'),
  ('3f000000-0000-4000-8000-000000000002','2f000000-0000-4000-8000-000000000002','Photo Lifecycle Branch B','PLB','Asia/Riyadh');

insert into public.branch_memberships(branch_id,user_id,role) values
  ('3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000001','branch_manager'),
  ('3f000000-0000-4000-8000-000000000002','1f000000-0000-4000-8000-000000000002','branch_manager');

insert into public.purchasing_memberships(organization_id,user_id,active,created_by,updated_by)
values ('2f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000003',true,'1f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000001');

insert into public.purchase_requests(id,organization_id,branch_id,requested_by,category,status,notes,created_at) values
  ('4f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000001','kitchen','submitted','submitted note','2026-10-06T08:00:00Z'),
  ('4f000000-0000-4000-8000-000000000002','2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000001','kitchen','processing','processing note','2026-10-06T08:01:00Z'),
  ('4f000000-0000-4000-8000-000000000003','2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000001','kitchen','purchased','purchased note','2026-10-06T08:02:00Z'),
  ('4f000000-0000-4000-8000-000000000004','2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000001','kitchen','received','received note','2026-10-06T08:03:00Z'),
  ('4f000000-0000-4000-8000-000000000005','2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000001','kitchen','cancelled','cancelled note','2026-10-06T08:04:00Z');

insert into public.purchase_request_items(id,purchase_request_id,item_name,quantity,unit,notes,sort_order)
select
  ('5f000000-0000-4000-8000-00000000000' || request_number)::uuid,
  ('4f000000-0000-4000-8000-00000000000' || request_number)::uuid,
  status_name || ' item',
  request_number,
  'box',
  status_name || ' item note',
  1
from (values
  ('1','submitted'),
  ('2','processing'),
  ('3','purchased'),
  ('4','received'),
  ('5','cancelled')
) statuses(request_number,status_name);

select lives_ok($$
  select public.set_supervisor_purchase_request_item_product_photo(
    '1f000000-0000-4000-8000-000000000001',
    '3f000000-0000-4000-8000-000000000001',
    '4f000000-0000-4000-8000-000000000001',
    '5f000000-0000-4000-8000-000000000001',
    '{"storage_path":"submitted/first.jpg","original_filename":"first.jpg","mime_type":"image/jpeg","size_bytes":100}'::jsonb
  )
$$,'submitted request accepts an initial product photo');
select is((select product_photo_storage_path from public.purchase_request_items where id='5f000000-0000-4000-8000-000000000001'),'submitted/first.jpg','submitted photo metadata is stored');
select lives_ok($$
  select public.set_supervisor_purchase_request_item_product_photo(
    '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001',
    '4f000000-0000-4000-8000-000000000001','5f000000-0000-4000-8000-000000000001',
    '{"storage_path":"submitted/replacement.webp","original_filename":"replacement.webp","mime_type":"image/webp","size_bytes":200}'::jsonb
  )
$$,'submitted request accepts a replacement product photo');
select is((select product_photo_storage_path from public.purchase_request_items where id='5f000000-0000-4000-8000-000000000001'),'submitted/replacement.webp','submitted replacement becomes current');
select is(
  (select row(item_name,quantity,unit,notes,sort_order)::text from public.purchase_request_items where id='5f000000-0000-4000-8000-000000000001'),
  '("submitted item",1,box,"submitted item note",1)',
  'photo replacement leaves non-photo item fields unchanged'
);
select lives_ok($$
  select public.clear_supervisor_purchase_request_item_product_photo(
    '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001',
    '4f000000-0000-4000-8000-000000000001','5f000000-0000-4000-8000-000000000001'
  )
$$,'submitted request accepts product photo removal');
select is((select product_photo_storage_path from public.purchase_request_items where id='5f000000-0000-4000-8000-000000000001'),null,'submitted removal atomically clears the current storage path');

select lives_ok($$
  select public.set_supervisor_purchase_request_item_product_photo(
    '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001',
    '4f000000-0000-4000-8000-000000000002','5f000000-0000-4000-8000-000000000002',
    '{"storage_path":"processing/first.png","original_filename":"first.png","mime_type":"image/png","size_bytes":300}'::jsonb
  )
$$,'processing request accepts an initial product photo');
select is((select product_photo_storage_path from public.purchase_request_items where id='5f000000-0000-4000-8000-000000000002'),'processing/first.png','processing photo metadata is stored');
select lives_ok($$
  select public.set_supervisor_purchase_request_item_product_photo(
    '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001',
    '4f000000-0000-4000-8000-000000000002','5f000000-0000-4000-8000-000000000002',
    '{"storage_path":"processing/replacement.jpg","original_filename":"replacement.jpg","mime_type":"image/jpeg","size_bytes":400}'::jsonb
  )
$$,'processing request accepts a replacement product photo');
select is((select product_photo_storage_path from public.purchase_request_items where id='5f000000-0000-4000-8000-000000000002'),'processing/replacement.jpg','processing replacement becomes current');
select lives_ok($$
  select public.clear_supervisor_purchase_request_item_product_photo(
    '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001',
    '4f000000-0000-4000-8000-000000000002','5f000000-0000-4000-8000-000000000002'
  )
$$,'processing request accepts product photo removal');
select ok((select product_photo_storage_path is null
                   and product_photo_original_name is null
                   and product_photo_mime_type is null
                   and product_photo_size_bytes is null
                   and product_photo_uploaded_at is null
                   and product_photo_uploaded_by is null
             from public.purchase_request_items
            where id='5f000000-0000-4000-8000-000000000002'),
          'processing removal clears all photo metadata');

select throws_ok($$select public.set_supervisor_purchase_request_item_product_photo('1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','4f000000-0000-4000-8000-000000000003','5f000000-0000-4000-8000-000000000003','{"storage_path":"denied.jpg","original_filename":"denied.jpg","mime_type":"image/jpeg","size_bytes":100}'::jsonb)$$,'55000','purchase request product photo is locked','purchased request rejects product photo add or replace');
select throws_ok($$select public.clear_supervisor_purchase_request_item_product_photo('1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','4f000000-0000-4000-8000-000000000003','5f000000-0000-4000-8000-000000000003')$$,'55000','purchase request product photo is locked','purchased request rejects product photo removal');
select throws_ok($$select public.set_supervisor_purchase_request_item_product_photo('1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','4f000000-0000-4000-8000-000000000004','5f000000-0000-4000-8000-000000000004','{"storage_path":"denied.jpg","original_filename":"denied.jpg","mime_type":"image/jpeg","size_bytes":100}'::jsonb)$$,'55000','purchase request product photo is locked','received request rejects product photo add or replace');
select throws_ok($$select public.clear_supervisor_purchase_request_item_product_photo('1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','4f000000-0000-4000-8000-000000000004','5f000000-0000-4000-8000-000000000004')$$,'55000','purchase request product photo is locked','received request rejects product photo removal');
select throws_ok($$select public.set_supervisor_purchase_request_item_product_photo('1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','4f000000-0000-4000-8000-000000000005','5f000000-0000-4000-8000-000000000005','{"storage_path":"denied.jpg","original_filename":"denied.jpg","mime_type":"image/jpeg","size_bytes":100}'::jsonb)$$,'55000','purchase request product photo is locked','cancelled request rejects product photo add or replace');
select throws_ok($$select public.clear_supervisor_purchase_request_item_product_photo('1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','4f000000-0000-4000-8000-000000000005','5f000000-0000-4000-8000-000000000005')$$,'55000','purchase request product photo is locked','cancelled request rejects product photo removal');

select throws_ok($$select public.set_supervisor_purchase_request_item_product_photo('1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000002','4f000000-0000-4000-8000-000000000001','5f000000-0000-4000-8000-000000000001','{"storage_path":"denied.jpg","original_filename":"denied.jpg","mime_type":"image/jpeg","size_bytes":100}'::jsonb)$$,'42501','purchase request not found','wrong-branch Supervisor cannot mutate a product photo');
select throws_ok($$select public.set_supervisor_purchase_request_item_product_photo('1f000000-0000-4000-8000-000000000002','3f000000-0000-4000-8000-000000000002','4f000000-0000-4000-8000-000000000001','5f000000-0000-4000-8000-000000000001','{"storage_path":"denied.jpg","original_filename":"denied.jpg","mime_type":"image/jpeg","size_bytes":100}'::jsonb)$$,'42501','purchase request not found','cross-organization Supervisor cannot mutate a product photo');

select lives_ok($$
  select public.set_supervisor_purchase_request_item_product_photo(
    '1f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001',
    '4f000000-0000-4000-8000-000000000002','5f000000-0000-4000-8000-000000000002',
    '{"storage_path":"processing/purchasing-visible.jpg","original_filename":"purchasing-visible.jpg","mime_type":"image/jpeg","size_bytes":500}'::jsonb
  )
$$,'processing photo can be restored for Purchasing visibility');
select is(
  jsonb_path_query_first(
    public.list_purchasing_purchase_requests('1f000000-0000-4000-8000-000000000003','2f000000-0000-4000-8000-000000000001',null),
    '$.purchase_requests[*].items[*] ? (@.id == "5f000000-0000-4000-8000-000000000002").product_photo.storage_path'
  ) #>> '{}',
  'processing/purchasing-visible.jpg',
  'Purchasing list reads the latest post-submit product photo metadata'
);
select is((select status from public.purchase_requests where id='4f000000-0000-4000-8000-000000000002'),'processing','photo mutation does not change request status');
select is((select notes from public.purchase_requests where id='4f000000-0000-4000-8000-000000000002'),'processing note','photo mutation does not change request business data');
select is((select product_photo_storage_path from public.purchase_request_items where id='5f000000-0000-4000-8000-000000000003'),null,'denied purchased mutation leaves photo metadata unchanged');

select * from finish();
rollback;
