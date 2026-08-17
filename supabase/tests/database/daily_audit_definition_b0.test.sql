begin;
select plan(5);

select is((select count(*)::integer from public.daily_audit_item_definitions where active),13,'Daily Audit has exactly 13 active definitions');
select is((select array_agg(item_number order by item_number)::integer[] from public.daily_audit_item_definitions where active),array[1,2,3,4,5,6,7,8,9,10,11,12,13]::integer[],'Daily Audit item numbers are contiguous');
select is((select count(*)::integer from public.daily_audit_item_definitions where item_id in ('daily-audit-1','daily-audit-2','daily-audit-3','daily-audit-4','daily-audit-5','daily-audit-6','daily-audit-7','daily-audit-8','daily-audit-9','daily-audit-10','daily-audit-11','daily-audit-12','daily-audit-13')),13,'Daily Audit IDs match the UI source');
select has_table('public','daily_audit_item_definitions','definition table exists');
set local role authenticated;
select throws_ok($$insert into public.daily_audit_item_definitions(item_id,item_number,item_label_en) values('should-fail',14,'Should fail')$$,'42501',null,'authenticated definition writes are denied');
reset role;

select * from finish();
rollback;
