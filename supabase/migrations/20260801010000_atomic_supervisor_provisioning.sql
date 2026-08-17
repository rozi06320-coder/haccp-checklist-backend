create or replace function public.finalize_provisioned_supervisor(
  p_actor_user_id uuid,
  p_organization_id uuid,
  p_new_user_id uuid,
  p_full_name text,
  p_branch_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  branch_id uuid;
  created_team_id uuid;
begin
  perform public.finalize_provisioned_user(
    p_actor_user_id,
    p_organization_id,
    p_new_user_id,
    p_full_name,
    'branch_manager',
    p_branch_ids
  );

  foreach branch_id in array p_branch_ids loop
    insert into public.branch_supervisor_teams (
      organization_id,
      branch_id,
      supervisor_user_id
    ) values (
      p_organization_id,
      branch_id,
      p_new_user_id
    )
    returning id into created_team_id;

    insert into public.account_management_audit_logs (
      organization_id,
      actor_user_id,
      target_user_id,
      branch_id,
      action,
      details
    ) values (
      p_organization_id,
      p_actor_user_id,
      p_new_user_id,
      branch_id,
      'supervisor_team_assigned',
      pg_catalog.jsonb_build_object(
        'team_id', created_team_id,
        'new_status', 'active'
      )
    );
  end loop;

  return pg_catalog.jsonb_build_object('success', true);
end;
$$;

revoke all on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[])
  from public, anon, authenticated;
grant execute on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[])
  to service_role;

comment on function public.finalize_provisioned_supervisor(uuid, uuid, uuid, text, uuid[]) is
  'Atomically finalizes a forced-password Branch Supervisor and creates one active shift-free team per selected branch. Service-role only.';
