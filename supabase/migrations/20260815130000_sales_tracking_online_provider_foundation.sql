-- Extensible Online Order provider foundation for Sales Tracking.
-- Existing sales_tracking_sales_rows.online_delivery remains the aggregate compatibility value.

create table public.sales_tracking_online_order_providers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  branch_id uuid not null references public.branches(id) on delete cascade,
  name text not null,
  normalized_name text not null,
  default_provider_key text null,
  is_default boolean not null default false,
  active boolean not null default true,
  created_by uuid null references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sales_tracking_online_order_provider_name_check check (
    name = btrim(name) and length(name) between 1 and 120
  ),
  constraint sales_tracking_online_order_provider_normalized_check check (
    normalized_name = lower(normalized_name)
    and normalized_name = btrim(normalized_name)
    and length(normalized_name) between 1 and 120
  ),
  constraint sales_tracking_online_order_provider_default_key_check check (
    default_provider_key is null
    or default_provider_key ~ '^[a-z0-9]+(?:_[a-z0-9]+)*$'
  )
);

create unique index sales_tracking_online_order_providers_branch_name_uidx
  on public.sales_tracking_online_order_providers(branch_id, normalized_name);
create unique index sales_tracking_online_order_providers_branch_default_uidx
  on public.sales_tracking_online_order_providers(branch_id, default_provider_key)
  where default_provider_key is not null;
create index sales_tracking_online_order_providers_branch_active_idx
  on public.sales_tracking_online_order_providers(branch_id, active, is_default desc, name);

create trigger sales_tracking_online_order_providers_set_updated_at
before update on public.sales_tracking_online_order_providers
for each row execute function private.set_updated_at();

create table public.sales_tracking_online_amounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  branch_id uuid not null references public.branches(id) on delete cascade,
  report_id uuid not null references public.sales_tracking_reports(id) on delete cascade,
  sales_row_id uuid not null references public.sales_tracking_sales_rows(id) on delete cascade,
  provider_id uuid not null references public.sales_tracking_online_order_providers(id) on delete restrict,
  amount numeric not null check (amount >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(sales_row_id, provider_id)
);

create index sales_tracking_online_amounts_provider_idx
  on public.sales_tracking_online_amounts(provider_id);
create index sales_tracking_online_amounts_report_idx
  on public.sales_tracking_online_amounts(report_id);

create trigger sales_tracking_online_amounts_set_updated_at
before update on public.sales_tracking_online_amounts
for each row execute function private.set_updated_at();

create function private.normalize_sales_tracking_online_provider_name(value text)
returns text language sql immutable security definer set search_path = '' as $$
  select lower(regexp_replace(btrim(coalesce(value, '')), '\s+', ' ', 'g'))
$$;
revoke all on function private.normalize_sales_tracking_online_provider_name(text) from public, anon, authenticated;

create function private.prepare_sales_tracking_online_order_provider()
returns trigger language plpgsql security definer set search_path = '' as $$
declare branch_org uuid;
begin
  new.name := regexp_replace(btrim(coalesce(new.name, '')), '\s+', ' ', 'g');
  new.normalized_name := private.normalize_sales_tracking_online_provider_name(new.name);

  if length(new.name) not between 1 and 120 or length(new.normalized_name) not between 1 and 120 then
    raise exception 'invalid sales tracking online provider name' using errcode = '22023';
  end if;

  select branch.organization_id into branch_org
  from public.branches branch
  where branch.id = new.branch_id;

  if branch_org is null or branch_org <> new.organization_id then
    raise exception 'invalid sales tracking online provider scope' using errcode = '23514';
  end if;

  if new.default_provider_key is not null then
    new.default_provider_key := lower(btrim(new.default_provider_key));
    new.is_default := true;
  end if;

  return new;
end $$;
revoke all on function private.prepare_sales_tracking_online_order_provider() from public, anon, authenticated;

create trigger sales_tracking_online_order_provider_prepare
before insert or update on public.sales_tracking_online_order_providers
for each row execute function private.prepare_sales_tracking_online_order_provider();

create function private.seed_sales_tracking_default_online_providers(target_organization_id uuid, target_branch_id uuid)
returns void language sql security definer set search_path = '' as $$
  insert into public.sales_tracking_online_order_providers(
    organization_id, branch_id, name, normalized_name, default_provider_key, is_default, created_by
  )
  select target_organization_id, target_branch_id, provider.name,
    private.normalize_sales_tracking_online_provider_name(provider.name), provider.provider_key, true, null::uuid
  from (values
    ('jahez', 'Jahez'),
    ('ninja', 'Ninja'),
    ('hungerstation', 'HungerStation'),
    ('the_chef', 'The Chef'),
    ('try_order', 'Try Order')
  ) provider(provider_key, name)
  on conflict (branch_id, normalized_name) do nothing
$$;
revoke all on function private.seed_sales_tracking_default_online_providers(uuid,uuid) from public, anon, authenticated;

select private.seed_sales_tracking_default_online_providers(branch.organization_id, branch.id)
from public.branches branch;

create function private.seed_sales_tracking_default_online_providers_for_branch()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform private.seed_sales_tracking_default_online_providers(new.organization_id, new.id);
  return new;
end $$;
revoke all on function private.seed_sales_tracking_default_online_providers_for_branch() from public, anon, authenticated;

