do $$
declare conflict_count integer;
begin
  select pg_catalog.count(*) into conflict_count
  from (
    select staff.organization_id, pg_catalog.lower(pg_catalog.btrim(staff.staff_code)) as normalized_staff_code
    from public.operational_staff staff
    where staff.employment_status = 'active'
      and staff.staff_code is not null
      and pg_catalog.btrim(staff.staff_code) <> ''
    group by staff.organization_id, pg_catalog.lower(pg_catalog.btrim(staff.staff_code))
    having pg_catalog.count(*) > 1
  ) conflicts;

  if conflict_count <> 0 then
    raise exception 'employee code uniqueness migration blocked: active duplicate staff codes exist'
      using errcode = '23505';
  end if;
end $$;

alter table public.operational_staff
  add column if not exists country_code text;

create or replace function private.operational_staff_country_code_is_valid(candidate text)
returns boolean language sql immutable security invoker set search_path = ''
as $$
  select candidate = any(array[
    'AD','AE','AF','AG','AI','AL','AM','AO','AQ','AR','AS','AT','AU','AW','AX','AZ',
    'BA','BB','BD','BE','BF','BG','BH','BI','BJ','BL','BM','BN','BO','BQ','BR','BS','BT','BV','BW','BY','BZ',
    'CA','CC','CD','CF','CG','CH','CI','CK','CL','CM','CN','CO','CR','CU','CV','CW','CX','CY','CZ',
    'DE','DJ','DK','DM','DO','DZ','EC','EE','EG','EH','ER','ES','ET',
    'FI','FJ','FK','FM','FO','FR','GA','GB','GD','GE','GF','GG','GH','GI','GL','GM','GN','GP','GQ','GR','GS','GT','GU','GW','GY',
    'HK','HM','HN','HR','HT','HU','ID','IE','IL','IM','IN','IO','IQ','IR','IS','IT',
    'JE','JM','JO','JP','KE','KG','KH','KI','KM','KN','KP','KR','KW','KY','KZ',
    'LA','LB','LC','LI','LK','LR','LS','LT','LU','LV','LY',
    'MA','MC','MD','ME','MF','MG','MH','MK','ML','MM','MN','MO','MP','MQ','MR','MS','MT','MU','MV','MW','MX','MY','MZ',
    'NA','NC','NE','NF','NG','NI','NL','NO','NP','NR','NU','NZ','OM','PA','PE','PF','PG','PH','PK','PL','PM','PN','PR','PS','PT','PW','PY',
    'QA','RE','RO','RS','RU','RW','SA','SB','SC','SD','SE','SG','SH','SI','SJ','SK','SL','SM','SN','SO','SR','SS','ST','SV','SX','SY','SZ',
    'TC','TD','TF','TG','TH','TJ','TK','TL','TM','TN','TO','TR','TT','TV','TW','TZ',
    'UA','UG','UM','US','UY','UZ','VA','VC','VE','VG','VI','VN','VU','WF','WS','YE','YT','ZA','ZM','ZW'
  ]::text[])
$$;

create or replace function private.clean_operational_staff_country_code(value text)
returns text language sql immutable security invoker set search_path = ''
as $$
  select case
    when nullif(pg_catalog.btrim(coalesce(value, '')), '') is null then null
    else pg_catalog.upper(pg_catalog.btrim(value))
  end
$$;

alter table public.operational_staff
  drop constraint if exists operational_staff_country_code_check;

alter table public.operational_staff
  add constraint operational_staff_country_code_check
  check (
    country_code is null
    or (
      country_code = pg_catalog.upper(pg_catalog.btrim(country_code))
      and private.operational_staff_country_code_is_valid(country_code)
    )
  );

create unique index if not exists operational_staff_active_org_staff_code_key
  on public.operational_staff(organization_id, pg_catalog.lower(pg_catalog.btrim(staff_code)))
  where employment_status = 'active' and staff_code is not null;

