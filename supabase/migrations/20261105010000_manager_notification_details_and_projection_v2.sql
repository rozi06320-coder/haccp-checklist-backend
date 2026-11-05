-- Forward-only migration: Manager notification details and projection cursor v2
-- Note: 20261105000000_safe_manager_notification_applicability_exemptions.sql
-- has already been executed in Production. This migration is strictly forward-only.

begin;

-- 1. Helper function to enrich category_context with authoritative tenant-isolated branch names,
-- module details, missing Cold Storage slots, and maintenance issue details.
create or replace function private.enrich_organization_manager_notification_context(
  p_organization_id uuid,
  p_category text,
  p_branch_id uuid,
  p_business_date date,
  p_source_id uuid,
  p_category_context jsonb,
  p_as_of timestamptz default pg_catalog.statement_timestamp()
)
returns jsonb
language plpgsql
stable security definer
set search_path to ''
as $$
declare
  v_result jsonb := coalesce(p_category_context, '{}'::jsonb);
  v_branch_name text;
  v_branch_name_ar text;
  v_branch_0200_required boolean;
  v_closed_slots text[];
  v_required_slots text[];
  v_missing_slots text[];
  v_modules_detail jsonb := '[]'::jsonb;
  v_mod text;
  v_issues jsonb := '[]'::jsonb;
  v_first_issue record;
  v_issue_count integer := 0;
  v_module_name text;
  v_module_name_ar text;
