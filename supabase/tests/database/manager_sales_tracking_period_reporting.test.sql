begin;
select no_plan();

select has_function('public','get_managed_sales_tracking_period_summary',array['uuid','uuid','date','date','uuid'],'Period summary RPC exists');
select has_function('public','list_managed_sales_tracking_period_evidence',array['uuid','uuid','date','date','uuid','integer','date','uuid','uuid','smallint','uuid','text'],'Evidence page RPC exists');
select has_function('public','authorize_managed_sales_tracking_evidence_renewal',array['uuid','uuid','date','date','uuid','uuid[]'],'Renewal authorization RPC exists');
select ok(has_function_privilege('service_role','public.get_managed_sales_tracking_period_summary(uuid,uuid,date,date,uuid)','execute'),'Service role can execute summary');
select ok(not has_function_privilege('authenticated','public.get_managed_sales_tracking_period_summary(uuid,uuid,date,date,uuid)','execute'),'Authenticated cannot execute summary');
select ok(not has_function_privilege('anon','public.list_managed_sales_tracking_period_evidence(uuid,uuid,date,date,uuid,integer,date,uuid,uuid,smallint,uuid,text)','execute'),'Anon cannot list evidence');
select ok(not has_function_privilege('public','public.authorize_managed_sales_tracking_evidence_renewal(uuid,uuid,date,date,uuid,uuid[])','execute'),'PUBLIC cannot authorize renewal');

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)values
 ('00000000-0000-0000-0000-000000000000','11000000-0000-4000-8000-000000000001','authenticated','authenticated','period-manager@example.invalid','{}','{}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','11000000-0000-4000-8000-000000000002','authenticated','authenticated','period-supervisor@example.invalid','{}','{}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','11000000-0000-4000-8000-000000000003','authenticated','authenticated','period-other-manager@example.invalid','{}','{}',now(),now());
update public.profiles set full_name='Period Test',must_change_password=false where id::text like '11000000-%';
insert into public.organizations(id,name,slug)values
 ('21000000-0000-4000-8000-000000000001','Period Org','period-org'),
 ('21000000-0000-4000-8000-000000000002','Other Period Org','other-period-org');
insert into public.branches(id,organization_id,name,name_ar,code,timezone,country_code)values
 ('31000000-0000-4000-8000-000000000001','21000000-0000-4000-8000-000000000001','Saudi Branch','فرع السعودية','PSA','Asia/Riyadh','SA'),
 ('31000000-0000-4000-8000-000000000002','21000000-0000-4000-8000-000000000001','UAE Branch','فرع الإمارات','PAE','Asia/Dubai','AE'),
 ('31000000-0000-4000-8000-000000000003','21000000-0000-4000-8000-000000000002','Other Branch',null,'POT','Asia/Riyadh','SA');
insert into public.organization_memberships(organization_id,user_id,role)values
 ('21000000-0000-4000-8000-000000000001','11000000-0000-4000-8000-000000000001','organization_manager'),
 ('21000000-0000-4000-8000-000000000002','11000000-0000-4000-8000-000000000003','organization_manager');
insert into public.branch_memberships(branch_id,user_id,role)values
 ('31000000-0000-4000-8000-000000000001','11000000-0000-4000-8000-000000000002','branch_manager'),
 ('31000000-0000-4000-8000-000000000002','11000000-0000-4000-8000-000000000002','branch_manager');
update public.sales_tracking_online_order_providers set id='91000000-0000-4000-8000-000000000001'
where branch_id='31000000-0000-4000-8000-000000000001'and default_provider_key='jahez';