create trigger branches_seed_sales_tracking_default_online_providers
after insert on public.branches
for each row execute function private.seed_sales_tracking_default_online_providers_for_branch();

create function private.prepare_sales_tracking_online_amount()
returns trigger language plpgsql security definer set search_path = '' as $$
declare row_scope record;
begin
  select report.organization_id, report.branch_id, row.report_id
    into row_scope
  from public.sales_tracking_sales_rows row
  join public.sales_tracking_reports report on report.id = row.report_id
  where row.id = new.sales_row_id;

  if row_scope.report_id is null then
    raise exception 'invalid sales tracking online amount scope' using errcode = '23514';
  end if;

  if not exists (
    select 1
    from public.sales_tracking_online_order_providers provider
    where provider.id = new.provider_id
      and provider.organization_id = row_scope.organization_id
      and provider.branch_id = row_scope.branch_id
      and provider.active
  ) then
    raise exception 'invalid sales tracking online provider scope' using errcode = '23514';
  end if;

  new.organization_id := row_scope.organization_id;
  new.branch_id := row_scope.branch_id;
  new.report_id := row_scope.report_id;
  return new;
end $$;
revoke all on function private.prepare_sales_tracking_online_amount() from public, anon, authenticated;

create trigger sales_tracking_online_amount_prepare
before insert or update on public.sales_tracking_online_amounts
for each row execute function private.prepare_sales_tracking_online_amount();

create function private.prevent_sales_tracking_online_amount_mutation()
returns trigger language plpgsql security definer set search_path = '' as $$
declare target_sales_row uuid := coalesce(old.sales_row_id, new.sales_row_id);
begin
  if exists (
    select 1
    from public.sales_tracking_sales_rows row
    join public.sales_tracking_reports report on report.id = row.report_id
    where row.id = target_sales_row
      and (row.period_entry_id is not null or report.state = 'submitted')
  ) then
    raise exception 'saved sales tracking online provider data is immutable' using errcode = '55000';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end $$;
revoke all on function private.prevent_sales_tracking_online_amount_mutation() from public, anon, authenticated;

create trigger sales_tracking_online_amounts_immutable
before update or delete on public.sales_tracking_online_amounts
for each row execute function private.prevent_sales_tracking_online_amount_mutation();

create function private.validate_sales_tracking_online_amount_total()
returns trigger language plpgsql security definer set search_path = '' as $$
declare target_sales_row uuid := coalesce(new.sales_row_id, old.sales_row_id);
declare row_total numeric;
declare provider_total numeric;
declare provider_count bigint;
begin
  select row.online_delivery into row_total
  from public.sales_tracking_sales_rows row
  where row.id = target_sales_row;

  if row_total is null then
    raise exception 'invalid sales tracking online amount row' using errcode = '23514';
  end if;

  select count(*), coalesce(sum(amount), 0::numeric)
    into provider_count, provider_total
  from public.sales_tracking_online_amounts
  where sales_row_id = target_sales_row;

  if provider_count > 0 and provider_total <> row_total then
    raise exception 'sales tracking online provider total mismatch' using errcode = '23514';
  end if;

  return null;
end $$;
revoke all on function private.validate_sales_tracking_online_amount_total() from public, anon, authenticated;

create constraint trigger sales_tracking_online_amounts_total_check
after insert or update or delete on public.sales_tracking_online_amounts
deferrable initially deferred
for each row execute function private.validate_sales_tracking_online_amount_total();

create function public.list_sales_tracking_online_order_providers(actor_user_id uuid, target_branch_id uuid)
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
      ) order by provider.is_default desc, provider.created_at, provider.name, provider.id)
      from public.sales_tracking_online_order_providers provider
      where provider.organization_id = c.organization_id
        and provider.branch_id = c.branch_id
        and provider.active
    ), '[]'::jsonb)
  );
exception when no_data_found or too_many_rows then
  raise exception 'sales tracking online provider access denied' using errcode = '42501';
end $$;

create function public.create_sales_tracking_online_order_provider(
  actor_user_id uuid,
  target_branch_id uuid,
  provider_name text
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c record;
declare provider public.sales_tracking_online_order_providers%rowtype;
begin
  select * into strict c from private.phase2_branch_context(actor_user_id, target_branch_id);

  insert into public.sales_tracking_online_order_providers(
    organization_id, branch_id, name, normalized_name, is_default, created_by
  )
  values (
    c.organization_id,
    c.branch_id,
    provider_name,
    private.normalize_sales_tracking_online_provider_name(provider_name),
    false,
    actor_user_id
  )
  returning * into provider;

  return pg_catalog.jsonb_build_object(
    'provider', pg_catalog.jsonb_build_object(
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
    )
  );
exception when no_data_found or too_many_rows then
  raise exception 'sales tracking online provider access denied' using errcode = '42501';
end $$;

alter table public.sales_tracking_online_order_providers enable row level security;
alter table public.sales_tracking_online_amounts enable row level security;

revoke all on public.sales_tracking_online_order_providers, public.sales_tracking_online_amounts
  from service_role, public, anon, authenticated;
revoke all on function public.list_sales_tracking_online_order_providers(uuid,uuid),
  public.create_sales_tracking_online_order_provider(uuid,uuid,text)
  from public, anon, authenticated;
grant execute on function public.list_sales_tracking_online_order_providers(uuid,uuid),
  public.create_sales_tracking_online_order_provider(uuid,uuid,text)
  to service_role;
