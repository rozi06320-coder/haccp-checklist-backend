begin;
select plan(65);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',
 id||'@example.invalid','{}','{}',now(),now()
from unnest(array[
 '18000000-0000-4000-8000-000000000001'::uuid,
 '18000000-0000-4000-8000-000000000002',
 '18000000-0000-4000-8000-000000000003',
 '18000000-0000-4000-8000-000000000004',
 '18000000-0000-4000-8000-000000000005',
 '18000000-0000-4000-8000-000000000006'
]) id;
update public.profiles set must_change_password=false
 where id in ('18000000-0000-4000-8000-000000000001','18000000-0000-4000-8000-000000000005');
insert into public.organizations(id,name,slug) values
 ('28000000-0000-4000-8000-000000000001','Provisioning A','provisioning-a'),
 ('28000000-0000-4000-8000-000000000002','Provisioning B','provisioning-b');
insert into public.branches(id,organization_id,name,code,timezone,active) values
 ('38000000-0000-4000-8000-000000000001','28000000-0000-4000-8000-000000000001','A1','PA1','Asia/Riyadh',true),
 ('38000000-0000-4000-8000-000000000002','28000000-0000-4000-8000-000000000001','A2','PA2','Asia/Riyadh',true),
 ('38000000-0000-4000-8000-000000000003','28000000-0000-4000-8000-000000000001','Inactive','PA3','Asia/Riyadh',false),
 ('38000000-0000-4000-8000-000000000004','28000000-0000-4000-8000-000000000002','B1','PB1','Asia/Riyadh',true);
insert into public.branch_operational_teams(id,organization_id,branch_id,name,active) values
 ('48000000-0000-4000-8000-000000000001','28000000-0000-4000-8000-000000000001','38000000-0000-4000-8000-000000000001','Kitchen Team',true),
 ('48000000-0000-4000-8000-000000000002','28000000-0000-4000-8000-000000000001','38000000-0000-4000-8000-000000000002','Cashier Team',true),
 ('48000000-0000-4000-8000-000000000003','28000000-0000-4000-8000-000000000001','38000000-0000-4000-8000-000000000003','Inactive Branch Team',true),
 ('48000000-0000-4000-8000-000000000004','28000000-0000-4000-8000-000000000002','38000000-0000-4000-8000-000000000004','Other Org Team',true);
insert into public.organization_memberships(organization_id,user_id,role) values
 ('28000000-0000-4000-8000-000000000001','18000000-0000-4000-8000-000000000001','organization_manager');
insert into public.internal_admin_memberships(user_id,active)
 values('18000000-0000-4000-8000-000000000005',true);

select lives_ok($$select public.finalize_provisioned_supervisor(
 '18000000-0000-4000-8000-000000000005','28000000-0000-4000-8000-000000000001',
 '18000000-0000-4000-8000-000000000002','Provisioned Supervisor',
 array['38000000-0000-4000-8000-000000000001','38000000-0000-4000-8000-000000000002']::uuid[],
 null,
 pg_catalog.jsonb_build_array(
  pg_catalog.jsonb_build_object('operational_team_id','48000000-0000-4000-8000-000000000001','assignment_role','primary'),
  pg_catalog.jsonb_build_object('operational_team_id','48000000-0000-4000-8000-000000000002','assignment_role','backup')
 ))$$,
 'forced-password Supervisor provisioning succeeds');
select ok((select must_change_password and disabled_at is null from public.profiles
 where id='18000000-0000-4000-8000-000000000002'),'forced-password lifecycle is retained');
select is((select count(*) from public.branch_memberships where user_id='18000000-0000-4000-8000-000000000002'
 and role='branch_manager' and active),2::bigint,'one active membership per selected branch');
select is((select count(*) from public.branch_operational_team_supervisors where supervisor_user_id='18000000-0000-4000-8000-000000000002'
 and active),2::bigint,'one active canonical team assignment per selected team');
select is((select count(*) from public.branch_supervisor_teams where supervisor_user_id='18000000-0000-4000-8000-000000000002'
 and active),0::bigint,'provisioning does not create supervisor-only legacy teams');
select is((select count(distinct branch_id) from public.branch_operational_team_supervisors
 where supervisor_user_id='18000000-0000-4000-8000-000000000002' and active),2::bigint,
 'selected branches have distinct canonical assignments');
select is((select count(*) from public.account_management_audit_logs where target_user_id='18000000-0000-4000-8000-000000000002'
 and action='user_created'),1::bigint,'user-created audit is exactly once');
