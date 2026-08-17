begin;
select plan(27);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
  id || '@example.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1b000000-0000-4000-8000-000000000001'::uuid,
  '1b000000-0000-4000-8000-000000000002',
  '1b000000-0000-4000-8000-000000000003'
]) id;
update public.profiles set full_name = case id
  when '1b000000-0000-4000-8000-000000000001' then 'Oil Supervisor One'
  when '1b000000-0000-4000-8000-000000000002' then 'Oil Supervisor Two'
  else 'Oil Staff'
end, must_change_password = false
where id::text like '1b000000-%';
insert into public.organizations(id,name,slug)
values('2b000000-0000-4000-8000-000000000001','Oil Tracking Org','oil-tracking-org');
insert into public.branches(id,organization_id,name,code,timezone)
values('3b000000-0000-4000-8000-000000000001','2b000000-0000-4000-8000-000000000001','Oil Branch','OIL','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role) values
 ('3b000000-0000-4000-8000-000000000001','1b000000-0000-4000-8000-000000000001','branch_manager'),
 ('3b000000-0000-4000-8000-000000000001','1b000000-0000-4000-8000-000000000002','branch_manager'),
 ('3b000000-0000-4000-8000-000000000001','1b000000-0000-4000-8000-000000000003','staff');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
 ('4b000000-0000-4000-8000-000000000001','2b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001','1b000000-0000-4000-8000-000000000001'),
 ('4b000000-0000-4000-8000-000000000002','2b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001','1b000000-0000-4000-8000-000000000002');

select has_table('public','oil_tracking_submissions','oil tracking submission table exists');
select has_table('public','oil_tracking_fryer_results','oil tracking fryer result table exists');
select col_is_pk('public','oil_tracking_submissions','id','oil submission UUID PK');
select col_is_pk('public','oil_tracking_fryer_results','id','oil fryer UUID PK');
select ok((select relrowsecurity from pg_class where oid = 'public.oil_tracking_submissions'::regclass),'oil submission RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.oil_tracking_fryer_results'::regclass),'oil fryer RLS enabled');
select is(has_function_privilege('authenticated','public.save_oil_tracking_draft(uuid,uuid,bigint,jsonb)','execute'),false,'authenticated cannot execute oil draft RPC');
select is(has_function_privilege('service_role','public.save_oil_tracking_draft(uuid,uuid,bigint,jsonb)','execute'),true,'service role can execute oil draft RPC');
select ok(not has_table_privilege('authenticated','public.oil_tracking_submissions','insert')
  and not has_table_privilege('authenticated','public.oil_tracking_fryer_results','insert')
  and not has_table_privilege('authenticated','public.oil_tracking_submissions','update')
  and not has_table_privilege('authenticated','public.oil_tracking_fryer_results','delete'),
  'authenticated role has no direct oil tracking writes');

select is(
  public.get_oil_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->>'business_date',
  private.phase4a_business_date('Asia/Riyadh')::text,
  'empty state uses server business date'
);
select is(
  jsonb_array_length(public.get_oil_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->'rows'),
  0,
  'empty current state has no rows'
);
select is(
  public.get_oil_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->>'opening_submitted',
  'false',
  'empty current state is not opening-submitted'
);
select is(
  public.get_oil_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->>'closing_submitted',
  'false',
  'empty current state is not closing-submitted'
);