select lives_ok($$select public.save_sales_tracking_draft('11000000-0000-4000-8000-000000000002','31000000-0000-4000-8000-000000000001','2026-10-01',0,'closing_shift','[{"entry_date":"2026-10-01","actual_cash":999,"actual_credit":0,"pos_cash":999,"pos_credit":0,"online_delivery":0,"refund_total":0}]','[{"entry_date":"2026-10-01","denom_100":9,"remaining_cash":999}]')$$,'Original SAR report saves');
select lives_ok($$select public.submit_sales_tracking('11000000-0000-4000-8000-000000000002','31000000-0000-4000-8000-000000000001','2026-10-01',1,'41000000-0000-4000-8000-000000000001',repeat('a',64))$$,'Original SAR report submits');
insert into public.sales_tracking_attachments(id,organization_id,branch_id,report_id,storage_path,original_filename,mime_type,size_bytes,uploaded_by_user_id,display_order)
select'b1000000-0000-4000-8000-000000000001','21000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000001',authoritative_report_id,'old/superseded.webp','old.webp','image/webp',100,'11000000-0000-4000-8000-000000000002',1 from public.sales_tracking_report_cases where branch_id='31000000-0000-4000-8000-000000000001';
select lives_ok($$select public.set_managed_sales_tracking_review_status('11000000-0000-4000-8000-000000000001','21000000-0000-4000-8000-000000000001',(select authoritative_report_id from public.sales_tracking_report_cases where branch_id='31000000-0000-4000-8000-000000000001'),0,'needs_review')$$,'Manager requests correction');
select lives_ok($$select public.start_sales_tracking_correction('11000000-0000-4000-8000-000000000002','31000000-0000-4000-8000-000000000001',(select authoritative_report_id from public.sales_tracking_report_cases where branch_id='31000000-0000-4000-8000-000000000001'),1)$$,'Correction starts');
select lives_ok($$select public.save_sales_tracking_correction('11000000-0000-4000-8000-000000000002','31000000-0000-4000-8000-000000000001',(select open_correction_report_id from public.sales_tracking_report_cases where branch_id='31000000-0000-4000-8000-000000000001'),1,'closing_shift','[{"entry_date":"2026-10-01","actual_cash":100,"actual_credit":200,"pos_cash":90,"pos_credit":190,"online_delivery":50,"refund_total":10,"online_amounts":[{"provider_id":"91000000-0000-4000-8000-000000000001","amount":50}]}]','[{"entry_date":"2026-10-01","denom_100":3,"remaining_cash":999}]')$$,'Correction values save');
select lives_ok($$select public.submit_sales_tracking_correction('11000000-0000-4000-8000-000000000002','31000000-0000-4000-8000-000000000001',(select open_correction_report_id from public.sales_tracking_report_cases where branch_id='31000000-0000-4000-8000-000000000001'),2,'41000000-0000-4000-8000-000000000002',repeat('b',64))$$,'Correction submits atomically');
insert into public.sales_tracking_attachments(id,organization_id,branch_id,report_id,storage_path,original_filename,mime_type,size_bytes,uploaded_by_user_id,display_order)
select id_value,'21000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000001',authoritative_report_id,path_value,name_value,'image/webp',100,'11000000-0000-4000-8000-000000000002',display_value
from public.sales_tracking_report_cases cross join(values
 ('b1000000-0000-4000-8000-000000000002'::uuid,'current/one.webp','one.webp',1),
 ('b1000000-0000-4000-8000-000000000003'::uuid,'current/two.webp','two.webp',2)
)as item(id_value,path_value,name_value,display_value)where branch_id='31000000-0000-4000-8000-000000000001';

select lives_ok($$select public.save_sales_tracking_draft('11000000-0000-4000-8000-000000000002','31000000-0000-4000-8000-000000000002','2026-10-02',0,'closing_shift','[{"entry_date":"2026-10-02","actual_cash":20,"actual_credit":30,"pos_cash":20,"pos_credit":30,"online_delivery":0,"refund_total":0}]','[{"entry_date":"2026-10-02","denom_10":5,"remaining_cash":999}]')$$,'AED report saves');
select lives_ok($$select public.submit_sales_tracking('11000000-0000-4000-8000-000000000002','31000000-0000-4000-8000-000000000002','2026-10-02',1,'41000000-0000-4000-8000-000000000003',repeat('c',64))$$,'AED report submits');
insert into public.sales_tracking_attachments(id,organization_id,branch_id,report_id,storage_path,original_filename,mime_type,size_bytes,uploaded_by_user_id,display_order)
select'b1000000-0000-4000-8000-000000000004','21000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000002',authoritative_report_id,'current/three.webp','three.webp','image/webp',100,'11000000-0000-4000-8000-000000000002',1 from public.sales_tracking_report_cases where branch_id='31000000-0000-4000-8000-000000000002';

