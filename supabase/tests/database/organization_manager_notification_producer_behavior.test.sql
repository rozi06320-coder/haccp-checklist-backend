begin;
select plan(23);

-- All fixtures use the disposable organization from the runtime setup. Every
-- row is rolled back at the end of this transaction.
insert into auth.users(id,email,created_at,updated_at,role,aud) values
  ('f2b00000-0000-0000-0000-000000001001','p2b-manager-a@test.invalid',now(),now(),'authenticated','authenticated'),
  ('f2b00000-0000-0000-0000-000000001002','p2b-manager-b@test.invalid',now(),now(),'authenticated','authenticated'),
  ('f2b00000-0000-0000-0000-000000001003','p2b-supervisor@test.invalid',now(),now(),'authenticated','authenticated');
insert into public.organization_memberships(organization_id,user_id,role,active) values
  ('f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001001','organization_manager',true),
  ('f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001002','organization_manager',true);

insert into public.branches(id,organization_id,name,code,timezone,active) values
  ('f2b00000-0000-0000-0000-000000001010','f2b00000-0000-4000-8000-000000000001','P2B Sales Missing','P2B-A','Asia/Riyadh',true),
  ('f2b00000-0000-0000-0000-000000001011','f2b00000-0000-4000-8000-000000000001','P2B Submitted','P2B-B','Asia/Riyadh',true),
  ('f2b00000-0000-0000-0000-000000001012','f2b00000-0000-4000-8000-000000000001','P2B Malformed','P2B-C','Asia/Riyadh',true),
  ('f2b00000-0000-0000-0000-000000001013','f2b00000-0000-4000-8000-000000000001','P2B Maintenance','P2B-D','Asia/Riyadh',true);
update public.daily_report_branch_lifecycle set effective_from_business_date='2026-10-01'
 where branch_id in ('f2b00000-0000-0000-0000-000000001010','f2b00000-0000-0000-0000-000000001011','f2b00000-0000-0000-0000-000000001012','f2b00000-0000-0000-0000-000000001013');
update public.daily_report_module_applicability set effective_from_business_date='2026-10-01'
 where branch_id in ('f2b00000-0000-0000-0000-000000001010','f2b00000-0000-0000-0000-000000001011','f2b00000-0000-0000-0000-000000001012','f2b00000-0000-0000-0000-000000001013');

-- Proven missing: complete applicability, no authoritative case.
insert into private.organization_manager_notification_evaluation_jobs(id,notification_category,organization_id,branch_id,business_date,state,lease_token,leased_by,lease_expires_at) values
 ('f2b00000-0000-0000-0000-000000001020','sales_tracking_missing','f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001010','2026-10-29','running','f2b00000-0000-0000-0000-000000001021','f2b00000-0000-0000-0000-000000001001',now()+interval '10 minutes');
select is((select result from public.produce_organization_manager_notification_evaluation_job('f2b00000-0000-0000-0000-000000001020','f2b00000-0000-0000-0000-000000001021')),'completed','proven missing completes producer');
select is((select count(*)::integer from public.organization_manager_notifications where branch_id='f2b00000-0000-0000-0000-000000001010' and event_type='sales_tracking_missing'),2,'both eligible managers receive missing notification');

-- Valid submitted report with needs_review, then with reviewed/none semantics.
insert into public.sales_tracking_report_cases(id,organization_id,branch_id,business_date)
 values('f2b00000-0000-0000-0000-000000001029','f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001011','2026-10-29');
insert into public.sales_tracking_reports(id,organization_id,branch_id,supervisor_user_id,business_date,state,submitted_at,branch_name_snapshot,supervisor_name_snapshot,supervisor_team_name_snapshot,review_status,reviewed_at,reviewed_by_user_id) values
 ('f2b00000-0000-0000-0000-000000001030','f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001011','f2b00000-0000-0000-0000-000000001003','2026-10-29','submitted',now(),'Submitted','Supervisor','Team','needs_review',now(),'f2b00000-0000-0000-0000-000000001001');
update public.sales_tracking_report_cases set authoritative_report_id='f2b00000-0000-0000-0000-000000001030' where branch_id='f2b00000-0000-0000-0000-000000001011';
insert into private.organization_manager_notification_evaluation_jobs(id,notification_category,organization_id,branch_id,business_date,state,lease_token,leased_by,lease_expires_at) values
 ('f2b00000-0000-0000-0000-000000001031','sales_tracking_missing','f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001011','2026-10-29','running','f2b00000-0000-0000-0000-000000001032','f2b00000-0000-0000-0000-000000001001',now()+interval '10 minutes');
