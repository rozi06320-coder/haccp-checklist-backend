begin;
select plan(31);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email, '{}', '{}', now(), now()
from (values
  ('1b300000-0000-4000-8000-000000000001'::uuid, 'internal-admin@example.invalid'),
  ('1b300000-0000-4000-8000-000000000002'::uuid, 'existing-manager@example.invalid'),
  ('1b300000-0000-4000-8000-000000000003'::uuid, 'existing-supervisor@example.invalid'),
  ('1b300000-0000-4000-8000-000000000004'::uuid, 'existing-maintenance@example.invalid'),
  ('1b300000-0000-4000-8000-000000000005'::uuid, 'not-admin@example.invalid'),
  ('1b300000-0000-4000-8000-000000000006'::uuid, 'legacy-supervisor@example.invalid'),
  ('1b300000-0000-4000-8000-000000000007'::uuid, 'zero-team-supervisor@example.invalid')
) users(id, email);

update public.profiles set full_name = case id
  when '1b300000-0000-4000-8000-000000000001' then 'Internal Admin'
  when '1b300000-0000-4000-8000-000000000002' then 'Existing Manager'
  when '1b300000-0000-4000-8000-000000000003' then 'Existing Supervisor'
  when '1b300000-0000-4000-8000-000000000004' then 'Existing Maintenance'
  when '1b300000-0000-4000-8000-000000000006' then 'Legacy Supervisor'
  when '1b300000-0000-4000-8000-000000000007' then 'Zero Team Supervisor'
  else 'Not Admin'
end, must_change_password = false
where id::text like '1b300000-%';

insert into public.internal_admin_memberships(user_id, active)
values ('1b300000-0000-4000-8000-000000000001', true);

insert into public.organizations(id,name,slug) values
 ('2b300000-0000-4000-8000-000000000001','Existing Role Org','existing-role-org'),
 ('2b300000-0000-4000-8000-000000000002','Other Existing Role Org','other-existing-role-org');

insert into public.branches(id,organization_id,name,code,timezone) values
 ('3b300000-0000-4000-8000-000000000001','2b300000-0000-4000-8000-000000000001','Branch One','B1','Asia/Riyadh'),
 ('3b300000-0000-4000-8000-000000000002','2b300000-0000-4000-8000-000000000001','Branch Two','B2','Asia/Riyadh'),
 ('3b300000-0000-4000-8000-000000000003','2b300000-0000-4000-8000-000000000002','Other Branch','OB','Asia/Riyadh');
insert into public.branch_operational_teams(id,organization_id,branch_id,name,active) values
 ('4b300000-0000-4000-8000-000000000001','2b300000-0000-4000-8000-000000000001','3b300000-0000-4000-8000-000000000001','Branch One Team',true),
 ('4b300000-0000-4000-8000-000000000002','2b300000-0000-4000-8000-000000000001','3b300000-0000-4000-8000-000000000002','Branch Two Team',true),
 ('4b300000-0000-4000-8000-000000000003','2b300000-0000-4000-8000-000000000002','3b300000-0000-4000-8000-000000000003','Other Branch Team',true);

insert into public.branch_memberships(branch_id,user_id,role,active) values
 ('3b300000-0000-4000-8000-000000000001','1b300000-0000-4000-8000-000000000006','branch_manager',true);
insert into public.branch_supervisor_teams(organization_id,branch_id,supervisor_user_id,active) values
 ('2b300000-0000-4000-8000-000000000001','3b300000-0000-4000-8000-000000000001','1b300000-0000-4000-8000-000000000006',true);

