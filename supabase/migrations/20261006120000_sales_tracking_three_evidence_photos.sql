begin;

alter table public.sales_tracking_attachments
  add column display_order smallint;

update public.sales_tracking_attachments set display_order=1 where display_order is null;

alter table public.sales_tracking_attachments
  alter column display_order set not null,
  add constraint sales_tracking_attachments_display_order_check check(display_order between 1 and 3);

drop index if exists public.sales_tracking_attachments_active_report_uidx;
create unique index sales_tracking_attachments_active_position_uidx
  on public.sales_tracking_attachments(report_id,display_order) where deleted_at is null;

create or replace function private.sales_tracking_attachment_json(target_report_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select case when attachment.id is null then null else pg_catalog.jsonb_build_object(
  'id',attachment.id,'storage_path',attachment.storage_path,'original_filename',attachment.original_filename,
  'mime_type',attachment.mime_type,'size_bytes',attachment.size_bytes,'created_at',attachment.created_at,
  'display_order',attachment.display_order)
 end from(select 1)seed left join lateral(
  select a.* from public.sales_tracking_attachments a
  where a.report_id=target_report_id and a.deleted_at is null
  order by a.display_order,a.created_at,a.id limit 1
 )attachment on true
$$;

create function private.sales_tracking_attachments_json(target_report_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
  'id',a.id,'storage_path',a.storage_path,'original_filename',a.original_filename,
  'mime_type',a.mime_type,'size_bytes',a.size_bytes,'created_at',a.created_at,
  'display_order',a.display_order) order by a.display_order,a.created_at,a.id),'[]'::jsonb)
 from public.sales_tracking_attachments a
 where a.report_id=target_report_id and a.deleted_at is null
$$;
revoke all on function private.sales_tracking_attachments_json(uuid) from public,anon,authenticated;

create function public.prepare_sales_tracking_attachment_upload(
 actor_user_id uuid,target_branch_id uuid,target_business_date date,target_report_id uuid,
 expected_revision bigint,attachment_id uuid,attachment_mime_type text,replacement_attachment_id uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;replacement public.sales_tracking_attachments%rowtype;active_count integer;
begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 if target_business_date is null or target_business_date>c.business_date then raise exception'invalid sales tracking business date'using errcode='22023';end if;
 if attachment_id is null or attachment_mime_type not in('image/jpeg','image/png','image/webp')then raise exception'invalid sales tracking attachment'using errcode='22023';end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||target_business_date::text||':sales_tracking',0));
 if target_report_id is null then
  select e.report_id into target_report_id from public.ensure_sales_tracking_draft_report(actor_user_id,target_branch_id,target_business_date)e;
 end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||target_report_id::text||':sales_tracking_photo',0));
 select*into s from public.sales_tracking_reports r where r.id=target_report_id and r.organization_id=c.organization_id and r.branch_id=c.branch_id and r.business_date=target_business_date for update;
 if not found then raise exception'sales tracking report not found'using errcode='P0002';end if;
 if s.state<>'draft'then raise exception'sales tracking already submitted'using errcode='23505';end if;
 if s.branch_revision<>expected_revision then raise sqlstate'PT409'using message='sales tracking changed';end if;
 select count(*)into active_count from public.sales_tracking_attachments a where a.report_id=s.id and a.deleted_at is null;
 if replacement_attachment_id is not null then
  select*into replacement from public.sales_tracking_attachments a where a.id=replacement_attachment_id and a.report_id=s.id and a.deleted_at is null for update;
  if not found then raise exception'sales tracking attachment not found'using errcode='P0002';end if;
 elsif active_count>=3 then raise exception'maximum sales tracking photos reached'using errcode='23505';
 end if;
 return pg_catalog.jsonb_build_object('report_id',s.id,'organization_id',s.organization_id,'branch_id',s.branch_id,
  'business_date',s.business_date,'revision',s.branch_revision,'attachment_id',attachment_id);
exception when no_data_found or too_many_rows then raise exception'sales tracking photo denied'using errcode='42501';end$$;

