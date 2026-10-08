begin;
select plan(52);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values
('00000000-0000-0000-0000-000000000000','ba000000-0000-4000-8000-000000000001','authenticated','authenticated','manager@monthly-supervisor.invalid','{}','{}',now(),now()),
('00000000-0000-0000-0000-000000000000','ba000000-0000-4000-8000-000000000002','authenticated','authenticated','supervisor@monthly-supervisor.invalid','{}','{}',now(),now()),
('00000000-0000-0000-0000-000000000000','ba000000-0000-4000-8000-000000000003','authenticated','authenticated','ambiguous@monthly-supervisor.invalid','{}','{}',now(),now()),
('00000000-0000-0000-0000-000000000000','ba000000-0000-4000-8000-000000000004','authenticated','authenticated','zero-team@monthly-supervisor.invalid','{}','{}',now(),now()),
('00000000-0000-0000-0000-000000000000','ba000000-0000-4000-8000-000000000005','authenticated','authenticated','other-manager@monthly-supervisor.invalid','{}','{}',now(),now()),
('00000000-0000-0000-0000-000000000000','ba000000-0000-4000-8000-000000000006','authenticated','authenticated','other-supervisor@monthly-supervisor.invalid','{}','{}',now(),now());
update public.profiles set full_name=case id
when'ba000000-0000-4000-8000-000000000001'then'Monthly Manager'
when'ba000000-0000-4000-8000-000000000002'then'Monthly Supervisor'
when'ba000000-0000-4000-8000-000000000003'then'Ambiguous Supervisor'
when'ba000000-0000-4000-8000-000000000004'then'Zero Team Supervisor'
when'ba000000-0000-4000-8000-000000000005'then'Other Manager'
else'Other Supervisor'end,must_change_password=false
where id between'ba000000-0000-4000-8000-000000000001'and'ba000000-0000-4000-8000-000000000006';
insert into public.organizations(id,name,slug)values
('bb000000-0000-4000-8000-000000000001','Monthly Evaluation Org','monthly-evaluation-org'),
('bb000000-0000-4000-8000-000000000002','Other Monthly Org','other-monthly-org');
insert into public.branches(id,organization_id,name,code)values
('bc000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001','Monthly Branch A','MON-A'),
('bc000000-0000-4000-8000-000000000002','bb000000-0000-4000-8000-000000000001','Monthly Branch B','MON-B'),
('bc000000-0000-4000-8000-000000000003','bb000000-0000-4000-8000-000000000002','Other Monthly Branch','MON-X');
insert into public.organization_memberships(organization_id,user_id,role,active)values
('bb000000-0000-4000-8000-000000000001','ba000000-0000-4000-8000-000000000001','organization_manager',true),
('bb000000-0000-4000-8000-000000000002','ba000000-0000-4000-8000-000000000005','organization_manager',true);
insert into public.branch_memberships(branch_id,user_id,role,active)values
('bc000000-0000-4000-8000-000000000001','ba000000-0000-4000-8000-000000000002','branch_manager',true),
('bc000000-0000-4000-8000-000000000001','ba000000-0000-4000-8000-000000000003','branch_manager',true),
('bc000000-0000-4000-8000-000000000002','ba000000-0000-4000-8000-000000000003','branch_manager',true),
('bc000000-0000-4000-8000-000000000001','ba000000-0000-4000-8000-000000000004','branch_manager',true),
('bc000000-0000-4000-8000-000000000003','ba000000-0000-4000-8000-000000000006','branch_manager',true);
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id)values
('bd000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001','bc000000-0000-4000-8000-000000000001','ba000000-0000-4000-8000-000000000002'),
('bd000000-0000-4000-8000-000000000002','bb000000-0000-4000-8000-000000000001','bc000000-0000-4000-8000-000000000001','ba000000-0000-4000-8000-000000000003'),
('bd000000-0000-4000-8000-000000000003','bb000000-0000-4000-8000-000000000001','bc000000-0000-4000-8000-000000000002','ba000000-0000-4000-8000-000000000003'),
('bd000000-0000-4000-8000-000000000004','bb000000-0000-4000-8000-000000000002','bc000000-0000-4000-8000-000000000003','ba000000-0000-4000-8000-000000000006');
insert into public.branch_operational_team_supervisors(
  organization_id,branch_id,operational_team_id,supervisor_user_id,assignment_role,active,valid_from,valid_to,created_by
)
select assignment.organization_id,assignment.branch_id,assignment.operational_team_id,assignment.supervisor_user_id,
  'backup',false,assignment.valid_from,assignment.valid_from,'ba000000-0000-4000-8000-000000000001'
from public.branch_operational_team_supervisors assignment
where assignment.supervisor_user_id='ba000000-0000-4000-8000-000000000002'
limit 1;

