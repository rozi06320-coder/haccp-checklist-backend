begin;
select plan(48);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',email,'{}','{}',now(),now()
from (values
  ('19000000-0000-4000-8000-000000000001'::uuid,'manager@people.invalid'),
  ('19000000-0000-4000-8000-000000000002'::uuid,'unauthorized@people.invalid'),
  ('19000000-0000-4000-8000-000000000003'::uuid,'multi@people.invalid'),
  ('19000000-0000-4000-8000-000000000004'::uuid,'cross@people.invalid'),
  ('19000000-0000-4000-8000-000000000005'::uuid,'inactive-membership@people.invalid'),
  ('19000000-0000-4000-8000-000000000006'::uuid,'inactive-branch@people.invalid'),
  ('19000000-0000-4000-8000-000000000007'::uuid,'deactivated@people.invalid'),
  ('19000000-0000-4000-8000-000000000008'::uuid,'disabled@people.invalid'),
  ('19000000-0000-4000-8000-000000000009'::uuid,'password@people.invalid'),
  ('19000000-0000-4000-8000-000000000010'::uuid,'both@people.invalid'),
  ('19000000-0000-4000-8000-000000000011'::uuid,'staff-supervisor@people.invalid'),
  ('19000000-0000-4000-8000-000000000012'::uuid,'transferred@people.invalid'),
  ('19000000-0000-4000-8000-000000000013'::uuid,'future-membership@people.invalid'),
  ('19000000-0000-4000-8000-000000000014'::uuid,'expiry-membership@people.invalid')
) users(id,email);

update public.profiles
set full_name = case id
    when '19000000-0000-4000-8000-000000000001' then 'People Manager'
    when '19000000-0000-4000-8000-000000000002' then 'Unauthorized Manager'
    when '19000000-0000-4000-8000-000000000003' then 'Multi Branch Supervisor'
    when '19000000-0000-4000-8000-000000000004' then 'Cross Org Supervisor'
    when '19000000-0000-4000-8000-000000000005' then 'Inactive Membership Supervisor'
    when '19000000-0000-4000-8000-000000000006' then 'Inactive Branch Supervisor'
    when '19000000-0000-4000-8000-000000000007' then 'Deactivated Supervisor'
    when '19000000-0000-4000-8000-000000000008' then 'Disabled Supervisor'
    when '19000000-0000-4000-8000-000000000009' then 'Password Change Supervisor'
    when '19000000-0000-4000-8000-000000000010' then 'Disabled Password Supervisor'
    when '19000000-0000-4000-8000-000000000011' then 'Promoted Supervisor'
    when '19000000-0000-4000-8000-000000000012' then 'Transferred Supervisor'
    when '19000000-0000-4000-8000-000000000013' then 'Future Membership Supervisor'
    else 'Expiry Membership Supervisor'
  end,
  full_name_ar = case when id='19000000-0000-4000-8000-000000000003' then 'مشرف متعدد الفروع' else null end,
  person_code = case
    when id='19000000-0000-4000-8000-000000000003' then 'SUP-MULTI-0736'
    when id='19000000-0000-4000-8000-000000000012' then 'SUP-TRANSFER'
    else null
  end,
  must_change_password = id in('19000000-0000-4000-8000-000000000009','19000000-0000-4000-8000-000000000010'),
  disabled_at = case when id in('19000000-0000-4000-8000-000000000008','19000000-0000-4000-8000-000000000010') then now() else null end,
  created_at = now()-interval '2 months'
where id::text like '19000000-0000-4000-8000-%';

insert into public.organizations(id,name,slug,active) values
  ('29000000-0000-4000-8000-000000000001','People Organization','people-organization',true),
  ('29000000-0000-4000-8000-000000000002','Other People Organization','other-people-organization',true);

insert into public.branches(id,organization_id,name,code,timezone,active) values
  ('39000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001','Alpha Branch','ALPHA','Asia/Riyadh',true),
  ('39000000-0000-4000-8000-000000000002','29000000-0000-4000-8000-000000000001','Beta Branch','BETA','Asia/Riyadh',true),
  ('39000000-0000-4000-8000-000000000003','29000000-0000-4000-8000-000000000001','Closed Branch','CLOSED','Asia/Riyadh',false),
  ('39000000-0000-4000-8000-000000000004','29000000-0000-4000-8000-000000000002','Cross Branch','CROSS','Asia/Riyadh',true);

