alter table public.organizations
  drop constraint if exists organizations_logo_path_check,
  add constraint organizations_logo_path_check
  check (
    logo_path is null
    or (
      length(logo_path) between 20 and 500
      and logo_path = btrim(logo_path)
      and logo_path ~ ('^organizations/' || id::text || '/logo/[0-9a-fA-F-]{36}\.(jpg|png|webp)$')
    )
  );

alter table public.branches
  drop constraint if exists branches_logo_path_check,
  add constraint branches_logo_path_check
  check (
    logo_path is null
    or (
      length(logo_path) between 20 and 500
      and logo_path = btrim(logo_path)
      and logo_path ~ ('^branches/' || id::text || '/logo/[0-9a-fA-F-]{36}\.(jpg|png|webp)$')
    )
  );
