begin;
select plan(23);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
 '1e000000-0000-4000-8000-000000000001'::uuid,
 '1e000000-0000-4000-8000-000000000002',
 '1e000000-0000-4000-8000-000000000003'
]) id;
update public.profiles set full_name=case id
 when '1e000000-0000-4000-8000-000000000001' then 'Monthly Evaluation Supervisor'
 when '1e000000-0000-4000-8000-000000000002' then 'Other Evaluation Supervisor'
 else 'Monthly Evaluation Manager' end,
 must_change_password=false
where id in (
 '1e000000-0000-4000-8000-000000000001',
 '1e000000-0000-4000-8000-000000000002',
 '1e000000-0000-4000-8000-000000000003'
);
insert into public.organizations(id,name,slug)
values('2e000000-0000-4000-8000-000000000001','Monthly Evaluation Org','monthly-evaluation-org');
insert into public.branches(id,organization_id,name,code,timezone)
values('3e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','Monthly Evaluation Branch','MEB','Asia/Riyadh');
insert into public.organization_memberships(organization_id,user_id,role)
values('2e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000003','organization_manager');
insert into public.branch_memberships(branch_id,user_id,role)
values
 ('3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000001','branch_manager'),
 ('3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000002','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id,company_name)
values('5e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001','1e000000-0000-4000-8000-000000000001','Evaluation Company');
insert into public.operational_staff(id,organization_id,branch_id,display_name,company_name,staff_code,created_by)
values
 ('6e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001','Evaluation Worker','Evaluation Company','ME-1','1e000000-0000-4000-8000-000000000001'),
 ('6e000000-0000-4000-8000-000000000002','2e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001','Unassigned Evaluation Worker','Evaluation Company','ME-2','1e000000-0000-4000-8000-000000000001');
insert into public.operational_staff_assignments(id,organization_id,branch_id,operational_staff_id,supervisor_team_id,operational_roles)
values('7e000000-0000-4000-8000-000000000001','2e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001','6e000000-0000-4000-8000-000000000001','5e000000-0000-4000-8000-000000000001',array['front_of_house']);

select has_table('public','operational_staff_monthly_evaluations','monthly evaluations table exists');
select has_table('public','operational_staff_monthly_evaluation_scores','monthly evaluation scores table exists');
select has_column('public','operational_staff_monthly_evaluations','average_score','monthly evaluations store average score');
select has_column('public','operational_staff_monthly_evaluation_scores','rating','monthly evaluation scores store rating');
select ok(not has_function_privilege('authenticated','public.list_operational_staff_monthly_evaluations(uuid,uuid,date)','execute')
 and has_function_privilege('service_role','public.list_operational_staff_monthly_evaluations(uuid,uuid,date)','execute'),
 'monthly evaluation list RPC is service-role only');
select ok(not has_function_privilege('authenticated','public.save_operational_staff_monthly_evaluation(uuid,uuid,uuid,date,text,jsonb,text)','execute')
 and has_function_privilege('service_role','public.save_operational_staff_monthly_evaluation(uuid,uuid,uuid,date,text,jsonb,text)','execute'),
 'monthly evaluation save RPC is service-role only');

set local role service_role;
select lives_ok($$select * from public.save_operational_staff_monthly_evaluation(
 '1e000000-0000-4000-8000-000000000001',
 '3e000000-0000-4000-8000-000000000001',
 '6e000000-0000-4000-8000-000000000001',
 '2026-08-01',
 '  Evaluation Lead  ',
 jsonb_build_array(
  jsonb_build_object('section','Performance','factor_key','performance_initiative','factor_label','Strong initiative','rating',5,'comment',' Great '),
  jsonb_build_object('section','Performance','factor_key','performance_team','factor_label','Works well with others','rating',null,'comment',''),
  jsonb_build_object('section','Skills','factor_key','skills_service','factor_label','Customer service skills','rating',3,'comment',null)
 ),
 'draft')$$,'supervisor saves draft monthly evaluation');
reset role;

select is((select evaluator_name from public.operational_staff_monthly_evaluations where operational_staff_id='6e000000-0000-4000-8000-000000000001'),'Evaluation Lead','evaluator name is trimmed and stored');
select is((select status from public.operational_staff_monthly_evaluations where operational_staff_id='6e000000-0000-4000-8000-000000000001'),'draft','draft status is stored');
select is((select average_score from public.operational_staff_monthly_evaluations where operational_staff_id='6e000000-0000-4000-8000-000000000001'),4.00::numeric,'average score ignores unrated factors');
select is((select count(*)::integer from public.operational_staff_monthly_evaluation_scores score join public.operational_staff_monthly_evaluations evaluation on evaluation.id=score.evaluation_id where evaluation.operational_staff_id='6e000000-0000-4000-8000-000000000001'),3,'scores are persisted');
select is((select scores->0->>'factor_key' from public.list_operational_staff_monthly_evaluations(
 '1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001','2026-08-01')
 where operational_staff_id='6e000000-0000-4000-8000-000000000001'),'performance_initiative','list restores score payload');

select throws_ok($$select * from public.save_operational_staff_monthly_evaluation(
 '1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001','6e000000-0000-4000-8000-000000000001','2026-08-01','Lead',
 jsonb_build_array(jsonb_build_object('section','Performance','factor_key','performance_team','factor_label','Works well with others','rating',null)),
 'completed')$$,'23514','completed monthly evaluation requires all ratings','completed requires all ratings');

set local role service_role;
select lives_ok($$select * from public.save_operational_staff_monthly_evaluation(
 '1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001','6e000000-0000-4000-8000-000000000001','2026-08-01','Lead',
 jsonb_build_array(
  jsonb_build_object('section','Performance','factor_key','performance_initiative','factor_label','Strong initiative','rating',5),
  jsonb_build_object('section','Performance','factor_key','performance_team','factor_label','Works well with others','rating',4)
 ),
 'completed')$$,'completed evaluation saves when every rating exists');
reset role;
select is((select status from public.operational_staff_monthly_evaluations where operational_staff_id='6e000000-0000-4000-8000-000000000001'),'completed','completed status is stored');
select is((select average_score from public.operational_staff_monthly_evaluations where operational_staff_id='6e000000-0000-4000-8000-000000000001'),4.50::numeric,'average recomputes on replacement');
select is((select count(*)::integer from public.operational_staff_monthly_evaluation_scores score join public.operational_staff_monthly_evaluations evaluation on evaluation.id=score.evaluation_id where evaluation.operational_staff_id='6e000000-0000-4000-8000-000000000001'),2,'second save replaces scores');

select throws_ok($$select * from public.save_operational_staff_monthly_evaluation(
 '1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001','6e000000-0000-4000-8000-000000000001','2026-08-02','Lead',
 jsonb_build_array(jsonb_build_object('section','Performance','factor_key','x','factor_label','X','rating',5)),'draft')$$,'22023','invalid monthly evaluation','month must be first day');
select throws_ok($$select * from public.save_operational_staff_monthly_evaluation(
 '1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001','6e000000-0000-4000-8000-000000000001','2026-08-01','Lead',
 jsonb_build_array(jsonb_build_object('section','Performance','factor_key','x','factor_label','X','rating',6)),'draft')$$,'22023','invalid monthly evaluation rating','invalid rating rejected');
select throws_ok($$select * from public.save_operational_staff_monthly_evaluation(
 '1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001','6e000000-0000-4000-8000-000000000001','2026-08-01','Lead',
 jsonb_build_array(jsonb_build_object('section','Performance','factor_key','x','factor_label','X','rating',5)),'archived')$$,'22023','invalid monthly evaluation','invalid status rejected');
select throws_ok($$select * from public.save_operational_staff_monthly_evaluation(
 '1e000000-0000-4000-8000-000000000002','3e000000-0000-4000-8000-000000000001','6e000000-0000-4000-8000-000000000001','2026-08-01','Lead',
 jsonb_build_array(jsonb_build_object('section','Performance','factor_key','x','factor_label','X','rating',5)),'draft')$$,'42501','monthly evaluation access denied','other supervisor denied');
select throws_ok($$select * from public.save_operational_staff_monthly_evaluation(
 '1e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001','6e000000-0000-4000-8000-000000000002','2026-08-01','Lead',
 jsonb_build_array(jsonb_build_object('section','Performance','factor_key','x','factor_label','X','rating',5)),'draft')$$,'42501','monthly evaluation access denied','unassigned staff denied');

set local role authenticated;
select throws_ok($$insert into public.operational_staff_monthly_evaluations(
 organization_id,branch_id,supervisor_team_id,operational_staff_id,evaluation_month,status
) values (
 '2e000000-0000-4000-8000-000000000001','3e000000-0000-4000-8000-000000000001',
 '5e000000-0000-4000-8000-000000000001','6e000000-0000-4000-8000-000000000001','2026-08-01','draft'
)$$,'42501',null,'direct authenticated writes are denied');
reset role;

select * from finish();
rollback;
