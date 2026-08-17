begin;
select plan(15);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated', email, '{}', '{}', now(), now()
from (values
  ('1b500000-0000-4000-8000-000000000001'::uuid, 'internal-admin@example.invalid'),
  ('1b500000-0000-4000-8000-000000000002'::uuid, 'manager@example.invalid'),
  ('1b500000-0000-4000-8000-000000000003'::uuid, 'supervisor@example.invalid'),
  ('1b500000-0000-4000-8000-000000000004'::uuid, 'not-admin@example.invalid')
) users(id,email);

update public.profiles
set full_name = case id
  when '1b500000-0000-4000-8000-000000000001' then 'Internal Admin'
  when '1b500000-0000-4000-8000-000000000002' then 'Organization Manager'
  when '1b500000-0000-4000-8000-000000000003' then 'Branch Supervisor'
  else 'Not Admin'
end,
must_change_password = false,
disabled_at = null
where id::text like '1b500000-%';

insert into public.internal_admin_memberships(user_id, active)
values ('1b500000-0000-4000-8000-000000000001', true);

insert into public.organizations(id,name,slug) values
 ('2b500000-0000-4000-8000-000000000001','Branding Org','branding-org'),
 ('2b500000-0000-4000-8000-000000000002','Other Org','other-branding-org');

insert into public.branches(id,organization_id,name,code,timezone) values
 ('3b500000-0000-4000-8000-000000000001','2b500000-0000-4000-8000-000000000001','Branding Branch','BRND','Asia/Riyadh'),
 ('3b500000-0000-4000-8000-000000000002','2b500000-0000-4000-8000-000000000002','Other Branch','OTHR','Asia/Riyadh');

insert into public.organization_memberships(organization_id,user_id,role,active)
values ('2b500000-0000-4000-8000-000000000001','1b500000-0000-4000-8000-000000000002','organization_manager',true);

insert into public.branch_memberships(branch_id,user_id,role,active)
values ('3b500000-0000-4000-8000-000000000001','1b500000-0000-4000-8000-000000000003','branch_manager',true);

select ok((select not public and file_size_limit=5242880 and allowed_mime_types=array['image/jpeg','image/png','image/webp'] from storage.buckets where id='branding-assets'),'branding bucket is private and image bounded');
select col_is_null('public','organizations','logo_path','organizations.logo_path is nullable');
select col_is_null('public','branches','logo_path','branches.logo_path is nullable');
select ok(has_function_privilege('service_role','public.update_internal_admin_organization_logo(uuid,uuid,text)','execute'),'service role can execute organization branding update');
select ok(not has_function_privilege('authenticated','public.update_internal_admin_organization_logo(uuid,uuid,text)','execute'),'authenticated cannot execute organization branding update');
select ok(has_function_privilege('service_role','public.update_internal_admin_branch_logo(uuid,uuid,uuid,text)','execute'),'service role can execute branch branding update');
select ok(not has_function_privilege('authenticated','public.update_internal_admin_branch_logo(uuid,uuid,uuid,text)','execute'),'authenticated cannot execute branch branding update');

select lives_ok($$select * from public.update_internal_admin_organization_logo(
 '1b500000-0000-4000-8000-000000000001',
 '2b500000-0000-4000-8000-000000000001',
 'organizations/2b500000-0000-4000-8000-000000000001/logo/4b500000-0000-4000-8000-000000000001.png'
)$$,'internal admin updates organization logo path');
select is(
  (select logo_path from public.organizations where id='2b500000-0000-4000-8000-000000000001'),
  'organizations/2b500000-0000-4000-8000-000000000001/logo/4b500000-0000-4000-8000-000000000001.png',
  'organization logo path persisted'
);
select lives_ok($$select * from public.update_internal_admin_branch_logo(
 '1b500000-0000-4000-8000-000000000001',
 '2b500000-0000-4000-8000-000000000001',
 '3b500000-0000-4000-8000-000000000001',
 'branches/3b500000-0000-4000-8000-000000000001/logo/4b500000-0000-4000-8000-000000000002.webp'
)$$,'internal admin updates branch logo path');
select is(
  (select logo_path from public.branches where id='3b500000-0000-4000-8000-000000000001'),
  'branches/3b500000-0000-4000-8000-000000000001/logo/4b500000-0000-4000-8000-000000000002.webp',
  'branch logo path persisted'
);
select throws_ok($$select * from public.update_internal_admin_organization_logo(
 '1b500000-0000-4000-8000-000000000004',
 '2b500000-0000-4000-8000-000000000001',
 'organizations/2b500000-0000-4000-8000-000000000001/logo/4b500000-0000-4000-8000-000000000003.png'
)$$,'42501','invalid branding request','non-admin cannot update organization logo');
select throws_ok($$select * from public.update_internal_admin_branch_logo(
 '1b500000-0000-4000-8000-000000000001',
 '2b500000-0000-4000-8000-000000000001',
 '3b500000-0000-4000-8000-000000000002',
 'branches/3b500000-0000-4000-8000-000000000002/logo/4b500000-0000-4000-8000-000000000004.png'
)$$,'42501','invalid branding request','branch must belong to target organization');
select is(
  (select organization_logo_path from public.get_management_organization_branding('1b500000-0000-4000-8000-000000000002','2b500000-0000-4000-8000-000000000001')),
  'organizations/2b500000-0000-4000-8000-000000000001/logo/4b500000-0000-4000-8000-000000000001.png',
  'manager can read authorized organization branding path'
);
select is(
  (select branch_logo_path from public.get_supervisor_branch_branding('1b500000-0000-4000-8000-000000000003','3b500000-0000-4000-8000-000000000001')),
  'branches/3b500000-0000-4000-8000-000000000001/logo/4b500000-0000-4000-8000-000000000002.webp',
  'supervisor can read authorized branch branding path'
);

select * from finish();
rollback;