create temporary table period_result as select public.get_managed_sales_tracking_period_summary('11000000-0000-4000-8000-000000000001','21000000-0000-4000-8000-000000000001','2026-10-01','2026-10-02',null)value;
select is(jsonb_array_length(value->'currency_summaries'),2,'SAR and AED remain separate')from period_result;
select is((select item->>'gross_sales'from period_result,jsonb_array_elements(value->'currency_summaries')item where item->>'currency_code'='SAR'),'350','Superseded values are excluded');
select is((select item->>'refund_total'from period_result,jsonb_array_elements(value->'currency_summaries')item where item->>'currency_code'='SAR'),'10.00','Refund aggregates exactly');
select is((select item->>'net_sales'from period_result,jsonb_array_elements(value->'currency_summaries')item where item->>'currency_code'='SAR'),'340.00','Net is recalculated');
select is((select item->'pos_reconciliation'->>'variance'from period_result,jsonb_array_elements(value->'currency_summaries')item where item->>'currency_code'='SAR'),'20','Variance formula is preserved');
select is((select item->>'counted_cash_total'from period_result,jsonb_array_elements(value->'currency_summaries')item where item->>'currency_code'='SAR'),'300','Remaining cash snapshots are excluded');
select is((select item->'provider_breakdown'->0->>'amount'from period_result,jsonb_array_elements(value->'currency_summaries')item where item->>'currency_code'='SAR'),'50','Provider amounts aggregate by stable identity');

create temporary table evidence_result as select public.list_managed_sales_tracking_period_evidence('11000000-0000-4000-8000-000000000001','21000000-0000-4000-8000-000000000001','2026-10-01','2026-10-02',null,51)value;
select is(jsonb_array_length(value->'items'),3,'Only active authoritative photos are listed')from evidence_result;
select ok(not exists(select 1 from evidence_result,jsonb_array_elements(value->'items')item where item->>'attachment_id'='b1000000-0000-4000-8000-000000000001'),'Superseded photo is excluded');
select ok((select value->>'authority_revision' from evidence_result) ~ '^[0-9a-f]{32}$','Authority revision is a valid 32-character hex fingerprint');

select is(jsonb_array_length(public.list_managed_sales_tracking_period_evidence('11000000-0000-4000-8000-000000000001','21000000-0000-4000-8000-000000000001','2026-10-01','2026-10-02',null,2)->'items'),2,'Metadata page limit is honored');
create temporary table first_page_envelope as
select public.list_managed_sales_tracking_period_evidence('11000000-0000-4000-8000-000000000001','21000000-0000-4000-8000-000000000001','2026-10-01','2026-10-02',null,2) as payload;

create temporary table first_page as
select item,ordinality from first_page_envelope,jsonb_array_elements(payload->'items')with ordinality as page(item,ordinality);

create temporary table second_page as
select next_item.value as item from first_page last_item,first_page_envelope,jsonb_array_elements(public.list_managed_sales_tracking_period_evidence(
 '11000000-0000-4000-8000-000000000001','21000000-0000-4000-8000-000000000001','2026-10-01','2026-10-02',null,2,
 (last_item.item->>'business_date')::date,(last_item.item->>'branch_id')::uuid,(last_item.item->>'report_id')::uuid,
 (last_item.item->>'display_order')::smallint,(last_item.item->>'attachment_id')::uuid,
 (first_page_envelope.payload->>'authority_revision')
)->'items')as next_item(value)where last_item.ordinality=2;
select is((select count(*)from second_page),1::bigint,'Cursor returns the remaining row without a gap');
select ok(not exists(select 1 from second_page s join first_page f on s.item->>'attachment_id'=f.item->>'attachment_id'),'Cursor page has no duplicate attachment');

select throws_ok($$select public.list_managed_sales_tracking_period_evidence(
 '11000000-0000-4000-8000-000000000001','21000000-0000-4000-8000-000000000001','2026-10-01','2026-10-02',null,2,
 '2026-10-01'::date,'31000000-0000-4000-8000-000000000001'::uuid,'56000000-0000-4000-8000-000000000001'::uuid,1::smallint,'76000000-0000-4000-8000-000000000001'::uuid,
 '00000000000000000000000000000000'
)$$,'40001','sales tracking evidence authority changed','Mismatched authority revision is rejected with 40001');

