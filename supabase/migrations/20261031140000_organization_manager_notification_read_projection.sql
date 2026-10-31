begin;

-- Phase 3A additive Manager notification read projection.
-- Legacy notification rows and read_at values are never modified.

create function public.list_organization_manager_notification_projection(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_before timestamptz default null,
  p_limit integer default 50
)
returns table(
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
stable
security definer
set search_path = ''
as $$
begin
  perform private.assert_active_organization_manager(p_actor_user_id,p_organization_id);
  if p_limit not between 1 and 100 then
    raise exception 'invalid manager notification projection list' using errcode='22023';
  end if;

  return query
  with projected as (
    -- New category rows are already source-validated at insertion. Recheck
    -- the context and cutoff here so the browser cannot bypass either rule.
    select n.id,n.organization_id,n.event_type as category,n.branch_id,n.business_date,
      n.source_type,n.source_id,null::uuid as legacy_notification_id,n.occurrence_key,
      n.category_context,n.read_at,n.created_at
    from public.organization_manager_notifications n
    where n.organization_id=p_organization_id
      and n.recipient_user_id=p_actor_user_id
      and n.event_type in('sales_tracking_missing','maintenance_issue','incomplete_branch_tasks')
      and private.organization_manager_category_context_valid(n.event_type,n.category_context)
      and private.organization_manager_notification_branch_date_closed(
        n.organization_id,n.branch_id,n.business_date,pg_catalog.statement_timestamp())

    union all

    -- Legacy branch maintenance is normalized only when its source issue and
    -- branch/date can be proven. A category row for the same issue wins.
    select n.id,n.organization_id,'maintenance_issue'::text,
      issue.branch_id,
      private.phase4a_business_date_at(branch.timezone,n.created_at),
      'maintenance_issue'::text,issue.id,n.id,n.occurrence_key,
      pg_catalog.jsonb_build_object('schema_version','1','category','maintenance_issue','scope','branch','legacy',true,'issue_id',issue.id),
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
      and private.organization_manager_notification_branch_date_closed(
        n.organization_id,issue.branch_id,
        private.phase4a_business_date_at(branch.timezone,n.created_at),
        pg_catalog.statement_timestamp())
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

    -- Office-scoped legacy maintenance has no authoritative branch/date. It is
    -- retained as an explicit office row, never assigned a fabricated scope.
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

create function public.count_organization_manager_notification_projection(
  p_actor_user_id uuid,
  p_organization_id uuid
)
returns bigint
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.assert_active_organization_manager(p_actor_user_id,p_organization_id);
  return (
    with counts as (
      select count(*)::bigint as item_count
      from public.organization_manager_notifications n
      where n.organization_id=p_organization_id
        and n.recipient_user_id=p_actor_user_id
        and n.read_at is null
        and n.event_type in('sales_tracking_missing','maintenance_issue','incomplete_branch_tasks')
        and private.organization_manager_category_context_valid(n.event_type,n.category_context)
        and private.organization_manager_notification_branch_date_closed(
          n.organization_id,n.branch_id,n.business_date,pg_catalog.statement_timestamp())
      union all
      select count(*)::bigint
      from public.organization_manager_notifications n
      join public.maintenance_issues issue
        on issue.id=n.source_id and issue.organization_id=n.organization_id
      join public.branches branch
        on branch.id=issue.branch_id and branch.organization_id=issue.organization_id
      where n.organization_id=p_organization_id
        and n.recipient_user_id=p_actor_user_id
        and n.read_at is null
        and n.event_type='maintenance_issue_created'
        and n.source_type='maintenance_issue'
        and private.organization_manager_notification_branch_date_closed(
          n.organization_id,issue.branch_id,
          private.phase4a_business_date_at(branch.timezone,n.created_at),
          pg_catalog.statement_timestamp())
        and not exists(
          select 1 from public.organization_manager_notifications category_notification
          where category_notification.organization_id=n.organization_id
            and category_notification.recipient_user_id=n.recipient_user_id
            and category_notification.event_type='maintenance_issue'
            and private.organization_manager_category_context_valid(
              category_notification.event_type,category_notification.category_context)
            and category_notification.category_context->'issue_ids' ? issue.id::text
        )
      union all
      select count(*)::bigint
      from public.organization_manager_notifications n
      where n.organization_id=p_organization_id
        and n.recipient_user_id=p_actor_user_id
        and n.read_at is null
        and n.event_type='maintenance_issue_created'
        and (n.source_type is null or n.source_type<>'maintenance_issue'
          or not exists(
            select 1 from public.maintenance_issues issue
            where issue.id=n.source_id and issue.organization_id=n.organization_id
          ))
    )
    select coalesce(sum(item_count),0)::bigint from counts
  );
end;
$$;

revoke all on function public.list_organization_manager_notification_projection(uuid,uuid,timestamptz,integer)
  from public,anon,authenticated,service_role;
revoke all on function public.count_organization_manager_notification_projection(uuid,uuid)
  from public,anon,authenticated,service_role;
grant execute on function public.list_organization_manager_notification_projection(uuid,uuid,timestamptz,integer)
  to service_role;
grant execute on function public.count_organization_manager_notification_projection(uuid,uuid)
  to service_role;

commit;