create or replace function private.operational_roles_are_valid(candidate text[])
returns boolean language sql immutable security invoker set search_path = ''
as $$
  select candidate is not null
    and pg_catalog.cardinality(candidate) between 1 and 2
    and not candidate @> array[null]::text[]
    and (select pg_catalog.count(*) = pg_catalog.count(distinct value)
      from pg_catalog.unnest(candidate) value)
    and candidate <@ array['kitchen','dispatcher','production','front_of_house','cleaner','cashier']::text[]
$$;

drop function if exists public.get_supervisor_operational_team(uuid, uuid, date);
create function public.get_supervisor_operational_team(actor_user_id uuid,target_branch_id uuid,requested_date date)
returns table(team_id uuid,team_name text,team_active boolean,can_write boolean,assignment_role text,
  company_name text,staff_id uuid,display_name text,staff_company_name text,staff_code text,country_code text,
  iqama_number text,iqama_expiry_date date,phone_number text,email text,employment_status text,
  assignment_id uuid,operational_roles text[],duty_status text)
language plpgsql security definer set search_path = '' as $$
begin
  if requested_date is null or not private.actor_can_read_operational_branch(actor_user_id,target_branch_id)
  then raise exception 'team access denied' using errcode='42501'; end if;
  return query
  select team.id,team.name,team.active,private.actor_can_write_operational_team(actor_user_id,target_branch_id,team.id),
    actor_assignment.assignment_role,coalesce(legacy.company_name,organization.name),
    staff.id,staff.display_name,staff.company_name,staff.staff_code,staff.country_code,staff.iqama_number,staff.iqama_expiry_date,
    staff.phone_number,staff.email,staff.employment_status,assignment.id,assignment.operational_roles,
    coalesce(duty.duty_status,'on_duty')
  from public.branch_operational_teams team
  join public.organizations organization on organization.id=team.organization_id
  left join public.branch_supervisor_teams legacy on legacy.id=team.legacy_supervisor_team_id
  left join public.branch_operational_team_supervisors actor_assignment
    on actor_assignment.operational_team_id=team.id and actor_assignment.supervisor_user_id=actor_user_id and actor_assignment.active
  left join public.operational_staff_assignments assignment
    on assignment.operational_team_id=team.id and assignment.active
  left join public.operational_staff staff on staff.id=assignment.operational_staff_id
  left join public.operational_staff_duty_statuses duty
    on duty.assignment_id=assignment.id and duty.duty_date=requested_date
  where team.branch_id=target_branch_id and team.active
  order by case actor_assignment.assignment_role when 'primary' then 0 when 'backup' then 1 else 2 end,
    team.normalized_name,pg_catalog.lower(staff.display_name),staff.id;
end $$;

drop function if exists public.create_operational_team_staff(uuid,uuid,uuid,text,text[],text,text,text,date,text,text);
create function public.create_operational_team_staff(actor_user_id uuid,target_branch_id uuid,target_operational_team_id uuid,
  new_display_name text,new_operational_roles text[],new_staff_code text,new_company_name text,new_country_code text,
  new_iqama_number text,new_iqama_expiry_date date,new_phone_number text,new_email text)
returns table(staff_id uuid,assignment_id uuid,duplicate_name_warning boolean,country_code text,iqama_number text,iqama_expiry_date date,phone_number text,email text)
language plpgsql security definer set search_path = '' as $$
declare target_team public.branch_operational_teams%rowtype; created_staff uuid; created_assignment uuid;
 clean_name text:=pg_catalog.regexp_replace(pg_catalog.btrim(new_display_name),'[[:space:]]+',' ','g');
 clean_code text:=private.clean_operational_staff_code(new_staff_code);
 clean_company text:=private.clean_operational_staff_company_name(new_company_name);
 clean_country text:=private.clean_operational_staff_country_code(new_country_code);
 clean_iqama text:=private.clean_operational_staff_optional_text(new_iqama_number,80);
 clean_phone text:=private.clean_operational_staff_optional_text(new_phone_number,40);
 clean_email text:=private.clean_operational_staff_email(new_email);
