begin;
select plan(45);

insert into auth.users(instance_id,id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
select '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
  id || '@example.invalid', '{}', '{}', now(), now()
from unnest(array[
  '1c000000-0000-4000-8000-000000000001'::uuid,
  '1c000000-0000-4000-8000-000000000002',
  '1c000000-0000-4000-8000-000000000003'
]) id;
update public.profiles set full_name = case id
  when '1c000000-0000-4000-8000-000000000001' then 'Oil Submit One'
  when '1c000000-0000-4000-8000-000000000002' then 'Oil Submit Two'
  else 'Oil Submit Staff'
end, must_change_password = false
where id::text like '1c000000-%';
insert into public.organizations(id,name,slug)
values('2c000000-0000-4000-8000-000000000001','Oil Submit Org','oil-submit-org');
insert into public.branches(id,organization_id,name,code,timezone)
values('3c000000-0000-4000-8000-000000000001','2c000000-0000-4000-8000-000000000001','Oil Submit Branch','OSC','Asia/Riyadh');
insert into public.branch_memberships(branch_id,user_id,role) values
 ('3c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000001','branch_manager'),
 ('3c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000002','branch_manager'),
 ('3c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000003','staff');
insert into public.branch_supervisor_teams(id,organization_id,branch_id,supervisor_user_id) values
 ('4c000000-0000-4000-8000-000000000001','2c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000001'),
 ('4c000000-0000-4000-8000-000000000002','2c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001','1c000000-0000-4000-8000-000000000002');

select has_table('public','oil_tracking_submission_idempotency','oil tracking idempotency table exists');
select has_table('public','oil_tracking_issues','oil tracking issue table exists');
select ok((select relrowsecurity from pg_class where oid = 'public.oil_tracking_submission_idempotency'::regclass),'oil idempotency RLS enabled');
select ok((select relrowsecurity from pg_class where oid = 'public.oil_tracking_issues'::regclass),'oil issue RLS enabled');
select is(has_function_privilege('authenticated','public.submit_oil_tracking_opening(uuid,uuid,bigint,uuid,text,jsonb)','execute'),false,'authenticated cannot execute oil opening submit RPC');
select is(has_function_privilege('service_role','public.submit_oil_tracking_opening(uuid,uuid,bigint,uuid,text,jsonb)','execute'),true,'service role can execute oil opening submit RPC');
select is(has_function_privilege('authenticated','public.submit_oil_tracking_closing(uuid,uuid,bigint,uuid,text,jsonb)','execute'),false,'authenticated cannot execute oil closing submit RPC');
select is(has_function_privilege('service_role','public.submit_oil_tracking_closing(uuid,uuid,bigint,uuid,text,jsonb)','execute'),true,'service role can execute oil closing submit RPC');
select ok(not has_table_privilege('authenticated','public.oil_tracking_submission_idempotency','insert')
  and not has_table_privilege('authenticated','public.oil_tracking_issues','insert')
  and not has_table_privilege('authenticated','public.oil_tracking_issues','update'),
  'authenticated role has no direct idempotency or issue writes');

select throws_ok($$
  select public.submit_oil_tracking_opening(
    '1c000000-0000-4000-8000-000000000001',
    '3c000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '5c000000-0000-4000-8000-000000000001',
    repeat('a',64),
    '[{"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1","fryer_short_label_snapshot":"F1","in_use_today":false,"oil_status":"pending","opening_status":"pending"}]'::jsonb
  )
$$, '22023', 'invalid oil tracking opening', 'opening requires at least one active fryer');
select throws_ok($$
  select public.submit_oil_tracking_opening(
    '1c000000-0000-4000-8000-000000000001',
    '3c000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '5c000000-0000-4000-8000-000000000002',
    repeat('a',64),
    '[{"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1","fryer_short_label_snapshot":"F1","in_use_today":true,"oil_status":"pending","opening_temperature_c":175,"opening_status":"pass"}]'::jsonb
  )
$$, '22023', 'invalid oil tracking opening', 'active opening requires oil status');
select throws_ok($$
  select public.submit_oil_tracking_opening(
    '1c000000-0000-4000-8000-000000000001',
    '3c000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '5c000000-0000-4000-8000-000000000003',
    repeat('a',64),
    '[{"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1","fryer_short_label_snapshot":"F1","in_use_today":true,"oil_status":"new_oil","opening_status":"pass"}]'::jsonb
  )
$$, '22023', 'invalid oil tracking opening', 'active opening requires temperature');
select throws_ok($$
  select public.submit_oil_tracking_opening(
    '1c000000-0000-4000-8000-000000000001',
    '3c000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '5c000000-0000-4000-8000-000000000004',
    repeat('a',64),
    '[{"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1","fryer_short_label_snapshot":"F1","in_use_today":true,"oil_status":"new_oil","opening_temperature_c":175,"opening_status":"pending"}]'::jsonb
  )
$$, '22023', 'invalid oil tracking opening', 'active opening requires pass or fail');
select throws_ok($$
  select public.submit_oil_tracking_opening(
    '1c000000-0000-4000-8000-000000000001',
    '3c000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '5c000000-0000-4000-8000-000000000005',
    repeat('a',64),
    '[{"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1","fryer_short_label_snapshot":"F1","in_use_today":true,"oil_status":"new_oil","opening_temperature_c":175,"opening_status":"fail","opening_note":"   "}]'::jsonb
  )
$$, '22023', 'invalid oil tracking opening', 'opening fail requires note');

select lives_ok($$
  select public.submit_oil_tracking_opening(
    '1c000000-0000-4000-8000-000000000001',
    '3c000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '5c000000-0000-4000-8000-000000000006',
    repeat('b',64),
    '[
      {"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1","fryer_short_label_snapshot":"F1","in_use_today":true,"oil_status":"new_oil","opening_temperature_c":175,"opening_status":"pass","closing_tpm_percent":20.9},
      {"fryer_id":"fryer-2","fryer_label_snapshot":"Fryer 2","fryer_short_label_snapshot":"F2","in_use_today":true,"oil_status":"filtered_oil","opening_temperature_c":"176.5","opening_status":"fail","opening_note":"replace filter"},
      {"fryer_id":"inactive","fryer_label_snapshot":"Inactive Fryer","fryer_short_label_snapshot":"IF","in_use_today":false,"oil_status":"pending","opening_status":"fail","opening_note":"","closing_tpm_percent":30}
    ]'::jsonb
  )
$$, 'successful opening submit');
select isnt(
  (select opening_submitted_at from public.oil_tracking_submissions where supervisor_team_id = '4c000000-0000-4000-8000-000000000001'),
  null,
  'opening submitted timestamp is set'
);
select is(
  (select count(*) from public.oil_tracking_issues where section = 'opening'
   and source_submission_id = (select id from public.oil_tracking_submissions where supervisor_team_id = '4c000000-0000-4000-8000-000000000001')),
  1::bigint,
  'active opening fail creates one issue and inactive fail is ignored'
);
select is(
  (select fryer_id from public.oil_tracking_issues where section = 'opening'
   and source_submission_id = (select id from public.oil_tracking_submissions where supervisor_team_id = '4c000000-0000-4000-8000-000000000001')),
  'fryer-2',
  'opening issue references failed active fryer'
);
select lives_ok($$
  select public.submit_oil_tracking_opening(
    '1c000000-0000-4000-8000-000000000001',
    '3c000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '5c000000-0000-4000-8000-000000000006',
    repeat('b',64),
    '[
      {"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1","fryer_short_label_snapshot":"F1","in_use_today":true,"oil_status":"new_oil","opening_temperature_c":175,"opening_status":"pass","closing_tpm_percent":20.9},
      {"fryer_id":"fryer-2","fryer_label_snapshot":"Fryer 2","fryer_short_label_snapshot":"F2","in_use_today":true,"oil_status":"filtered_oil","opening_temperature_c":"176.5","opening_status":"fail","opening_note":"replace filter"},
      {"fryer_id":"inactive","fryer_label_snapshot":"Inactive Fryer","fryer_short_label_snapshot":"IF","in_use_today":false,"oil_status":"pending","opening_status":"fail","opening_note":"","closing_tpm_percent":30}
    ]'::jsonb
  )
