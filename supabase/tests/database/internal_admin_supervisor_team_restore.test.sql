begin;
select plan(37);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email, '{}', '{}', now(), now()
from (values
  ('1d400000-0000-4000-8000-000000000001'::uuid, 'restore-admin@example.invalid'),
  ('1d400000-0000-4000-8000-000000000002'::uuid, 'jonathan@example.invalid'),
  ('1d400000-0000-4000-8000-000000000003'::uuid, 'replacement@example.invalid'),
  ('1d400000-0000-4000-8000-000000000004'::uuid, 'conflict-supervisor@example.invalid'),
  ('1d400000-0000-4000-8000-000000000005'::uuid, 'inactive-team-supervisor@example.invalid'),
  ('1d400000-0000-4000-8000-000000000006'::uuid, 'transferred-supervisor@example.invalid'),
  ('1d400000-0000-4000-8000-000000000007'::uuid, 'modern-only-supervisor@example.invalid')
) users(id,email);

update public.profiles
set full_name = case id
  when '1d400000-0000-4000-8000-000000000001' then 'Restore Admin'
  when '1d400000-0000-4000-8000-000000000002' then 'Jonathan'
  else 'Restore Test Supervisor'
end,
must_change_password = false
where id::text like '1d400000-%';

insert into public.internal_admin_memberships(user_id,active)
values ('1d400000-0000-4000-8000-000000000001',true);

insert into public.organizations(id,name,slug) values
  ('2d400000-0000-4000-8000-000000000001','Restore Org','restore-org'),
  ('2d400000-0000-4000-8000-000000000002','Other Restore Org','other-restore-org');

insert into public.branches(id,organization_id,name,code,timezone) values
  ('3d400000-0000-4000-8000-000000000001','2d400000-0000-4000-8000-000000000001','Burger Hunch Al Rimal','RML','Asia/Riyadh'),
  ('3d400000-0000-4000-8000-000000000002','2d400000-0000-4000-8000-000000000001','Restore Branch Two','RB2','Asia/Riyadh'),
  ('3d400000-0000-4000-8000-000000000003','2d400000-0000-4000-8000-000000000002','Other Restore Branch','ORB','Asia/Riyadh');

insert into public.branch_memberships(branch_id,user_id,role,active) values
  ('3d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000002','branch_manager',true),
  ('3d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000003','branch_manager',true),
  ('3d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000004','branch_manager',true),
  ('3d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000005','branch_manager',true),
  ('3d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000006','branch_manager',true),
  ('3d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000007','branch_manager',true);

insert into public.branch_shifts(id,organization_id,branch_id,name,start_time,end_time) values
  ('4d400000-0000-4000-8000-000000000001','2d400000-0000-4000-8000-000000000001','3d400000-0000-4000-8000-000000000001','Restore Shift','08:00','16:00');

insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id,shift_id,active,company_name) values
  ('5d400000-0000-4000-8000-000000000001','2d400000-0000-4000-8000-000000000001','3d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000002','4d400000-0000-4000-8000-000000000001',true,'NAHTANOJ'),
  ('5d400000-0000-4000-8000-000000000002','2d400000-0000-4000-8000-000000000001','3d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000004','4d400000-0000-4000-8000-000000000001',true,'Conflict Team'),
  ('5d400000-0000-4000-8000-000000000003','2d400000-0000-4000-8000-000000000001','3d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000005','4d400000-0000-4000-8000-000000000001',true,'Inactive Team'),
  ('5d400000-0000-4000-8000-000000000004','2d400000-0000-4000-8000-000000000001','3d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000006','4d400000-0000-4000-8000-000000000001',true,'Transferred Team'),
  ('5d400000-0000-4000-8000-000000000005','2d400000-0000-4000-8000-000000000001','3d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000003','4d400000-0000-4000-8000-000000000001',true,'Jonathan Backup Team');

update public.branch_operational_teams
set name = case legacy_supervisor_team_id
  when '5d400000-0000-4000-8000-000000000001' then 'NAHTANOJ'
  when '5d400000-0000-4000-8000-000000000002' then 'Conflict Team'
  when '5d400000-0000-4000-8000-000000000003' then 'Inactive Team'
  when '5d400000-0000-4000-8000-000000000005' then 'Jonathan Backup Team'
  else 'Transferred Team'
end
where legacy_supervisor_team_id in (
  '5d400000-0000-4000-8000-000000000001',
  '5d400000-0000-4000-8000-000000000002',
  '5d400000-0000-4000-8000-000000000003',
  '5d400000-0000-4000-8000-000000000004',
  '5d400000-0000-4000-8000-000000000005'
);