begin
  select * into strict target_team from public.branch_operational_teams
  where id=target_operational_team_id and branch_id=target_branch_id and active for update;
  if not private.actor_can_write_operational_team(actor_user_id,target_branch_id,target_team.id)
    or target_team.legacy_supervisor_team_id is null or length(clean_name) not between 1 and 120
    or length(coalesce(clean_company,'')) not between 1 and 160
    or (clean_code is not null and length(clean_code) not between 1 and 80)
    or (clean_country is not null and not private.operational_staff_country_code_is_valid(clean_country))
    or not private.operational_roles_are_valid(new_operational_roles)
  then raise exception 'staff operation denied' using errcode='42501'; end if;
  insert into public.operational_staff(organization_id,branch_id,display_name,company_name,staff_code,country_code,iqama_number,iqama_expiry_date,phone_number,email,created_by)
  values(target_team.organization_id,target_branch_id,clean_name,clean_company,clean_code,clean_country,clean_iqama,new_iqama_expiry_date,clean_phone,clean_email,actor_user_id)
  returning id into created_staff;
  insert into public.operational_staff_assignments(organization_id,branch_id,operational_staff_id,supervisor_team_id,
    operational_team_id,operational_roles,created_by_user_id)
  values(target_team.organization_id,target_branch_id,created_staff,target_team.legacy_supervisor_team_id,
    target_team.id,new_operational_roles,actor_user_id)
  returning id into created_assignment;
  insert into public.account_management_audit_logs(organization_id,actor_user_id,branch_id,action,details)
  values(target_team.organization_id,actor_user_id,target_branch_id,'operational_staff_created',
    pg_catalog.jsonb_build_object('team_id',target_team.id,'operational_staff_id',created_staff,
      'assignment_id',created_assignment,'operational_roles',new_operational_roles));
  return query select created_staff,created_assignment,false,clean_country,clean_iqama,new_iqama_expiry_date,clean_phone,clean_email;
exception when unique_violation then raise exception 'employee code already exists' using errcode='23505';
when no_data_found or too_many_rows then raise exception 'staff operation denied' using errcode='42501';
end $$;

drop function if exists public.update_operational_team_staff(uuid,uuid,uuid,text,text,text[],text,text,text,date,text,text);
create function public.update_operational_team_staff(actor_user_id uuid,target_branch_id uuid,target_staff_id uuid,
  new_display_name text,new_employment_status text,new_operational_roles text[],new_staff_code text,new_company_name text,new_country_code text,
  new_iqama_number text,new_iqama_expiry_date date,new_phone_number text,new_email text)
returns table(staff_id uuid,assignment_id uuid,duplicate_name_warning boolean,country_code text,iqama_number text,iqama_expiry_date date,phone_number text,email text)
language plpgsql security definer set search_path = '' as $$
declare assignment_row public.operational_staff_assignments%rowtype;
 clean_name text:=pg_catalog.regexp_replace(pg_catalog.btrim(new_display_name),'[[:space:]]+',' ','g');
 clean_code text:=private.clean_operational_staff_code(new_staff_code);
 clean_company text:=private.clean_operational_staff_company_name(new_company_name);
 clean_country text:=private.clean_operational_staff_country_code(new_country_code);
 clean_iqama text:=private.clean_operational_staff_optional_text(new_iqama_number,80);
 clean_phone text:=private.clean_operational_staff_optional_text(new_phone_number,40);
 clean_email text:=private.clean_operational_staff_email(new_email);
