-- Explicit committed fixture for the two-session Item Usage edit test.
-- No pgTAP assertions are used here. Never run against Production.
begin;

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000',id,'authenticated','authenticated',
  id||'@example.invalid','{}','{}',pg_catalog.now(),pg_catalog.now()
from unnest(array[
  'e1000000-0000-4000-8000-000000000001'::uuid,
  'e1000000-0000-4000-8000-000000000002'::uuid
]) id;

update public.profiles set full_name='Item Usage Edit Supervisor',must_change_password=false,disabled_at=null
where id='e1000000-0000-4000-8000-000000000001';
update public.profiles set full_name='Item Usage Other Branch Supervisor',must_change_password=false,disabled_at=null
where id='e1000000-0000-4000-8000-000000000002';

insert into public.organizations(id,name,slug)
values('e2000000-0000-4000-8000-000000000001','Item Usage Edit Org','item-usage-edit-runtime');
insert into private.daily_report_timezones(name)
values('Asia/Riyadh') on conflict(name) do nothing;
insert into public.branches(id,organization_id,name,code,timezone) values
  ('e3000000-0000-4000-8000-000000000001','e2000000-0000-4000-8000-000000000001','Item Usage Edit Branch','EUI1','Asia/Riyadh'),
  ('e3000000-0000-4000-8000-000000000002','e2000000-0000-4000-8000-000000000001','Item Usage Other Branch','EUI2','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role,active) values
  ('e3000000-0000-4000-8000-000000000001','e1000000-0000-4000-8000-000000000001','branch_manager',true),
  ('e3000000-0000-4000-8000-000000000002','e1000000-0000-4000-8000-000000000002','branch_manager',true);
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
  ('e4000000-0000-4000-8000-000000000001','e2000000-0000-4000-8000-000000000001','e3000000-0000-4000-8000-000000000001','e1000000-0000-4000-8000-000000000001'),
  ('e4000000-0000-4000-8000-000000000002','e2000000-0000-4000-8000-000000000001','e3000000-0000-4000-8000-000000000002','e1000000-0000-4000-8000-000000000002');
insert into public.branch_operational_teams(id,organization_id,branch_id,name) values
  ('e5000000-0000-4000-8000-000000000001','e2000000-0000-4000-8000-000000000001','e3000000-0000-4000-8000-000000000001','Item Usage Edit Team'),
  ('e5000000-0000-4000-8000-000000000002','e2000000-0000-4000-8000-000000000001','e3000000-0000-4000-8000-000000000002','Item Usage Other Team');
insert into public.branch_operational_team_supervisors(
  id,organization_id,branch_id,operational_team_id,supervisor_user_id,assignment_role,created_by
) values
  ('e5000000-0000-4000-8000-000000000011','e2000000-0000-4000-8000-000000000001','e3000000-0000-4000-8000-000000000001','e5000000-0000-4000-8000-000000000001','e1000000-0000-4000-8000-000000000001','primary','e1000000-0000-4000-8000-000000000001'),
  ('e5000000-0000-4000-8000-000000000012','e2000000-0000-4000-8000-000000000001','e3000000-0000-4000-8000-000000000002','e5000000-0000-4000-8000-000000000002','e1000000-0000-4000-8000-000000000002','primary','e1000000-0000-4000-8000-000000000002');

select public.save_inventory_items_draft(
  'e1000000-0000-4000-8000-000000000001',
  'e3000000-0000-4000-8000-000000000001',
  '[]'::jsonb,
  pg_catalog.jsonb_build_object(
    'usage_month',
      (pg_catalog.date_trunc('month',private.phase4a_business_date('Asia/Riyadh')) - interval '1 month')::date,
    'items', pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'item_id','e6000000-0000-4000-8000-000000000001',
        'group_name','Runtime',
        'item_name','Editable Usage',
        'usage',pg_catalog.jsonb_build_object('1','2','2','3')
      )
    )
  )
);

commit;