begin
  -- 1. Resolve branch names (authoritative, tenant-isolated)
  if p_branch_id is not null then
    select b.name, b.name_ar, coalesce(b.cold_storage_0200_notification_required, true)
    into v_branch_name, v_branch_name_ar, v_branch_0200_required
    from public.branches b
    where b.id = p_branch_id and b.organization_id = p_organization_id;

    v_result := v_result || pg_catalog.jsonb_build_object(
      'branch_name', coalesce(v_branch_name, 'Archived Branch'),
      'branch_name_ar', v_branch_name_ar
    );
  end if;

  -- 2. Category: Incomplete Branch Tasks
  if p_category = 'incomplete_branch_tasks' then
    if p_category_context ? 'incomplete_modules' and pg_catalog.jsonb_typeof(p_category_context->'incomplete_modules') = 'array' then
      for v_mod in select pg_catalog.jsonb_array_elements_text(p_category_context->'incomplete_modules')
      loop
        case v_mod
          when 'kitchen_opening' then
            v_module_name := 'Kitchen Opening';
            v_module_name_ar := 'افتتاح المطبخ';
          when 'foh_opening' then
            v_module_name := 'Front of House Opening';
            v_module_name_ar := 'افتتاح صالة الطعام';
          when 'staff_hygiene' then
            v_module_name := 'Staff Hygiene';
            v_module_name_ar := 'نظافة الموظفين';
          when 'cold_storage' then
            v_module_name := 'Cold Storage';
            v_module_name_ar := 'التخزين البارد';
          when 'oil_tracking' then
            v_module_name := 'Oil Tracking';
            v_module_name_ar := 'متابعة الزيت';
          when 'daily_audit' then
            v_module_name := 'Daily Audit';
            v_module_name_ar := 'التدقيق اليومي';
          else
            v_module_name := v_mod;
            v_module_name_ar := v_mod;
        end case;

        if v_mod = 'cold_storage' then
          v_missing_slots := null;
          if p_branch_id is not null and p_business_date is not null then
            select private.cold_storage_closed_slots_for(p_branch_id, p_business_date, p_as_of)
            into v_closed_slots;
            if not coalesce(v_branch_0200_required, true) then
              v_required_slots := array_remove(v_closed_slots, '02:00');
            else
              v_required_slots := v_closed_slots;
            end if;

            if not exists (
              select 1 from public.cold_storage_submissions s
              where s.organization_id = p_organization_id and s.branch_id = p_branch_id and s.business_date = p_business_date
            ) then
              v_missing_slots := v_required_slots;
            else
              select coalesce(array_agg(slot_name.slot order by slot_name.slot), array[]::text[])
              into v_missing_slots
              from unnest(v_required_slots) as slot_name(slot)
              where not exists (
                select 1
                from public.cold_storage_submissions s
                join public.cold_storage_readings r on r.submission_id = s.id
                where s.organization_id = p_organization_id
                  and s.branch_id = p_branch_id
                  and s.business_date = p_business_date
                  and r.slot = slot_name.slot
                  and r.status in ('pass', 'fail')
                  and r.temperature_c is not null
              );
            end if;
          end if;

          v_modules_detail := v_modules_detail || pg_catalog.jsonb_build_array(
            pg_catalog.jsonb_build_object(
              'module_key', 'cold_storage',
              'module_name', v_module_name,
              'module_name_ar', v_module_name_ar,
              'state', 'incomplete',
              'missing_slots', pg_catalog.to_jsonb(coalesce(v_missing_slots, array[]::text[]))
            )
          );
        else
          v_modules_detail := v_modules_detail || pg_catalog.jsonb_build_array(
            pg_catalog.jsonb_build_object(
              'module_key', v_mod,
              'module_name', v_module_name,
              'module_name_ar', v_module_name_ar,
              'state', 'incomplete'
            )
          );
        end if;
      end loop;
    end if;
    v_result := v_result || pg_catalog.jsonb_build_object('modules_detail', v_modules_detail);

  -- 3. Category: Maintenance Issues
  elsif p_category = 'maintenance_issue' then
    if p_source_id is not null then
      select issue.id, issue.title, issue.priority, issue.status, issue.location, issue.description
      into v_first_issue
      from public.maintenance_issues issue
      where issue.id = p_source_id and issue.organization_id = p_organization_id;

      if v_first_issue.id is not null then
        v_issues := pg_catalog.jsonb_build_array(
          pg_catalog.jsonb_build_object(
            'id', v_first_issue.id,
            'title', v_first_issue.title,
            'priority', v_first_issue.priority,
            'status', v_first_issue.status,
            'location', v_first_issue.location,
            'description', v_first_issue.description
          )
        );
        v_result := v_result || pg_catalog.jsonb_build_object(
          'issue_id', v_first_issue.id,
          'issue_title', v_first_issue.title,
          'priority', v_first_issue.priority,
          'issue_status', v_first_issue.status,
          'location', v_first_issue.location,
          'description', v_first_issue.description,
          'issue_count', 1,
          'issues', v_issues
        );
      end if;
    elsif p_category_context ? 'issue_ids' and pg_catalog.jsonb_typeof(p_category_context->'issue_ids') = 'array' then
      select coalesce(pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'id', issue.id,
          'title', issue.title,
          'priority', issue.priority,
          'status', issue.status,
          'location', issue.location,
          'description', issue.description
        ) order by issue.created_at desc
      ), '[]'::jsonb), count(*)::integer
      into v_issues, v_issue_count
      from public.maintenance_issues issue
      where issue.organization_id = p_organization_id
        and (p_branch_id is null or issue.branch_id = p_branch_id)
        and issue.id::text in (select pg_catalog.jsonb_array_elements_text(p_category_context->'issue_ids'));

      v_result := v_result || pg_catalog.jsonb_build_object(
        'issue_count', v_issue_count,
        'issues', v_issues
      );

      if v_issue_count = 1 then
        v_result := v_result || pg_catalog.jsonb_build_object(
          'issue_id', v_issues->0->'id',
          'issue_title', v_issues->0->'title',
          'priority', v_issues->0->'priority',
          'issue_status', v_issues->0->'status',
          'location', v_issues->0->'location',
          'description', v_issues->0->'description'
        );
      end if;
    end if;

  -- 4. Category: Sales Tracking Missing
  elsif p_category = 'sales_tracking_missing' then
    v_result := v_result || pg_catalog.jsonb_build_object(
      'status', 'missing',
      'evidence', 'missing'
    );
  end if;

  return v_result;
end;
$$;

revoke all on function private.enrich_organization_manager_notification_context(uuid, text, uuid, date, uuid, jsonb, timestamptz)
  from public,anon,authenticated,service_role;
grant execute on function private.enrich_organization_manager_notification_context(uuid, text, uuid, date, uuid, jsonb, timestamptz)
  to service_role;