select lives_ok($$select * from public.grant_existing_organization_manager(
 '1b300000-0000-4000-8000-000000000001',
 '2b300000-0000-4000-8000-000000000001',
 ' EXISTING-MANAGER@example.invalid '
)$$,'internal admin grants existing organization manager access');
select is(
  (select count(*) from public.organization_memberships where organization_id='2b300000-0000-4000-8000-000000000001' and user_id='1b300000-0000-4000-8000-000000000002' and role='organization_manager' and active),
  1::bigint,
  'existing manager membership is active'
);
select lives_ok($$select * from public.grant_existing_organization_manager(
 '1b300000-0000-4000-8000-000000000001',
 '2b300000-0000-4000-8000-000000000001',
 'existing-manager@example.invalid'
)$$,'duplicate existing manager grant is idempotent');
select is(
  (select count(*) from public.organization_memberships where organization_id='2b300000-0000-4000-8000-000000000001' and user_id='1b300000-0000-4000-8000-000000000002'),
  1::bigint,
  'duplicate existing manager grant does not duplicate membership'
);
select throws_ok($$select * from public.grant_existing_organization_manager(
 '1b300000-0000-4000-8000-000000000001',
 '2b300000-0000-4000-8000-000000000001',
 'missing@example.invalid'
)$$,'P0002','existing user not found','unknown manager email is safe not found');

select lives_ok($$select * from public.deactivate_organization_manager(
 '1b300000-0000-4000-8000-000000000001',
 '2b300000-0000-4000-8000-000000000001',
 '1b300000-0000-4000-8000-000000000002'
)$$,'internal admin removes manager access');
select ok(
  (select disabled_at is null from public.profiles where id='1b300000-0000-4000-8000-000000000002'),
  'manager access removal does not disable profile'
);
select lives_ok($$select * from public.reactivate_organization_manager(
 '1b300000-0000-4000-8000-000000000001',
 '2b300000-0000-4000-8000-000000000001',
 '1b300000-0000-4000-8000-000000000002'
)$$,'internal admin reactivates manager access');

select lives_ok($$select * from public.grant_existing_branch_supervisor(
 '1b300000-0000-4000-8000-000000000001',
 '2b300000-0000-4000-8000-000000000001',
 'existing-supervisor@example.invalid',
 array['3b300000-0000-4000-8000-000000000001'::uuid,'3b300000-0000-4000-8000-000000000002'::uuid],
 pg_catalog.jsonb_build_array(
  pg_catalog.jsonb_build_object('operational_team_id','4b300000-0000-4000-8000-000000000001','assignment_role','backup'),
  pg_catalog.jsonb_build_object('operational_team_id','4b300000-0000-4000-8000-000000000002','assignment_role','backup')
 )
)$$,'internal admin grants existing supervisor access');
select is(
  (select count(*) from public.branch_memberships where user_id='1b300000-0000-4000-8000-000000000003' and role='branch_manager' and active),
  2::bigint,
  'existing supervisor receives active branch memberships'
);
select is(
  (select count(*) from public.branch_operational_team_supervisors where supervisor_user_id='1b300000-0000-4000-8000-000000000003' and active),
  2::bigint,
  'existing supervisor receives active canonical team assignments'
);
select lives_ok($$select * from public.grant_existing_branch_supervisor(
 '1b300000-0000-4000-8000-000000000001',
 '2b300000-0000-4000-8000-000000000001',
 'zero-team-supervisor@example.invalid',
 array['3b300000-0000-4000-8000-000000000001'::uuid],
 '[]'::jsonb
)$$,'internal admin grants existing supervisor branch access without team assignments');
select is(
  (select count(*) from public.branch_memberships where user_id='1b300000-0000-4000-8000-000000000007' and role='branch_manager' and active),
  1::bigint,
  'zero-team existing supervisor receives active branch membership'
);
select is(
  (select count(*) from public.branch_operational_team_supervisors where supervisor_user_id='1b300000-0000-4000-8000-000000000007' and active),
  0::bigint,
  'zero-team existing supervisor receives no canonical team assignment'
);
select ok(private.actor_can_read_operational_branch('1b300000-0000-4000-8000-000000000007','3b300000-0000-4000-8000-000000000001'),
  'zero-team existing supervisor can read assigned branch');
select ok(not private.actor_can_write_operational_team('1b300000-0000-4000-8000-000000000007','3b300000-0000-4000-8000-000000000001','4b300000-0000-4000-8000-000000000001'),
  'zero-team existing supervisor cannot write operational team');
select lives_ok($$select * from public.deactivate_internal_admin_supervisor(
 '1b300000-0000-4000-8000-000000000001',
 '2b300000-0000-4000-8000-000000000001',
 '1b300000-0000-4000-8000-000000000007'
)$$,'internal admin deactivates zero-team supervisor');
select is((select count(*) from public.branch_memberships where user_id='1b300000-0000-4000-8000-000000000007' and active),0::bigint,
  'zero-team supervisor branch membership is inactive after deactivation');