begin
  select assignment.* into strict assignment_row
  from public.operational_staff_assignments assignment
  join public.operational_staff staff on staff.id=assignment.operational_staff_id
  where assignment.operational_staff_id=target_staff_id and assignment.active and staff.branch_id=target_branch_id
  for update of assignment,staff;
  if not private.actor_can_write_operational_team(actor_user_id,target_branch_id,assignment_row.operational_team_id)
    or new_employment_status<>'active' or length(clean_name) not between 1 and 120
    or length(coalesce(clean_company,'')) not between 1 and 160
    or (clean_code is not null and length(clean_code) not between 1 and 80)
    or (clean_country is not null and not private.operational_staff_country_code_is_valid(clean_country))
    or not private.operational_roles_are_valid(new_operational_roles)
  then raise exception 'staff operation denied' using errcode='42501'; end if;
  update public.operational_staff set display_name=clean_name,company_name=clean_company,staff_code=clean_code,country_code=clean_country,
    iqama_number=clean_iqama,iqama_expiry_date=new_iqama_expiry_date,phone_number=clean_phone,email=clean_email
  where id=target_staff_id;
  update public.operational_staff_assignments set operational_roles=new_operational_roles
  where id=assignment_row.id returning * into assignment_row;
  return query select target_staff_id,assignment_row.id,false,clean_country,clean_iqama,new_iqama_expiry_date,clean_phone,clean_email;
exception when unique_violation then raise exception 'employee code already exists' using errcode='23505';
when no_data_found or too_many_rows then raise exception 'staff operation denied' using errcode='42501';
end $$;

drop function if exists public.list_managed_operational_staff(uuid,uuid,integer,integer,text,uuid,uuid,text,text,date);
create function public.list_managed_operational_staff(actor_user_id uuid,target_organization_id uuid,
 requested_page integer default 1,requested_page_size integer default 20,search_term text default null,
 branch_filter uuid default null,supervisor_filter uuid default null,role_filter text default null,
 employment_filter text default null,requested_date date default null)
returns table(staff_id uuid,display_name text,staff_code text,country_code text,employment_status text,branch_id uuid,branch_name text,
 supervisor_user_id uuid,supervisor_name text,team_id uuid,assignment_id uuid,
 operational_roles text[],duty_status text,total_count bigint)
language plpgsql security definer set search_path = ''
as $$
begin
 if requested_page<1 or requested_page_size not between 1 and 50 or length(coalesce(search_term,''))>120
  or (role_filter is not null and role_filter not in ('kitchen','dispatcher','production','front_of_house','cleaner','cashier'))
  or (employment_filter is not null and employment_filter not in ('active','inactive'))
  or not private.actor_manages_active_organization(actor_user_id,target_organization_id)
 then raise exception 'listing denied' using errcode='42501'; end if;
 return query select staff.id,staff.display_name,staff.staff_code,staff.country_code,staff.employment_status,branch.id,branch.name,
  team.supervisor_user_id,profile.full_name,team.id,assignment.id,assignment.operational_roles,
  coalesce(duty.duty_status,'on_duty'),count(*) over()
 from public.operational_staff staff join public.branches branch on branch.id=staff.branch_id
 left join public.operational_staff_assignments assignment
  on assignment.operational_staff_id=staff.id and assignment.active
 left join public.branch_supervisor_teams team on team.id=assignment.supervisor_team_id
 left join public.profiles profile on profile.id=team.supervisor_user_id
 left join public.operational_staff_duty_statuses duty
  on duty.assignment_id=assignment.id and duty.duty_date=requested_date
 where staff.organization_id=target_organization_id
  and (nullif(btrim(search_term),'') is null
    or staff.normalized_name like '%'||private.normalize_operational_staff_name(search_term)||'%')
  and (branch_filter is null or staff.branch_id=branch_filter)
  and (supervisor_filter is null or team.supervisor_user_id=supervisor_filter)
  and (role_filter is null or assignment.operational_roles @> array[role_filter])
  and (employment_filter is null or staff.employment_status=employment_filter)
 order by staff.normalized_name,staff.id limit requested_page_size
 offset ((requested_page-1)::bigint*requested_page_size);
end $$;