insert into public.organization_memberships(organization_id,user_id,role,active) values
  ('29000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000001','organization_manager',true);

insert into public.branch_memberships(branch_id,user_id,role,active,created_at) values
  ('39000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000003','branch_manager',true,now()),
  ('39000000-0000-4000-8000-000000000002','19000000-0000-4000-8000-000000000003','branch_manager',true,now()),
  ('39000000-0000-4000-8000-000000000004','19000000-0000-4000-8000-000000000004','branch_manager',true,now()),
  ('39000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000005','branch_manager',false,now()),
  ('39000000-0000-4000-8000-000000000003','19000000-0000-4000-8000-000000000006','branch_manager',true,now()),
  ('39000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000007','branch_manager',false,now()),
  ('39000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000008','branch_manager',true,now()),
  ('39000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000009','branch_manager',true,now()),
  ('39000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000010','branch_manager',true,now()),
  ('39000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000011','branch_manager',true,now()),
  ('39000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000012','branch_manager',false,now()-interval '2 months'),
  ('39000000-0000-4000-8000-000000000002','19000000-0000-4000-8000-000000000012','branch_manager',true,now()),
  ('39000000-0000-4000-8000-000000000004','19000000-0000-4000-8000-000000000003','branch_manager',true,now()-interval '2 months'),
  ('39000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000013','branch_manager',true,now()+interval '1 day'),
  ('39000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000014','branch_manager',true,now()-interval '1 month');

insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id,active) values
  ('49000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000003',true);
select set_config('test.people_team',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='49000000-0000-4000-8000-000000000001'),false);

insert into public.operational_staff(
  id,organization_id,branch_id,display_name,employment_status,created_by,created_at,deactivated_at,deactivated_by,
  staff_code,email
) values
  ('59000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001','Assigned Staff','active','19000000-0000-4000-8000-000000000001',now()-interval '2 months',null,null,'EMP-ASSIGNED','assigned@people.invalid'),
  ('59000000-0000-4000-8000-000000000002','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000002','Beta Staff','active','19000000-0000-4000-8000-000000000001',now()-interval '2 months',null,null,'EMP-BETA','beta@people.invalid'),
  ('59000000-0000-4000-8000-000000000003','29000000-0000-4000-8000-000000000002','39000000-0000-4000-8000-000000000004','Cross Org Staff','active','19000000-0000-4000-8000-000000000001',now()-interval '2 months',null,null,'EMP-CROSS','cross-staff@people.invalid'),
  ('59000000-0000-4000-8000-000000000004','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001','New Staff','active','19000000-0000-4000-8000-000000000001',now()-interval '15 days',null,null,'EMP-NEW','new-staff@people.invalid'),
  ('59000000-0000-4000-8000-000000000005','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001','Before Expiry Staff','active','19000000-0000-4000-8000-000000000001',now()-interval '1 month'+interval '1 microsecond',null,null,'EMP-BEFORE','before@people.invalid'),
  ('59000000-0000-4000-8000-000000000006','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001','At Expiry Staff','active','19000000-0000-4000-8000-000000000001',now()-interval '1 month',null,null,'EMP-AT','at@people.invalid'),
  ('59000000-0000-4000-8000-000000000007','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001','Future Staff','active','19000000-0000-4000-8000-000000000001',now()+interval '1 day',null,null,'EMP-FUTURE','future@people.invalid'),
  ('59000000-0000-4000-8000-000000000008','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001','Transferred Staff','active','19000000-0000-4000-8000-000000000001',now()-interval '2 months',null,null,'EMP-TRANSFER','transfer@people.invalid'),
  ('59000000-0000-4000-8000-000000000009','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001','Promoted Historical Staff','inactive','19000000-0000-4000-8000-000000000001',now()-interval '2 months',now(),'19000000-0000-4000-8000-000000000001','EMP-PROMOTED','promoted@people.invalid');

insert into public.operational_staff_assignments(
  id,organization_id,branch_id,operational_staff_id,supervisor_team_id,operational_team_id,operational_roles,created_at
) values
  ('69000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001','59000000-0000-4000-8000-000000000001','49000000-0000-4000-8000-000000000001',current_setting('test.people_team')::uuid,array['kitchen'],now()),
  ('69000000-0000-4000-8000-000000000002','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001','59000000-0000-4000-8000-000000000008','49000000-0000-4000-8000-000000000001',current_setting('test.people_team')::uuid,array['front_of_house'],now());

