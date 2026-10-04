begin;
select plan(25);

select has_column('public','sales_tracking_sales_rows','refund_total','Sales rows store a refund');
select col_type_is('public','sales_tracking_sales_rows','refund_total','numeric(14,2)','Refund uses money precision');
select has_table('public','sales_tracking_attachments','Sales evidence metadata has a dedicated table');
select ok((select relrowsecurity from pg_catalog.pg_class where oid='public.sales_tracking_attachments'::regclass),'Attachment metadata has RLS enabled');
select ok(not has_table_privilege('authenticated','public.sales_tracking_attachments','insert,update,delete'),'Authenticated clients cannot mutate attachments');
select ok(has_function_privilege('service_role','public.finalize_sales_tracking_attachment(uuid,uuid,uuid,bigint,uuid,jsonb)','execute'),'Service role can finalize evidence');
select ok(not has_function_privilege('authenticated','public.finalize_sales_tracking_attachment(uuid,uuid,uuid,bigint,uuid,jsonb)','execute'),'Authenticated clients cannot finalize evidence');
select is((select public from storage.buckets where id='sales-tracking-evidence'),false,'Sales evidence bucket is private');
select is((select file_size_limit from storage.buckets where id='sales-tracking-evidence'),5242880::bigint,'Sales evidence bucket is limited to 5 MB');

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('00000000-0000-0000-0000-000000000000','1b000000-0000-4000-8000-000000000001','authenticated','authenticated','refund-photo@example.invalid','{}','{}',now(),now());
update public.profiles set full_name='Refund Photo Supervisor',must_change_password=false where id='1b000000-0000-4000-8000-000000000001';
insert into public.organizations(id,name,slug)values('2b000000-0000-4000-8000-000000000001','Refund Photo Org','refund-photo-org');
insert into public.branches(id,organization_id,name,code,timezone,country_code)
values('3b000000-0000-4000-8000-000000000001','2b000000-0000-4000-8000-000000000001','Refund Photo Branch','RFP','Asia/Riyadh','SA');
insert into public.branch_memberships(branch_id,user_id,role)values('3b000000-0000-4000-8000-000000000001','1b000000-0000-4000-8000-000000000001','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id)
values('4b000000-0000-4000-8000-000000000001','2b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001','1b000000-0000-4000-8000-000000000001');

select lives_ok(format($$select public.ensure_sales_tracking_draft_report('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001','%s')$$,private.phase4a_business_date('Asia/Riyadh')),'A draft report shell can be ensured before sales rows exist');
select is((select count(*) from public.sales_tracking_sales_rows row join public.sales_tracking_reports report on report.id=row.report_id where report.branch_id='3b000000-0000-4000-8000-000000000001'),0::bigint,'Ensuring a report does not create a fake period row');
select lives_ok(format($$select public.save_sales_tracking_draft('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001','%s',0,'middle_shift','[{"entry_date":"%s","actual_cash":"0","actual_credit":"0","pos_cash":"0","pos_credit":"0","online_delivery":"0"}]','[{"entry_date":"%s","remaining_cash":"0"}]')$$,private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh')),'An old-style payload without refund defaults to zero');
select lives_ok(format($$select public.save_sales_tracking_draft('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001','%s',1,'closing_shift','[{"entry_date":"%s","actual_cash":"60.00","actual_credit":"40.00","pos_cash":"50.00","pos_credit":"30.00","online_delivery":"0","refund_total":"10.00"}]','[{"entry_date":"%s","remaining_cash":"0"}]')$$,private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh'),private.phase4a_business_date('Asia/Riyadh')),'A valid refund saves with the immutable period');
select is((select max(refund_total) from public.sales_tracking_sales_rows row join public.sales_tracking_reports report on report.id=row.report_id where report.branch_id='3b000000-0000-4000-8000-000000000001'),10.00::numeric,'Refund persists');
select is((public.get_sales_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->'totals'->>'gross_sales')::numeric,100.00::numeric,'Gross sales remain unchanged');
select is((public.get_sales_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->'totals'->>'net_sales')::numeric,90.00::numeric,'Net sales subtract refund');
select is((public.get_sales_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->'totals'->>'variance')::numeric,20.00::numeric,'Refund does not alter variance');
select throws_ok(format($$select private.sales_tracking_refund_field('{"actual_cash":1,"actual_credit":0,"online_delivery":0,"refund_total":"0.001"}')$$),'22023','invalid sales tracking refund','Refund rejects more than two decimals');
select throws_ok(format($$select private.sales_tracking_refund_field('{"actual_cash":1,"actual_credit":0,"online_delivery":0,"refund_total":"2.00"}')$$),'22023','invalid sales tracking refund','Refund cannot exceed gross sales');

select lives_ok(format($sql$select public.finalize_sales_tracking_attachment('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001','%s',2,'7b000000-0000-4000-8000-000000000001',jsonb_build_object('storage_path','2b000000-0000-4000-8000-000000000001/3b000000-0000-4000-8000-000000000001/sales-tracking/%s/7b000000-0000-4000-8000-000000000001.jpg','original_filename','evidence.jpg','mime_type','image/jpeg','size_bytes',128))$sql$,(select id from public.sales_tracking_reports where branch_id='3b000000-0000-4000-8000-000000000001'),(select id from public.sales_tracking_reports where branch_id='3b000000-0000-4000-8000-000000000001')),'JPEG metadata can be finalized for a draft report');
select is((select count(*) from public.sales_tracking_attachments where report_id=(select id from public.sales_tracking_reports where branch_id='3b000000-0000-4000-8000-000000000001')and deleted_at is null),1::bigint,'Exactly one active photo exists');
select lives_ok(format($sql$select public.finalize_sales_tracking_attachment('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001','%s',2,'7b000000-0000-4000-8000-000000000002',jsonb_build_object('storage_path','2b000000-0000-4000-8000-000000000001/3b000000-0000-4000-8000-000000000001/sales-tracking/%s/7b000000-0000-4000-8000-000000000002.png','original_filename','replacement.png','mime_type','image/png','size_bytes',256))$sql$,(select id from public.sales_tracking_reports where branch_id='3b000000-0000-4000-8000-000000000001'),(select id from public.sales_tracking_reports where branch_id='3b000000-0000-4000-8000-000000000001')),'Replacement finalizes before the prior metadata is archived');
select is((select count(*) from public.sales_tracking_attachments where report_id=(select id from public.sales_tracking_reports where branch_id='3b000000-0000-4000-8000-000000000001')and deleted_at is null),1::bigint,'Replacement still leaves one active photo');
select lives_ok(format($$select public.submit_sales_tracking('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001','%s',2,'5b000000-0000-4000-8000-000000000001',repeat('a',64))$$,private.phase4a_business_date('Asia/Riyadh')),'Report submits with its optional photo');
select throws_ok(format($sql$select public.remove_sales_tracking_attachment('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001','%s','7b000000-0000-4000-8000-000000000002',3)$sql$,(select id from public.sales_tracking_reports where branch_id='3b000000-0000-4000-8000-000000000001')),'23505','sales tracking already submitted','Submitted evidence is immutable');

select * from finish();
rollback;