select is((select result from public.produce_organization_manager_notification_evaluation_job('f2b00000-0000-0000-0000-000000001031','f2b00000-0000-0000-0000-000000001032')),'completed','submitted needs_review is satisfied');
select is((select count(*)::integer from public.organization_manager_notifications where branch_id='f2b00000-0000-0000-0000-000000001011' and event_type='sales_tracking_missing'),0,'satisfied submitted report creates no missing event');

-- Full producer-path coverage for valid submitted reports with the two
-- accepted review states that must remain satisfied for missing detection.
insert into public.branches(id,organization_id,name,code,timezone,active) values
  ('f2b00000-0000-0000-0000-000000001014','f2b00000-0000-4000-8000-000000000001','P2B Reviewed None','P2B-E','Asia/Riyadh',true),
  ('f2b00000-0000-0000-0000-000000001015','f2b00000-0000-4000-8000-000000000001','P2B Reviewed','P2B-F','Asia/Riyadh',true);
update public.daily_report_branch_lifecycle set effective_from_business_date='2026-10-01'
 where branch_id in ('f2b00000-0000-0000-0000-000000001014','f2b00000-0000-0000-0000-000000001015');
update public.daily_report_module_applicability set effective_from_business_date='2026-10-01'
 where branch_id in ('f2b00000-0000-0000-0000-000000001014','f2b00000-0000-0000-0000-000000001015');
insert into public.sales_tracking_report_cases(id,organization_id,branch_id,business_date) values
  ('f2b00000-0000-0000-0000-000000001044','f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001014','2026-10-29'),
  ('f2b00000-0000-0000-0000-000000001045','f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001015','2026-10-29');
insert into public.sales_tracking_reports(id,organization_id,branch_id,supervisor_user_id,business_date,state,submitted_at,branch_name_snapshot,supervisor_name_snapshot,supervisor_team_name_snapshot,review_status,reviewed_at,reviewed_by_user_id) values
  ('f2b00000-0000-0000-0000-000000001046','f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001014','f2b00000-0000-0000-0000-000000001003','2026-10-29','submitted',now(),'Submitted','Supervisor','Team','none',null,null),
  ('f2b00000-0000-0000-0000-000000001047','f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001015','f2b00000-0000-0000-0000-000000001003','2026-10-29','submitted',now(),'Submitted','Supervisor','Team','reviewed',now(),'f2b00000-0000-0000-0000-000000001001');
update public.sales_tracking_report_cases set authoritative_report_id='f2b00000-0000-0000-0000-000000001046' where id='f2b00000-0000-0000-0000-000000001044';
update public.sales_tracking_report_cases set authoritative_report_id='f2b00000-0000-0000-0000-000000001047' where id='f2b00000-0000-0000-0000-000000001045';
insert into private.organization_manager_notification_evaluation_jobs(id,notification_category,organization_id,branch_id,business_date,state,lease_token,leased_by,lease_expires_at) values
 ('f2b00000-0000-0000-0000-000000001048','sales_tracking_missing','f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001014','2026-10-29','running','f2b00000-0000-0000-0000-000000001049','f2b00000-0000-0000-0000-000000001001',now()+interval '10 minutes'),
 ('f2b00000-0000-0000-0000-000000001052','sales_tracking_missing','f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001015','2026-10-29','running','f2b00000-0000-0000-0000-000000001053','f2b00000-0000-0000-0000-000000001001',now()+interval '10 minutes');
select is((select result from public.produce_organization_manager_notification_evaluation_job('f2b00000-0000-0000-0000-000000001048','f2b00000-0000-0000-0000-000000001049')),'completed','submitted review_status none is satisfied');
select is((select created_count from public.produce_organization_manager_notification_evaluation_job('f2b00000-0000-0000-0000-000000001048','f2b00000-0000-0000-0000-000000001049')),0,'review_status none creates no missing event');
select is((select result from public.produce_organization_manager_notification_evaluation_job('f2b00000-0000-0000-0000-000000001052','f2b00000-0000-0000-0000-000000001053')),'completed','submitted review_status reviewed is satisfied');
select is((select created_count from public.produce_organization_manager_notification_evaluation_job('f2b00000-0000-0000-0000-000000001052','f2b00000-0000-0000-0000-000000001053')),0,'review_status reviewed creates no missing event');

-- Schema-valid malformed linkage: the case points to a submitted report from
-- another branch, so the FK is valid but source scope is inconsistent.
insert into public.sales_tracking_report_cases(id,organization_id,branch_id,business_date)
 values('f2b00000-0000-0000-0000-000000001039','f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001012','2026-10-29');
insert into public.sales_tracking_reports(id,organization_id,branch_id,supervisor_user_id,business_date,state,submitted_at,branch_name_snapshot,supervisor_name_snapshot,supervisor_team_name_snapshot,review_status) values
 ('f2b00000-0000-0000-0000-000000001040','f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001010','f2b00000-0000-0000-0000-000000001003','2026-10-28','submitted',now(),'Wrong Scope','Supervisor','Team','none');