select is((select count(*) from public.account_management_audit_logs where target_user_id='18000000-0000-4000-8000-000000000002'
 and action='branch_assignment_added'),2::bigint,'membership audits are exactly once per branch');
select is((select details->>'operational_team_assignment_count' from public.account_management_audit_logs where target_user_id='18000000-0000-4000-8000-000000000002'
 and action='user_created'),'2','user-created audit records canonical team assignment count');
select ok(not exists(select 1 from public.account_management_audit_logs log cross join lateral
 pg_catalog.jsonb_object_keys(log.details) key where log.target_user_id='18000000-0000-4000-8000-000000000002'
 and pg_catalog.lower(key) ~ 'email|password|token|secret'),'audit details contain no forbidden keys');

insert into public.annual_evaluations(id,organization_id,branch_id,evaluation_year,subject_type,supervisor_user_id,evaluator_user_id,evaluator_name_snapshot,subject_name_snapshot,subject_role_snapshot,branch_name_snapshot)
values('88000000-0000-4000-8000-000000000001','28000000-0000-4000-8000-000000000001','38000000-0000-4000-8000-000000000001',2026,'supervisor','18000000-0000-4000-8000-000000000002','18000000-0000-4000-8000-000000000001','Org Manager','Provisioned Supervisor','Supervisor','A1');

select is((select person_code from public.update_internal_admin_supervisor_profile(
 '18000000-0000-4000-8000-000000000005',
 '28000000-0000-4000-8000-000000000001',
 '18000000-0000-4000-8000-000000000002',
 ' Updated   Supervisor ',
 ' مشرف محدّث ',
 ' SUP-002 ',
 ' +966511111111 ',
 'ph',
 ' 000112233 ',
 '2028-01-31'::date
)),'SUP-002','Internal Admin updates Supervisor profile and receives normalized code');
select is((select full_name from public.profiles where id='18000000-0000-4000-8000-000000000002'),'Updated Supervisor','Supervisor full name updates');
select is((select full_name_ar from public.profiles where id='18000000-0000-4000-8000-000000000002'),'مشرف محدّث','Supervisor Arabic name updates');
select is((select phone_number from public.profiles where id='18000000-0000-4000-8000-000000000002'),'+966511111111','Supervisor phone updates');
select is((select country_code from public.profiles where id='18000000-0000-4000-8000-000000000002'),'PH','Supervisor country updates uppercase');
select is((select iqama_number from public.profiles where id='18000000-0000-4000-8000-000000000002'),'000112233','Supervisor Iqama number updates as text');
select is((select iqama_expiry_date::text from public.profiles where id='18000000-0000-4000-8000-000000000002'),'2028-01-31','Supervisor Iqama expiry updates as date');
select is((select email::text from auth.users where id='18000000-0000-4000-8000-000000000002'),'18000000-0000-4000-8000-000000000002@example.invalid','Supervisor auth email remains unchanged');
select is((select count(*) from public.branch_memberships where user_id='18000000-0000-4000-8000-000000000002'
 and role='branch_manager' and active),2::bigint,'profile update leaves branch memberships unchanged');
select is((select count(*) from public.branch_operational_team_supervisors where supervisor_user_id='18000000-0000-4000-8000-000000000002'
 and active),2::bigint,'profile update leaves team assignments unchanged');
select is((select person_code from public.list_managed_organization_users(
 '18000000-0000-4000-8000-000000000001','28000000-0000-4000-8000-000000000001',
 1,20,null,'branch_manager',null,null)
 where id='18000000-0000-4000-8000-000000000002'),'SUP-002','Manager read model returns updated Supervisor profile');
select is((select subject_name_snapshot from public.annual_evaluations where id='88000000-0000-4000-8000-000000000001'),'Provisioned Supervisor','historical Annual Evaluation snapshot is not rewritten');
select is((select count(*) from public.account_management_audit_logs where target_user_id='18000000-0000-4000-8000-000000000002'
 and action='supervisor_profile_updated'),1::bigint,'Supervisor profile update audit is recorded');

select lives_ok($$select public.finalize_provisioned_supervisor(
 '18000000-0000-4000-8000-000000000005','28000000-0000-4000-8000-000000000001',
 '18000000-0000-4000-8000-000000000006','Zero Team Supervisor',
 array['38000000-0000-4000-8000-000000000001']::uuid[],
 null,
 '[]'::jsonb,
 ' SUP-006 ',
 ' +966500000000 ',
 'np',
 ' 0099887766 ',
 '2027-12-31'::date)$$,
 'internal admin can provision supervisor with zero operational team assignments');
