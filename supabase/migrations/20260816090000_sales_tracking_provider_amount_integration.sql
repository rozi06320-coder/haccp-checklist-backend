-- Sales Tracking provider amount integration.
-- sales_tracking_sales_rows.online_delivery remains the aggregate compatibility value.

create or replace function private.sales_tracking_online_provider_sort(default_provider_key text, is_default boolean, created_at timestamptz, provider_name text, provider_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select lpad((
    case
      when default_provider_key = 'jahez' then 1
      when default_provider_key = 'ninja' then 2
      when default_provider_key = 'hungerstation' then 3
      when default_provider_key = 'the_chef' then 4
      when default_provider_key = 'try_order' then 5
      when is_default then 50
      else 100
    end
  )::text, 3, '0') || ':' || to_char(created_at at time zone 'UTC', 'YYYYMMDDHH24MISSUS') || ':' || lower(provider_name) || ':' || provider_id::text
$$;
revoke all on function private.sales_tracking_online_provider_sort(text,boolean,timestamptz,text,uuid) from public, anon, authenticated;

create or replace function private.sales_tracking_online_amounts_for_row(target_sales_row_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', amount.id,
    'provider_id', amount.provider_id,
    'provider_name', provider.name,
    'amount', amount.amount
  ) order by private.sales_tracking_online_provider_sort(provider.default_provider_key, provider.is_default, provider.created_at, provider.name, provider.id)), '[]'::jsonb)
  from public.sales_tracking_online_amounts amount
  join public.sales_tracking_online_order_providers provider on provider.id = amount.provider_id
  where amount.sales_row_id = target_sales_row_id
$$;
revoke all on function private.sales_tracking_online_amounts_for_row(uuid) from public, anon, authenticated;

create or replace function public.list_sales_tracking_online_order_providers(actor_user_id uuid, target_branch_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c record;
begin
  select * into strict c from private.phase2_branch_context(actor_user_id, target_branch_id);

  return pg_catalog.jsonb_build_object(
    'providers',
    coalesce((
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', provider.id,
        'organization_id', provider.organization_id,
        'branch_id', provider.branch_id,
        'name', provider.name,
        'normalized_name', provider.normalized_name,
        'default_provider_key', provider.default_provider_key,
        'is_default', provider.is_default,
        'active', provider.active,
        'created_by', provider.created_by,
        'created_at', provider.created_at,
        'updated_at', provider.updated_at
      ) order by private.sales_tracking_online_provider_sort(provider.default_provider_key, provider.is_default, provider.created_at, provider.name, provider.id))
      from public.sales_tracking_online_order_providers provider
      where provider.organization_id = c.organization_id
        and provider.branch_id = c.branch_id
        and provider.active
    ), '[]'::jsonb)
  );
exception when no_data_found or too_many_rows then
  raise exception 'sales tracking online provider access denied' using errcode = '42501';
end $$;

