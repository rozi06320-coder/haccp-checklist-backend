begin;
select plan(15);

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
select is(private.cold_storage_eligible_slot_at('Asia/Riyadh','2026-09-03 23:59:59.999+00'::timestamptz),'02:00','fixed 02:00 slot is eligible immediately before 03:00');
select is(private.cold_storage_eligible_slot_at('Asia/Riyadh','2026-09-04 00:00:00+00'::timestamptz),null,'fixed 02:00 slot closes at 03:00');
select is(private.phase4a_business_date_at('Asia/Riyadh','2026-09-04 00:30:00+00'::timestamptz),'2026-09-03'::date,'Sales and Daily Audit canonical 03:30 date is previous day');

select * from finish();
rollback;