insert into public.operational_staff(
  id,organization_id,branch_id,display_name,employment_status,created_by
) values (
  '6d400000-0000-4000-8000-000000000001','2d400000-0000-4000-8000-000000000001',
  '3d400000-0000-4000-8000-000000000001','Jonathan Team Staff','active','1d400000-0000-4000-8000-000000000001'
), (
  '6d400000-0000-4000-8000-000000000002','2d400000-0000-4000-8000-000000000001',
  '3d400000-0000-4000-8000-000000000001','Jonathan Backup Staff','active','1d400000-0000-4000-8000-000000000001'
);

insert into public.operational_staff_assignments(
  id,organization_id,branch_id,operational_staff_id,supervisor_team_id,shift_id,operational_roles,active
) values (
  '7d400000-0000-4000-8000-000000000001','2d400000-0000-4000-8000-000000000001',
  '3d400000-0000-4000-8000-000000000001','6d400000-0000-4000-8000-000000000001',
  '5d400000-0000-4000-8000-000000000001','4d400000-0000-4000-8000-000000000001',array['kitchen'],true
), (
  '7d400000-0000-4000-8000-000000000002','2d400000-0000-4000-8000-000000000001',
  '3d400000-0000-4000-8000-000000000001','6d400000-0000-4000-8000-000000000002',
  '5d400000-0000-4000-8000-000000000005','4d400000-0000-4000-8000-000000000001',array['front_of_house'],true
);

create temporary table restore_ids as
select
  (array_agg(id) filter (where legacy_supervisor_team_id='5d400000-0000-4000-8000-000000000001'))[1] as jonathan_team_id,
  (array_agg(id) filter (where legacy_supervisor_team_id='5d400000-0000-4000-8000-000000000002'))[1] as conflict_team_id,
  (array_agg(id) filter (where legacy_supervisor_team_id='5d400000-0000-4000-8000-000000000003'))[1] as inactive_team_id,
  (array_agg(id) filter (where legacy_supervisor_team_id='5d400000-0000-4000-8000-000000000004'))[1] as transferred_team_id,
  (array_agg(id) filter (where legacy_supervisor_team_id='5d400000-0000-4000-8000-000000000005'))[1] as backup_team_id
from public.branch_operational_teams;

insert into public.branch_operational_team_supervisors(
  id,organization_id,branch_id,operational_team_id,supervisor_user_id,assignment_role,created_by
)
select
  '9d400000-0000-4000-8000-000000000002','2d400000-0000-4000-8000-000000000001',
  '3d400000-0000-4000-8000-000000000001',backup_team_id,
  '1d400000-0000-4000-8000-000000000002','backup','1d400000-0000-4000-8000-000000000001'
from restore_ids;

select lives_ok($$select * from public.deactivate_internal_admin_supervisor(
  '1d400000-0000-4000-8000-000000000001','2d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000002'
)$$,'Jonathan-equivalent access revoke succeeds');
select ok(not (select active from public.branch_memberships where branch_id='3d400000-0000-4000-8000-000000000001' and user_id='1d400000-0000-4000-8000-000000000002'),
  'revoke closes only selected active branch membership');
select is((select count(*) from public.branch_operational_team_supervisors where supervisor_user_id='1d400000-0000-4000-8000-000000000002' and active),0::bigint,
  'revoke closes Jonathan historical canonical assignment');
select ok((select active from public.branch_operational_teams where id=(select jonathan_team_id from restore_ids)),
  'revoke preserves NAHTANOJ team');
select is((select id from public.operational_staff_assignments where operational_staff_id='6d400000-0000-4000-8000-000000000001' and active),'7d400000-0000-4000-8000-000000000001'::uuid,
  'revoke preserves staff assignment identity');

select lives_ok($$select * from public.reactivate_internal_admin_supervisor(
  '1d400000-0000-4000-8000-000000000001','2d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000002','3d400000-0000-4000-8000-000000000001'
)$$,'explicit branch restore succeeds');
select ok((select active from public.branch_memberships where branch_id='3d400000-0000-4000-8000-000000000001' and user_id='1d400000-0000-4000-8000-000000000002'),
  'restore activates selected membership');
select is((select count(*) from public.branch_operational_team_supervisors where supervisor_user_id='1d400000-0000-4000-8000-000000000002' and active and operational_team_id=(select jonathan_team_id from restore_ids)),1::bigint,
  'restore reconnects the same canonical team ID');
