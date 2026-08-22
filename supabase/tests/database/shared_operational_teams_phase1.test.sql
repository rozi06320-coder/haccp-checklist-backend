begin;
select plan(42);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
  '12000000-0000-4000-8000-000000000001'::uuid,
  '12000000-0000-4000-8000-000000000002',
  '12000000-0000-4000-8000-000000000003',
  '12000000-0000-4000-8000-000000000004'
]) id;
update public.profiles set full_name=case id
  when '12000000-0000-4000-8000-000000000001' then 'Supervisor A'
  when '12000000-0000-4000-8000-000000000002' then 'Supervisor B'
  when '12000000-0000-4000-8000-000000000003' then 'Manager A'
  else 'Supervisor Other' end,must_change_password=false;

insert into public.organizations(id,name,slug) values
  ('22000000-0000-4000-8000-000000000001','Teams Org A','teams-org-a'),
  ('22000000-0000-4000-8000-000000000002','Teams Org B','teams-org-b');
insert into public.branches(id,organization_id,name,code,timezone) values
  ('32000000-0000-4000-8000-000000000001','22000000-0000-4000-8000-000000000001','Branch A','TA','Asia/Riyadh'),
  ('32000000-0000-4000-8000-000000000002','22000000-0000-4000-8000-000000000002','Branch B','TB','Asia/Riyadh');
insert into public.organization_memberships(organization_id,user_id,role) values
  ('22000000-0000-4000-8000-000000000001','12000000-0000-4000-8000-000000000003','organization_manager');
insert into public.branch_memberships(branch_id,user_id,role) values
  ('32000000-0000-4000-8000-000000000001','12000000-0000-4000-8000-000000000001','branch_manager'),
  ('32000000-0000-4000-8000-000000000001','12000000-0000-4000-8000-000000000002','branch_manager'),
  ('32000000-0000-4000-8000-000000000002','12000000-0000-4000-8000-000000000004','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
  ('42000000-0000-4000-8000-000000000001','22000000-0000-4000-8000-000000000001','32000000-0000-4000-8000-000000000001','12000000-0000-4000-8000-000000000001'),
  ('42000000-0000-4000-8000-000000000002','22000000-0000-4000-8000-000000000001','32000000-0000-4000-8000-000000000001','12000000-0000-4000-8000-000000000002'),
  ('42000000-0000-4000-8000-000000000003','22000000-0000-4000-8000-000000000002','32000000-0000-4000-8000-000000000002','12000000-0000-4000-8000-000000000004');
select set_config('test.team_a',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='42000000-0000-4000-8000-000000000001'),false);
select set_config('test.team_b',(select id::text from public.branch_operational_teams where legacy_supervisor_team_id='42000000-0000-4000-8000-000000000002'),false);

select is((select count(*) from public.branch_operational_teams where branch_id='32000000-0000-4000-8000-000000000001'),2::bigint,'one durable team per unambiguous legacy group');
select results_eq($$select name from public.branch_operational_teams where branch_id='32000000-0000-4000-8000-000000000001' order by normalized_name$$,$$values('Team A'::text),('Team B'::text)$$,'deterministic default names do not use company name');
select is((select count(distinct team_id) from public.get_supervisor_operational_team('12000000-0000-4000-8000-000000000001','32000000-0000-4000-8000-000000000001',current_date)),2::bigint,'Supervisor A views both branch teams');
select is((select count(distinct team_id) from public.get_supervisor_operational_team('12000000-0000-4000-8000-000000000002','32000000-0000-4000-8000-000000000001',current_date)),2::bigint,'Supervisor B views both branch teams');
select ok(private.actor_can_write_operational_team('12000000-0000-4000-8000-000000000001','32000000-0000-4000-8000-000000000001',(select id from public.branch_operational_teams where legacy_supervisor_team_id='42000000-0000-4000-8000-000000000001')),'Supervisor A writes Team A');
select ok(not private.actor_can_write_operational_team('12000000-0000-4000-8000-000000000001','32000000-0000-4000-8000-000000000001',(select id from public.branch_operational_teams where legacy_supervisor_team_id='42000000-0000-4000-8000-000000000002')),'Supervisor A cannot write Team B without assignment');
select ok(private.actor_can_write_operational_team('12000000-0000-4000-8000-000000000002','32000000-0000-4000-8000-000000000001',(select id from public.branch_operational_teams where legacy_supervisor_team_id='42000000-0000-4000-8000-000000000002')),'Supervisor B writes Team B');
select ok(not private.actor_can_write_operational_team('12000000-0000-4000-8000-000000000002','32000000-0000-4000-8000-000000000001',(select id from public.branch_operational_teams where legacy_supervisor_team_id='42000000-0000-4000-8000-000000000001')),'Supervisor B cannot initially write Team A');