create function public.finalize_sales_tracking_attachment_v2(
 actor_user_id uuid,target_branch_id uuid,target_report_id uuid,expected_revision bigint,
 attachment_id uuid,attachment_metadata jsonb,replacement_attachment_id uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;replacement public.sales_tracking_attachments%rowtype;created public.sales_tracking_attachments%rowtype;active_count integer;selected_order smallint;
begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||target_report_id::text||':sales_tracking_photo',0));
 select*into s from public.sales_tracking_reports r where r.id=target_report_id and r.organization_id=c.organization_id and r.branch_id=c.branch_id for update;
 if not found then raise exception'sales tracking report not found'using errcode='P0002';end if;
 if s.state<>'draft'then raise exception'sales tracking already submitted'using errcode='23505';end if;
 if s.branch_revision<>expected_revision then raise sqlstate'PT409'using message='sales tracking changed';end if;
 if attachment_metadata->>'storage_path'<>c.organization_id::text||'/'||c.branch_id::text||'/sales-tracking/'||s.id::text||'/'||attachment_id::text||(case attachment_metadata->>'mime_type' when'image/jpeg'then'.jpg'when'image/png'then'.png'when'image/webp'then'.webp'else''end)then raise exception'invalid sales tracking attachment path'using errcode='22023';end if;
 perform 1 from public.sales_tracking_attachments a where a.report_id=s.id and a.deleted_at is null for update;
 select count(*)into active_count from public.sales_tracking_attachments a where a.report_id=s.id and a.deleted_at is null;
 if replacement_attachment_id is not null then
  select*into replacement from public.sales_tracking_attachments a where a.id=replacement_attachment_id and a.report_id=s.id and a.deleted_at is null for update;
  if not found then raise exception'sales tracking attachment not found'using errcode='P0002';end if;
  selected_order:=replacement.display_order;
  update public.sales_tracking_attachments set deleted_at=now(),deleted_by_user_id=actor_user_id where id=replacement.id;
 else
  if active_count>=3 then raise exception'maximum sales tracking photos reached'using errcode='23505';end if;
  select candidate into selected_order from pg_catalog.generate_series(1,3)candidate
   where not exists(select 1 from public.sales_tracking_attachments a where a.report_id=s.id and a.deleted_at is null and a.display_order=candidate)
   order by candidate limit 1;
 end if;
 insert into public.sales_tracking_attachments(id,organization_id,branch_id,report_id,storage_path,original_filename,mime_type,size_bytes,uploaded_by_user_id,display_order)
 values(attachment_id,c.organization_id,c.branch_id,s.id,attachment_metadata->>'storage_path',attachment_metadata->>'original_filename',attachment_metadata->>'mime_type',(attachment_metadata->>'size_bytes')::bigint,actor_user_id,selected_order)returning*into created;
 return pg_catalog.jsonb_build_object('attachments',private.sales_tracking_attachments_json(s.id),'old_storage_path',replacement.storage_path);
exception when no_data_found or too_many_rows then raise exception'sales tracking photo denied'using errcode='42501';end$$;

create function public.remove_sales_tracking_attachment_v2(actor_user_id uuid,target_branch_id uuid,target_report_id uuid,
 target_attachment_id uuid,expected_revision bigint)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;a public.sales_tracking_attachments%rowtype;
begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||target_report_id::text||':sales_tracking_photo',0));
 select*into s from public.sales_tracking_reports r where r.id=target_report_id and r.organization_id=c.organization_id and r.branch_id=c.branch_id for update;
 if not found then raise exception'sales tracking report not found'using errcode='P0002';end if;
 if s.state<>'draft'then raise exception'sales tracking already submitted'using errcode='23505';end if;
 if s.branch_revision<>expected_revision then raise sqlstate'PT409'using message='sales tracking changed';end if;
 select*into a from public.sales_tracking_attachments x where x.id=target_attachment_id and x.report_id=s.id and x.deleted_at is null for update;
 if not found then raise exception'sales tracking attachment not found'using errcode='P0002';end if;
 update public.sales_tracking_attachments set deleted_at=now(),deleted_by_user_id=actor_user_id where id=a.id;
 return pg_catalog.jsonb_build_object('attachments',private.sales_tracking_attachments_json(s.id),'old_storage_path',a.storage_path);
exception when no_data_found or too_many_rows then raise exception'sales tracking photo denied'using errcode='42501';end$$;