select lives_ok($$select * from public.reactivate_internal_admin_supervisor(
 '1b300000-0000-4000-8000-000000000001',
 '2b300000-0000-4000-8000-000000000001',
 '1b300000-0000-4000-8000-000000000007'
)$$,'internal admin reactivates zero-team supervisor');
select ok(
  (select count(*) = 1 from public.branch_memberships where user_id='1b300000-0000-4000-8000-000000000007' and active)
  and (select count(*) = 0 from public.branch_operational_team_supervisors where supervisor_user_id='1b300000-0000-4000-8000-000000000007' and active),
  'zero-team supervisor reactivation restores branch access without team assignments'
);
select is(
  (select count(*) from public.list_internal_admin_supervisors('1b300000-0000-4000-8000-000000000001','2b300000-0000-4000-8000-000000000001') where email='legacy-supervisor@example.invalid' and active),
  1::bigint,
  'legacy supervisor appears in internal admin list'
);
select throws_ok($$select * from public.grant_existing_branch_supervisor(
 '1b300000-0000-4000-8000-000000000001',
 '2b300000-0000-4000-8000-000000000001',
 'existing-supervisor@example.invalid',
 array['3b300000-0000-4000-8000-000000000003'::uuid],
 pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object('operational_team_id','4b300000-0000-4000-8000-000000000003','assignment_role','backup'))
)$$,'22023','invalid branch assignment','cross-organization branch grant rejected');
select lives_ok($$select * from public.deactivate_internal_admin_supervisor(
 '1b300000-0000-4000-8000-000000000001',
 '2b300000-0000-4000-8000-000000000001',
 '1b300000-0000-4000-8000-000000000003'
)$$,'internal admin removes supervisor access');
select is(
  (select count(*) from public.branch_memberships where user_id='1b300000-0000-4000-8000-000000000003' and active),
  0::bigint,
  'supervisor branch access inactive after removal'
);
select ok(
  (select disabled_at is null from public.profiles where id='1b300000-0000-4000-8000-000000000003')
  and (select count(*) = 0 from public.branch_operational_team_supervisors where supervisor_user_id='1b300000-0000-4000-8000-000000000003' and active),
  'supervisor access removal does not disable profile and removes canonical write assignment'
);
select lives_ok($$select * from public.reactivate_internal_admin_supervisor(
 '1b300000-0000-4000-8000-000000000001',
 '2b300000-0000-4000-8000-000000000001',
 '1b300000-0000-4000-8000-000000000003'
)$$,'internal admin reactivates supervisor access');

select lives_ok($$select * from public.grant_existing_maintenance_user(
 '1b300000-0000-4000-8000-000000000001',
 '2b300000-0000-4000-8000-000000000001',
 'existing-maintenance@example.invalid'
)$$,'internal admin grants existing maintenance access');
select is(
  (select count(*) from public.maintenance_memberships where organization_id='2b300000-0000-4000-8000-000000000001' and user_id='1b300000-0000-4000-8000-000000000004' and active),
  1::bigint,
  'existing maintenance membership active'
);
select lives_ok($$select * from public.deactivate_maintenance_user(
 '1b300000-0000-4000-8000-000000000001',
 '2b300000-0000-4000-8000-000000000001',
 '1b300000-0000-4000-8000-000000000004'
)$$,'internal admin removes maintenance access');
select lives_ok($$select * from public.reactivate_maintenance_user(
 '1b300000-0000-4000-8000-000000000001',
 '2b300000-0000-4000-8000-000000000001',
 '1b300000-0000-4000-8000-000000000004'
)$$,'internal admin reactivates maintenance access');

select throws_ok($$select * from public.grant_existing_maintenance_user(
 '1b300000-0000-4000-8000-000000000005',
 '2b300000-0000-4000-8000-000000000001',
 'existing-maintenance@example.invalid'
)$$,'42501','maintenance user access denied','non-admin cannot grant existing maintenance access');

select * from finish();
rollback;