select is((select count(*) from public.branch_memberships where user_id='18000000-0000-4000-8000-000000000006'
 and branch_id='38000000-0000-4000-8000-000000000001' and role='branch_manager' and active),1::bigint,
 'zero-team supervisor receives active branch membership');
select is((select count(*) from public.branch_operational_team_supervisors where supervisor_user_id='18000000-0000-4000-8000-000000000006'
 and active),0::bigint,'zero-team supervisor receives no canonical team assignment');
select is((select count(*) from public.branch_operational_teams where branch_id='38000000-0000-4000-8000-000000000001'),1::bigint,
 'zero-team provisioning does not create a fake/default operational team');
update public.profiles set must_change_password=false where id='18000000-0000-4000-8000-000000000006';
select ok(private.actor_can_read_operational_branch('18000000-0000-4000-8000-000000000006','38000000-0000-4000-8000-000000000001'),
 'zero-team supervisor can read the assigned branch after first-login password change');
select ok(not private.actor_can_write_operational_team('18000000-0000-4000-8000-000000000006','38000000-0000-4000-8000-000000000001','48000000-0000-4000-8000-000000000001'),
 'zero-team supervisor cannot write existing operational teams');
select is((select details->>'operational_team_assignment_count' from public.account_management_audit_logs where target_user_id='18000000-0000-4000-8000-000000000006'
 and action='user_created'),'0','zero-team audit records zero operational team assignments');
select is((select person_code from public.profiles where id='18000000-0000-4000-8000-000000000006'),'SUP-006',
 'Supervisor person code is normalized and stored');
select is((select phone_number from public.profiles where id='18000000-0000-4000-8000-000000000006'),'+966500000000',
 'Supervisor phone number is normalized and stored');
select is((select country_code from public.profiles where id='18000000-0000-4000-8000-000000000006'),'NP',
 'Supervisor country code is uppercased and stored');
select is((select iqama_number from public.profiles where id='18000000-0000-4000-8000-000000000006'),'0099887766',
 'Supervisor Iqama number remains text');
select is((select iqama_expiry_date::text from public.profiles where id='18000000-0000-4000-8000-000000000006'),'2027-12-31',
 'Supervisor Gregorian Iqama expiry date is stored as date');
select is((select person_code from public.list_internal_admin_supervisors(
 '18000000-0000-4000-8000-000000000005','28000000-0000-4000-8000-000000000001')
 where id='18000000-0000-4000-8000-000000000006'),'SUP-006',
 'Internal Admin supervisor listing returns canonical person code');
select is((select country_code from public.list_managed_organization_users(
 '18000000-0000-4000-8000-000000000001','28000000-0000-4000-8000-000000000001',
 1,20,null,'branch_manager',null,null)
 where id='18000000-0000-4000-8000-000000000006'),'NP',
 'Manager supervisor read model returns canonical country code');

select throws_ok($$select public.finalize_provisioned_supervisor(
 '18000000-0000-4000-8000-000000000005','28000000-0000-4000-8000-000000000001',
 '18000000-0000-4000-8000-000000000003','Duplicate code',
 array['38000000-0000-4000-8000-000000000001']::uuid[],
 null,
 '[]'::jsonb,
 'SUP-006',
 null,
 null,
 null,
 null::date)$$,
 '23505',null,'duplicate Supervisor person code is rejected');
select ok((select person_code is null from public.profiles where id='18000000-0000-4000-8000-000000000003'),
 'duplicate code failure rolls back profile fields');

select throws_ok($$select public.update_internal_admin_supervisor_profile(
 '18000000-0000-4000-8000-000000000005','28000000-0000-4000-8000-000000000001',
 '18000000-0000-4000-8000-000000000002','Updated Supervisor',null,'SUP-006',null,null,null,null::date)$$,
 '23505',null,'duplicate Supervisor person code update is rejected');
select is((select person_code from public.profiles where id='18000000-0000-4000-8000-000000000002'),'SUP-002',
 'duplicate code update leaves existing profile unchanged');