update public.sales_tracking_report_cases set authoritative_report_id='f2b00000-0000-0000-0000-000000001040' where branch_id='f2b00000-0000-0000-0000-000000001012';
insert into private.organization_manager_notification_evaluation_jobs(id,notification_category,organization_id,branch_id,business_date,state,lease_token,leased_by,lease_expires_at) values
 ('f2b00000-0000-0000-0000-000000001041','sales_tracking_missing','f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001012','2026-10-29','running','f2b00000-0000-0000-0000-000000001042','f2b00000-0000-0000-0000-000000001001',now()+interval '10 minutes');
select is((select result from public.produce_organization_manager_notification_evaluation_job('f2b00000-0000-0000-0000-000000001041','f2b00000-0000-0000-0000-000000001042')),'retryable_unknown','inconsistent authoritative linkage is UNKNOWN');

-- Duplicate case evidence is constraint-proven, not a behavior PASS.
select throws_ok($$insert into public.sales_tracking_report_cases(organization_id,branch_id,business_date) values('f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001011','2026-10-29')$$,'23505',NULL,'duplicate authoritative case is rejected by unique constraint');

-- Forged and expired leases are rejected by the producer boundary.
select throws_ok($$select * from public.produce_organization_manager_notification_evaluation_job('f2b00000-0000-0000-0000-000000001020','f2b00000-0000-0000-0000-000000001099')$$,'55000',NULL,'forged lease rejected');
insert into private.organization_manager_notification_evaluation_jobs(id,notification_category,organization_id,branch_id,business_date,state,lease_token,leased_by,lease_expires_at) values
 ('f2b00000-0000-0000-0000-000000001050','sales_tracking_missing','f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001010','2026-10-28','running','f2b00000-0000-0000-0000-000000001051','f2b00000-0000-0000-0000-000000001001',now()-interval '1 minute');
select throws_ok($$select * from public.produce_organization_manager_notification_evaluation_job('f2b00000-0000-0000-0000-000000001050','f2b00000-0000-0000-0000-000000001051')$$,'55000',NULL,'expired lease rejected');

-- Repeated execution is idempotent and does not create push rows.
select is((select created_count from public.produce_organization_manager_notification_evaluation_job('f2b00000-0000-0000-0000-000000001020','f2b00000-0000-0000-0000-000000001021')),0,'repeat execution deduplicates');
select is((select count(*)::integer from public.organization_manager_push_deliveries d join public.organization_manager_notifications n on n.id=d.notification_id where n.event_type in ('sales_tracking_missing','maintenance_issue','incomplete_branch_tasks')),0,'new categories have no push rows');

-- Maintenance: open at cutoff is included; resolved before cutoff is excluded;
-- unresolved historical update after cutoff yields UNKNOWN; office scope excluded.
insert into public.maintenance_issues(id,organization_id,branch_id,title,category,priority,status,reported_by,location_scope,created_at,updated_at) values
 ('f2b00000-0000-0000-0000-000000001060','f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001013','Open','equipment','normal','new','f2b00000-0000-0000-0000-000000001001','branch','2026-10-30 00:30+00','2026-10-30 00:30+00'),
 ('f2b00000-0000-0000-0000-000000001061','f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001013','Resolved Before','equipment','normal','resolved','f2b00000-0000-0000-0000-000000001001','branch','2026-10-30 00:10+00','2026-10-30 00:20+00'),
 ('f2b00000-0000-0000-0000-000000001062','f2b00000-0000-4000-8000-000000000001',null,'Office','equipment','normal','new','f2b00000-0000-0000-0000-000000001001','office','2026-10-30 00:10+00','2026-10-30 00:10+00');
insert into public.maintenance_issue_updates(id,issue_id,organization_id,status,updated_by,created_at) values
 ('f2b00000-0000-0000-0000-000000001063','f2b00000-0000-0000-0000-000000001061','f2b00000-0000-4000-8000-000000000001','resolved','f2b00000-0000-0000-0000-000000001001','2026-10-30 00:20+00');
select is((select issue_count from private.organization_manager_maintenance_issue_ids('f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001013','2026-10-29','2026-10-30 01:00+00')),1,'open maintenance included and resolved/office excluded');
select is((select source_completeness from private.organization_manager_maintenance_issue_ids('f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001013','2026-10-29','2026-10-30 00:59:59+00')),'unknown','before 04:00 is not complete');

insert into public.maintenance_issues(id,organization_id,branch_id,title,category,priority,status,reported_by,location_scope,created_at,updated_at) values
 ('f2b00000-0000-0000-0000-000000001064','f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001013','Resolved After','equipment','normal','resolved','f2b00000-0000-0000-0000-000000001001','branch','2026-10-30 00:10+00','2026-10-30 01:30+00');
