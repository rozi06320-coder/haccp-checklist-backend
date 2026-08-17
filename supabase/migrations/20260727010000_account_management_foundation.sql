alter table public.profiles
  add column must_change_password boolean not null default false,
  add column disabled_at timestamptz;

comment on column public.profiles.must_change_password is
  'Controlled only by trusted server/admin code. Clear only after the Auth password update succeeds, in the same server workflow that appends a password_changed audit row.';
comment on column public.profiles.disabled_at is
  'Controlled only by trusted server/admin code; authenticated application users have no UPDATE privilege on this column.';

alter table public.branches
  add constraint branches_id_organization_id_key unique (id, organization_id);

create function private.account_audit_details_are_safe(candidate jsonb)
returns boolean
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  item jsonb;
  item_key text;
  normalized_key text;
begin
  if candidate is null then
    return false;
  end if;

  if jsonb_typeof(candidate) = 'object' then
    for item_key, item in
      select entry.key, entry.value
      from pg_catalog.jsonb_each(candidate) as entry
    loop
      normalized_key := pg_catalog.regexp_replace(
        pg_catalog.lower(item_key),
        '[^a-z0-9]+',
        '',
        'g'
      );

      if normalized_key in (
        'password',
        'temporarypassword',
        'accesstoken',
        'refreshtoken',
        'servicerole',
        'secret'
      ) then
        return false;
      end if;

      if not private.account_audit_details_are_safe(item) then
        return false;
      end if;
    end loop;
  elsif jsonb_typeof(candidate) = 'array' then
    for item in
      select element.value
      from pg_catalog.jsonb_array_elements(candidate) as element
    loop
      if not private.account_audit_details_are_safe(item) then
        return false;
      end if;
    end loop;
  end if;

  return true;
end;
$$;

revoke all on function private.account_audit_details_are_safe(jsonb) from public;
revoke all on function private.account_audit_details_are_safe(jsonb) from anon;
revoke all on function private.account_audit_details_are_safe(jsonb) from authenticated;
grant usage on schema private to service_role;
grant execute on function private.account_audit_details_are_safe(jsonb) to service_role;

comment on function private.account_audit_details_are_safe(jsonb) is
  'Defense-in-depth rejection of obvious secret-bearing JSON keys, including nested keys. This constraint does not replace mandatory server-side allowlisting and redaction.';

create table public.account_management_audit_logs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null
    references public.organizations(id) on delete restrict,
  actor_user_id uuid
    references auth.users(id) on delete set null,
  target_user_id uuid
    references auth.users(id) on delete set null,
  branch_id uuid,
  action text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint account_management_audit_logs_action_check check (
    action in (
      'user_created',
      'user_disabled',
      'user_enabled',
      'temporary_password_reset',
      'password_changed',
      'branch_assignment_added',
      'branch_assignment_removed',
      'branch_role_changed'
    )
  ),
  constraint account_management_audit_logs_details_object_check check (
    jsonb_typeof(details) = 'object'
  ),
  constraint account_management_audit_logs_details_safe_check check (
    private.account_audit_details_are_safe(details)
  ),
  constraint account_management_audit_logs_branch_organization_fkey
    foreign key (branch_id, organization_id)
    references public.branches(id, organization_id)
    on delete set null (branch_id)
);

comment on table public.account_management_audit_logs is
  'Append-only account-management history. Application roles may only read through RLS; trusted server/admin code is responsible for inserts and server-side detail redaction. Organization deletion is restricted to retain tenant attribution.';

create index account_management_audit_logs_organization_created_at_idx
  on public.account_management_audit_logs (organization_id, created_at desc);
create index account_management_audit_logs_target_user_id_idx
  on public.account_management_audit_logs (target_user_id)
  where target_user_id is not null;
create index account_management_audit_logs_branch_id_idx
  on public.account_management_audit_logs (branch_id)
  where branch_id is not null;

alter table public.account_management_audit_logs enable row level security;

create policy account_management_audit_logs_select_organization_manager
on public.account_management_audit_logs
for select
to authenticated
using (private.is_organization_manager(organization_id));

revoke all on table public.account_management_audit_logs
  from public, anon, authenticated, service_role;
grant select on table public.account_management_audit_logs to authenticated;
grant insert on table public.account_management_audit_logs to service_role;

grant update (must_change_password, disabled_at)
  on table public.profiles
  to service_role;