create or replace function public.finalize_sales_tracking_attachment(actor_user_id uuid,target_branch_id uuid,target_report_id uuid,
 expected_revision bigint,attachment_id uuid,attachment_metadata jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;old public.sales_tracking_attachments%rowtype;created public.sales_tracking_attachments%rowtype;selected_order smallint;
begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||target_report_id::text||':sales_tracking_photo',0));
 select*into s from public.sales_tracking_reports r where r.id=target_report_id and r.organization_id=c.organization_id and r.branch_id=c.branch_id for update;
 if not found then raise exception'sales tracking report not found'using errcode='P0002';end if;
 if s.state<>'draft'then raise exception'sales tracking already submitted'using errcode='23505';end if;
 if s.branch_revision<>expected_revision then raise sqlstate'PT409'using message='sales tracking changed';end if;
 if attachment_metadata->>'storage_path'<>c.organization_id::text||'/'||c.branch_id::text||'/sales-tracking/'||s.id::text||'/'||attachment_id::text||(case attachment_metadata->>'mime_type' when'image/jpeg'then'.jpg'when'image/png'then'.png'when'image/webp'then'.webp'else''end)then raise exception'invalid sales tracking attachment path'using errcode='22023';end if;
 select*into old from public.sales_tracking_attachments a where a.report_id=s.id and a.deleted_at is null order by a.display_order,a.created_at,a.id limit 1 for update;
 selected_order:=coalesce(old.display_order,1);
 if old.id is not null then update public.sales_tracking_attachments set deleted_at=now(),deleted_by_user_id=actor_user_id where id=old.id;end if;
 insert into public.sales_tracking_attachments(id,organization_id,branch_id,report_id,storage_path,original_filename,mime_type,size_bytes,uploaded_by_user_id,display_order)
 values(attachment_id,c.organization_id,c.branch_id,s.id,attachment_metadata->>'storage_path',attachment_metadata->>'original_filename',attachment_metadata->>'mime_type',(attachment_metadata->>'size_bytes')::bigint,actor_user_id,selected_order)returning*into created;
 return pg_catalog.jsonb_build_object('attachment',private.sales_tracking_attachment_json(s.id),'old_storage_path',old.storage_path);
exception when no_data_found or too_many_rows then raise exception'sales tracking photo denied'using errcode='42501';end$$;

alter function public.get_sales_tracking_current_state(uuid,uuid,date) rename to get_sales_tracking_current_state_single_attachment_legacy;
revoke all on function public.get_sales_tracking_current_state_single_attachment_legacy(uuid,uuid,date) from public,anon,authenticated;

create function public.get_sales_tracking_current_state(actor_user_id uuid,target_branch_id uuid,target_business_date date)
returns jsonb language plpgsql security definer set search_path='' as $$
declare current_state jsonb;report_id uuid;
begin
 current_state:=public.get_sales_tracking_current_state_single_attachment_legacy(actor_user_id,target_branch_id,target_business_date);
 report_id:=(current_state->>'report_id')::uuid;
 return current_state||pg_catalog.jsonb_build_object('attachments',private.sales_tracking_attachments_json(report_id));
end$$;