select is((select count(*) from public.branch_operational_team_supervisors where supervisor_user_id='1d400000-0000-4000-8000-000000000002' and active and operational_team_id=(select backup_team_id from restore_ids) and assignment_role='backup'),1::bigint,
  'restore reconnects the audit-scoped backup team');
select is((select count(*) from public.branch_operational_team_supervisors where supervisor_user_id='1d400000-0000-4000-8000-000000000002' and not active),2::bigint,
  'old primary and backup assignments remain historical and inactive');
select is((select id from public.operational_staff_assignments where operational_staff_id='6d400000-0000-4000-8000-000000000001' and active),'7d400000-0000-4000-8000-000000000001'::uuid,
  'restore leaves staff assignment ID unchanged');
select is((select id from public.operational_staff_assignments where operational_staff_id='6d400000-0000-4000-8000-000000000002' and active),'7d400000-0000-4000-8000-000000000002'::uuid,
  'restore leaves backup-team staff assignment ID unchanged');
select is((select count(*) from public.get_supervisor_operational_team(
  '1d400000-0000-4000-8000-000000000002','3d400000-0000-4000-8000-000000000001',current_date
) where team_id=(select jonathan_team_id from restore_ids) and assignment_role='primary' and staff_id='6d400000-0000-4000-8000-000000000001'),1::bigint,
  'Supervisor team read returns the same team and staff after restore');
select ok(not (select active from public.branch_supervisor_teams where id='5d400000-0000-4000-8000-000000000001'),
  'modern restore does not reactivate legacy compatibility row');

select lives_ok($$select * from public.reactivate_internal_admin_supervisor(
  '1d400000-0000-4000-8000-000000000001','2d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000002','3d400000-0000-4000-8000-000000000001'
)$$,'repeated restore is idempotent');
select lives_ok($$select * from public.reactivate_internal_admin_supervisor(
  '1d400000-0000-4000-8000-000000000001','2d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000002'
)$$,'legacy three-argument restore overload remains compatible for an unambiguous branch');
select is((select count(*) from public.branch_operational_team_supervisors where supervisor_user_id='1d400000-0000-4000-8000-000000000002' and active),2::bigint,
  'repeated restore creates no duplicate active assignment');
select is((select count(*) from public.branch_operational_teams where id=(select jonathan_team_id from restore_ids)),1::bigint,
  'repeated restore creates no duplicate team');
select ok(exists(
  select 1 from public.account_management_audit_logs
  where target_user_id='1d400000-0000-4000-8000-000000000002'
    and action='user_enabled'
    and branch_id='3d400000-0000-4000-8000-000000000001'
    and details->>'restored_operational_team_id'=(select jonathan_team_id::text from restore_ids)
), 'restore audit records selected branch and canonical team');
select ok(exists(
  select 1
  from public.account_management_audit_logs audit
  cross join lateral pg_catalog.jsonb_array_elements(audit.details->'restored_team_assignments') restored(entry)
  where audit.target_user_id='1d400000-0000-4000-8000-000000000002'
    and audit.action='user_enabled'
    and audit.branch_id='3d400000-0000-4000-8000-000000000001'
    and restored.entry->>'operational_team_id'=(select backup_team_id::text from restore_ids)
    and restored.entry->>'assignment_role'='backup'
), 'restore audit records the restored backup assignment and role');

select lives_ok($$select * from public.deactivate_internal_admin_supervisor(
  '1d400000-0000-4000-8000-000000000001','2d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000004'
)$$,'conflict fixture revoke succeeds');
insert into public.branch_operational_team_supervisors(
  organization_id,branch_id,operational_team_id,supervisor_user_id,assignment_role,created_by
) select '2d400000-0000-4000-8000-000000000001','3d400000-0000-4000-8000-000000000001',conflict_team_id,
  '1d400000-0000-4000-8000-000000000003','primary','1d400000-0000-4000-8000-000000000001'
from restore_ids;
select throws_ok($$select * from public.reactivate_internal_admin_supervisor(
  '1d400000-0000-4000-8000-000000000001','2d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000004','3d400000-0000-4000-8000-000000000001'
)$$,'23505','operational team already has active primary supervisor','restore never steals an occupied primary team');
select ok(not (select active from public.branch_memberships where branch_id='3d400000-0000-4000-8000-000000000001' and user_id='1d400000-0000-4000-8000-000000000004'),
  'primary conflict leaves target membership inactive');