select lives_ok($$select * from public.assign_operational_team_supervisor('12000000-0000-4000-8000-000000000003','22000000-0000-4000-8000-000000000001',(select id from public.branch_operational_teams where legacy_supervisor_team_id='42000000-0000-4000-8000-000000000001'),'12000000-0000-4000-8000-000000000002','backup')$$,'Manager assigns Supervisor B as Team A backup');
select ok(private.actor_can_write_operational_team('12000000-0000-4000-8000-000000000002','32000000-0000-4000-8000-000000000001',(select id from public.branch_operational_teams where legacy_supervisor_team_id='42000000-0000-4000-8000-000000000001')),'backup assignment authorizes Team A writes');
select throws_ok($$select * from public.assign_operational_team_supervisor('12000000-0000-4000-8000-000000000003','22000000-0000-4000-8000-000000000001',(select id from public.branch_operational_teams where legacy_supervisor_team_id='42000000-0000-4000-8000-000000000001'),'12000000-0000-4000-8000-000000000002','primary')$$,'23505',null,'at most one active primary supervisor per team');
select lives_ok($$select * from public.assign_operational_team_supervisor('12000000-0000-4000-8000-000000000003','22000000-0000-4000-8000-000000000001',(select id from public.branch_operational_teams where legacy_supervisor_team_id='42000000-0000-4000-8000-000000000002'),'12000000-0000-4000-8000-000000000001','backup')$$,'one supervisor may cover multiple teams');

set local role service_role;
select lives_ok($$select * from public.create_operational_team_staff('12000000-0000-4000-8000-000000000001','32000000-0000-4000-8000-000000000001',current_setting('test.team_a')::uuid,'Move Me',array['kitchen'],null,'Teams Org A',null,null,null,null,null)$$,'Supervisor A creates Team A employee');
reset role;
select set_config('test.move_staff',(select id::text from public.operational_staff where branch_id='32000000-0000-4000-8000-000000000001' and display_name='Move Me'),false);
select set_config('test.move_assignment',(select id::text from public.operational_staff_assignments where operational_staff_id=current_setting('test.move_staff')::uuid and active),false);
select throws_ok($$insert into public.operational_staff_assignments(organization_id,branch_id,operational_staff_id,supervisor_team_id,operational_team_id,operational_roles) values('22000000-0000-4000-8000-000000000001','32000000-0000-4000-8000-000000000001',current_setting('test.move_staff')::uuid,'42000000-0000-4000-8000-000000000002',(select id from public.branch_operational_teams where legacy_supervisor_team_id='42000000-0000-4000-8000-000000000002'),array['kitchen'])$$,'23505',null,'same employee cannot have two active teams');
set local role service_role;
select lives_ok($$select * from public.move_operational_staff_team('12000000-0000-4000-8000-000000000001','32000000-0000-4000-8000-000000000001',current_setting('test.move_staff')::uuid,current_setting('test.move_assignment')::uuid,current_setting('test.team_b')::uuid)$$,'authorized move is atomic');
reset role;
select is((select count(*) from public.operational_staff_assignments where operational_staff_id=current_setting('test.move_staff')::uuid and active),1::bigint,'move leaves exactly one active assignment');
select is((select legacy_supervisor_team_id from public.branch_operational_teams where id=(select operational_team_id from public.operational_staff_assignments where operational_staff_id=current_setting('test.move_staff')::uuid and active)),'42000000-0000-4000-8000-000000000002'::uuid,'move activates the target team assignment');
select is((select count(*) from public.operational_staff_assignments where operational_staff_id=current_setting('test.move_staff')::uuid),2::bigint,'move preserves assignment history');