create or replace function public.get_sales_tracking_current_state(actor_user_id uuid,target_branch_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;
begin
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 select*into s from public.sales_tracking_reports x where x.organization_id=c.organization_id and x.branch_id=c.branch_id and x.business_date=c.business_date;
 return pg_catalog.jsonb_build_object(
  'report_id',s.id,'business_date',c.business_date,'state',coalesce(s.state,'draft'),'revision',coalesce(s.branch_revision,0),
  'submitted_at',s.submitted_at,'submitted_by_user_id',s.submitted_by_user_id,'submitted_by_name_snapshot',s.submitted_by_name_snapshot,
  'periods',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'id',p.id,'entry_period',p.entry_period,'entered_by_user_id',p.entered_by_user_id,
    'entered_by_name',p.entered_by_name_snapshot,'entered_at',p.entered_at
  )order by case p.entry_period when'middle_shift'then 1 else 2 end)from public.sales_tracking_period_entries p where p.report_id=s.id),'[]'::jsonb),
  'sales_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'id',r.id,'entry_date',r.entry_date,'entry_period',p.entry_period,'entered_by_user_id',p.entered_by_user_id,
    'entered_by_name',p.entered_by_name_snapshot,'entered_at',p.entered_at,
    'actual_cash',r.actual_cash,'actual_credit',r.actual_credit,'pos_cash',r.pos_cash,'pos_credit',r.pos_credit,
    'online_delivery',r.online_delivery,'online_amounts',private.sales_tracking_online_amounts_for_row(r.id),
    'remarks',r.remarks,'actual_total',r.actual_cash+r.actual_credit+r.online_delivery,
    'pos_total',r.pos_cash+r.pos_credit+r.online_delivery,
    'variance',(r.actual_cash+r.actual_credit+r.online_delivery)-(r.pos_cash+r.pos_credit+r.online_delivery)
  )order by case p.entry_period when'middle_shift'then 1 when'closing_shift'then 2 else 3 end,r.entry_date)from public.sales_tracking_sales_rows r left join public.sales_tracking_period_entries p on p.id=r.period_entry_id where r.report_id=s.id),'[]'::jsonb),
  'cash_rows',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'id',r.id,'entry_date',r.entry_date,'entry_period',p.entry_period,'entered_by_user_id',p.entered_by_user_id,
    'entered_by_name',p.entered_by_name_snapshot,'entered_at',p.entered_at,
    'denom_1',r.denom_1,'denom_2',r.denom_2,'denom_5',r.denom_5,'denom_10',r.denom_10,
    'denom_20',r.denom_20,'denom_50',r.denom_50,'denom_100',r.denom_100,'denom_200',r.denom_200,
    'denom_500',r.denom_500,'remaining_cash',r.remaining_cash,'remarks',r.remarks,
    'cash_total',r.denom_1+r.denom_2*2+r.denom_5*5+r.denom_10*10+r.denom_20*20+r.denom_50*50+r.denom_100*100+r.denom_200*200+r.denom_500*500
  )order by case p.entry_period when'middle_shift'then 1 when'closing_shift'then 2 else 3 end,r.entry_date)from public.sales_tracking_cash_rows r left join public.sales_tracking_period_entries p on p.id=r.period_entry_id where r.report_id=s.id),'[]'::jsonb),
  'totals',pg_catalog.jsonb_build_object(
    'actual_cash',coalesce((select sum(r.actual_cash)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),
    'actual_credit',coalesce((select sum(r.actual_credit)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),
    'pos_cash',coalesce((select sum(r.pos_cash)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),
    'pos_credit',coalesce((select sum(r.pos_credit)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),
    'online_delivery',coalesce((select sum(r.online_delivery)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),
    'actual_total',coalesce((select sum(r.actual_cash+r.actual_credit+r.online_delivery)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),
    'pos_total',coalesce((select sum(r.pos_cash+r.pos_credit+r.online_delivery)from public.sales_tracking_sales_rows r where r.report_id=s.id),0),
    'variance',coalesce((select sum((r.actual_cash+r.actual_credit)-(r.pos_cash+r.pos_credit))from public.sales_tracking_sales_rows r where r.report_id=s.id),0),
    'cash_total',coalesce((select sum(r.denom_1+r.denom_2*2+r.denom_5*5+r.denom_10*10+r.denom_20*20+r.denom_50*50+r.denom_100*100+r.denom_200*200+r.denom_500*500)from public.sales_tracking_cash_rows r where r.report_id=s.id),0),
    'remaining_cash',coalesce((select sum(r.remaining_cash)from public.sales_tracking_cash_rows r where r.report_id=s.id),0)
  )
 );
exception when no_data_found or too_many_rows then raise exception'sales tracking state denied'using errcode='42501';end$$;

create or replace function public.save_sales_tracking_draft(actor_user_id uuid,target_branch_id uuid,expected_revision bigint,entry_period text,sales_rows jsonb,cash_rows jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;s public.sales_tracking_reports%rowtype;p public.sales_tracking_period_entries%rowtype;v jsonb;provider_amounts jsonb;provider_total numeric;sales_row public.sales_tracking_sales_rows%rowtype;
begin
 if entry_period not in('middle_shift','closing_shift')then raise exception'invalid sales tracking period'using errcode='22023';end if;
 select*into strict c from private.phase2_branch_context(actor_user_id,target_branch_id);
 perform private.validate_sales_tracking_sales_rows(sales_rows);perform private.validate_sales_tracking_cash_rows(cash_rows);
 perform private.validate_sales_tracking_entry_dates(sales_rows,c.business_date);perform private.validate_sales_tracking_entry_dates(cash_rows,c.business_date);
 if pg_catalog.jsonb_array_length(sales_rows)<>1 or pg_catalog.jsonb_array_length(cash_rows)<>1 then raise exception'invalid sales tracking period rows'using errcode='22023';end if;
 select value into strict v from pg_catalog.jsonb_array_elements(sales_rows);
 provider_amounts := coalesce(v->'online_amounts','[]'::jsonb);
 if pg_catalog.jsonb_typeof(provider_amounts) <> 'array' then raise exception'invalid sales tracking online amounts'using errcode='22023';end if;
 if exists(select 1 from pg_catalog.jsonb_array_elements(provider_amounts)e(a) where pg_catalog.jsonb_typeof(a->'provider_id')<>'string' or (a->>'provider_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') then raise exception'invalid sales tracking online provider'using errcode='22023';end if;
 if (select count(*) <> count(distinct a->>'provider_id') from pg_catalog.jsonb_array_elements(provider_amounts)e(a)) then raise exception'duplicate sales tracking online provider'using errcode='22023';end if;
 if exists(
  select 1
  from pg_catalog.jsonb_array_elements(provider_amounts)e(a)
  left join public.sales_tracking_online_order_providers provider on provider.id=(a->>'provider_id')::uuid and provider.organization_id=c.organization_id and provider.branch_id=c.branch_id and provider.active
  where provider.id is null
 ) then raise exception'invalid sales tracking online provider scope'using errcode='22023';end if;
 if pg_catalog.jsonb_array_length(provider_amounts)>0 then
  select coalesce(sum(private.sales_tracking_numeric_field(a,'amount')),0) into provider_total from pg_catalog.jsonb_array_elements(provider_amounts)e(a);
 else
  provider_total := private.sales_tracking_numeric_field(v,'online_delivery');
 end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(c.organization_id::text||':'||c.branch_id::text||':'||c.business_date::text||':sales_tracking',0));
 select*into s from public.sales_tracking_reports x where x.organization_id=c.organization_id and x.branch_id=c.branch_id and x.business_date=c.business_date for update;
 if(s.id is null and coalesce(expected_revision,0)<>0)or(s.id is not null and coalesce(expected_revision,-1)<>s.branch_revision)then raise exception'sales tracking changed'using errcode='40001';end if;
 if s.state='submitted'then raise exception'sales tracking already submitted'using errcode='23505';end if;
 if s.id is null then
  insert into public.sales_tracking_reports(organization_id,branch_id,supervisor_user_id,supervisor_team_id,business_date,state,branch_name_snapshot,supervisor_name_snapshot,supervisor_team_name_snapshot,branch_revision,updated_by_user_id)
  values(c.organization_id,c.branch_id,actor_user_id,c.legacy_team_id,c.business_date,'draft',c.branch_name,c.actor_name,c.actor_name||' Team',1,actor_user_id)returning*into s;
 else
  if exists(select 1 from public.sales_tracking_period_entries x where x.report_id=s.id and x.entry_period=save_sales_tracking_draft.entry_period)then raise exception'sales tracking period already saved'using errcode='23505';end if;
  update public.sales_tracking_reports set branch_revision=branch_revision+1,updated_by_user_id=actor_user_id,updated_at=now()where id=s.id returning*into s;
 end if;
 insert into public.sales_tracking_period_entries(report_id,entry_period,entered_by_user_id,entered_by_name_snapshot)
 values(s.id,entry_period,actor_user_id,c.actor_name)returning*into p;
 insert into public.sales_tracking_sales_rows(report_id,period_entry_id,entry_date,actual_cash,actual_credit,pos_cash,pos_credit,online_delivery,remarks)
 values(s.id,p.id,private.sales_tracking_date_field(v,'entry_date'),private.sales_tracking_numeric_field(v,'actual_cash'),private.sales_tracking_numeric_field(v,'actual_credit'),private.sales_tracking_numeric_field(v,'pos_cash'),private.sales_tracking_numeric_field(v,'pos_credit'),provider_total,nullif(pg_catalog.btrim(coalesce(v->>'remarks','')),''))
 returning*into sales_row;
 if pg_catalog.jsonb_array_length(provider_amounts)>0 then
  insert into public.sales_tracking_online_amounts(sales_row_id,provider_id,amount)
  select sales_row.id,(a->>'provider_id')::uuid,private.sales_tracking_numeric_field(a,'amount')
  from pg_catalog.jsonb_array_elements(provider_amounts)e(a);
 end if;
 insert into public.sales_tracking_cash_rows(report_id,period_entry_id,entry_date,denom_1,denom_2,denom_5,denom_10,denom_20,denom_50,denom_100,denom_200,denom_500,remaining_cash,remarks)
 select s.id,p.id,private.sales_tracking_date_field(x,'entry_date'),private.sales_tracking_integer_field(x,'denom_1'),private.sales_tracking_integer_field(x,'denom_2'),private.sales_tracking_integer_field(x,'denom_5'),private.sales_tracking_integer_field(x,'denom_10'),private.sales_tracking_integer_field(x,'denom_20'),private.sales_tracking_integer_field(x,'denom_50'),private.sales_tracking_integer_field(x,'denom_100'),private.sales_tracking_integer_field(x,'denom_200'),private.sales_tracking_integer_field(x,'denom_500'),private.sales_tracking_numeric_field(x,'remaining_cash'),nullif(pg_catalog.btrim(coalesce(x->>'remarks','')),'')from pg_catalog.jsonb_array_elements(cash_rows)e(x);
 return public.get_sales_tracking_current_state(actor_user_id,target_branch_id);
exception when no_data_found or too_many_rows then raise exception'sales tracking draft denied'using errcode='42501';end$$;

revoke all on function public.get_sales_tracking_current_state(uuid,uuid),
  public.save_sales_tracking_draft(uuid,uuid,bigint,text,jsonb,jsonb),
  public.list_sales_tracking_online_order_providers(uuid,uuid)
  from public,anon,authenticated;
grant execute on function public.get_sales_tracking_current_state(uuid,uuid),
  public.save_sales_tracking_draft(uuid,uuid,bigint,text,jsonb,jsonb),
  public.list_sales_tracking_online_order_providers(uuid,uuid)
  to service_role;