select lives_ok($$select * from public.deactivate_internal_admin_supervisor(
  '1d400000-0000-4000-8000-000000000001','2d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000005'
)$$,'inactive team fixture revoke succeeds');
update public.branch_operational_teams set active=false where id=(select inactive_team_id from restore_ids);
select lives_ok($$select * from public.reactivate_internal_admin_supervisor(
  '1d400000-0000-4000-8000-000000000001','2d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000005','3d400000-0000-4000-8000-000000000001'
)$$,'inactive historical team does not block branch-only access restore');
select ok(not (select active from public.branch_operational_teams where id=(select inactive_team_id from restore_ids)),
  'restore never reactivates an intentionally inactive team');
select is((select count(*) from public.branch_operational_team_supervisors where supervisor_user_id='1d400000-0000-4000-8000-000000000005' and active),0::bigint,
  'inactive team receives no restored supervisor assignment');

select lives_ok($$select * from public.deactivate_internal_admin_supervisor(
  '1d400000-0000-4000-8000-000000000001','2d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000006'
)$$,'transfer fixture source revoke succeeds');
insert into public.branch_memberships(branch_id,user_id,role,active) values
  ('3d400000-0000-4000-8000-000000000002','1d400000-0000-4000-8000-000000000006','branch_manager',true);
insert into public.account_management_audit_logs(organization_id,actor_user_id,target_user_id,branch_id,action,details)
values(
  '2d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000006',
  '3d400000-0000-4000-8000-000000000002','branch_assignment_added',
  pg_catalog.jsonb_build_object('role','branch_manager','from_branch_id','3d400000-0000-4000-8000-000000000001','to_branch_id','3d400000-0000-4000-8000-000000000002')
);
select lives_ok($$select * from public.deactivate_internal_admin_supervisor(
  '1d400000-0000-4000-8000-000000000001','2d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000006'
)$$,'transferred current branch revoke records the explicit restore branch');
select throws_ok($$select * from public.reactivate_internal_admin_supervisor(
  '1d400000-0000-4000-8000-000000000001','2d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000006','3d400000-0000-4000-8000-000000000001'
)$$,'23514','supervisor restore branch conflicts with latest transfer','restore rejects the transferred old branch');
select lives_ok($$select * from public.reactivate_internal_admin_supervisor(
  '1d400000-0000-4000-8000-000000000001','2d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000006','3d400000-0000-4000-8000-000000000002'
)$$,'selected current transfer branch restores without the old team');
select ok(not (select active from public.branch_memberships where branch_id='3d400000-0000-4000-8000-000000000001' and user_id='1d400000-0000-4000-8000-000000000006'),
  'current branch restore leaves old branch inactive');
select ok((select active from public.branch_memberships where branch_id='3d400000-0000-4000-8000-000000000002' and user_id='1d400000-0000-4000-8000-000000000006'),
  'only the explicitly selected current branch becomes active');

select throws_ok($$select * from public.reactivate_internal_admin_supervisor(
  '1d400000-0000-4000-8000-000000000001','2d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000002','3d400000-0000-4000-8000-000000000003'
)$$,'42501','supervisor restore branch unavailable','cross-organization branch restore is denied');

insert into public.branch_operational_teams(
  id,organization_id,branch_id,name,active,legacy_supervisor_team_id
) values (
  '8d400000-0000-4000-8000-000000000001','2d400000-0000-4000-8000-000000000001',
  '3d400000-0000-4000-8000-000000000001','Modern Only Team',true,null
);
insert into public.branch_operational_team_supervisors(
  id,organization_id,branch_id,operational_team_id,supervisor_user_id,assignment_role,created_by
) values (
  '9d400000-0000-4000-8000-000000000001','2d400000-0000-4000-8000-000000000001',
  '3d400000-0000-4000-8000-000000000001','8d400000-0000-4000-8000-000000000001',
  '1d400000-0000-4000-8000-000000000007','primary','1d400000-0000-4000-8000-000000000001'
);
select lives_ok($$select * from public.deactivate_internal_admin_supervisor(
  '1d400000-0000-4000-8000-000000000001','2d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000007'
)$$,'modern-only fixture revoke succeeds');
select lives_ok($$select * from public.reactivate_internal_admin_supervisor(
  '1d400000-0000-4000-8000-000000000001','2d400000-0000-4000-8000-000000000001','1d400000-0000-4000-8000-000000000007','3d400000-0000-4000-8000-000000000001'
)$$,'missing legacy compatibility row does not block modern restore');
select is((select count(*) from public.branch_operational_team_supervisors where operational_team_id='8d400000-0000-4000-8000-000000000001' and supervisor_user_id='1d400000-0000-4000-8000-000000000007' and active),1::bigint,
  'modern-only team has one restored active assignment');

select * from finish();
rollback;