select is(jsonb_array_length(public.authorize_managed_sales_tracking_evidence_renewal('11000000-0000-4000-8000-000000000001','21000000-0000-4000-8000-000000000001','2026-10-01','2026-10-02',null,array['b1000000-0000-4000-8000-000000000002','b1000000-0000-4000-8000-000000000001']::uuid[])->'items'),1,'Renewal omits superseded attachment without disclosure');
select throws_ok($$select public.list_managed_sales_tracking_period_evidence('11000000-0000-4000-8000-000000000001','21000000-0000-4000-8000-000000000001','2026-10-01','2026-10-02',null,2,'2026-10-01',null,null,null,null,null)$$,'22023','invalid sales tracking evidence cursor','Partial SQL cursor is rejected');
select throws_ok($$select public.authorize_managed_sales_tracking_evidence_renewal('11000000-0000-4000-8000-000000000001','21000000-0000-4000-8000-000000000001','2026-10-01','2026-10-02',null,array['b1000000-0000-4000-8000-000000000002','b1000000-0000-4000-8000-000000000002']::uuid[])$$,'22023','invalid sales tracking evidence renewal','Duplicate renewal IDs are rejected');
select throws_ok($$select public.get_managed_sales_tracking_period_summary('11000000-0000-4000-8000-000000000003','21000000-0000-4000-8000-000000000001','2026-10-01','2026-10-02',null)$$,'42501','sales tracking period access denied','Cross-organization summary is denied');
select throws_ok($$select public.get_managed_sales_tracking_period_summary('11000000-0000-4000-8000-000000000001','21000000-0000-4000-8000-000000000001','2026-01-01','2027-01-02',null)$$,'22023','invalid sales tracking period','SQL rejects more than 366 inclusive days');
select is(jsonb_array_length(public.get_managed_sales_tracking_period_summary('11000000-0000-4000-8000-000000000001','21000000-0000-4000-8000-000000000001','2026-10-01','2026-10-02','31000000-0000-4000-8000-000000000002')->'branches'),1,'Branch filter executes in SQL');

-- Test authority swap between page requests using real database transactions:
-- 1. Grab initial authority revision
create temporary table captured_initial_authority as
select (public.list_managed_sales_tracking_period_evidence('11000000-0000-4000-8000-000000000001','21000000-0000-4000-8000-000000000001','2026-10-01','2026-10-02',null,2)->>'authority_revision') as rev;

-- 2. Simulate correction on UAE Branch (2026-10-02)
select lives_ok($$select public.set_managed_sales_tracking_review_status('11000000-0000-4000-8000-000000000001','21000000-0000-4000-8000-000000000001',(select authoritative_report_id from public.sales_tracking_report_cases where branch_id='31000000-0000-4000-8000-000000000002'),0,'needs_review')$$,'Correction requested on UAE branch');
select lives_ok($$select public.start_sales_tracking_correction('11000000-0000-4000-8000-000000000002','31000000-0000-4000-8000-000000000002',(select authoritative_report_id from public.sales_tracking_report_cases where branch_id='31000000-0000-4000-8000-000000000002'),1)$$,'Correction started on UAE branch');
select lives_ok($$select public.save_sales_tracking_correction('11000000-0000-4000-8000-000000000002','31000000-0000-4000-8000-000000000002',(select open_correction_report_id from public.sales_tracking_report_cases where branch_id='31000000-0000-4000-8000-000000000002'),1,'closing_shift','[{"entry_date":"2026-10-02","actual_cash":25,"actual_credit":30,"pos_cash":25,"pos_credit":30,"online_delivery":0,"refund_total":0}]','[{"entry_date":"2026-10-02","denom_10":5,"remaining_cash":999}]')$$,'Correction saved');
select lives_ok($$select public.submit_sales_tracking_correction('11000000-0000-4000-8000-000000000002','31000000-0000-4000-8000-000000000002',(select open_correction_report_id from public.sales_tracking_report_cases where branch_id='31000000-0000-4000-8000-000000000002'),2,'41000000-0000-4000-8000-000000000004',repeat('d',64))$$,'Correction submitted atomically, swapping authoritative_report_id');

-- 3. Now verify that attempting to fetch page 2 using the previous captured authority revision fails with 40001
select throws_ok(
 format(
   $$select public.list_managed_sales_tracking_period_evidence('11000000-0000-4000-8000-000000000001','21000000-0000-4000-8000-000000000001','2026-10-01','2026-10-02',null,2,'2026-10-01'::date,'31000000-0000-4000-8000-000000000001'::uuid,'56000000-0000-4000-8000-000000000001'::uuid,1::smallint,'76000000-0000-4000-8000-000000000001'::uuid,%L)$$,
   (select rev from captured_initial_authority)
 ),
 '40001',
 'sales tracking evidence authority changed',
 'Page 2 request is rejected with 40001 after authority swap correction'
);

select * from finish();
rollback;