set local role service_role;
select lives_ok($$select * from public.create_operational_team_staff('12000000-0000-4000-8000-000000000001','32000000-0000-4000-8000-000000000001',current_setting('test.team_a')::uuid,'Hygiene A',array['cleaner'],null,'Teams Org A',null,null,null,null,null)$$,'Team A employee created for Hygiene');
reset role;
select set_config('test.hygiene_staff',(select id::text from public.operational_staff where branch_id='32000000-0000-4000-8000-000000000001' and display_name='Hygiene A'),false);
select set_config('test.hygiene_assignment',(select id::text from public.operational_staff_assignments where operational_staff_id=current_setting('test.hygiene_staff')::uuid and active),false);
set local role service_role;
select lives_ok($$select * from public.save_operational_team_hygiene_draft('12000000-0000-4000-8000-000000000001','32000000-0000-4000-8000-000000000001',current_setting('test.team_a')::uuid,0,jsonb_build_array(jsonb_build_object('staff_id',current_setting('test.hygiene_staff'),'uniform','pass','fingernails','pending','hair','pass','facial_hair','pass','remark','')))$$,'Supervisor A saves Team A Hygiene draft');
reset role;
select is((public.get_operational_team_hygiene_current_state('12000000-0000-4000-8000-000000000002','32000000-0000-4000-8000-000000000001',(select id from public.branch_operational_teams where legacy_supervisor_team_id='42000000-0000-4000-8000-000000000001'))->>'state'),'draft','Supervisor B sees the same Team A draft');
set local role service_role;
select throws_ok($$select * from public.save_operational_team_hygiene_draft('12000000-0000-4000-8000-000000000002','32000000-0000-4000-8000-000000000001',current_setting('test.team_a')::uuid,0,jsonb_build_array(jsonb_build_object('staff_id',current_setting('test.hygiene_staff'),'uniform','issue','fingernails','pass','hair','pass','facial_hair','pass','remark','changed')))$$,'40001','hygiene draft changed','stale concurrent draft revision is rejected');
select lives_ok($$select * from public.submit_operational_team_hygiene('12000000-0000-4000-8000-000000000001','32000000-0000-4000-8000-000000000001',current_setting('test.team_a')::uuid,'72000000-0000-4000-8000-000000000001',repeat('a',64),jsonb_build_array(jsonb_build_object('staff_id',current_setting('test.hygiene_staff'),'uniform','pass','fingernails','pass','hair','pass','facial_hair','pass','remark','')))$$,'Supervisor A submits Team A Hygiene');
reset role;
select is((public.get_operational_team_hygiene_current_state('12000000-0000-4000-8000-000000000002','32000000-0000-4000-8000-000000000001',(select id from public.branch_operational_teams where legacy_supervisor_team_id='42000000-0000-4000-8000-000000000001'))->>'state'),'submitted','Supervisor B sees the shared submitted Team A Hygiene');
select is((public.list_phase4a_supervisor_reports('12000000-0000-4000-8000-000000000002','32000000-0000-4000-8000-000000000001',1,20,'staff_hygiene')->>'total')::int,1,'Supervisor B sees Team A Hygiene in shared report history');
select is((public.get_phase4a_report_detail('12000000-0000-4000-8000-000000000002',(select id from public.checklist_submissions where operational_team_id=current_setting('test.team_a')::uuid and checklist_type='staff_hygiene' and state='submitted'),false)->>'operational_team_name'),'Team A','Supervisor B can read Team A submitted Hygiene detail');
set local role service_role;
select throws_ok($$select * from public.submit_operational_team_hygiene('12000000-0000-4000-8000-000000000002','32000000-0000-4000-8000-000000000001',current_setting('test.team_a')::uuid,'72000000-0000-4000-8000-000000000002',repeat('b',64),jsonb_build_array(jsonb_build_object('staff_id',current_setting('test.hygiene_staff'),'uniform','pass','fingernails','pass','hair','pass','facial_hair','pass','remark','')))$$,'23505','hygiene already submitted','duplicate Team A/date submission is rejected');
reset role;
select is((public.get_operational_team_hygiene_current_state('12000000-0000-4000-8000-000000000002','32000000-0000-4000-8000-000000000001',(select id from public.branch_operational_teams where legacy_supervisor_team_id='42000000-0000-4000-8000-000000000002'))->>'state'),'none','Team B Hygiene remains a separate ledger');
select is((select submitted_by_user_id from public.checklist_submissions where operational_team_id=(select id from public.branch_operational_teams where legacy_supervisor_team_id='42000000-0000-4000-8000-000000000001') and checklist_type='staff_hygiene' and state='submitted'),'12000000-0000-4000-8000-000000000001'::uuid,'submission actor is audit attribution, not ownership');
select is((select operational_team_name_snapshot from public.checklist_submissions where operational_team_id=(select id from public.branch_operational_teams where legacy_supervisor_team_id='42000000-0000-4000-8000-000000000001') and checklist_type='staff_hygiene' and state='submitted'),'Team A','team name snapshot preserves history');
set local role service_role;
select lives_ok($$select * from public.move_operational_staff_team('12000000-0000-4000-8000-000000000002','32000000-0000-4000-8000-000000000001',current_setting('test.hygiene_staff')::uuid,current_setting('test.hygiene_assignment')::uuid,current_setting('test.team_b')::uuid)$$,'same-business-date move is allowed after submitted Hygiene');
reset role;