insert into public.operational_staff_supervisor_training(
  id,organization_id,operational_staff_id,branch_id_at_start,status,started_by_user_id,promoted_at,promoted_by_user_id,promoted_supervisor_user_id
) values(
  '79000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001','59000000-0000-4000-8000-000000000009','39000000-0000-4000-8000-000000000001','promoted','19000000-0000-4000-8000-000000000001',now(),'19000000-0000-4000-8000-000000000001','19000000-0000-4000-8000-000000000011'
);

insert into public.operational_staff_health_cards(
  organization_id,branch_id,supervisor_team_id,operational_staff_id,status,certificate_number
) values(
  '29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001','49000000-0000-4000-8000-000000000001','59000000-0000-4000-8000-000000000001','passed','HC-PEOPLE'
);

insert into public.operational_staff_monthly_evaluations(
  organization_id,branch_id,supervisor_team_id,operational_staff_id,evaluation_month,status
) values(
  '29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001','49000000-0000-4000-8000-000000000001','59000000-0000-4000-8000-000000000001',pg_catalog.date_trunc('month',current_date)::date,'draft'
);

create temporary table people_results(name text primary key,payload jsonb) on commit drop;
insert into people_results values
  ('all',public.list_managed_people_directory('19000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001',null,pg_catalog.date_trunc('month',current_date)::date,null)),
  ('alpha',public.list_managed_people_directory('19000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001',pg_catalog.date_trunc('month',current_date)::date,null)),
  ('beta',public.list_managed_people_directory('19000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000002',pg_catalog.date_trunc('month',current_date)::date,null)),
  ('staff-search',public.list_managed_people_directory('19000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001',null,pg_catalog.date_trunc('month',current_date)::date,'EMP-NEW')),
  ('supervisor-search',public.list_managed_people_directory('19000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001',null,pg_catalog.date_trunc('month',current_date)::date,'مشرف متعدد')),
  ('cross-search',public.list_managed_people_directory('19000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001',null,pg_catalog.date_trunc('month',current_date)::date,'Cross Org')),
  ('staff-code',public.list_managed_people_directory('19000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001',null,pg_catalog.date_trunc('month',current_date)::date,null,'emp-new')),
  ('supervisor-code',public.list_managed_people_directory('19000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001',null,pg_catalog.date_trunc('month',current_date)::date,null,'0736')),
  ('literal-search',public.list_managed_people_directory('19000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001',null,pg_catalog.date_trunc('month',current_date)::date,'%_')),
  ('literal-code',public.list_managed_people_directory('19000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001',null,pg_catalog.date_trunc('month',current_date)::date,null,'%_')),
  ('combined-filters',public.list_managed_people_directory('19000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001','39000000-0000-4000-8000-000000000001',pg_catalog.date_trunc('month',current_date)::date,'New Staff','EMP-NEW'));

create temporary view all_people as
select person
from people_results result
cross join lateral pg_catalog.jsonb_array_elements(result.payload->'people') person
where result.name='all';

