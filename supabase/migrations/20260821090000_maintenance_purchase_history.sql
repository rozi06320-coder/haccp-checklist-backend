create or replace function public.list_maintenance_purchase_history(actor_user_id uuid)
returns table(
  id uuid, organization_id uuid, branch_id uuid, branch_name text, maintenance_issue_id uuid,
  issue_title text, issue_category text, issue_status text, maintenance_user_id uuid,
  maintenance_user_name text, item_name text, quantity numeric, unit text, amount numeric, vendor_name text,
  purchase_date date, notes text, payment_status text, reimbursement_note text, reimbursed_at timestamptz,
  receipt_storage_path text, receipt_original_name text, attachments jsonb, created_at timestamptz, updated_at timestamptz
)
language plpgsql
security definer
set search_path=''
as $$
begin
  if not private.actor_has_active_maintenance_membership(actor_user_id,null) then
    raise exception 'maintenance purchase history access denied' using errcode='42501';
  end if;

  return query
    select p.id,p.organization_id,p.branch_id,b.name,p.maintenance_issue_id,i.title,i.category,i.status,p.maintenance_user_id,
      profile.full_name,p.item_name,p.quantity,p.unit,p.amount,p.vendor_name,p.purchase_date,p.notes,p.payment_status,p.reimbursement_note,
      p.reimbursed_at,p.receipt_storage_path,p.receipt_original_name,
      coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'storage_path',a.storage_path,'original_filename',a.original_filename,'mime_type',a.mime_type,'size_bytes',a.size_bytes,'position',a.position) order by a.position) from public.maintenance_purchase_attachments a where a.purchase_id=p.id),'[]'::jsonb) as attachments,
      p.created_at,p.updated_at
    from public.maintenance_purchase_logs p
    join public.branches b on b.id=p.branch_id
    join public.maintenance_issues i on i.id=p.maintenance_issue_id
    left join public.profiles profile on profile.id=p.maintenance_user_id
    where exists(
      select 1
      from public.maintenance_memberships membership
      join public.organizations organization on organization.id=membership.organization_id
      join public.profiles actor_profile on actor_profile.id=membership.user_id
      where membership.user_id=actor_user_id
        and membership.organization_id=p.organization_id
        and membership.active
        and organization.active
        and actor_profile.disabled_at is null
        and not actor_profile.must_change_password
    )
    order by p.purchase_date desc,p.created_at desc
    limit 1000;
end;
$$;

revoke all on function public.list_maintenance_purchase_history(uuid) from public,anon,authenticated;
grant execute on function public.list_maintenance_purchase_history(uuid) to service_role;