create or replace function public.list_managed_sales_tracking_reports(actor_user_id uuid,target_organization_id uuid,from_date date default null,to_date date default null)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not private.actor_manages_active_organization(actor_user_id,target_organization_id)or(from_date is not null and to_date is not null and from_date>to_date)then raise exception'sales tracking report access denied'using errcode='42501';end if;
 return pg_catalog.jsonb_build_object(
 'sales_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
  'report_id',r.id,'row_id',x.id,'currency_code',r.currency_code,'business_date',r.business_date,'entry_date',x.entry_date,
  'entry_period',p.entry_period,'entered_by',p.entered_by_name_snapshot,'entered_at',p.entered_at,'branch_id',r.branch_id,
  'branch_name',r.branch_name_snapshot,'supervisor_user_id',r.supervisor_user_id,'submitted_by',coalesce(sp.full_name,r.supervisor_name_snapshot),
  'supervisor_team_id',r.supervisor_team_id,'supervisor_team_name',r.supervisor_team_name_snapshot,'submitted_at',r.submitted_at,
  'actual_cash',x.actual_cash,'actual_credit',x.actual_credit,'pos_cash',x.pos_cash,'pos_credit',x.pos_credit,'online_delivery',x.online_delivery,
  'refund_total',x.refund_total,'online_provider_breakdown',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
   'provider_id',provider.id,'provider_key',provider.default_provider_key,'provider_name',provider.name,'amount',amount.amount)
   order by private.sales_tracking_online_provider_sort(provider.default_provider_key,provider.is_default,provider.created_at,provider.name,provider.id))
   from public.sales_tracking_online_amounts amount join public.sales_tracking_online_order_providers provider on provider.id=amount.provider_id
   where amount.sales_row_id=x.id and amount.amount<>0),'[]'::jsonb),
  'actual_total',x.actual_cash+x.actual_credit+x.online_delivery,'gross_sales',x.actual_cash+x.actual_credit+x.online_delivery,
  'net_sales',x.actual_cash+x.actual_credit+x.online_delivery-x.refund_total,
  'evidence_filename',(select a.original_filename from public.sales_tracking_attachments a where a.report_id=r.id and a.deleted_at is null order by a.display_order,a.created_at,a.id limit 1),
  'evidence_filenames',coalesce((select pg_catalog.jsonb_agg(a.original_filename order by a.display_order,a.created_at,a.id)from public.sales_tracking_attachments a where a.report_id=r.id and a.deleted_at is null),'[]'::jsonb),
  'evidence_count',(select pg_catalog.count(*)from public.sales_tracking_attachments a where a.report_id=r.id and a.deleted_at is null),
  'evidence_available',exists(select 1 from public.sales_tracking_attachments a where a.report_id=r.id and a.deleted_at is null),
  'pos_total',x.pos_cash+x.pos_credit+x.online_delivery,'variance',(x.actual_cash+x.actual_credit)-(x.pos_cash+x.pos_credit),'remarks',x.remarks)
  order by r.business_date desc,r.branch_name_snapshot,p.entry_period,x.id)
  from public.sales_tracking_reports r join public.sales_tracking_sales_rows x on x.report_id=r.id
  left join public.sales_tracking_period_entries p on p.id=x.period_entry_id left join public.profiles sp on sp.id=coalesce(r.submitted_by_user_id,r.supervisor_user_id)
  where r.organization_id=target_organization_id and r.state='submitted'and r.submitted_at is not null
   and(from_date is null or r.business_date>=from_date)and(to_date is null or r.business_date<=to_date)),'[]'::jsonb),
 'cash_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
  'report_id',r.id,'row_id',x.id,'currency_code',r.currency_code,'business_date',r.business_date,'entry_date',x.entry_date,
  'entry_period',p.entry_period,'entered_by',p.entered_by_name_snapshot,'entered_at',p.entered_at,'branch_id',r.branch_id,
  'branch_name',r.branch_name_snapshot,'supervisor_user_id',r.supervisor_user_id,'submitted_by',coalesce(sp.full_name,r.supervisor_name_snapshot),
  'supervisor_team_id',r.supervisor_team_id,'supervisor_team_name',r.supervisor_team_name_snapshot,'submitted_at',r.submitted_at,
  'denom_1',x.denom_1,'denom_2',x.denom_2,'denom_5',x.denom_5,'denom_10',x.denom_10,'denom_20',x.denom_20,
  'denom_50',x.denom_50,'denom_100',x.denom_100,'denom_200',x.denom_200,'denom_500',x.denom_500,
  'cash_total',x.denom_1+x.denom_2*2+x.denom_5*5+x.denom_10*10+x.denom_20*20+x.denom_50*50+x.denom_100*100+x.denom_200*200+x.denom_500*500,
  'remaining_cash',x.remaining_cash,'remarks',x.remarks)order by r.business_date desc,r.branch_name_snapshot,p.entry_period,x.id)
  from public.sales_tracking_reports r join public.sales_tracking_cash_rows x on x.report_id=r.id
  left join public.sales_tracking_period_entries p on p.id=x.period_entry_id left join public.profiles sp on sp.id=coalesce(r.submitted_by_user_id,r.supervisor_user_id)
  where r.organization_id=target_organization_id and r.state='submitted'and r.submitted_at is not null
   and(from_date is null or r.business_date>=from_date)and(to_date is null or r.business_date<=to_date)),'[]'::jsonb));
end$$;

create function public.get_managed_sales_tracking_attachments(actor_user_id uuid,target_organization_id uuid,target_report_id uuid)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare report_id uuid;
begin
 if not private.actor_manages_active_organization(actor_user_id,target_organization_id)then raise exception'sales tracking attachment access denied'using errcode='42501';end if;
 select r.id into report_id from public.sales_tracking_reports r
 where r.id=target_report_id and r.organization_id=target_organization_id and r.state='submitted'and r.submitted_at is not null;
 if report_id is null then raise exception'sales tracking report not found'using errcode='P0002';end if;
 return pg_catalog.jsonb_build_object('report_id',report_id,'attachments',private.sales_tracking_attachments_json(report_id));