select ok(exists(select 1 from all_people where person->>'person_type'='staff' and person->>'person_id'='59000000-0000-4000-8000-000000000001'),'operational staff appears');
select ok(exists(select 1 from all_people where person->>'person_type'='supervisor' and person->>'person_id'='19000000-0000-4000-8000-000000000003'),'active supervisor appears');
select ok(not exists(select 1 from all_people where person->>'person_id'='19000000-0000-4000-8000-000000000004'),'cross-organization supervisor is hidden');
select ok(not exists(select 1 from all_people where person->>'person_id'='19000000-0000-4000-8000-000000000005'),'inactive supervisor membership is hidden');
select ok(not exists(select 1 from all_people where person->>'person_id'='19000000-0000-4000-8000-000000000006'),'supervisor on inactive branch is hidden');
select ok(not exists(select 1 from all_people where person->>'person_id'='19000000-0000-4000-8000-000000000007'),'canonically deactivated supervisor is excluded');
select ok(not exists(select 1 from people_results result cross join lateral pg_catalog.jsonb_array_elements(result.payload->'people') person where result.name='alpha' and person->>'person_id'='59000000-0000-4000-8000-000000000002'),'staff branch filter excludes another branch');
select ok(exists(select 1 from people_results result cross join lateral pg_catalog.jsonb_array_elements(result.payload->'people') person where result.name='beta' and person->>'person_id'='59000000-0000-4000-8000-000000000002'),'staff branch filter includes matching branch');
select ok(exists(select 1 from people_results result cross join lateral pg_catalog.jsonb_array_elements(result.payload->'people') person where result.name in('alpha','beta') and person->>'person_id'='19000000-0000-4000-8000-000000000003' group by person->>'person_id' having count(*)=2),'supervisor branch filter matches either active branch');
select is((select count(*) from all_people where person->>'person_id'='19000000-0000-4000-8000-000000000003'),1::bigint,'multi-branch supervisor is returned once');
select is((select person->'branches' from all_people where person->>'person_id'='19000000-0000-4000-8000-000000000003'),pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('id','39000000-0000-4000-8000-000000000001','name','Alpha Branch','name_ar',null,'code','ALPHA'),pg_catalog.jsonb_build_object('id','39000000-0000-4000-8000-000000000002','name','Beta Branch','name_ar',null,'code','BETA')),'supervisor branches are deterministically ordered and unfiltered in the row');
select is((select (person->>'joined_at')::timestamptz from all_people where person->>'person_id'='59000000-0000-4000-8000-000000000001'),(select created_at from public.operational_staff where id='59000000-0000-4000-8000-000000000001'),'staff joined_at uses operational_staff.created_at');
select is((select (person->>'joined_at')::timestamptz from all_people where person->>'person_id'='19000000-0000-4000-8000-000000000003'),(select min(membership.created_at) from public.branch_memberships membership join public.branches branch on branch.id=membership.branch_id where membership.user_id='19000000-0000-4000-8000-000000000003' and branch.organization_id='29000000-0000-4000-8000-000000000001'),'supervisor joined_at uses the first membership in the target organization');
select is((select (person->>'is_new')::boolean from all_people where person->>'person_id'='59000000-0000-4000-8000-000000000004'),true,'new staff is New');
select is((select (person->>'is_new')::boolean from all_people where person->>'person_id'='19000000-0000-4000-8000-000000000003'),true,'new supervisor is New');
select is((select (person->>'is_new')::boolean from all_people where person->>'person_id'='59000000-0000-4000-8000-000000000005'),true,'one microsecond before new_until remains New');
select is((select (person->>'is_new')::boolean from all_people where person->>'person_id'='59000000-0000-4000-8000-000000000006'),false,'exactly at new_until is not New');
select is((select (person->>'is_new')::boolean from all_people where person->>'person_id'='59000000-0000-4000-8000-000000000007'),false,'future joined_at is not New');
select is((select (person->>'is_new')::boolean from all_people where person->>'person_id'='19000000-0000-4000-8000-000000000012'),false,'new branch membership does not reset supervisor New');
select is((select (person->>'joined_at')::timestamptz from all_people where person->>'person_id'='19000000-0000-4000-8000-000000000012'),now()-interval '2 months','branch transfer preserves the earliest inactive historical membership timestamp');
select is((select (person->>'is_new')::boolean from all_people where person->>'person_id'='19000000-0000-4000-8000-000000000014'),false,'month-old supervisor is not New');
select is((select joined_at <= test_now and test_now < joined_at + interval '1 month' from (values('2024-01-31 12:00:00+00'::timestamptz,'2024-02-29 12:00:00+00'::timestamptz)) boundary(joined_at,test_now)),false,'exactly at calendar-month expiry is not New');
select is((select joined_at <= test_now and test_now < joined_at + interval '1 month' from (values('2024-01-31 12:00:00+00'::timestamptz,'2024-02-29 11:59:59.999999+00'::timestamptz)) boundary(joined_at,test_now)),true,'one microsecond before calendar-month expiry remains New');
select is((select (person->>'is_new')::boolean from all_people where person->>'person_id'='19000000-0000-4000-8000-000000000013'),false,'future supervisor membership is not New');
select is((select (person->>'is_new')::boolean from all_people where person->>'person_id'='59000000-0000-4000-8000-000000000008'),false,'new assignment does not reset staff New');
select is((select person->>'status' from all_people where person->>'person_id'='19000000-0000-4000-8000-000000000008'),'disabled','disabled supervisor status is returned');
select is((select person->>'status' from all_people where person->>'person_id'='19000000-0000-4000-8000-000000000009'),'password_change_required','password-change supervisor status is returned');
select is((select person->>'status' from all_people where person->>'person_id'='19000000-0000-4000-8000-000000000010'),'disabled','disabled status wins over password-change status');
select is((select count(*) from pg_catalog.jsonb_array_elements((select payload->'health_cards' from people_results where name='all')) card where card->>'operational_staff_id'='19000000-0000-4000-8000-000000000003'),0::bigint,'health cards contain no supervisor rows');
select is((select count(*) from pg_catalog.jsonb_array_elements((select payload->'monthly_evaluations' from people_results where name='all')) evaluation where evaluation->>'operational_staff_id'='19000000-0000-4000-8000-000000000003'),0::bigint,'monthly evaluations contain no supervisor rows');
select is(pg_catalog.jsonb_array_length((select payload->'people' from people_results where name='staff-search')),1,'search finds staff by person code');
select is((select payload->'people'->0->>'person_id' from people_results where name='supervisor-search'),'19000000-0000-4000-8000-000000000003','search finds supervisor by Arabic name');
select is(pg_catalog.jsonb_array_length((select payload->'people' from people_results where name='cross-search')),0,'cross-organization search cannot leak people');
select is((select payload->'people'->0->>'person_id' from people_results where name='staff-code'),'59000000-0000-4000-8000-000000000004','code filter finds staff by literal case-insensitive substring');
select is((select payload->'people'->0->>'person_id' from people_results where name='supervisor-code'),'19000000-0000-4000-8000-000000000003','code filter uses profiles.person_code for supervisors');
select is(pg_catalog.jsonb_array_length((select payload->'people' from people_results where name='literal-search')),0,'search treats percent and underscore as literal characters');
select is(pg_catalog.jsonb_array_length((select payload->'people' from people_results where name='literal-code')),0,'code filter treats percent and underscore as literal characters');
select is((select payload->'people'->0->>'person_id' from people_results where name='combined-filters'),'59000000-0000-4000-8000-000000000004','branch search and code filters compose with AND semantics');
select throws_ok($$select public.list_managed_people_directory('19000000-0000-4000-8000-000000000002','29000000-0000-4000-8000-000000000001',null,pg_catalog.date_trunc('month',current_date)::date,null)$$,'42501','people directory access denied','Manager authorization is required');
select ok((select prosecdef from pg_catalog.pg_proc where oid='public.list_managed_people_directory(uuid,uuid,uuid,date,text,text)'::regprocedure),'RPC is SECURITY DEFINER');
select ok(has_function_privilege('service_role','public.list_managed_people_directory(uuid,uuid,uuid,date,text,text)','execute'),'service_role can execute the RPC');
select ok(not has_function_privilege('anon','public.list_managed_people_directory(uuid,uuid,uuid,date,text,text)','execute') and not has_function_privilege('authenticated','public.list_managed_people_directory(uuid,uuid,uuid,date,text,text)','execute'),'browser roles cannot execute the RPC');
select like(pg_catalog.pg_get_functiondef('public.list_managed_people_directory(uuid,uuid,uuid,date,text,text)'::regprocedure),$$%SET search_path TO ''%$$,'RPC fixes an empty search_path');
select ok((public.list_managed_employee_team('19000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001',null,pg_catalog.date_trunc('month',current_date)::date) ? 'employees') and not (public.list_managed_employee_team('19000000-0000-4000-8000-000000000001','29000000-0000-4000-8000-000000000001',null,pg_catalog.date_trunc('month',current_date)::date) ? 'people'),'existing employee-team RPC remains unchanged');
select ok(not exists(select 1 from all_people where person->>'person_id'='59000000-0000-4000-8000-000000000009') and exists(select 1 from all_people where person->>'person_id'='19000000-0000-4000-8000-000000000011'),'explicitly linked promoted staff is suppressed in favor of returned supervisor');
select ok(not ((select person from all_people where person->>'person_id'='19000000-0000-4000-8000-000000000003') ?| array['staff_id','assignment_id','operational_team_id','operational_roles','supervisor_training_status']),'supervisor variant omits staff-only keys');
select is((select (payload->>'people_limit')::integer from people_results where name='all'),1000,'response declares the people result cap');
select ok((select payload ?& array['people_total','people_limit','people_truncated'] from people_results where name='all'),'response exposes total and truncation metadata');

select * from finish();
rollback;