$$, 'opening idempotent replay with same hash succeeds');
select is(
  (select count(*) from public.oil_tracking_issues where section = 'opening'
   and source_submission_id = (select id from public.oil_tracking_submissions where supervisor_team_id = '4c000000-0000-4000-8000-000000000001')),
  1::bigint,
  'opening replay does not duplicate issue'
);
select throws_ok($$
  select public.submit_oil_tracking_opening(
    '1c000000-0000-4000-8000-000000000001',
    '3c000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '5c000000-0000-4000-8000-000000000006',
    repeat('c',64),
    '[{"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1","fryer_short_label_snapshot":"F1","in_use_today":true,"oil_status":"new_oil","opening_temperature_c":175,"opening_status":"pass"}]'::jsonb
  )
$$, '23505', 'idempotency conflict', 'opening idempotent replay with changed hash is rejected');
select throws_ok($$
  select public.submit_oil_tracking_opening(
    '1c000000-0000-4000-8000-000000000001',
    '3c000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '5c000000-0000-4000-8000-000000000007',
    repeat('d',64),
    '[{"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1","fryer_short_label_snapshot":"F1","in_use_today":true,"oil_status":"new_oil","opening_temperature_c":175,"opening_status":"pass"}]'::jsonb
  )
$$, '23505', 'submitted oil tracking row set is immutable', 'second opening submit with new key is rejected');

