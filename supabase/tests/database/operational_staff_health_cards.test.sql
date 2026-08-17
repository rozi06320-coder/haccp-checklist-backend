begin;
select plan(25);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
 '1d000000-0000-4000-8000-000000000001'::uuid,
 '1d000000-0000-4000-8000-000000000002',
 '1d000000-0000-4000-8000-000000000003'
]) id;
update public.profiles set full_name=case id
 when '1d000000-0000-4000-8000-000000000001' then 'Health Card Supervisor'
 when '1d000000-0000-4000-8000-000000000002' then 'Other Health Supervisor'
 else 'Health Card Manager' end,
 must_change_password=false
where id in (
 '1d000000-0000-4000-8000-000000000001',
 '1d000000-0000-4000-8000-000000000002',
 '1d000000-0000-4000-8000-000000000003'
);
insert into public.organizations(id,name,slug)
values('2d000000-0000-4000-8000-000000000001','Health Card Org','health-card-org');
insert into public.branches(id,organization_id,name,code,timezone)
values('3d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','Health Card Branch','HCB','Asia/Riyadh');
insert into public.organization_memberships(organization_id,user_id,role)
values('2d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000003','organization_manager');
insert into public.branch_memberships(branch_id,user_id,role)
values
 ('3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000001','branch_manager'),
 ('3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000002','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id,company_name)
values('5d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','1d000000-0000-4000-8000-000000000001','Health Company');
insert into public.operational_staff(id,organization_id,branch_id,display_name,company_name,staff_code,created_by)
values
 ('6d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','Health Worker','Health Company','HC-1','1d000000-0000-4000-8000-000000000001'),
 ('6d000000-0000-4000-8000-000000000002','2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','Unassigned Worker','Health Company','HC-2','1d000000-0000-4000-8000-000000000001');
insert into public.operational_staff_assignments(id,organization_id,branch_id,operational_staff_id,supervisor_team_id,operational_roles)
values('7d000000-0000-4000-8000-000000000001','2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001','6d000000-0000-4000-8000-000000000001','5d000000-0000-4000-8000-000000000001',array['kitchen']);

select has_table('public','operational_staff_health_cards','health cards table exists');
select has_column('public','operational_staff_health_cards','certificate_number','health cards store certificate number');
select has_column('public','operational_staff_health_cards','status','health cards store status');
select has_column('public','operational_staff_health_cards','expiry_date','health cards store expiry date');
select has_column('public','operational_staff_health_cards','date_issue','health cards store issue date');
select ok(not has_function_privilege('authenticated','public.list_operational_staff_health_cards(uuid,uuid)','execute')
 and has_function_privilege('service_role','public.list_operational_staff_health_cards(uuid,uuid)','execute'),
 'health card list RPC is service-role only');
select ok(not has_function_privilege('authenticated','public.upsert_operational_staff_health_card(uuid,uuid,jsonb)','execute')
 and has_function_privilege('service_role','public.upsert_operational_staff_health_card(uuid,uuid,jsonb)','execute'),
 'health card upsert RPC is service-role only');
select is((select count(*)::int from public.list_operational_staff_health_cards(
 '1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001')),
 0,'health card list returns an empty set before any cards exist');

set local role service_role;
select lives_ok($$select * from public.upsert_operational_staff_health_card(
 '1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001',
 jsonb_build_object(
  'operational_staff_id','6d000000-0000-4000-8000-000000000001',
  'certificate_number',' HC-7788 ',
  'status','passed',
  'place_of_issue',' Riyadh ',
  'expiry_date','2027-01-31',
  'date_issue','2026-01-31',
  'occupation',' Kitchen ',
  'company',' Burger Hunch ',
  'notes',' Complete '
 ))$$,'supervisor upserts own staff health card');
reset role;

select is((select certificate_number from public.operational_staff_health_cards where operational_staff_id='6d000000-0000-4000-8000-000000000001'),'HC-7788','certificate number is trimmed and stored');
select is((select status from public.operational_staff_health_cards where operational_staff_id='6d000000-0000-4000-8000-000000000001'),'passed','status is stored');
select is((select expiry_date from public.operational_staff_health_cards where operational_staff_id='6d000000-0000-4000-8000-000000000001'),'2027-01-31'::date,'expiry date is stored');
select is((select branch_name_snapshot from public.operational_staff_health_cards where operational_staff_id='6d000000-0000-4000-8000-000000000001'),'Health Card Branch','branch snapshot is stored');
select is((select certificate_number from public.list_operational_staff_health_cards(
 '1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001')
 where operational_staff_id='6d000000-0000-4000-8000-000000000001'),'HC-7788','list restores health card fields');

set local role service_role;
select lives_ok($$select * from public.upsert_operational_staff_health_card(
 '1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001',
 jsonb_build_object('operational_staff_id','6d000000-0000-4000-8000-000000000001','status','not_done','certificate_number','   ','expiry_date','','date_issue',''))$$,'blank optional health card values clear fields');
reset role;
select ok((select certificate_number is null and expiry_date is null and date_issue is null
 from public.operational_staff_health_cards where operational_staff_id='6d000000-0000-4000-8000-000000000001'),'blank values become null');

set local role service_role;
select lives_ok($$select * from public.upsert_operational_staff_health_card(
 '1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001',
 jsonb_build_object('operational_staff_id','6d000000-0000-4000-8000-000000000001','status','failed','expiry_date','2027-01-31'))$$,'failed health card status saves');
reset role;
select is((select status from public.operational_staff_health_cards where operational_staff_id='6d000000-0000-4000-8000-000000000001'),'failed','failed status is stored explicitly');
select is((select status from public.list_operational_staff_health_cards(
 '1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001')
 where operational_staff_id='6d000000-0000-4000-8000-000000000001'),'failed','list returns failed health card status');
select is((select employment_status from public.operational_staff where id='6d000000-0000-4000-8000-000000000001'),'active','failed health card status does not alter employee lifecycle');

select throws_ok($$select * from public.upsert_operational_staff_health_card(
 '1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001',
 jsonb_build_object('operational_staff_id','6d000000-0000-4000-8000-000000000001','status','bad'))$$,
 '42501','health card access denied','invalid status is rejected safely');
select throws_ok($$select * from public.upsert_operational_staff_health_card(
 '1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001',
 jsonb_build_object('operational_staff_id','6d000000-0000-4000-8000-000000000001','status','pending','expiry_date','2026-02-31'))$$,
 '22023','invalid health card date','invalid dates are rejected');
select throws_ok($$select * from public.upsert_operational_staff_health_card(
 '1d000000-0000-4000-8000-000000000002','3d000000-0000-4000-8000-000000000001',
 jsonb_build_object('operational_staff_id','6d000000-0000-4000-8000-000000000001','status','pending'))$$,
 '42501','health card access denied','other supervisor cannot upsert health card');
select throws_ok($$select * from public.upsert_operational_staff_health_card(
 '1d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001',
 jsonb_build_object('operational_staff_id','6d000000-0000-4000-8000-000000000002','status','pending'))$$,
 '42501','health card access denied','unassigned staff cannot receive team health card');

set local role authenticated;
select throws_ok($$insert into public.operational_staff_health_cards(
 organization_id,branch_id,supervisor_team_id,operational_staff_id,status
) values (
 '2d000000-0000-4000-8000-000000000001','3d000000-0000-4000-8000-000000000001',
 '5d000000-0000-4000-8000-000000000001','6d000000-0000-4000-8000-000000000001','pending'
)$$,'42501',null,'direct authenticated writes are denied');
reset role;

select * from finish();
rollback;
