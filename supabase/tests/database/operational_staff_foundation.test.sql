begin;
select plan(34);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
 '11000000-0000-4000-8000-000000000001'::uuid,
 '11000000-0000-4000-8000-000000000002',
 '11000000-0000-4000-8000-000000000003',
 '11000000-0000-4000-8000-000000000004',
 '11000000-0000-4000-8000-000000000005'
]) id;
update public.profiles set full_name=case id
 when '11000000-0000-4000-8000-000000000001' then 'Supervisor One'
 when '11000000-0000-4000-8000-000000000002' then 'Supervisor Two'
 when '11000000-0000-4000-8000-000000000003' then 'Manager A'
 when '11000000-0000-4000-8000-000000000004' then 'Legacy Staff'
 else 'Manager B' end;
insert into public.organizations(id,name,slug) values
 ('21000000-0000-4000-8000-000000000001','Operational Org A','operational-org-a'),
 ('21000000-0000-4000-8000-000000000002','Operational Org B','operational-org-b');
insert into public.branches(id,organization_id,name,code,active) values
 ('31000000-0000-4000-8000-000000000001','21000000-0000-4000-8000-000000000001','Branch A','OA',true),
 ('31000000-0000-4000-8000-000000000002','21000000-0000-4000-8000-000000000001','Branch A2','OA2',true),
 ('31000000-0000-4000-8000-000000000003','21000000-0000-4000-8000-000000000002','Branch B','OB',true);
insert into public.organization_memberships(organization_id,user_id,role) values
 ('21000000-0000-4000-8000-000000000001','11000000-0000-4000-8000-000000000003','organization_manager'),
 ('21000000-0000-4000-8000-000000000002','11000000-0000-4000-8000-000000000005','organization_manager');
insert into public.branch_memberships(branch_id,user_id,role) values
 ('31000000-0000-4000-8000-000000000001','11000000-0000-4000-8000-000000000001','branch_manager'),
 ('31000000-0000-4000-8000-000000000001','11000000-0000-4000-8000-000000000002','branch_manager'),
 ('31000000-0000-4000-8000-000000000001','11000000-0000-4000-8000-000000000004','staff');
insert into public.branch_shifts(id,organization_id,branch_id,name,start_time,end_time) values
 ('41000000-0000-4000-8000-000000000001','21000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000001','Shift 1','08:00','16:00'),
 ('41000000-0000-4000-8000-000000000002','21000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000001','Shift 2','16:00','23:00');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id,shift_id) values
 ('51000000-0000-4000-8000-000000000001','21000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000001','11000000-0000-4000-8000-000000000001','41000000-0000-4000-8000-000000000001'),
 ('51000000-0000-4000-8000-000000000002','21000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000001','11000000-0000-4000-8000-000000000002','41000000-0000-4000-8000-000000000002');

select ok(not exists(select 1 from unnest(array[
 'account_management_audit_logs','branches','branch_memberships','branch_shifts','branch_supervisor_teams',
 'branch_operational_teams','branch_operational_team_supervisors',
 'operational_staff','operational_staff_assignments','operational_staff_duty_statuses',
 'organizations','organization_memberships','profiles','checklist_definitions','checklist_definition_items',
 'checklist_submissions','opening_item_results','hygiene_staff_snapshots','checklist_issues','checklist_submission_idempotency','checklist_issue_evidence'
]::text[]) required(name) where pg_catalog.to_regclass('public.'||required.name) is null),'all required production tables exist');
select ok((select bool_and(relrowsecurity) from pg_class c join pg_namespace n on n.oid=c.relnamespace
 where n.nspname='public' and c.relname in ('branch_shifts','branch_supervisor_teams','operational_staff','operational_staff_assignments','operational_staff_duty_statuses')),'RLS enabled on every new table');
select ok(not has_table_privilege('anon','public.operational_staff','select')
 and not has_table_privilege('authenticated','public.operational_staff','insert')
 and not has_table_privilege('authenticated','public.operational_staff','update')
 and not has_table_privilege('authenticated','public.operational_staff','delete')
 and not has_table_privilege('service_role','public.operational_staff','delete'),'no application hard-delete or broad mutation grants');