create or replace function public.list_managed_employee_team(
  actor_user_id uuid,target_organization_id uuid,branch_filter uuid default null,requested_month date default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare result jsonb;
begin
  if requested_month is null or requested_month<>pg_catalog.date_trunc('month',requested_month)::date
    or not private.actor_manages_active_organization(actor_user_id,target_organization_id)
    or (branch_filter is not null and not exists(select 1 from public.branches
      where id=branch_filter and organization_id=target_organization_id))
  then raise exception 'employee team access denied' using errcode='42501'; end if;
  select pg_catalog.jsonb_build_object(
    'employees',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'staff_id',staff.id,'display_name',staff.display_name,'staff_code',staff.staff_code,'country_code',staff.country_code,
      'employment_status',staff.employment_status,'company_name',staff.company_name,
      'iqama_number',staff.iqama_number,'phone_number',staff.phone_number,'email',staff.email,
      'branch_id',branch.id,'branch_name',branch.name,'branch_name_ar',branch.name_ar,
      'supervisor_name',profile.full_name,'supervisor_name_ar',profile.full_name_ar,
      'assignment_id',assignment.id,'operational_team_id',operational_team.id,
      'operational_team_name',operational_team.name,'operational_roles',assignment.operational_roles,
      'duty_status',case when staff.employment_status='active' and assignment.id is not null
        then coalesce(duty.duty_status,'on_duty') else null end
    ) order by staff.normalized_name,staff.id)
    from public.operational_staff staff
    join public.branches branch on branch.id=staff.branch_id
    left join public.operational_staff_assignments assignment
      on assignment.operational_staff_id=staff.id and assignment.active
    left join public.branch_operational_teams operational_team on operational_team.id=assignment.operational_team_id
    left join public.branch_supervisor_teams team on team.id=assignment.supervisor_team_id
    left join public.profiles profile on profile.id=team.supervisor_user_id
    left join public.operational_staff_duty_statuses duty on duty.assignment_id=assignment.id
      and duty.duty_date=private.phase4a_business_date(branch.timezone)
    where staff.organization_id=target_organization_id
      and (branch_filter is null or staff.branch_id=branch_filter)),'[]'::jsonb),
    'operational_teams',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',team.id,'branch_id',branch.id,'branch_name',branch.name,'branch_name_ar',branch.name_ar,
      'name',team.name,'active',team.active
    ) order by pg_catalog.lower(branch.name),team.normalized_name,team.id)
    from public.branch_operational_teams team join public.branches branch on branch.id=team.branch_id
    where team.organization_id=target_organization_id and team.active),'[]'::jsonb),
    'health_cards',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',card.id,'operational_staff_id',staff.id,'display_name',staff.display_name,
      'branch_id',branch.id,'branch_name',branch.name,'branch_name_ar',branch.name_ar,
      'certificate_number',card.certificate_number,'status',card.status,'place_of_issue',card.place_of_issue,
      'expiry_date',card.expiry_date,'date_issue',card.date_issue,'occupation',card.occupation,
      'company',card.company,'branch_name_snapshot',card.branch_name_snapshot,'notes',card.notes,'updated_at',card.updated_at
    ) order by pg_catalog.lower(staff.display_name),staff.id)
    from public.operational_staff_health_cards card
    join public.operational_staff staff on staff.id=card.operational_staff_id and staff.organization_id=target_organization_id
    join public.branches branch on branch.id=staff.branch_id
    where branch_filter is null or staff.branch_id=branch_filter),'[]'::jsonb),
    'monthly_evaluations',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',evaluation.id,'operational_staff_id',staff.id,'display_name',staff.display_name,
      'branch_id',branch.id,'branch_name',branch.name,'branch_name_ar',branch.name_ar,
      'evaluation_month',evaluation.evaluation_month,'evaluator_name',evaluation.evaluator_name,
      'status',evaluation.status,'average_score',evaluation.average_score,
      'scores',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'section',score.section,'factor_key',score.factor_key,'factor_label',score.factor_label,
        'rating',score.rating,'comment',score.comment) order by score.section,score.factor_key)
        from public.operational_staff_monthly_evaluation_scores score
        where score.evaluation_id=evaluation.id),'[]'::jsonb),'updated_at',evaluation.updated_at
    ) order by pg_catalog.lower(staff.display_name),staff.id)
    from public.operational_staff_monthly_evaluations evaluation
    join public.operational_staff staff on staff.id=evaluation.operational_staff_id
      and staff.organization_id=target_organization_id
    join public.branches branch on branch.id=staff.branch_id
    where evaluation.evaluation_month=requested_month
      and (branch_filter is null or staff.branch_id=branch_filter)),'[]'::jsonb)
  ) into result;
  return result;