select lives_ok($$
  select public.save_oil_tracking_draft(
    '1c000000-0000-4000-8000-000000000001',
    '3c000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '[
      {"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1 changed","fryer_short_label_snapshot":"F1X","in_use_today":true,"oil_status":"filtered_oil","opening_temperature_c":199,"opening_status":"fail","opening_note":"changed opening","closing_tpm_percent":20.9},
      {"fryer_id":"fryer-2","fryer_label_snapshot":"Fryer 2 changed","fryer_short_label_snapshot":"F2X","in_use_today":true,"oil_status":"new_oil","opening_temperature_c":199,"opening_status":"pass","opening_note":"","closing_tpm_percent":21,"closing_note":"nearing"},
      {"fryer_id":"inactive","fryer_label_snapshot":"Inactive Fryer changed","fryer_short_label_snapshot":"IFX","in_use_today":false,"oil_status":"new_oil","opening_temperature_c":199,"opening_status":"pass","closing_tpm_percent":30,"closing_note":"ignored"}
    ]'::jsonb
  )
$$, 'draft after opening submit can update unsubmitted closing fields');
select is(
  (select opening_status from public.oil_tracking_fryer_results r
   join public.oil_tracking_submissions s on s.id = r.submission_id
   where s.supervisor_team_id = '4c000000-0000-4000-8000-000000000001' and r.fryer_id = 'fryer-1'),
  'pass',
  'opening fields remain immutable after draft save'
);
select is(
  (select closing_tpm_percent from public.oil_tracking_fryer_results r
   join public.oil_tracking_submissions s on s.id = r.submission_id
   where s.supervisor_team_id = '4c000000-0000-4000-8000-000000000001' and r.fryer_id = 'fryer-2'),
  21::numeric,
  'unsubmitted closing fields are updated by draft save'
);

select throws_ok($$
  select public.submit_oil_tracking_closing(
    '1c000000-0000-4000-8000-000000000001',
    '3c000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '5c000000-0000-4000-8000-000000000008',
    repeat('e',64),
    '[{"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1","fryer_short_label_snapshot":"F1","in_use_today":false,"oil_status":"new_oil","opening_status":"pass","closing_tpm_percent":20}]'::jsonb
  )
$$, '22023', 'invalid oil tracking closing', 'closing requires at least one active fryer');
select throws_ok($$
  select public.submit_oil_tracking_closing(
    '1c000000-0000-4000-8000-000000000001',
    '3c000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '5c000000-0000-4000-8000-000000000009',
    repeat('e',64),
    '[{"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1","fryer_short_label_snapshot":"F1","in_use_today":true,"oil_status":"new_oil","opening_status":"pass"}]'::jsonb
  )
$$, '22023', 'invalid oil tracking closing', 'closing requires TPM for active fryer');
select throws_ok($$
  select public.submit_oil_tracking_closing(
    '1c000000-0000-4000-8000-000000000001',
    '3c000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '5c000000-0000-4000-8000-000000000010',
    repeat('e',64),
    '[{"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1","fryer_short_label_snapshot":"F1","in_use_today":true,"oil_status":"new_oil","opening_status":"pass","closing_tpm_percent":21}]'::jsonb
  )
$$, '22023', 'invalid oil tracking closing', 'closing TPM at 21 requires note');