select ok(not has_function_privilege('public','public.create_supervisor_operational_staff(uuid,uuid,text,uuid,text[])','execute')
 and not has_function_privilege('anon','public.create_supervisor_operational_staff(uuid,uuid,text,uuid,text[])','execute')
 and not has_function_privilege('authenticated','public.create_supervisor_operational_staff(uuid,uuid,text,uuid,text[])','execute')
 and has_function_privilege('service_role','public.create_supervisor_operational_staff(uuid,uuid,text,uuid,text[])','execute'),'mutation RPC is service-role only');
select is((select proconfig from pg_proc where oid='public.create_supervisor_operational_staff(uuid,uuid,text,uuid,text[])'::regprocedure),
 array['search_path=""'],'RPC has fixed empty search path');

select throws_ok($$insert into public.branch_shifts(organization_id,branch_id,name,start_time,end_time)
 values('21000000-0000-4000-8000-000000000002','31000000-0000-4000-8000-000000000001','Bad','01:00','02:00')$$,'23503',null,'shift organization mismatch rejected');
select throws_ok($$insert into public.branch_shifts(organization_id,branch_id,name,start_time,end_time)
 values('21000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000001',' shift 1 ','01:00','02:00')$$,'23514',null,'untrimmed shift name rejected');
select throws_ok($$insert into public.branch_shifts(organization_id,branch_id,name,start_time,end_time)
 values('21000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000001','SHIFT 1','01:00','02:00')$$,'23505',null,'case-insensitive duplicate shift rejected');
select throws_ok($$insert into public.branch_shifts(organization_id,branch_id,name,start_time,end_time)
 values('21000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000001','Bad Time','01:00','01:00')$$,'23514',null,'equal shift times rejected');
select throws_ok($$insert into public.branch_supervisor_teams(organization_id,branch_id,supervisor_user_id,shift_id)
 values('21000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000001','11000000-0000-4000-8000-000000000004','41000000-0000-4000-8000-000000000001')$$,'23514','invalid supervisor team scope','legacy Staff cannot own team');

set local role service_role;
select lives_ok($$select * from public.create_supervisor_operational_staff(
 '11000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000001',
 '  Fake   Worker  ','41000000-0000-4000-8000-000000000001',array['kitchen'])$$,'supervisor creates own-team worker');
reset role;
select is((select staff.display_name from public.operational_staff staff
 join public.operational_staff_assignments assignment on assignment.operational_staff_id=staff.id
 where assignment.supervisor_team_id='51000000-0000-4000-8000-000000000001'),
 'Fake Worker','name normalized');
select is((select staff.normalized_name from public.operational_staff staff
 join public.operational_staff_assignments assignment on assignment.operational_staff_id=staff.id
 where assignment.supervisor_team_id='51000000-0000-4000-8000-000000000001'),
 'fake worker','search name normalized');
select is((select count(*) from public.account_management_audit_logs
 where organization_id='21000000-0000-4000-8000-000000000001'
 and actor_user_id='11000000-0000-4000-8000-000000000001'
 and action='operational_staff_created'),1::bigint,'create audited');
select throws_ok($$insert into public.account_management_audit_logs(organization_id,action,details)
 values('21000000-0000-4000-8000-000000000001','operational_staff_updated','{"email":"forbidden"}')$$,
 '23514',null,'operational audit keys are strictly allowlisted');
select lives_ok($$insert into public.account_management_audit_logs(organization_id,action,details)
 values('21000000-0000-4000-8000-000000000001','operational_staff_updated',
 '{"operational_staff_id":"61000000-0000-4000-8000-000000000001","new_status":"active"}')$$,
 'allowlisted operational audit keys accepted');
select lives_ok($$insert into public.operational_staff(id,organization_id,branch_id,display_name,created_by)
 values('61000000-0000-4000-8000-000000000002','21000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000001','Fake Worker','11000000-0000-4000-8000-000000000001')$$,'duplicate active names are allowed');

select throws_ok($$insert into public.operational_staff_assignments(organization_id,branch_id,operational_staff_id,supervisor_team_id,shift_id,operational_roles)
 select organization_id,branch_id,id,'51000000-0000-4000-8000-000000000001','41000000-0000-4000-8000-000000000001','{}'::text[] from public.operational_staff where id='61000000-0000-4000-8000-000000000002'$$,'23514',null,'zero roles rejected');