insert into public.maintenance_issue_updates(id,issue_id,organization_id,status,updated_by,created_at) values
 ('f2b00000-0000-0000-0000-000000001065','f2b00000-0000-0000-0000-000000001064','f2b00000-0000-4000-8000-000000000001','resolved','f2b00000-0000-0000-0000-000000001001','2026-10-30 01:30+00');
select is((select source_completeness from private.organization_manager_maintenance_issue_ids('f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001013','2026-10-29','2026-10-30 01:00+00')),'complete','resolved after cutoff remains open at the historical cutoff');
select is((select issue_count from private.organization_manager_maintenance_issue_ids('f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001013','2026-10-29','2026-10-30 01:00+00')),2,'resolved-after-cutoff issue is included in historical open count');

-- Scope and recipient isolation: mismatched organization/branch composite keys
-- are rejected by the real FK, and a second organization cannot receive the
-- first organization's category notifications.
insert into public.organizations(id,name,slug,active) values
 ('f2b00000-0000-4000-8000-000000000002','P2B Other Org','p2b-other-org',true);
insert into auth.users(id,email,created_at,updated_at,role,aud) values
 ('f2b00000-0000-0000-0000-000000001006','p2b-other-manager@test.invalid',now(),now(),'authenticated','authenticated');
insert into public.organization_memberships(organization_id,user_id,role,active) values
 ('f2b00000-0000-4000-8000-000000000002','f2b00000-0000-0000-0000-000000001006','organization_manager',true);
insert into public.branches(id,organization_id,name,code,timezone,active) values
 ('f2b00000-0000-0000-0000-000000001020','f2b00000-0000-4000-8000-000000000002','P2B Other Branch','P2B-X','Asia/Riyadh',true);
select throws_ok($$insert into private.organization_manager_notification_evaluation_jobs(id,notification_category,organization_id,branch_id,business_date,state,lease_token,leased_by,lease_expires_at) values ('f2b00000-0000-0000-0000-000000001066','sales_tracking_missing','f2b00000-0000-4000-8000-000000000001','f2b00000-0000-0000-0000-000000001020','2026-10-29','pending',null,null,null)$$,'23503',NULL,'cross-organization job scope is rejected');
select throws_ok($$insert into private.organization_manager_notification_evaluation_jobs(id,notification_category,organization_id,branch_id,business_date,state,lease_token,leased_by,lease_expires_at) values ('f2b00000-0000-0000-0000-000000001067','sales_tracking_missing','f2b00000-0000-4000-8000-000000000002','f2b00000-0000-0000-0000-000000001010','2026-10-29','pending',null,null,null)$$,'23503',NULL,'cross-branch job scope is rejected');
select is((select count(*)::integer from public.organization_manager_notifications n where n.recipient_user_id='f2b00000-0000-0000-0000-000000001006'),0,'other organization receives no notifications');

-- Transaction-level atomicity proof. The first category insert is followed by
-- a schema-valid RPC call with an invalid context; the enclosing PL/pgSQL
-- subtransaction rolls back both writes. This is not a partial-recipient
-- producer failure, which requires a deterministic per-recipient fault hook.
select is((select count(*)::integer from public.organization_manager_notifications
  where branch_id='f2b00000-0000-0000-0000-000000001014'
    and event_type='sales_tracking_missing'),0,'atomicity fixture starts empty');
do $$
begin
  perform public.create_organization_manager_category_notification(
    'f2b00000-0000-4000-8000-000000000001',
    'f2b00000-0000-0000-0000-000000001001',
    'sales_tracking_missing',
    'f2b00000-0000-0000-0000-000000001014',
    '2026-10-29',
    '{"schema_version":"1","category":"sales_tracking_missing","evidence":"missing"}'::jsonb,
    'manager:v1:sales_tracking_missing:f2b00000-0000-4000-8000-000000000001:f2b00000-0000-0000-0000-000000001014:2026-10-29');
  perform public.create_organization_manager_category_notification(
    'f2b00000-0000-4000-8000-000000000001',
    'f2b00000-0000-0000-0000-000000001001',
    'sales_tracking_missing',
    'f2b00000-0000-0000-0000-000000001014',
    '2026-10-29',
    '{"schema_version":"1","category":"sales_tracking_missing","evidence":"invalid"}'::jsonb,
    'manager:v1:sales_tracking_missing:f2b00000-0000-4000-8000-000000000001:f2b00000-0000-0000-0000-000000001014:2026-10-29');
exception when others then
  null;
end
$$;
select is((select count(*)::integer from public.organization_manager_notifications
  where branch_id='f2b00000-0000-0000-0000-000000001014'
    and event_type='sales_tracking_missing'),0,'later category failure rolls back earlier insert');

select * from finish();
rollback;
