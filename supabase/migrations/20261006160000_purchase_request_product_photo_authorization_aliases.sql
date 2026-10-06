create or replace function public.authorize_supervisor_purchase_request_item_product_photo(
  actor_user_id uuid,
  target_branch_id uuid,
  target_request_id uuid,
  target_item_id uuid
)
returns table(organization_id uuid, branch_id uuid, request_id uuid, item_id uuid)
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_scope record;
  v_request public.purchase_requests;
begin
  select scope_row.organization_id, scope_row.branch_id
  into v_scope
  from private.purchase_request_actor_branch_scope(actor_user_id, target_branch_id) as scope_row;

  select pr.*
  into v_request
  from public.purchase_requests as pr
  where pr.id = target_request_id
    and pr.branch_id = target_branch_id
    and pr.organization_id = v_scope.organization_id;

  if not found then
    raise exception 'purchase request not found' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.purchase_request_items as pri
    where pri.id = target_item_id
      and pri.purchase_request_id = target_request_id
  ) then
    raise exception 'purchase request item not found' using errcode = '42501';
  end if;

  return query
  select v_request.organization_id, v_request.branch_id, v_request.id, target_item_id;
end;
$function$;

revoke all on function public.authorize_supervisor_purchase_request_item_product_photo(uuid, uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.authorize_supervisor_purchase_request_item_product_photo(uuid, uuid, uuid, uuid) to service_role;