end $$;

create or replace function public.list_internal_admin_branch_teams(
  actor_user_id uuid,
  target_organization_id uuid
)
returns table(
  team_id uuid,
  organization_id uuid,
  company_name text,
  branch_id uuid,
  branch_name text,
  branch_name_ar text,
  branch_code text,
  supervisor_user_id uuid,
  supervisor_name text,
  supervisor_name_ar text,
  supervisor_email text,
  supervisor_role text,
  active boolean,
  operational_staff_count bigint,
  staff jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.organizations organization
    where organization.id = target_organization_id
      and organization.active
  ) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  return query
    select
      team.id,
      team.organization_id,
      team.company_name,
      branch.id,
      branch.name,
      branch.name_ar,
      branch.code,
      team.supervisor_user_id,
      profile.full_name,
      profile.full_name_ar,
      auth_user.email::text,
      membership.role,
      team.active,
      count(assignment.id) filter (where assignment.active),
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'staff_id', staff.id,
            'display_name', staff.display_name,
            'company_name', staff.company_name,
            'staff_code', staff.staff_code,
            'country_code', staff.country_code,
            'employment_status', staff.employment_status,
            'assignment_id', assignment.id,
            'operational_roles', assignment.operational_roles
          )
          order by pg_catalog.lower(staff.display_name), staff.id
        ) filter (where staff.id is not null and assignment.active),
        '[]'::jsonb
      ) as staff
    from public.branch_supervisor_teams team
    join public.branches branch on branch.id = team.branch_id
    join public.profiles profile on profile.id = team.supervisor_user_id
    join auth.users auth_user on auth_user.id = team.supervisor_user_id
    join public.branch_memberships membership
      on membership.branch_id = team.branch_id
      and membership.user_id = team.supervisor_user_id
      and membership.role = 'branch_manager'
    left join public.operational_staff_assignments assignment on assignment.supervisor_team_id = team.id
    left join public.operational_staff staff on staff.id = assignment.operational_staff_id
    where team.organization_id = target_organization_id
      and branch.organization_id = target_organization_id
    group by team.id, team.organization_id, team.company_name, branch.id, branch.name, branch.name_ar, branch.code,
      team.supervisor_user_id, profile.full_name, profile.full_name_ar, auth_user.email, membership.role, team.active
    order by coalesce(team.company_name, ''), branch.name, profile.full_name, auth_user.email, team.id
    limit 500;
end;
$$;

drop function if exists public.create_internal_admin_branch_team_staff(uuid, uuid, uuid, text, text, text, text[]);
create function public.create_internal_admin_branch_team_staff(
  actor_user_id uuid,
  target_organization_id uuid,
  target_team_id uuid,
  new_display_name text,
  new_company_name text,
  new_staff_code text,
  new_country_code text,
  new_operational_roles text[]
)
returns table(staff_id uuid, assignment_id uuid, duplicate_name_warning boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_team public.branch_supervisor_teams%rowtype;
  created_staff uuid;
  created_assignment uuid;
  clean_name text := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(new_display_name, '')), '[[:space:]]+', ' ', 'g');
  clean_company_name text := private.clean_operational_staff_company_name(new_company_name);
  clean_code text := private.clean_operational_staff_code(new_staff_code);
  clean_country text := private.clean_operational_staff_country_code(new_country_code);