-- 2. Update list_organization_manager_notification_projection to return enriched category_context
create or replace function public.list_organization_manager_notification_projection(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_before timestamptz default null,
  p_limit integer default 50
)
returns table (
  id uuid,
  organization_id uuid,
  category text,
  branch_id uuid,
  business_date date,
  source_type text,
  source_id uuid,
  legacy_notification_id uuid,
  occurrence_key text,
  category_context jsonb,
  read_at timestamptz,
  created_at timestamptz
)
language plpgsql
stable security definer
set search_path to ''
as $$
begin
  perform private.assert_active_organization_manager(p_actor_user_id,p_organization_id);
  if p_limit not between 1 and 100 then
    raise exception 'invalid manager notification projection list' using errcode='22023';
  end if;

  return query
  with projected as (
    -- Category rollup rows remain strictly gated on closed business date
    select n.id,n.organization_id,n.event_type as category,n.branch_id,n.business_date,
      n.source_type,n.source_id,null::uuid as legacy_notification_id,n.occurrence_key,
      private.enrich_organization_manager_notification_context(
        n.organization_id, n.event_type, n.branch_id, n.business_date, n.source_id, n.category_context, pg_catalog.statement_timestamp()
      ) as category_context,n.read_at,n.created_at
    from public.organization_manager_notifications n
    where n.organization_id=p_organization_id
      and n.recipient_user_id=p_actor_user_id
      and n.event_type in('sales_tracking_missing','maintenance_issue','incomplete_branch_tasks')
      and private.organization_manager_category_context_valid(n.event_type,n.category_context)
      and private.organization_manager_notification_branch_date_closed(
        n.organization_id,n.branch_id,n.business_date,pg_catalog.statement_timestamp())

    union all

    -- Maintenance issue notifications are visible immediately upon creation
    select n.id,n.organization_id,'maintenance_issue'::text,
      issue.branch_id,
      private.phase4a_business_date_at(branch.timezone,n.created_at),
      'maintenance_issue'::text,issue.id,n.id,n.occurrence_key,
      private.enrich_organization_manager_notification_context(
        n.organization_id, 'maintenance_issue', issue.branch_id,
        private.phase4a_business_date_at(branch.timezone,n.created_at), issue.id,
        pg_catalog.jsonb_build_object('schema_version','1','category','maintenance_issue','scope','branch','legacy',true,'issue_id',issue.id),
        pg_catalog.statement_timestamp()
      ) as category_context,
      n.read_at,n.created_at
    from public.organization_manager_notifications n
    join public.maintenance_issues issue
      on issue.id=n.source_id and issue.organization_id=n.organization_id
    join public.branches branch
      on branch.id=issue.branch_id and branch.organization_id=issue.organization_id
    where n.organization_id=p_organization_id
      and n.recipient_user_id=p_actor_user_id
      and n.event_type='maintenance_issue_created'
      and n.source_type='maintenance_issue'
      and not exists(
        select 1
        from public.organization_manager_notifications category_notification
        where category_notification.organization_id=n.organization_id
          and category_notification.recipient_user_id=n.recipient_user_id
          and category_notification.event_type='maintenance_issue'
          and private.organization_manager_category_context_valid(
            category_notification.event_type,category_notification.category_context)
          and category_notification.category_context->'issue_ids' ? issue.id::text
      )

    union all

    -- Office-scoped legacy maintenance
    select n.id,n.organization_id,'maintenance_issue'::text,null::uuid,null::date,
      n.source_type,n.source_id,n.id,n.occurrence_key,
      pg_catalog.jsonb_build_object('schema_version','1','category','maintenance_issue','scope','office','legacy',true),
      n.read_at,n.created_at
    from public.organization_manager_notifications n
    where n.organization_id=p_organization_id
      and n.recipient_user_id=p_actor_user_id
      and n.event_type='maintenance_issue_created'
      and (n.source_type is null or n.source_type<>'maintenance_issue'
        or not exists(
          select 1 from public.maintenance_issues issue
          where issue.id=n.source_id and issue.organization_id=n.organization_id
        ))
  )
  select projected.id,projected.organization_id,projected.category,projected.branch_id,
    projected.business_date,projected.source_type,projected.source_id,
    projected.legacy_notification_id,projected.occurrence_key,projected.category_context,
    projected.read_at,projected.created_at
  from projected
  where p_before is null
    or projected.created_at<p_before
  order by projected.created_at desc,projected.id desc
  limit p_limit;
end;
$$;

