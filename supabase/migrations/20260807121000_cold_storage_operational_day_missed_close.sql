create or replace function private.cold_storage_closed_slots_for(target_branch_id uuid, target_business_date date, as_of timestamptz default pg_catalog.statement_timestamp())
returns text[] language plpgsql stable security definer set search_path = '' as $$
declare branch_timezone text; local_date date; local_hour int;
begin
  select timezone into strict branch_timezone from public.branches where id = target_branch_id;
  local_date := (as_of at time zone branch_timezone)::date;
  local_hour := extract(hour from as_of at time zone branch_timezone)::int;

  if target_business_date < local_date - 1 then
    return array['12:00','3:00','8:00']::text[];
  elsif target_business_date = local_date - 1 then
    if local_hour >= 3 then
      return array['12:00','3:00','8:00']::text[];
    end if;
    return array[]::text[];
  end if;

  return array[]::text[];
end $$;

revoke all on function private.cold_storage_closed_slots_for(uuid,date,timestamptz) from public, anon, authenticated;