begin
  if not private.is_internal_admin(actor_user_id) then
    raise exception 'internal admin access denied' using errcode = '42501';
  end if;

  select team.*
    into strict target_team
  from public.branch_supervisor_teams team
  join public.branches branch on branch.id = team.branch_id
  join public.organizations organization on organization.id = team.organization_id
  where team.id = target_team_id
    and team.organization_id = target_organization_id
    and team.active
    and branch.active
    and organization.active
  for update;

  if length(clean_name) not between 1 and 120
    or length(coalesce(clean_company_name, '')) not between 1 and 160
    or (clean_code is not null and length(clean_code) not between 1 and 80)
    or (clean_country is not null and not private.operational_staff_country_code_is_valid(clean_country))
    or not private.operational_roles_are_valid(new_operational_roles)
  then
    raise exception 'invalid branch team staff request' using errcode = '22023';
  end if;

  insert into public.operational_staff(organization_id, branch_id, display_name, company_name, staff_code, country_code, created_by)
  values(target_team.organization_id, target_team.branch_id, clean_name, clean_company_name, clean_code, clean_country, actor_user_id)
  returning id into created_staff;

  insert into public.operational_staff_assignments(
    organization_id,
    branch_id,
    operational_staff_id,
    supervisor_team_id,
    operational_roles
  )
  values(
    target_team.organization_id,
    target_team.branch_id,
    created_staff,
    target_team.id,
    new_operational_roles
  )
  returning id into created_assignment;

  insert into public.account_management_audit_logs(organization_id, actor_user_id, target_user_id, branch_id, action, details)
  values(
    target_team.organization_id,
    actor_user_id,
    target_team.supervisor_user_id,
    target_team.branch_id,
    'operational_staff_created',
    jsonb_build_object(
      'team_id', target_team.id,
      'operational_staff_id', created_staff,
      'assignment_id', created_assignment,
      'operational_roles', new_operational_roles
    )
  );

  return query select created_staff, created_assignment, exists(
    select 1
    from public.operational_staff staff
    where staff.organization_id = target_team.organization_id
      and staff.branch_id = target_team.branch_id
      and staff.id <> created_staff
      and staff.employment_status = 'active'
      and staff.normalized_name = private.normalize_operational_staff_name(clean_name)
  );
exception when unique_violation then
  raise exception 'employee code already exists' using errcode = '23505';
when no_data_found or too_many_rows then
  raise exception 'invalid branch team staff request' using errcode = '22023';
end;
$$;

revoke all on function private.operational_roles_are_valid(text[]),
  private.operational_staff_country_code_is_valid(text),
  private.clean_operational_staff_country_code(text)
  from public, anon, authenticated;

revoke all on function public.get_supervisor_operational_team(uuid,uuid,date),
  public.create_operational_team_staff(uuid,uuid,uuid,text,text[],text,text,text,text,date,text,text),
  public.update_operational_team_staff(uuid,uuid,uuid,text,text,text[],text,text,text,text,date,text,text),
  public.list_managed_operational_staff(uuid,uuid,integer,integer,text,uuid,uuid,text,text,date),
  public.list_managed_employee_team(uuid,uuid,uuid,date),
  public.list_internal_admin_branch_teams(uuid,uuid),
  public.create_internal_admin_branch_team_staff(uuid,uuid,uuid,text,text,text,text,text[])
  from public, anon, authenticated;

grant execute on function public.get_supervisor_operational_team(uuid,uuid,date),
  public.create_operational_team_staff(uuid,uuid,uuid,text,text[],text,text,text,text,date,text,text),
  public.update_operational_team_staff(uuid,uuid,uuid,text,text,text[],text,text,text,text,date,text,text),
  public.list_managed_operational_staff(uuid,uuid,integer,integer,text,uuid,uuid,text,text,date),
  public.list_managed_employee_team(uuid,uuid,uuid,date),
  public.list_internal_admin_branch_teams(uuid,uuid),
  public.create_internal_admin_branch_team_staff(uuid,uuid,uuid,text,text,text,text,text[])
  to service_role;