end$$;

alter function public.get_managed_sales_tracking_monthly_summary(uuid,uuid,date,uuid) rename to get_managed_sales_tracking_monthly_summary_without_evidence_legacy;
revoke all on function public.get_managed_sales_tracking_monthly_summary_without_evidence_legacy(uuid,uuid,date,uuid) from public,anon,authenticated;

create function public.get_managed_sales_tracking_monthly_summary(actor_user_id uuid,target_organization_id uuid,target_month date,branch_filter uuid default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;currency_rows jsonb:='[]'::jsonb;branch_rows jsonb:='[]'::jsonb;entry jsonb;photo_count bigint;
begin
 result:=public.get_managed_sales_tracking_monthly_summary_without_evidence_legacy(actor_user_id,target_organization_id,target_month,branch_filter);
 for entry in select value from pg_catalog.jsonb_array_elements(coalesce(result->'currency_totals','[]'::jsonb))loop
  select pg_catalog.count(a.id)into photo_count from public.sales_tracking_reports r left join public.sales_tracking_attachments a on a.report_id=r.id and a.deleted_at is null
  where r.organization_id=target_organization_id and r.state='submitted'and r.submitted_at is not null and r.currency_code=entry->>'currency_code'
   and r.business_date>=target_month and r.business_date<(target_month+interval'1 month')::date and(branch_filter is null or r.branch_id=branch_filter);
  currency_rows:=currency_rows||pg_catalog.jsonb_build_array(entry||pg_catalog.jsonb_build_object('evidence_photo_count',photo_count));
 end loop;
 for entry in select value from pg_catalog.jsonb_array_elements(coalesce(result->'branches','[]'::jsonb))loop
  select pg_catalog.count(a.id)into photo_count from public.sales_tracking_reports r left join public.sales_tracking_attachments a on a.report_id=r.id and a.deleted_at is null
  where r.organization_id=target_organization_id and r.branch_id=(entry->>'branch_id')::uuid and r.state='submitted'and r.submitted_at is not null and r.currency_code=entry->>'currency_code'
   and r.business_date>=target_month and r.business_date<(target_month+interval'1 month')::date;
  branch_rows:=branch_rows||pg_catalog.jsonb_build_array(entry||pg_catalog.jsonb_build_object('evidence_photo_count',photo_count));
 end loop;
 result:=pg_catalog.jsonb_set(pg_catalog.jsonb_set(result,'{currency_totals}',currency_rows),'{branches}',branch_rows);
 if result?'totals'then result:=pg_catalog.jsonb_set(result,'{totals}',coalesce(currency_rows->0,(result->'totals')||pg_catalog.jsonb_build_object('evidence_photo_count',0)));end if;
 return result;
end$$;

revoke all on function public.prepare_sales_tracking_attachment_upload(uuid,uuid,date,uuid,bigint,uuid,text,uuid),
 public.finalize_sales_tracking_attachment_v2(uuid,uuid,uuid,bigint,uuid,jsonb,uuid),
 public.remove_sales_tracking_attachment_v2(uuid,uuid,uuid,uuid,bigint),
 public.get_sales_tracking_current_state(uuid,uuid,date),
 public.list_managed_sales_tracking_reports(uuid,uuid,date,date),
 public.get_managed_sales_tracking_attachments(uuid,uuid,uuid),
 public.get_managed_sales_tracking_monthly_summary(uuid,uuid,date,uuid) from public,anon,authenticated;
grant execute on function public.prepare_sales_tracking_attachment_upload(uuid,uuid,date,uuid,bigint,uuid,text,uuid),
 public.finalize_sales_tracking_attachment_v2(uuid,uuid,uuid,bigint,uuid,jsonb,uuid),
 public.remove_sales_tracking_attachment_v2(uuid,uuid,uuid,uuid,bigint),
 public.get_sales_tracking_current_state(uuid,uuid,date),
 public.list_managed_sales_tracking_reports(uuid,uuid,date,date),
 public.get_managed_sales_tracking_attachments(uuid,uuid,uuid),
 public.get_managed_sales_tracking_monthly_summary(uuid,uuid,date,uuid) to service_role;

commit;
