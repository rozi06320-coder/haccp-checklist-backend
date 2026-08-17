create or replace function public.create_managed_branch(
  actor_user_id uuid,
  target_organization_id uuid,
  branch_name text,
  branch_timezone text default 'Asia/Riyadh',
  branch_active boolean default true
) returns table(id uuid, name text, code text, timezone text, active boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_name text := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(branch_name, '')), '\s+', ' ', 'g');
  normalized_timezone text := pg_catalog.btrim(coalesce(branch_timezone, 'Asia/Riyadh'));
  candidate_code text;
  suffix int := 0;
  created_branch public.branches%rowtype;
begin
  if not (
      private.actor_manages_active_organization(actor_user_id, target_organization_id)
      or private.is_internal_admin(actor_user_id)
    )
    or length(normalized_name) = 0
    or length(normalized_name) > 120
    or length(normalized_timezone) = 0
    or length(normalized_timezone) > 80
    or not exists (select 1 from pg_catalog.pg_timezone_names zone where zone.name = normalized_timezone)
    or not exists (select 1 from public.organizations organization where organization.id = target_organization_id and organization.active)
  then
    raise exception 'invalid branch creation request' using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.branches branch
    where branch.organization_id = target_organization_id
      and pg_catalog.lower(pg_catalog.btrim(branch.name)) = pg_catalog.lower(normalized_name)
  ) then
    raise exception 'branch already exists' using errcode = '23505';
  end if;

  loop
    candidate_code := private.branch_code_candidate(normalized_name, suffix);
    exit when not exists (
      select 1
      from public.branches branch
      where branch.organization_id = target_organization_id
        and branch.code = candidate_code
    );
    suffix := suffix + 1;
    if suffix > 999 then
      raise exception 'branch code generation failed' using errcode = '54000';
    end if;
  end loop;

  insert into public.branches(organization_id, name, code, timezone, active)
  values(target_organization_id, normalized_name, candidate_code, normalized_timezone, coalesce(branch_active, true))
  returning * into created_branch;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, branch_id, action, details)
  values(
    target_organization_id,
    actor_user_id,
    created_branch.id,
    'branch_created',
    pg_catalog.jsonb_build_object('branch_name', created_branch.name, 'branch_code', created_branch.code)
  );

  return query select created_branch.id, created_branch.name, created_branch.code, created_branch.timezone, created_branch.active;
end;
$$;

revoke all on function public.create_managed_branch(uuid,uuid,text,text,boolean) from public, anon, authenticated;
grant execute on function public.create_managed_branch(uuid,uuid,text,text,boolean) to service_role;
