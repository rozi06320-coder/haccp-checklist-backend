begin;
select plan(6);

select is(
  (select id from public.checklist_definitions where checklist_type='daily_audit'),
  'daily_audit_v1',
  'Daily Audit has the parent definition referenced by draft and submit'
);
select is(
  (select version from public.checklist_definitions where id='daily_audit_v1'),
  1,
  'Daily Audit parent definition is version 1'
);
select ok(
  exists(
    select 1
    from pg_constraint constraint_row
    join pg_attribute attribute_row
      on attribute_row.attrelid=constraint_row.conrelid
     and attribute_row.attnum=any(constraint_row.conkey)
    where constraint_row.conrelid='public.checklist_submissions'::regclass
      and constraint_row.contype='f'
      and constraint_row.confrelid='public.checklist_definitions'::regclass
      and attribute_row.attname='definition_id'
  ),
  'checklist submissions definition_id remains protected by the parent FK'
);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values (
  '00000000-0000-0000-0000-000000000000',
  '1f000000-0000-4000-8000-000000000001',
  'authenticated','authenticated','daily-audit-parent@example.invalid','{}','{}',now(),now()
);
update public.profiles
set full_name='Daily Audit Supervisor',must_change_password=false
where id='1f000000-0000-4000-8000-000000000001';
insert into public.organizations(id,name,slug)
values ('2f000000-0000-4000-8000-000000000001','Daily Audit Parent Org','daily-audit-parent-org');
insert into public.branches(id,organization_id,name,code,timezone)
values ('3f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','Daily Audit Parent Branch','DAP','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role)
values ('3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000001','branch_manager');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id)
values ('4f000000-0000-4000-8000-000000000001','2f000000-0000-4000-8000-000000000001','3f000000-0000-4000-8000-000000000001','1f000000-0000-4000-8000-000000000001');

select lives_ok(
  $$select public.save_supervisor_daily_audit_draft(
	    '1f000000-0000-4000-8000-000000000001',
	    '3f000000-0000-4000-8000-000000000001',
	    '2026-08-11',
	    0,
	    'manual_access_user',
    '5f000000-0000-4000-8000-000000000001',
    'Daily Audit Runner',
    '6f000000-0000-4000-8000-000000000001',
    '[]'::jsonb
  )$$,
  'the previously failing draft parent insert now succeeds'
);
select is(
  (select count(*) from public.checklist_submissions
    where branch_id='3f000000-0000-4000-8000-000000000001'
      and checklist_type='daily_audit'
      and definition_id='daily_audit_v1'
      and state='draft'),
  1::bigint,
  'draft stores the canonical Daily Audit parent definition'
);
select is(
  (select count(*) from public.daily_audit_item_results result
    join public.checklist_submissions submission on submission.id=result.submission_id
    where submission.branch_id='3f000000-0000-4000-8000-000000000001'),
  13::bigint,
  'draft normalizes all 13 item rows after the parent insert'
);

select * from finish();
rollback;
