begin;
select plan(28);

insert into public.organizations(id,name,slug)
values('12000000-0000-4000-8000-000000000040','Cold Boundary Test','cold-boundary-test');
insert into public.branches(id,organization_id,name,code,timezone)
values('32000000-0000-4000-8000-000000000040','12000000-0000-4000-8000-000000000040','Cold Boundary Branch','COLD-0400','Asia/Riyadh');

select is(private.phase4a_business_date_at('Asia/Riyadh','2026-09-04 00:59:59.999+00'::timestamptz),'2026-09-03'::date,'03:59:59.999 Riyadh is previous business date');
select is(private.phase4a_business_date_at('Asia/Riyadh','2026-09-04 01:00:00+00'::timestamptz),'2026-09-04'::date,'04:00 Riyadh starts current business date');
select is(private.phase4a_business_date_at('Asia/Riyadh','2026-09-04 01:00:00.001+00'::timestamptz),'2026-09-04'::date,'04:00:00.001 Riyadh is current business date');
select is(private.phase4a_business_date_at('Asia/Riyadh','2026-09-03 21:00:00+00'::timestamptz),'2026-09-03'::date,'midnight Riyadh is previous business date');
select is(private.phase4a_business_date_at('Asia/Riyadh','2026-09-04 20:59:00+00'::timestamptz),'2026-09-04'::date,'23:59 Riyadh is current business date');
select is(private.phase4a_business_date_at('Asia/Riyadh','2026-10-31 22:00:00+00'::timestamptz),'2026-10-31'::date,'month boundary before 04:00 remains previous month');
select is(private.phase4a_business_date_at('Asia/Riyadh','2026-12-31 22:00:00+00'::timestamptz),'2026-12-31'::date,'year boundary before 04:00 remains previous year');
select is(private.phase4a_business_date_at('Asia/Riyadh','2028-02-29 00:59:59.999+00'::timestamptz),'2028-02-28'::date,'leap-day pre-boundary remains previous date');
select is(private.phase4a_business_date_at('America/New_York','2026-01-15 08:59:59.999+00'::timestamptz),'2026-01-14'::date,'DST-capable timezone pre-boundary uses local wall clock');
select is(private.phase4a_business_date_at('America/New_York','2026-01-15 09:00:00+00'::timestamptz),'2026-01-15'::date,'DST-capable timezone boundary uses local wall clock');

select is((select first_eligible_business_date from private.cold_storage_master_first_eligible_slot('Asia/Riyadh','2026-09-04 00:30:00+00'::timestamptz)),'2026-09-04'::date,'equipment created at 03:30 starts on current calendar date');
select is((select first_eligible_slot from private.cold_storage_master_first_eligible_slot('Asia/Riyadh','2026-09-04 00:30:00+00'::timestamptz)),'12:00','equipment created at 03:30 starts at 12:00');
select is(private.cold_storage_eligible_slot_at('Asia/Riyadh','2026-09-03 22:59:59+00'::timestamptz),'20:00','01:59:59 Riyadh remains in the 20:00 slot');
select is(private.cold_storage_eligible_slot_at('Asia/Riyadh','2026-09-03 23:00:00+00'::timestamptz),'02:00','02:00 Riyadh opens the final slot');
select is(private.cold_storage_eligible_slot_at('Asia/Riyadh','2026-09-03 23:59:59+00'::timestamptz),'02:00','02:59:59 Riyadh remains in the final slot');
select is(private.cold_storage_eligible_slot_at('Asia/Riyadh','2026-09-04 00:00:00+00'::timestamptz),'02:00','03:00 Riyadh remains in the final slot');
select is(private.cold_storage_eligible_slot_at('Asia/Riyadh','2026-09-04 00:30:00+00'::timestamptz),'02:00','03:30 Riyadh remains in the final slot');
select is(private.cold_storage_eligible_slot_at('Asia/Riyadh','2026-09-04 00:59:59+00'::timestamptz),'02:00','03:59:59 Riyadh remains in the final slot');
select is(private.cold_storage_eligible_slot_at('Asia/Riyadh','2026-09-04 01:00:00+00'::timestamptz),null,'04:00 Riyadh closes the final slot');
select is(private.cold_storage_eligible_slot_at('Asia/Riyadh','2026-09-04 08:59:59+00'::timestamptz),null,'11:59:59 Riyadh has no active slot');
select is(private.cold_storage_eligible_slot_at('Asia/Riyadh','2026-09-04 09:00:00+00'::timestamptz),'12:00','12:00 Riyadh opens the midday slot');
select is(private.cold_storage_eligible_slot_at('Asia/Riyadh','2026-09-04 16:59:59+00'::timestamptz),'12:00','19:59:59 Riyadh remains in the midday slot');
select is(private.cold_storage_eligible_slot_at('Asia/Riyadh','2026-09-04 17:00:00+00'::timestamptz),'20:00','20:00 Riyadh opens the evening slot');
select is(private.cold_storage_closed_slots_for('32000000-0000-4000-8000-000000000040','2026-09-03','2026-09-04 00:59:59+00'),array['12:00','20:00']::text[],'03:59:59 does not close the final slot');
select is(private.cold_storage_missed_slots_for('32000000-0000-4000-8000-000000000040','2026-09-03',array[]::text[],'2026-09-04 00:59:59+00'),array['12:00','20:00']::text[],'03:59:59 does not mark the final slot missed');
select is(private.cold_storage_closed_slots_for('32000000-0000-4000-8000-000000000040','2026-09-03','2026-09-04 01:00:00+00'),array['12:00','20:00','02:00']::text[],'04:00 closes the final slot');
select is(private.cold_storage_missed_slots_for('32000000-0000-4000-8000-000000000040','2026-09-03',array[]::text[],'2026-09-04 01:00:00+00'),array['12:00','20:00','02:00']::text[],'04:00 marks an unsubmitted final slot missed');
select is(private.phase4a_business_date_at('Asia/Riyadh','2026-09-04 00:30:00+00'::timestamptz),'2026-09-03'::date,'Sales and Daily Audit canonical 03:30 date is previous day');

select * from finish();
rollback;
