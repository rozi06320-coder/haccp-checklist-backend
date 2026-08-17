create or replace function private.account_audit_details_are_safe(candidate jsonb)
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

      if normalized_key like '%password%'
        or normalized_key like '%accesstoken%'
        or normalized_key like '%refreshtoken%'
        or normalized_key like '%servicerole%'
        or normalized_key like '%secret%'
      then
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
grant execute on function private.account_audit_details_are_safe(jsonb) to service_role;

comment on function private.account_audit_details_are_safe(jsonb) is
  'Defense-in-depth rejection of obvious secret-bearing JSON keys and variants, including nested keys. This constraint does not replace mandatory server-side allowlisting and redaction.';