select lives_ok($$
  select public.submit_oil_tracking_closing(
    '1c000000-0000-4000-8000-000000000001',
    '3c000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '5c000000-0000-4000-8000-000000000011',
    repeat('f',64),
    '[
      {"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1 new label","fryer_short_label_snapshot":"F1N","in_use_today":true,"oil_status":"filtered_oil","opening_temperature_c":199,"opening_status":"fail","opening_note":"changed","closing_tpm_percent":20.9},
      {"fryer_id":"fryer-2","fryer_label_snapshot":"Fryer 2 new label","fryer_short_label_snapshot":"F2N","in_use_today":true,"oil_status":"filtered_oil","opening_temperature_c":199,"opening_status":"pass","closing_tpm_percent":21,"closing_note":"nearing"},
      {"fryer_id":"inactive","fryer_label_snapshot":"Inactive Fryer","fryer_short_label_snapshot":"IF","in_use_today":false,"oil_status":"filtered_oil","opening_status":"pass","closing_tpm_percent":30}
    ]'::jsonb
  )
$$, 'successful closing submit');
select is(
  (select state from public.oil_tracking_submissions where supervisor_team_id = '4c000000-0000-4000-8000-000000000001'),
  'submitted',
  'oil tracking submission is submitted after both sections'
);
select isnt(
  (select closing_submitted_at from public.oil_tracking_submissions where supervisor_team_id = '4c000000-0000-4000-8000-000000000001'),
  null,
  'closing submitted timestamp is set'
);
select is(
  (select opening_status from public.oil_tracking_fryer_results r
   join public.oil_tracking_submissions s on s.id = r.submission_id
   where s.supervisor_team_id = '4c000000-0000-4000-8000-000000000001' and r.fryer_id = 'fryer-1'),
  'pass',
  'closing submit cannot change submitted opening fields'
);
select is(
  (select count(*) from public.oil_tracking_issues where section = 'closing'
   and source_submission_id = (select id from public.oil_tracking_submissions where supervisor_team_id = '4c000000-0000-4000-8000-000000000001')),
  1::bigint,
  'TPM 21 creates issue and TPM 20.9 plus inactive high TPM do not'
);
select is(
  (select tpm_status from public.oil_tracking_issues where section = 'closing'
   and source_submission_id = (select id from public.oil_tracking_submissions where supervisor_team_id = '4c000000-0000-4000-8000-000000000001')),
  'nearing_end',
  'TPM 21 maps to nearing end'
);
select lives_ok($$
  select public.submit_oil_tracking_closing(
    '1c000000-0000-4000-8000-000000000001',
    '3c000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '5c000000-0000-4000-8000-000000000011',
    repeat('f',64),
    '[
      {"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1 new label","fryer_short_label_snapshot":"F1N","in_use_today":true,"oil_status":"filtered_oil","opening_temperature_c":199,"opening_status":"fail","opening_note":"changed","closing_tpm_percent":20.9},
      {"fryer_id":"fryer-2","fryer_label_snapshot":"Fryer 2 new label","fryer_short_label_snapshot":"F2N","in_use_today":true,"oil_status":"filtered_oil","opening_temperature_c":199,"opening_status":"pass","closing_tpm_percent":21,"closing_note":"nearing"},
      {"fryer_id":"inactive","fryer_label_snapshot":"Inactive Fryer","fryer_short_label_snapshot":"IF","in_use_today":false,"oil_status":"filtered_oil","opening_status":"pass","closing_tpm_percent":30}
    ]'::jsonb
  )