select has_table('public','manager_monthly_supervisor_evaluation_templates','template table exists');
select has_table('public','manager_monthly_supervisor_evaluation_criteria','criteria table exists');
select has_table('public','manager_monthly_supervisor_evaluations','evaluation table exists');
select has_table('public','manager_monthly_supervisor_evaluation_scores','score table exists');
select is((select count(*) from public.manager_monthly_supervisor_evaluation_criteria where template_version=1 and active),10::bigint,'ten active criteria are catalogued');
select is((select max_score from public.manager_monthly_supervisor_evaluation_criteria where criterion_key='leadership'),5::numeric,'criterion maximum is five');
select is((select title_ar from public.manager_monthly_supervisor_evaluation_criteria where criterion_key='leadership'),'القيادة','Arabic criterion title is persisted');
select is(public.get_managed_monthly_supervisor_evaluation_workspace('ba000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001','2026-10-01')->>'evaluation_month','2026-10-01','selected month is respected');
select is((select count(distinct assignment.branch_id) from public.branch_operational_team_supervisors assignment where assignment.supervisor_user_id='ba000000-0000-4000-8000-000000000002' and assignment.valid_from<'2026-11-01'and coalesce(assignment.valid_to,'2026-11-01')>='2026-10-01'),1::bigint,'duplicate assignment rows still represent one overlapping branch');
select is((select count(*) from public.branch_operational_team_supervisors assignment where assignment.supervisor_user_id='ba000000-0000-4000-8000-000000000002' and assignment.valid_from<'2026-11-01'and coalesce(assignment.valid_to,'2026-11-01')>='2026-10-01'),2::bigint,'duplicate rows for the sole branch exercise UUID extraction without creating ambiguity');
select ok((public.get_managed_monthly_supervisor_evaluation_workspace('ba000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001','2026-10-01')->'subjects')@>'[{"supervisor_user_id":"ba000000-0000-4000-8000-000000000002","eligible":true,"branch":{"id":"bc000000-0000-4000-8000-000000000001"}}]'::jsonb,'current active Supervisor is eligible with historical branch attribution');
select ok((public.get_managed_monthly_supervisor_evaluation_workspace('ba000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001','2026-10-01')->'subjects')@>'[{"supervisor_user_id":"ba000000-0000-4000-8000-000000000003","eligible":false,"ineligibility_reason":"ambiguous_branch_history"}]'::jsonb,'ambiguous transfer attribution is exposed and blocked');
select ok((public.get_managed_monthly_supervisor_evaluation_workspace('ba000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001','2026-11-01')->'subjects')@>'[{"supervisor_user_id":"ba000000-0000-4000-8000-000000000004","eligible":false,"ineligibility_reason":"historical_branch_unavailable"}]'::jsonb,'unproven historical branch attribution is blocked');
select is((public.get_managed_monthly_supervisor_evaluation_workspace('ba000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001','2026-10-01')->'summary'->>'evaluated_count')::integer,0,'workspace begins with no submitted evaluations');
select throws_ok($$select public.get_managed_monthly_supervisor_evaluation_workspace('ba000000-0000-4000-8000-000000000005','bb000000-0000-4000-8000-000000000001','2026-10-01')$$,'42501','monthly supervisor evaluation access denied','cross-organization Manager is denied');
select throws_ok($$select public.get_managed_monthly_supervisor_evaluation_workspace('ba000000-0000-4000-8000-000000000002','bb000000-0000-4000-8000-000000000001','2026-10-01')$$,'42501','monthly supervisor evaluation access denied','Supervisor cannot invoke Manager workspace');
select lives_ok($$select public.save_managed_monthly_supervisor_evaluation_draft('ba000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001','ba000000-0000-4000-8000-000000000002','2026-10-01',0,'[{"criterion_key":"leadership","rating":5},{"criterion_key":"communication","rating":null}]')$$,'incomplete draft is accepted');
select is((select revision from public.manager_monthly_supervisor_evaluations where supervisor_user_id='ba000000-0000-4000-8000-000000000002'),1::bigint,'new draft revision is one');
select is((select count(*) from public.manager_monthly_supervisor_evaluation_scores where evaluation_id=(select id from public.manager_monthly_supervisor_evaluations where supervisor_user_id='ba000000-0000-4000-8000-000000000002')),2::bigint,'draft stores supplied canonical score set');
select is((select branch_name_snapshot from public.manager_monthly_supervisor_evaluations where supervisor_user_id='ba000000-0000-4000-8000-000000000002'),'Monthly Branch A','branch snapshot is server-derived');
select is((select evaluator_name_snapshot from public.manager_monthly_supervisor_evaluations where supervisor_user_id='ba000000-0000-4000-8000-000000000002'),'Monthly Manager','evaluator snapshot is server-derived');
select throws_ok($$select public.save_managed_monthly_supervisor_evaluation_draft('ba000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001','ba000000-0000-4000-8000-000000000002','2026-10-01',0,'[]')$$,'40001','monthly supervisor evaluation changed','stale draft revision is rejected');
select throws_ok($$select public.save_managed_monthly_supervisor_evaluation_draft('ba000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001','ba000000-0000-4000-8000-000000000002','2026-10-01',1,'[{"criterion_key":"unknown","rating":5}]')$$,'22023','unknown monthly supervisor evaluation criterion','unknown criterion is rejected');
select throws_ok($$select public.save_managed_monthly_supervisor_evaluation_draft('ba000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001','ba000000-0000-4000-8000-000000000002','2026-10-01',1,'[{"criterion_key":"leadership","rating":5},{"criterion_key":"leadership","rating":4}]')$$,'22023','duplicate monthly supervisor evaluation criterion','duplicate criterion is rejected');
select throws_ok($$select public.save_managed_monthly_supervisor_evaluation_draft('ba000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001','ba000000-0000-4000-8000-000000000002','2026-10-01',1,'[{"criterion_key":"leadership","rating":6}]')$$,'22023','invalid monthly supervisor evaluation rating','out-of-range rating is rejected');
select throws_ok($$select public.save_managed_monthly_supervisor_evaluation_draft('ba000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001','ba000000-0000-4000-8000-000000000002','2026-10-01',1,'[{"criterion_key":"leadership","rating":"5"}]')$$,'22023','invalid monthly supervisor evaluation rating','string rating is rejected');
select throws_ok($$select public.save_managed_monthly_supervisor_evaluation_draft('ba000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001','ba000000-0000-4000-8000-000000000002','2026-10-01',1,'[{"criterion_key":"leadership","extra":5}]')$$,'22023','invalid monthly supervisor evaluation scores','malformed score objects are rejected');
select throws_ok($$select public.submit_managed_monthly_supervisor_evaluation('ba000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001',(select id from public.manager_monthly_supervisor_evaluations where supervisor_user_id='ba000000-0000-4000-8000-000000000002'),1)$$,'22023','monthly supervisor evaluation incomplete','submit requires all ten criteria');
select lives_ok($$select public.save_managed_monthly_supervisor_evaluation_draft('ba000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001','ba000000-0000-4000-8000-000000000002','2026-10-01',1,(select jsonb_agg(jsonb_build_object('criterion_key',criterion_key,'rating',case when display_order<=3 then 5 else 4 end)order by display_order)from public.manager_monthly_supervisor_evaluation_criteria where template_version=1 and active))$$,'complete draft saves');
select is((select revision from public.manager_monthly_supervisor_evaluations where supervisor_user_id='ba000000-0000-4000-8000-000000000002'),2::bigint,'draft revision increments');
select is(public.submit_managed_monthly_supervisor_evaluation('ba000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001',(select id from public.manager_monthly_supervisor_evaluations where supervisor_user_id='ba000000-0000-4000-8000-000000000002'),2)->>'status','submitted','submit returns canonical submitted result immediately');
select is((select total_score from public.manager_monthly_supervisor_evaluations where supervisor_user_id='ba000000-0000-4000-8000-000000000002'),43::numeric,'server calculates total score');
select is((select max_score from public.manager_monthly_supervisor_evaluations where supervisor_user_id='ba000000-0000-4000-8000-000000000002'),50::numeric,'server calculates maximum score of fifty');
select is((select percentage from public.manager_monthly_supervisor_evaluations where supervisor_user_id='ba000000-0000-4000-8000-000000000002'),86.00::numeric,'server calculates rounded percentage');
select is(jsonb_array_length(public.get_managed_monthly_supervisor_evaluation_detail('ba000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001',(select id from public.manager_monthly_supervisor_evaluations where supervisor_user_id='ba000000-0000-4000-8000-000000000002'))->'scores'),10,'canonical result has criterion breakdown');
select is((select revision from public.manager_monthly_supervisor_evaluations where supervisor_user_id='ba000000-0000-4000-8000-000000000002'),3::bigint,'submit increments revision');
select is(public.submit_managed_monthly_supervisor_evaluation('ba000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001',(select id from public.manager_monthly_supervisor_evaluations where supervisor_user_id='ba000000-0000-4000-8000-000000000002'),0)->>'percentage','86.00','double-submit is idempotent even with stale revision');
select throws_ok($$insert into public.manager_monthly_supervisor_evaluations(organization_id,supervisor_user_id,subject_type,evaluation_month,branch_id,branch_name_snapshot,supervisor_name_snapshot,supervisor_role_snapshot,evaluator_user_id,evaluator_name_snapshot,template_version)values('bb000000-0000-4000-8000-000000000001','ba000000-0000-4000-8000-000000000002','supervisor','2026-10-01','bc000000-0000-4000-8000-000000000001','Monthly Branch A','Monthly Supervisor','Supervisor','ba000000-0000-4000-8000-000000000001','Monthly Manager',1)$$,'23505',null,'unique Supervisor month identity is enforced');
select throws_ok($$update public.manager_monthly_supervisor_evaluations set status='draft'where supervisor_user_id='ba000000-0000-4000-8000-000000000002'$$,'55000','submitted monthly supervisor evaluation is immutable','submitted evaluation cannot be changed');
select throws_ok($$delete from public.manager_monthly_supervisor_evaluations where supervisor_user_id='ba000000-0000-4000-8000-000000000002'$$,'55000','submitted monthly supervisor evaluation is immutable','submitted evaluation cannot be deleted');
select throws_ok($$update public.manager_monthly_supervisor_evaluation_scores set rating=1 where evaluation_id=(select id from public.manager_monthly_supervisor_evaluations where supervisor_user_id='ba000000-0000-4000-8000-000000000002')$$,'55000','submitted monthly supervisor evaluation is immutable','submitted scores cannot be changed');
select throws_ok($$delete from public.manager_monthly_supervisor_evaluation_scores where evaluation_id=(select id from public.manager_monthly_supervisor_evaluations where supervisor_user_id='ba000000-0000-4000-8000-000000000002')$$,'55000','submitted monthly supervisor evaluation is immutable','submitted scores cannot be deleted');
select throws_ok($$insert into public.manager_monthly_supervisor_evaluation_scores(evaluation_id,criterion_key,criterion_title_en_snapshot,criterion_title_ar_snapshot,max_score_snapshot,weight_snapshot,rating)values((select id from public.manager_monthly_supervisor_evaluations where supervisor_user_id='ba000000-0000-4000-8000-000000000002'),'extra','Extra','إضافي',5,1,5)$$,'55000','submitted monthly supervisor evaluation is immutable','submitted scores cannot be inserted');
select throws_ok($$select public.save_managed_monthly_supervisor_evaluation_draft('ba000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001','ba000000-0000-4000-8000-000000000003','2026-10-01',0,'[]')$$,'23514','monthly supervisor evaluation scope changed','ambiguous historical branch is safely blocked');
select throws_ok($$select public.save_managed_monthly_supervisor_evaluation_draft('ba000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001','ba000000-0000-4000-8000-000000000004','2026-11-01',0,'[]')$$,'23514','monthly supervisor evaluation scope changed','unproven historical branch is safely blocked');
select ok(not has_table_privilege('anon','public.manager_monthly_supervisor_evaluations','select,insert,update,delete,truncate')and not has_table_privilege('authenticated','public.manager_monthly_supervisor_evaluations','select,insert,update,delete,truncate'),'browser roles have no direct evaluation table access');
select ok(not has_table_privilege('service_role','public.manager_monthly_supervisor_evaluations','insert,update,delete,truncate')and not has_table_privilege('service_role','public.manager_monthly_supervisor_evaluation_scores','insert,update,delete,truncate'),'service role mutates only through RPCs');
select ok(not has_function_privilege('anon','public.save_managed_monthly_supervisor_evaluation_draft(uuid,uuid,uuid,date,bigint,jsonb)','execute')and not has_function_privilege('authenticated','public.save_managed_monthly_supervisor_evaluation_draft(uuid,uuid,uuid,date,bigint,jsonb)','execute'),'browser roles cannot execute mutation RPC');
select ok(has_function_privilege('service_role','public.save_managed_monthly_supervisor_evaluation_draft(uuid,uuid,uuid,date,bigint,jsonb)','execute'),'service role can execute mutation RPC');
select is((select proconfig from pg_catalog.pg_proc where oid='public.submit_managed_monthly_supervisor_evaluation(uuid,uuid,uuid,bigint)'::regprocedure),array['search_path='], 'submit RPC fixes an empty search path');
select is((public.get_managed_monthly_supervisor_evaluation_workspace('ba000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001','2026-10-01')->'summary'->>'evaluated_count')::integer,1,'workspace summary reflects submitted result');
select is(public.get_managed_monthly_supervisor_evaluation_detail('ba000000-0000-4000-8000-000000000001','bb000000-0000-4000-8000-000000000001',(select id from public.manager_monthly_supervisor_evaluations where supervisor_user_id='ba000000-0000-4000-8000-000000000002'))->>'supervisor_user_id','ba000000-0000-4000-8000-000000000002','submitted history remains readable');

select * from finish();
rollback;