select throws_ok($$insert into public.operational_staff_assignments(organization_id,branch_id,operational_staff_id,supervisor_team_id,shift_id,operational_roles)
 select organization_id,branch_id,id,'51000000-0000-4000-8000-000000000001','41000000-0000-4000-8000-000000000001',array['kitchen','kitchen'] from public.operational_staff where id='61000000-0000-4000-8000-000000000002'$$,'23514',null,'duplicate roles rejected');
select throws_ok($$insert into public.operational_staff_assignments(organization_id,branch_id,operational_staff_id,supervisor_team_id,shift_id,operational_roles)
 select organization_id,branch_id,id,'51000000-0000-4000-8000-000000000001','41000000-0000-4000-8000-000000000001',array['kitchen','cleaner','production'] from public.operational_staff where id='61000000-0000-4000-8000-000000000002'$$,'23514',null,'three roles rejected');
select throws_ok($$insert into public.operational_staff_assignments(organization_id,branch_id,operational_staff_id,supervisor_team_id,shift_id,operational_roles)
 select organization_id,branch_id,id,'51000000-0000-4000-8000-000000000001','41000000-0000-4000-8000-000000000001',array['owner'] from public.operational_staff where id='61000000-0000-4000-8000-000000000002'$$,'23514',null,'unknown role rejected');

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','11000000-0000-4000-8000-000000000001',true);
select is((select count(*) from public.branch_supervisor_teams),1::bigint,'supervisor reads own team only');
select is((select count(*) from public.operational_staff),2::bigint,'supervisor reads branch employee roster');
select set_config('request.jwt.claim.sub','11000000-0000-4000-8000-000000000002',true);
select is((select count(*) from public.operational_staff),2::bigint,'same-branch other supervisor reads shared roster');
select set_config('request.jwt.claim.sub','11000000-0000-4000-8000-000000000004',true);
select is((select count(*) from public.operational_staff),0::bigint,'legacy authenticated Staff denied');
select set_config('request.jwt.claim.sub','11000000-0000-4000-8000-000000000003',true);
select is((select count(*) from public.operational_staff),2::bigint,'organization manager reads all tenant staff');
select set_config('request.jwt.claim.sub','11000000-0000-4000-8000-000000000005',true);
select is((select count(*) from public.operational_staff),0::bigint,'unrelated organization manager denied');
reset role;
select set_config('test.operational_staff_id',(select operational_staff_id::text
 from public.operational_staff_assignments
 where supervisor_team_id='51000000-0000-4000-8000-000000000001'),false);

set local role service_role;
select lives_ok($$select * from public.set_supervisor_operational_duty(
 '11000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000001',
 current_setting('test.operational_staff_id')::uuid,
 '2026-07-31','day_off')$$,'day off recorded');
reset role;
select is((select duty_status from public.operational_staff_duty_statuses
 where operational_staff_id=current_setting('test.operational_staff_id')::uuid and duty_date='2026-07-31'),'day_off','day off is date scoped');
select is((select employment_status from public.operational_staff
 where id=current_setting('test.operational_staff_id')::uuid),'active','day off preserves employment');
select is((select operational_roles from public.operational_staff_assignments
 where operational_staff_id=current_setting('test.operational_staff_id')::uuid),array['kitchen'],'day off preserves roles and assignment');
set local role service_role;
select lives_ok($$select * from public.set_supervisor_operational_duty(
 '11000000-0000-4000-8000-000000000001','31000000-0000-4000-8000-000000000001',
 current_setting('test.operational_staff_id')::uuid,
 '2026-07-31','on_duty')$$,'on duty restoration works');
reset role;
select is((select count(*) from public.operational_staff_duty_statuses
 where operational_staff_id=current_setting('test.operational_staff_id')::uuid),1::bigint,'upsert preserves one historical row per date');
select is((select count(*) from public.operational_staff
 where organization_id='21000000-0000-4000-8000-000000000001'),2::bigint,'duty changes never delete staff');

select * from finish();
rollback;
