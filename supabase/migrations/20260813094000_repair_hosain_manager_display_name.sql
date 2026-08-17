do $$
declare
  target_user_id uuid;
  email_user_count integer;
  match_count integer;
begin
  select count(*)
    into email_user_count
  from auth.users auth_user
  where pg_catalog.lower(pg_catalog.btrim(auth_user.email::text)) = 'hosain@gmail.com';

  if email_user_count = 0 then
    raise notice 'display name repair skipped: hosain@gmail.com does not exist in this database';
    return;
  end if;

  select count(*), min(auth_user.id::text)::uuid
    into match_count, target_user_id
  from auth.users auth_user
  join public.organization_memberships membership on membership.user_id = auth_user.id
  join public.profiles profile on profile.id = auth_user.id
  where pg_catalog.lower(pg_catalog.btrim(auth_user.email::text)) = 'hosain@gmail.com'
    and membership.role = 'organization_manager'
    and membership.active;

  if match_count = 0 then
    raise exception 'display name repair failed: active organization manager not found for hosain@gmail.com'
      using errcode = 'P0002';
  end if;

  if match_count > 1 then
    raise exception 'display name repair failed: multiple active organization managers found for hosain@gmail.com'
      using errcode = '21000';
  end if;

  update public.profiles
  set full_name = 'Hosain',
      updated_at = now()
  where id = target_user_id
    and coalesce(full_name, '') is distinct from 'Hosain';
end $$;