select lives_ok($$
  select public.save_oil_tracking_draft(
    '1b000000-0000-4000-8000-000000000001',
    '3b000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '[
      {"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1","fryer_short_label_snapshot":"F1","in_use_today":true,"oil_status":"new_oil","opening_temperature_c":"175.5","opening_status":"pass","opening_note":null,"closing_tpm_percent":"","closing_note":" closing note "},
      {"fryer_id":"fryer-2","fryer_label_snapshot":"Fryer 2","fryer_short_label_snapshot":"F2","in_use_today":false,"oil_status":"pending","opening_temperature_c":null,"opening_status":"pending"}
    ]'::jsonb
  )
$$, 'supervisor saves oil tracking draft');
select is(
  (select count(*) from public.oil_tracking_submissions
   where organization_id = '2b000000-0000-4000-8000-000000000001'
     and branch_id = '3b000000-0000-4000-8000-000000000001'
     and supervisor_team_id = '4b000000-0000-4000-8000-000000000001'),
  1::bigint,
  'one oil tracking submission row saved'
);
select is(
  (select business_date from public.oil_tracking_submissions
   where supervisor_team_id = '4b000000-0000-4000-8000-000000000001'),
  private.phase4a_business_date('Asia/Riyadh'),
  'draft business date is server-calculated'
);
select is(
  (select branch_name_snapshot || '|' || supervisor_name_snapshot || '|' || team_name_snapshot
   from public.oil_tracking_submissions where supervisor_team_id = '4b000000-0000-4000-8000-000000000001'),
  'Oil Branch|Oil Supervisor One|Oil Supervisor One Team',
  'snapshots are populated from verified server context'
);
select is(
  jsonb_array_length(public.get_oil_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->'rows'),
  2,
  'current state restores saved fryer rows'
);
select is(
  public.get_oil_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->'rows'->0->>'opening_temperature_c',
  '175.5',
  'numeric string restores as numeric JSON'
);
select is(
  public.get_oil_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->'rows'->0->>'opening_note',
  '',
  'missing or null note defaults to empty string'
);
select is(
  jsonb_array_length(public.get_oil_tracking_current_state('1b000000-0000-4000-8000-000000000002','3b000000-0000-4000-8000-000000000001')->'rows'),
  2,
  'same-branch other supervisor can read branch-shared oil draft'
);
select throws_ok($$
  select public.get_oil_tracking_current_state('1b000000-0000-4000-8000-000000000003','3b000000-0000-4000-8000-000000000001')
$$, '42501', 'oil tracking state denied', 'staff actor is denied');

select lives_ok($$
  select public.save_oil_tracking_draft(
    '1b000000-0000-4000-8000-000000000001',
    '3b000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '[{"fryer_id":"fryer-3","fryer_label_snapshot":"Fryer 3","fryer_short_label_snapshot":"F3","in_use_today":true,"oil_status":"filtered_oil","opening_temperature_c":180,"opening_status":"fail","opening_note":"filter","closing_tpm_percent":21.5,"closing_note":"filter again"}]'::jsonb
  )
$$, 'second draft save succeeds');
select is(
  (select count(*) from public.oil_tracking_fryer_results r
   join public.oil_tracking_submissions s on s.id = r.submission_id
   where s.supervisor_team_id = '4b000000-0000-4000-8000-000000000001'),
  1::bigint,
  'second draft replaces fryer rows instead of duplicating'
);
select is(
  public.get_oil_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->'rows'->0->>'fryer_id',
  'fryer-3',
  'replacement row is restored'
);
select throws_ok($$
  select public.save_oil_tracking_draft(
    '1b000000-0000-4000-8000-000000000001',
    '3b000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '[{"fryer_id":"fryer-4","fryer_label_snapshot":"Fryer 4","fryer_short_label_snapshot":"F4","in_use_today":true,"oil_status":"used_oil","opening_status":"pass"}]'::jsonb
  )
$$, '22023', 'invalid oil tracking row', 'invalid enum values are rejected');
select throws_ok($$
  select public.save_oil_tracking_draft(
    '1b000000-0000-4000-8000-000000000001',
    '3b000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1b000000-0000-4000-8000-000000000001','3b000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '[{"fryer_id":"fryer-4","fryer_label_snapshot":"Fryer 4","fryer_short_label_snapshot":"F4","in_use_today":true,"oil_status":"new_oil","opening_status":"pass","opening_temperature_c":"hot"}]'::jsonb
  )
$$, '22023', 'invalid oil tracking numeric field', 'invalid numeric values are rejected');

select * from finish();
rollback;