revoke all on function public.list_organization_manager_notification_projection(uuid,uuid,timestamptz,integer)
  from public,anon,authenticated,service_role;
grant execute on function public.list_organization_manager_notification_projection(uuid,uuid,timestamptz,integer)
  to service_role;


-- 3. Update list_organization_manager_notification_projection_cursor to return enriched category_context
create or replace function public.list_organization_manager_notification_projection_cursor(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
)
returns table (
  id uuid,
  organization_id uuid,
  category text,
  branch_id uuid,
  business_date date,
  source_type text,
  source_id uuid,
  legacy_notification_id uuid,
  occurrence_key text,
  category_context jsonb,
  read_at timestamptz,
  created_at timestamptz
)
language plpgsql
stable security definer
set search_path to ''
as $$
begin
  perform private.assert_active_organization_manager(p_actor_user_id,p_organization_id);
  if p_limit not between 1 and 100 then
    raise exception 'invalid manager notification projection cursor list' using errcode='22023';
  end if;
  if (p_before_created_at is null) <> (p_before_id is null) then
    raise exception 'invalid manager notification projection cursor' using errcode='22023';
  end if;

  return query
  with projected as (
    select n.id,n.organization_id,n.event_type as category,n.branch_id,n.business_date,
      n.source_type,n.source_id,null::uuid as legacy_notification_id,n.occurrence_key,
      private.enrich_organization_manager_notification_context(
        n.organization_id, n.event_type, n.branch_id, n.business_date, n.source_id, n.category_context, pg_catalog.statement_timestamp()
      ) as category_context,n.read_at,n.created_at
    from public.organization_manager_notifications n
    where n.organization_id=p_organization_id
      and n.recipient_user_id=p_actor_user_id
      and n.event_type in('sales_tracking_missing','maintenance_issue','incomplete_branch_tasks')
      and private.organization_manager_category_context_valid(n.event_type,n.category_context)
      and private.organization_manager_notification_branch_date_closed(
        n.organization_id,n.branch_id,n.business_date,pg_catalog.statement_timestamp())

    union all

    select n.id,n.organization_id,'maintenance_issue'::text,issue.branch_id,
      private.phase4a_business_date_at(branch.timezone,n.created_at),
      'maintenance_issue'::text,issue.id,n.id,n.occurrence_key,
      private.enrich_organization_manager_notification_context(
        n.organization_id, 'maintenance_issue', issue.branch_id,
        private.phase4a_business_date_at(branch.timezone,n.created_at), issue.id,
        pg_catalog.jsonb_build_object('schema_version','1','category','maintenance_issue','scope','branch','legacy',true,'issue_id',issue.id),
        pg_catalog.statement_timestamp()
      ) as category_context,
      n.read_at,n.created_at
    from public.organization_manager_notifications n
    join public.maintenance_issues issue on issue.id=n.source_id and issue.organization_id=n.organization_id
    join public.branches branch on branch.id=issue.branch_id and branch.organization_id=issue.organization_id
    where n.organization_id=p_organization_id and n.recipient_user_id=p_actor_user_id
      and n.event_type='maintenance_issue_created' and n.source_type='maintenance_issue'
      and not exists(
        select 1 from public.organization_manager_notifications category_notification
        where category_notification.organization_id=n.organization_id
          and category_notification.recipient_user_id=n.recipient_user_id
          and category_notification.event_type='maintenance_issue'
          and private.organization_manager_category_context_valid(category_notification.event_type,category_notification.category_context)
          and category_notification.category_context->'issue_ids' ? issue.id::text
      )

    union all

    select n.id,n.organization_id,'maintenance_issue'::text,null::uuid,null::date,
      n.source_type,n.source_id,n.id,n.occurrence_key,
      pg_catalog.jsonb_build_object('schema_version','1','category','maintenance_issue','scope','office','legacy',true),
      n.read_at,n.created_at
    from public.organization_manager_notifications n
    where n.organization_id=p_organization_id and n.recipient_user_id=p_actor_user_id
      and n.event_type='maintenance_issue_created'
      and (n.source_type is null or n.source_type<>'maintenance_issue' or not exists(
        select 1 from public.maintenance_issues issue
        where issue.id=n.source_id and issue.organization_id=n.organization_id
      ))
  )
  select projected.id,projected.organization_id,projected.category,projected.branch_id,
    projected.business_date,projected.source_type,projected.source_id,
    projected.legacy_notification_id,projected.occurrence_key,projected.category_context,
    projected.read_at,projected.created_at
  from projected
  where p_before_created_at is null
    or (projected.created_at,projected.id) < (p_before_created_at,p_before_id)
  order by projected.created_at desc,projected.id desc
  limit p_limit;
