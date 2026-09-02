-- Repair the two Maintenance cleaners that attempted to call pg_catalog.nullif
-- as a function. Keep their existing signatures, attributes, and validation.

create or replace function private.clean_maintenance_payment_method(candidate text)
returns text
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  cleaned text := pg_catalog.btrim(coalesce(candidate, ''));
begin
  if cleaned = '' then
    return null;
  end if;
  if cleaned not in ('cash', 'credit_card', 'pay_later') then
    raise exception 'invalid maintenance payment method' using errcode = '22023';
  end if;
  return cleaned;
end;
$$;

create or replace function private.clean_maintenance_responsible_person(candidate text)
returns text
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  cleaned text := pg_catalog.btrim(coalesce(candidate, ''));
begin
  if cleaned = '' then
    return null;
  end if;
  if pg_catalog.char_length(cleaned) > 100 then
    raise exception 'invalid maintenance responsible person' using errcode = '22023';
  end if;
  return cleaned;
end;
$$;