select throws_ok($$select public.update_internal_admin_supervisor_profile(
 '18000000-0000-4000-8000-000000000005','28000000-0000-4000-8000-000000000002',
 '18000000-0000-4000-8000-000000000002','Cross Org',null,null,null,null,null,null::date)$$,
 '42501','internal admin access denied','cross-organization Supervisor profile edit is rejected');

select throws_ok($$select * from public.create_managed_supervisor_team(
 '18000000-0000-4000-8000-000000000001','28000000-0000-4000-8000-000000000001',
 '38000000-0000-4000-8000-000000000001','18000000-0000-4000-8000-000000000002')$$,
 '42501','team operation denied','manual team ensure still rejects forced-password candidates');

select throws_ok($$select public.finalize_provisioned_supervisor(
 '18000000-0000-4000-8000-000000000001','28000000-0000-4000-8000-000000000001',
 '18000000-0000-4000-8000-000000000003','Manager denied',
 array['38000000-0000-4000-8000-000000000001']::uuid[],
 null,
 pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('operational_team_id','48000000-0000-4000-8000-000000000001','assignment_role','backup')))$$,
 '42501','provisioning denied','Organization Manager cannot finalize supervisor provisioning');

select throws_ok($$select public.finalize_provisioned_supervisor(
 '18000000-0000-4000-8000-000000000005','28000000-0000-4000-8000-000000000001',
 '18000000-0000-4000-8000-000000000003','Wrong branch',
 array['38000000-0000-4000-8000-000000000004']::uuid[],
 null,
 pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('operational_team_id','48000000-0000-4000-8000-000000000004','assignment_role','backup')))$$,
 '22023','invalid provisioning input','cross-organization branch is rejected');
select ok((select full_name is null and not must_change_password from public.profiles
 where id='18000000-0000-4000-8000-000000000003'),'cross-organization failure rolls back profile');
select is((select count(*) from public.branch_memberships where user_id='18000000-0000-4000-8000-000000000003'),0::bigint,
 'cross-organization failure leaves no membership');
select is((select count(*) from public.branch_supervisor_teams where supervisor_user_id='18000000-0000-4000-8000-000000000003'),0::bigint,
 'cross-organization failure leaves no team');
select is((select count(*) from public.account_management_audit_logs where target_user_id='18000000-0000-4000-8000-000000000003'),0::bigint,
 'cross-organization failure leaves no audit');

select throws_ok($$select public.finalize_provisioned_supervisor(
 '18000000-0000-4000-8000-000000000005','28000000-0000-4000-8000-000000000001',
 '18000000-0000-4000-8000-000000000003','Inactive branch',
 array['38000000-0000-4000-8000-000000000003']::uuid[],
 null,
 pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('operational_team_id','48000000-0000-4000-8000-000000000003','assignment_role','backup')))$$,
 '22023','invalid provisioning input','inactive branch is rejected');
select is((select count(*) from public.branch_memberships where user_id='18000000-0000-4000-8000-000000000003'),0::bigint,
 'inactive-branch failure leaves no membership');
select is((select count(*) from public.branch_supervisor_teams where supervisor_user_id='18000000-0000-4000-8000-000000000003'),0::bigint,
 'inactive-branch failure leaves no team');

insert into public.branch_memberships(branch_id,user_id,role) values(
 '38000000-0000-4000-8000-000000000001','18000000-0000-4000-8000-000000000004','branch_manager');
insert into public.branch_memberships(branch_id,user_id,role) values(
 '38000000-0000-4000-8000-000000000002','18000000-0000-4000-8000-000000000005','branch_manager');
insert into public.branch_operational_team_supervisors(organization_id,branch_id,operational_team_id,supervisor_user_id,assignment_role,created_by)
values('28000000-0000-4000-8000-000000000001','38000000-0000-4000-8000-000000000002',
 '48000000-0000-4000-8000-000000000002','18000000-0000-4000-8000-000000000005','primary',
 '18000000-0000-4000-8000-000000000005');
select throws_ok($$select public.finalize_provisioned_supervisor(
 '18000000-0000-4000-8000-000000000005','28000000-0000-4000-8000-000000000001',
 '18000000-0000-4000-8000-000000000004','Conflicting partial',
 array['38000000-0000-4000-8000-000000000002']::uuid[],
 null,
 pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('operational_team_id','48000000-0000-4000-8000-000000000002','assignment_role','primary')))$$,
 '23505',null,'existing team conflict aborts provisioning');
select ok((select full_name is null and not must_change_password from public.profiles
 where id='18000000-0000-4000-8000-000000000004'),'team conflict rolls back profile update');