end;
$$;

revoke all on function public.list_organization_manager_notification_projection_cursor(uuid,uuid,timestamptz,uuid,integer)
  from public,anon,authenticated,service_role;
grant execute on function public.list_organization_manager_notification_projection_cursor(uuid,uuid,timestamptz,uuid,integer)
  to service_role;


-- 4. New list_organization_manager_notification_projection_cursor_v2 with first-class branch name columns
create or replace function public.list_organization_manager_notification_projection_cursor_v2(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
)
returns table (
  id uuid,
  organization_id uuid,
  category text,
  branch_id uuid,
  branch_name text,
  branch_name_ar text,
  business_date date,
  source_type text,
  source_id uuid,
  legacy_notification_id uuid,
  occurrence_key text,
  category_context jsonb,
  read_at timestamptz,
  created_at timestamptz
)
language plpgsql
stable security definer
set search_path to ''
as $$
begin
  perform private.assert_active_organization_manager(p_actor_user_id,p_organization_id);
  if p_limit not between 1 and 100 then
    raise exception 'invalid manager notification projection cursor list' using errcode='22023';
  end if;
  if (p_before_created_at is null) <> (p_before_id is null) then
    raise exception 'invalid manager notification projection cursor' using errcode='22023';
  end if;

  return query
  select
    c.id, c.organization_id, c.category, c.branch_id,
    c.category_context->>'branch_name' as branch_name,
    c.category_context->>'branch_name_ar' as branch_name_ar,
    c.business_date, c.source_type, c.source_id,
    c.legacy_notification_id, c.occurrence_key, c.category_context,
    c.read_at, c.created_at
  from public.list_organization_manager_notification_projection_cursor(
    p_actor_user_id, p_organization_id, p_before_created_at, p_before_id, p_limit
  ) c;
end;
$$;

revoke all on function public.list_organization_manager_notification_projection_cursor_v2(uuid,uuid,timestamptz,uuid,integer)
  from public,anon,authenticated,service_role;
grant execute on function public.list_organization_manager_notification_projection_cursor_v2(uuid,uuid,timestamptz,uuid,integer)
  to service_role;


-- 5. New get_organization_manager_notification_detail RPC returning full authoritative enriched details
create or replace function public.get_organization_manager_notification_detail(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_notification_id uuid
)
returns table (
  id uuid,
  organization_id uuid,
  category text,
  branch_id uuid,
  branch_name text,
  branch_name_ar text,
  business_date date,
  source_type text,
  source_id uuid,
  legacy_notification_id uuid,
  occurrence_key text,
  category_context jsonb,
  read_at timestamptz,
  created_at timestamptz
)
language plpgsql
stable security definer
set search_path to ''
as $$
declare
  v_notif record;
  v_enriched jsonb;
begin
  perform private.assert_active_organization_manager(p_actor_user_id,p_organization_id);

  select * into v_notif
  from public.organization_manager_notifications n
  where n.id = p_notification_id and n.organization_id = p_organization_id and n.recipient_user_id = p_actor_user_id;

  if v_notif.id is null then
    return;
  end if;

  v_enriched := private.enrich_organization_manager_notification_context(
    v_notif.organization_id, v_notif.event_type, v_notif.branch_id, v_notif.business_date,
    v_notif.source_id, v_notif.category_context, pg_catalog.statement_timestamp()
  );

  return query
  select
    v_notif.id, v_notif.organization_id, v_notif.event_type, v_notif.branch_id,
    v_enriched->>'branch_name', v_enriched->>'branch_name_ar',
    v_notif.business_date, v_notif.source_type, v_notif.source_id,
    null::uuid, v_notif.occurrence_key, v_enriched,
    v_notif.read_at, v_notif.created_at;
end;
$$;

revoke all on function public.get_organization_manager_notification_detail(uuid,uuid,uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.get_organization_manager_notification_detail(uuid,uuid,uuid)
  to service_role;

commit;