$$, 'closing idempotent replay with same hash succeeds');
select throws_ok($$
  select public.submit_oil_tracking_closing(
    '1c000000-0000-4000-8000-000000000001',
    '3c000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '5c000000-0000-4000-8000-000000000011',
    repeat('0',64),
    '[{"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1","fryer_short_label_snapshot":"F1","in_use_today":true,"oil_status":"new_oil","opening_status":"pass","closing_tpm_percent":20}]'::jsonb
  )
$$, '23505', 'idempotency conflict', 'closing idempotent replay with changed hash is rejected');
select throws_ok($$
  select public.save_oil_tracking_draft(
    '1c000000-0000-4000-8000-000000000001',
    '3c000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1c000000-0000-4000-8000-000000000001','3c000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '[{"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1","fryer_short_label_snapshot":"F1","in_use_today":true,"oil_status":"new_oil","opening_temperature_c":175,"opening_status":"pass","closing_tpm_percent":20}]'::jsonb
  )
$$, '23505', 'submitted oil tracking row set is immutable', 'submitted row set cannot be changed by draft save');

select is(
  jsonb_array_length(public.get_oil_tracking_current_state('1c000000-0000-4000-8000-000000000002','3c000000-0000-4000-8000-000000000001')->'rows'),
  3,
  'same-branch other supervisor reads branch-shared submitted oil state'
);
select is(
  public.get_oil_tracking_current_state('1c000000-0000-4000-8000-000000000002','3c000000-0000-4000-8000-000000000001')->>'opening_submitted',
  'true',
  'same-branch shared oil state shows opening submitted'
);
select is(
  public.get_oil_tracking_current_state('1c000000-0000-4000-8000-000000000002','3c000000-0000-4000-8000-000000000001')->>'closing_submitted',
  'true',
  'same-branch shared oil state shows closing submitted'
);
select throws_ok($$
  select public.save_oil_tracking_draft(
    '1c000000-0000-4000-8000-000000000002',
    '3c000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1c000000-0000-4000-8000-000000000002','3c000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '[{"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1","fryer_short_label_snapshot":"F1","in_use_today":true,"oil_status":"new_oil","opening_temperature_c":175,"opening_status":"pass","closing_tpm_percent":20}]'::jsonb
  )
$$, '23505', 'submitted oil tracking row set is immutable', 'same-branch supervisor cannot mutate submitted branch-shared oil state by draft'
);
select throws_ok($$
  select public.submit_oil_tracking_opening(
    '1c000000-0000-4000-8000-000000000002',
    '3c000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1c000000-0000-4000-8000-000000000002','3c000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '5c000000-0000-4000-8000-000000000012',
    repeat('1',64),
    '[{"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1","fryer_short_label_snapshot":"F1","in_use_today":true,"oil_status":"new_oil","opening_temperature_c":175,"opening_status":"pass"}]'::jsonb
  )
$$, '23505', 'submitted oil tracking row set is immutable', 'same-branch supervisor cannot resubmit branch-shared opening'
);
select throws_ok($$
  select public.submit_oil_tracking_closing(
    '1c000000-0000-4000-8000-000000000002',
    '3c000000-0000-4000-8000-000000000001',
    (public.get_oil_tracking_current_state('1c000000-0000-4000-8000-000000000002','3c000000-0000-4000-8000-000000000001')->>'revision')::bigint,
    '5c000000-0000-4000-8000-000000000013',
    repeat('2',64),
    '[{"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1","fryer_short_label_snapshot":"F1","in_use_today":true,"oil_status":"new_oil","opening_status":"pass","closing_tpm_percent":20}]'::jsonb
  )
$$, '23505', 'submitted oil tracking row set is immutable', 'same-branch supervisor cannot resubmit branch-shared closing'
);
select is(
  (select count(*) from public.oil_tracking_submissions where branch_id = '3c000000-0000-4000-8000-000000000001'),
  1::bigint,
  'branch-shared oil model keeps one submission row for the branch day'
);
select throws_ok($$
  select public.submit_oil_tracking_opening(
    '1c000000-0000-4000-8000-000000000003',
    '3c000000-0000-4000-8000-000000000001',
    0,
    '5c000000-0000-4000-8000-000000000014',
    repeat('2',64),
    '[{"fryer_id":"fryer-1","fryer_label_snapshot":"Fryer 1","fryer_short_label_snapshot":"F1","in_use_today":true,"oil_status":"new_oil","opening_temperature_c":175,"opening_status":"pass"}]'::jsonb
  )
$$, '42501', 'oil tracking operation denied', 'staff actor cannot submit opening');

select * from finish();
rollback;
