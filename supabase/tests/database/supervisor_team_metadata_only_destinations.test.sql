begin;
select plan(18);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
  '1aa00000-0000-4000-8000-000000000001'::uuid,
  '1aa00000-0000-4000-8000-000000000002',
  '1aa00000-0000-4000-8000-000000000003',
  '1aa00000-0000-4000-8000-000000000004',
  '1aa00000-0000-4000-8000-000000000005'
]) id;

update public.profiles set full_name=case id
  when '1aa00000-0000-4000-8000-000000000001' then 'Source Supervisor'
  when '1aa00000-0000-4000-8000-000000000002' then 'Destination Supervisor'
  when '1aa00000-0000-4000-8000-000000000003' then 'Unassigned Supervisor'
  when '1aa00000-0000-4000-8000-000000000004' then 'Other Branch Supervisor'
  else 'Inactive Team Supervisor' end,must_change_password=false;

insert into public.organizations(id,name,slug)
values('2aa00000-0000-4000-8000-000000000001','Metadata Team Org','metadata-team-org');
insert into public.branches(id,organization_id,name,code,timezone) values
  ('3aa00000-0000-4000-8000-000000000001','2aa00000-0000-4000-8000-000000000001','Metadata Branch','MTA','Asia/Riyadh'),
  ('3aa00000-0000-4000-8000-000000000002','2aa00000-0000-4000-8000-000000000001','Other Branch','MTB','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role) values
  ('3aa00000-0000-4000-8000-000000000001','1aa00000-0000-4000-8000-000000000001','branch_manager'),
  ('3aa00000-0000-4000-8000-000000000001','1aa00000-0000-4000-8000-000000000002','branch_manager'),
  ('3aa00000-0000-4000-8000-000000000001','1aa00000-0000-4000-8000-000000000003','branch_manager'),
  ('3aa00000-0000-4000-8000-000000000002','1aa00000-0000-4000-8000-000000000004','branch_manager'),
  ('3aa00000-0000-4000-8000-000000000001','1aa00000-0000-4000-8000-000000000005','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
  ('4aa00000-0000-4000-8000-000000000001','2aa00000-0000-4000-8000-000000000001','3aa00000-0000-4000-8000-000000000001','1aa00000-0000-4000-8000-000000000001'),
  ('4aa00000-0000-4000-8000-000000000002','2aa00000-0000-4000-8000-000000000001','3aa00000-0000-4000-8000-000000000001','1aa00000-0000-4000-8000-000000000002'),
  ('4aa00000-0000-4000-8000-000000000003','2aa00000-0000-4000-8000-000000000001','3aa00000-0000-4000-8000-000000000001','1aa00000-0000-4000-8000-000000000005');

select set_config('test.team_a',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='4aa00000-0000-4000-8000-000000000001'),false);
select set_config('test.team_b',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='4aa00000-0000-4000-8000-000000000002'),false);
select set_config('test.inactive_team',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='4aa00000-0000-4000-8000-000000000003'),false);

set local role service_role;
select lives_ok($$select * from public.create_operational_team_staff('1aa00000-0000-4000-8000-000000000001','3aa00000-0000-4000-8000-000000000001',current_setting('test.team_a')::uuid,'Visible Staff',array['kitchen'],'VISIBLE-01','Metadata Team Org','SA',null,null,null,null)$$,'assigned Team A staff can be created');
select lives_ok($$select * from public.create_operational_team_staff('1aa00000-0000-4000-8000-000000000002','3aa00000-0000-4000-8000-000000000001',current_setting('test.team_b')::uuid,'Hidden Staff',array['front_of_house'],'HIDDEN-02','Hidden Company','SA','9999999999','2027-01-01','+966500000000','hidden@example.invalid')$$,'unassigned destination Team B staff can be created by its owner');
reset role;

update public.branch_operational_teams set active=false where id=current_setting('test.inactive_team')::uuid;