select throws_ok($$select * from public.get_operational_team_hygiene_current_state('12000000-0000-4000-8000-000000000004','32000000-0000-4000-8000-000000000001',(select id from public.branch_operational_teams where legacy_supervisor_team_id='42000000-0000-4000-8000-000000000001'))$$,'42501','hygiene access denied','other branch cannot read Branch A Hygiene');
select throws_ok($$select * from public.get_supervisor_operational_team('12000000-0000-4000-8000-000000000004','32000000-0000-4000-8000-000000000001',current_date)$$,'42501','team access denied','other organization cannot read Branch A teams');
select ok(not has_table_privilege('authenticated','public.checklist_submissions','insert') and not has_table_privilege('authenticated','public.hygiene_staff_snapshots','update'),'authenticated has no direct Hygiene mutation privileges');
select ok(not has_table_privilege('authenticated','public.checklist_submissions','truncate') and not has_table_privilege('anon','public.hygiene_staff_snapshots','truncate'),'anon and authenticated have no Hygiene TRUNCATE privilege');

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','12000000-0000-4000-8000-000000000002',true);
select is((select count(*) from public.branch_operational_teams),2::bigint,'same-branch Supervisor reads both teams through RLS');
select set_config('request.jwt.claim.sub','12000000-0000-4000-8000-000000000004',true);
select is((select count(*) from public.branch_operational_teams),1::bigint,'other branch sees only its own team through RLS');
reset role;

update public.branch_supervisor_teams set active=false where id='42000000-0000-4000-8000-000000000001';
select is((select active from public.branch_operational_teams where legacy_supervisor_team_id='42000000-0000-4000-8000-000000000001'),true,'supervisor deactivation does not deactivate durable team');
select is((select count(*) from public.operational_staff_assignments where operational_team_id=current_setting('test.team_b')::uuid and active),2::bigint,'supervisor deactivation preserves moved employee roster on active target team');
select is((select proconfig from pg_proc where oid='public.submit_operational_team_hygiene(uuid,uuid,uuid,uuid,text,jsonb)'::regprocedure),array['search_path=""'],'Hygiene SECURITY DEFINER RPC fixes empty search_path');
select ok(not has_function_privilege('authenticated','public.submit_operational_team_hygiene(uuid,uuid,uuid,uuid,text,jsonb)','execute') and has_function_privilege('service_role','public.submit_operational_team_hygiene(uuid,uuid,uuid,uuid,text,jsonb)','execute'),'Hygiene persistence RPC is service-role only');
select ok(exists(select 1 from pg_indexes where schemaname='public' and indexname='checklist_submissions_hygiene_one_final'),'database has team/date duplicate protection');

select * from finish();
rollback;
