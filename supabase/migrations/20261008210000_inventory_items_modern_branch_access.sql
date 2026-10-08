-- Inventory Items uses canonical branch-manager access. Legacy Supervisor-team
-- rows remain optional historical attribution and are never authorization.

alter table public.inventory_items_reports
  alter column supervisor_team_id drop not null;

create or replace function private.inventory_items_actor_context(
  actor_user_id uuid,
  target_branch_id uuid
)
returns table(
  organization_id uuid,
  branch_id uuid,
  team_id uuid,
  business_date date,
  branch_name text,
  branch_code text,
  supervisor_name text
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    context.organization_id,
    context.branch_id,
    context.legacy_team_id,
    context.business_date,
    context.branch_name,
    context.branch_code,
    context.actor_name
  from private.phase2_branch_context(actor_user_id, target_branch_id) context
$$;

comment on function private.inventory_items_actor_context(uuid, uuid) is
  'Authorizes Inventory Items through canonical active branch-manager access and returns an optional legacy team ID for historical attribution.';

revoke all on function private.inventory_items_actor_context(uuid, uuid)
  from public, anon, authenticated;

-- Preserve the latest definitions of every Inventory Items routine and replace
-- only their legacy authorization dependency. Guards make migration drift fail
-- closed instead of silently leaving mixed authorization behind.
do $$
declare
  target_function regprocedure;
  function_definition text;
  legacy_reference_count integer;
begin
  foreach target_function in array array[
    'private.inventory_items_state_json(uuid,uuid,date)'::regprocedure,
    'public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb)'::regprocedure,
    'public.submit_inventory_items(uuid,uuid,uuid,text,jsonb,jsonb)'::regprocedure,
    'public.update_inventory_beef_production_field_labels(uuid,uuid,text,text,text)'::regprocedure,
    'public.create_inventory_beef_production_row(uuid,uuid,date,jsonb)'::regprocedure,
    'public.update_inventory_beef_production_row(uuid,uuid,uuid,timestamptz,jsonb)'::regprocedure,
    'public.delete_inventory_item_usage_item(uuid,uuid,uuid)'::regprocedure
  ]
  loop
    function_definition := pg_catalog.pg_get_functiondef(target_function::oid);
    legacy_reference_count := (
      pg_catalog.length(function_definition)
      - pg_catalog.length(pg_catalog.replace(
          function_definition,
          'private.phase4a_actor_context',
          ''
        ))
    ) / pg_catalog.length('private.phase4a_actor_context');

    if legacy_reference_count <> 1 then
      raise exception
        'Inventory Items modern-access migration expected one legacy context reference in %, found %',
        target_function::text,
        legacy_reference_count
        using errcode = '55000';
    end if;

    execute pg_catalog.replace(
      function_definition,
      'private.phase4a_actor_context',
      'private.inventory_items_actor_context'
    );
  end loop;
end
$$;

do $$
begin
  if exists (
    select 1
    from pg_catalog.pg_proc procedure
    join pg_catalog.pg_namespace namespace on namespace.oid = procedure.pronamespace
    where (namespace.nspname, procedure.proname) in (
      ('private', 'inventory_items_state_json'),
      ('public', 'save_inventory_items_draft'),
      ('public', 'submit_inventory_items'),
      ('public', 'update_inventory_beef_production_field_labels'),
      ('public', 'create_inventory_beef_production_row'),
      ('public', 'update_inventory_beef_production_row'),
      ('public', 'delete_inventory_item_usage_item')
    )
      and pg_catalog.pg_get_functiondef(procedure.oid) like '%private.phase4a_actor_context%'
  ) then
    raise exception 'Inventory Items legacy authorization reference remains'
      using errcode = '55000';
  end if;
end
$$;

-- Public read wrappers already delegate to inventory_items_state_json. Reassert
-- the complete browser/service-role boundary for every affected public RPC.
revoke all on function public.get_inventory_items_current_state(uuid,uuid),
  public.get_inventory_items_current_state(uuid,uuid,date),
  public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb),
  public.submit_inventory_items(uuid,uuid,uuid,text,jsonb,jsonb),
  public.update_inventory_beef_production_field_labels(uuid,uuid,text,text,text),
  public.create_inventory_beef_production_row(uuid,uuid,date,jsonb),
  public.update_inventory_beef_production_row(uuid,uuid,uuid,timestamptz,jsonb),
  public.delete_inventory_item_usage_item(uuid,uuid,uuid)
  from public, anon, authenticated;

grant execute on function public.get_inventory_items_current_state(uuid,uuid),
  public.get_inventory_items_current_state(uuid,uuid,date),
  public.save_inventory_items_draft(uuid,uuid,jsonb,jsonb),
  public.submit_inventory_items(uuid,uuid,uuid,text,jsonb,jsonb),
  public.update_inventory_beef_production_field_labels(uuid,uuid,text,text,text),
  public.create_inventory_beef_production_row(uuid,uuid,date,jsonb),
  public.update_inventory_beef_production_row(uuid,uuid,uuid,timestamptz,jsonb),
  public.delete_inventory_item_usage_item(uuid,uuid,uuid)
  to service_role;