select is((select count(distinct team_id) from public.get_supervisor_operational_team('1aa00000-0000-4000-8000-000000000001','3aa00000-0000-4000-8000-000000000001',current_date)),2::bigint,'assigned Team A and active unassigned Team B are both returned');
select is((select count(*) from public.get_supervisor_operational_team('1aa00000-0000-4000-8000-000000000001','3aa00000-0000-4000-8000-000000000001',current_date) where team_id=current_setting('test.team_b')::uuid),1::bigint,'metadata-only Team B returns one safe row');
select is((select assignment_role from public.get_supervisor_operational_team('1aa00000-0000-4000-8000-000000000001','3aa00000-0000-4000-8000-000000000001',current_date) where team_id=current_setting('test.team_b')::uuid),null::text,'metadata-only Team B has null assignment role');
select is((select team_active from public.get_supervisor_operational_team('1aa00000-0000-4000-8000-000000000001','3aa00000-0000-4000-8000-000000000001',current_date) where team_id=current_setting('test.team_b')::uuid),true,'metadata-only Team B preserves active metadata');
select is((select can_write from public.get_supervisor_operational_team('1aa00000-0000-4000-8000-000000000001','3aa00000-0000-4000-8000-000000000001',current_date) where team_id=current_setting('test.team_b')::uuid),false,'metadata-only Team B does not grant write access');
select ok((select bool_and(staff_id is null and display_name is null and staff_company_name is null and staff_code is null and iqama_number is null and phone_number is null and email is null and assignment_id is null and operational_roles is null and duty_status is null)
  from public.get_supervisor_operational_team('1aa00000-0000-4000-8000-000000000001','3aa00000-0000-4000-8000-000000000001',current_date)
  where team_id=current_setting('test.team_b')::uuid),'metadata-only Team B exposes no staff PII assignment or duty fields');
select ok(not exists(select 1 from public.get_supervisor_operational_team('1aa00000-0000-4000-8000-000000000001','3aa00000-0000-4000-8000-000000000001',current_date)
  where display_name='Hidden Staff' or staff_code='HIDDEN-02' or phone_number='+966500000000' or email='hidden@example.invalid' or iqama_number='9999999999'),'Team B staff details never leak to Team A supervisor');
select is((select display_name from public.get_supervisor_operational_team('1aa00000-0000-4000-8000-000000000001','3aa00000-0000-4000-8000-000000000001',current_date) where team_id=current_setting('test.team_a')::uuid and staff_id is not null),'Visible Staff','assigned Team A staff remains visible');
select ok(not exists(select 1 from public.get_supervisor_operational_team('1aa00000-0000-4000-8000-000000000001','3aa00000-0000-4000-8000-000000000001',current_date) where team_id=current_setting('test.inactive_team')::uuid),'inactive teams are excluded');
select throws_ok($$select * from public.get_supervisor_operational_team('1aa00000-0000-4000-8000-000000000004','3aa00000-0000-4000-8000-000000000001',current_date)$$,'42501','team access denied','unauthorized branch access is denied');
select is((select count(*) from public.get_supervisor_operational_team('1aa00000-0000-4000-8000-000000000003','3aa00000-0000-4000-8000-000000000001',current_date) where can_write or assignment_role is not null or staff_id is not null or assignment_id is not null),0::bigint,'branch supervisor with no valid team assignment gains no staff or write access through metadata rows');
select ok(not private.actor_can_write_operational_team('1aa00000-0000-4000-8000-000000000001','3aa00000-0000-4000-8000-000000000001',current_setting('test.team_b')::uuid),'same-branch destination remains selectable metadata without granting destination write access');

set local role service_role;
select lives_ok($$select * from public.request_operational_staff_team_move('1aa00000-0000-4000-8000-000000000001','3aa00000-0000-4000-8000-000000000001',(select staff_id from public.get_supervisor_operational_team('1aa00000-0000-4000-8000-000000000001','3aa00000-0000-4000-8000-000000000001',current_date) where display_name='Visible Staff'),(select assignment_id from public.get_supervisor_operational_team('1aa00000-0000-4000-8000-000000000001','3aa00000-0000-4000-8000-000000000001',current_date) where display_name='Visible Staff'),current_setting('test.team_b')::uuid)$$,'same-branch move to metadata-only destination works through source-team permission');
reset role;
select is((select operational_team_id from public.operational_staff_assignments where operational_staff_id=(select id from public.operational_staff where display_name='Visible Staff') and active),current_setting('test.team_b')::uuid,'successful move places employee in Team B');
select is((select count(*) from public.operational_staff_assignments where operational_staff_id=(select id from public.operational_staff where display_name='Visible Staff') and active),1::bigint,'successful move leaves exactly one active assignment');
select is((select count(*) from public.get_supervisor_operational_team('1aa00000-0000-4000-8000-000000000001','3aa00000-0000-4000-8000-000000000001',current_date) where staff_id=(select id from public.operational_staff where display_name='Hidden Staff')),0::bigint,'Team B hidden staff still does not leak after moving another employee');

select * from finish();
rollback;