select is((select count(*) from public.branch_memberships where user_id='18000000-0000-4000-8000-000000000004'),1::bigint,
 'partial-state conflict leaves the pre-existing membership unchanged');
select is((select count(*) from public.account_management_audit_logs where target_user_id='18000000-0000-4000-8000-000000000004'),0::bigint,
 'team conflict rolls back provisioning audits');
select is((select count(*) from public.branch_supervisor_teams where supervisor_user_id='18000000-0000-4000-8000-000000000002'
 and branch_id='38000000-0000-4000-8000-000000000001' and active),0::bigint,'successful provisioning has no duplicate active legacy team');

select ok(not has_function_privilege('public','public.finalize_provisioned_supervisor(uuid,uuid,uuid,text,uuid[])','execute')
 and not has_function_privilege('anon','public.finalize_provisioned_supervisor(uuid,uuid,uuid,text,uuid[])','execute')
 and not has_function_privilege('authenticated','public.finalize_provisioned_supervisor(uuid,uuid,uuid,text,uuid[])','execute')
 and has_function_privilege('service_role','public.finalize_provisioned_supervisor(uuid,uuid,uuid,text,uuid[])','execute')
 and not has_function_privilege('public','public.finalize_provisioned_supervisor(uuid,uuid,uuid,text,uuid[],text,jsonb)','execute')
 and not has_function_privilege('authenticated','public.finalize_provisioned_supervisor(uuid,uuid,uuid,text,uuid[],text,jsonb)','execute')
 and has_function_privilege('service_role','public.finalize_provisioned_supervisor(uuid,uuid,uuid,text,uuid[],text,jsonb)','execute')
 and not has_function_privilege('public','public.finalize_provisioned_supervisor(uuid,uuid,uuid,text,uuid[],text,jsonb,text,text,text,text,date)','execute')
 and not has_function_privilege('authenticated','public.finalize_provisioned_supervisor(uuid,uuid,uuid,text,uuid[],text,jsonb,text,text,text,text,date)','execute')
 and has_function_privilege('service_role','public.finalize_provisioned_supervisor(uuid,uuid,uuid,text,uuid[],text,jsonb,text,text,text,text,date)','execute')
 and not has_function_privilege('public','public.update_internal_admin_supervisor_profile(uuid,uuid,uuid,text,text,text,text,text,text,date)','execute')
 and not has_function_privilege('authenticated','public.update_internal_admin_supervisor_profile(uuid,uuid,uuid,text,text,text,text,text,text,date)','execute')
 and has_function_privilege('service_role','public.update_internal_admin_supervisor_profile(uuid,uuid,uuid,text,text,text,text,text,text,date)','execute'),
 'provisioning exception remains service-role-only');
select is((select proconfig from pg_proc where oid='public.finalize_provisioned_supervisor(uuid,uuid,uuid,text,uuid[],text,jsonb)'::regprocedure),
 array['search_path=""'],'provisioning function keeps an empty search path');
select is((select proconfig from pg_proc where oid='public.update_internal_admin_supervisor_profile(uuid,uuid,uuid,text,text,text,text,text,text,date)'::regprocedure),
 array['search_path=""'],'Supervisor profile update function keeps an empty search path');
select is((select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname='finalize_provisioned_supervisor'),4::bigint,
 'provisioning RPC retains compatibility overloads');
select is((select count(*) from public.branch_operational_team_supervisors where supervisor_user_id='18000000-0000-4000-8000-000000000002'
 and operational_team_id in('48000000-0000-4000-8000-000000000001','48000000-0000-4000-8000-000000000002') and active),2::bigint,'provisioning sends canonical operational team identity');
select is((select count(*) from public.account_management_audit_logs where target_user_id='18000000-0000-4000-8000-000000000002'
 and details::text ~* 'example.invalid'),0::bigint,'audit details contain no email value');
select is((select count(*) from public.account_management_audit_logs where target_user_id='18000000-0000-4000-8000-000000000002'
 and actor_user_id='18000000-0000-4000-8000-000000000005'),4::bigint,'all Supervisor account audits retain the internal admin actor');
select is((select count(*) from public.branch_operational_team_supervisors where supervisor_user_id='18000000-0000-4000-8000-000000000002'
 and organization_id='28000000-0000-4000-8000-000000000001'),2::bigint,'all provisioned teams retain tenant scope');

select * from finish();
rollback;
