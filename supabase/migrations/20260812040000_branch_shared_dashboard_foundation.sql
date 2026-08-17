-- Phase 2: branch-owned operational ledgers and concurrency metadata.
-- Abort rather than reconcile when legacy supervisor namespaces contain conflicting logical records.
do $$
begin
  if exists (
    select 1 from public.checklist_submissions
    where checklist_type in ('kitchen_opening','foh_opening','daily_audit')
    group by organization_id,branch_id,business_date,checklist_type having count(*)>1
  ) then raise exception 'phase2 duplicate branch checklist records require manual reconciliation' using errcode='23505'; end if;
  if exists (select 1 from public.oil_tracking_submissions group by organization_id,branch_id,business_date having count(*)>1)
    then raise exception 'phase2 duplicate oil ledgers require manual reconciliation' using errcode='23505'; end if;
  if exists (select 1 from public.cold_storage_submissions group by organization_id,branch_id,business_date having count(*)>1)
    then raise exception 'phase2 duplicate cold-storage ledgers require manual reconciliation' using errcode='23505'; end if;
  if exists (select 1 from public.sales_tracking_reports group by organization_id,branch_id,business_date having count(*)>1)
    then raise exception 'phase2 duplicate sales ledgers require manual reconciliation' using errcode='23505'; end if;
  if exists (
    select 1 from public.branch_suppliers
    group by organization_id,branch_id,lower(pg_catalog.btrim(supplier_name_en)) having count(*)>1
  ) then raise exception 'phase2 duplicate branch suppliers require manual reconciliation' using errcode='23505'; end if;
end $$;

create function private.phase2_branch_context(actor uuid,target_branch uuid)
returns table(organization_id uuid,branch_id uuid,legacy_team_id uuid,business_date date,branch_name text,branch_code text,actor_name text)
language sql stable security definer set search_path='' as $$
  select b.organization_id,b.id,t.id,private.phase4a_business_date(b.timezone),b.name,b.code,p.full_name
  from public.profiles p
  join public.branch_memberships m on m.user_id=p.id and m.branch_id=target_branch and m.role='branch_manager' and m.active
  join public.branches b on b.id=m.branch_id and b.active
  join public.organizations o on o.id=b.organization_id and o.active
  join lateral (
    select legacy.id from public.branch_supervisor_teams legacy
    where legacy.branch_id=b.id and legacy.organization_id=b.organization_id
      and legacy.supervisor_user_id=p.id and legacy.active
    order by legacy.created_at,legacy.id limit 1
  ) t on true
  where p.id=actor and p.disabled_at is null and not p.must_change_password
$$;
revoke all on function private.phase2_branch_context(uuid,uuid) from public,anon,authenticated;
grant execute on function private.phase2_branch_context(uuid,uuid) to service_role;

alter table public.checklist_submissions
  add column if not exists branch_revision bigint not null default 0,
  add column if not exists updated_by_user_id uuid references public.profiles(id) on delete set null,
  add column if not exists submitted_by_user_id uuid references public.profiles(id) on delete set null;
alter table public.checklist_submissions add constraint checklist_submissions_branch_revision_check check(branch_revision>=0);
drop index if exists public.checklist_submissions_one_draft;
drop index if exists public.checklist_submissions_one_final;
create unique index checklist_submissions_branch_owned_key
  on public.checklist_submissions(organization_id,branch_id,business_date,checklist_type)
  where checklist_type in ('kitchen_opening','foh_opening','daily_audit');

alter table public.checklist_issue_evidence drop constraint if exists checklist_issue_evidence_draft_submission_fkey;
alter table public.checklist_issue_evidence drop constraint if exists checklist_issue_evidence_final_submission_fkey;
alter table public.checklist_issue_evidence
  add constraint checklist_issue_evidence_draft_submission_branch_fkey
    foreign key(draft_submission_id,organization_id,branch_id)
    references public.checklist_submissions(id,organization_id,branch_id) on delete restrict,
  add constraint checklist_issue_evidence_final_submission_branch_fkey
    foreign key(final_submission_id,organization_id,branch_id)
    references public.checklist_submissions(id,organization_id,branch_id) on delete restrict;
drop index if exists public.checklist_issue_evidence_active_item_key;
create unique index checklist_issue_evidence_active_branch_item_key
  on public.checklist_issue_evidence(organization_id,branch_id,business_date,checklist_type,item_id)
  where status in('pending','draft','finalized');

alter table public.oil_tracking_submissions
  add column if not exists branch_revision bigint not null default 0,
  add column if not exists updated_by_user_id uuid references public.profiles(id) on delete set null,
  add column if not exists opening_submitted_by_user_id uuid references public.profiles(id) on delete set null,
  add column if not exists closing_submitted_by_user_id uuid references public.profiles(id) on delete set null;
alter table public.oil_tracking_submissions drop constraint oil_tracking_submissions_branch_id_supervisor_team_id_busin_key;
alter table public.oil_tracking_submissions add constraint oil_tracking_submissions_branch_revision_check check(branch_revision>=0);
create unique index oil_tracking_submissions_branch_day_key on public.oil_tracking_submissions(organization_id,branch_id,business_date);

alter table public.cold_storage_submissions
  add column if not exists branch_revision bigint not null default 0,
  add column if not exists updated_by_user_id uuid references public.profiles(id) on delete set null;
alter table public.cold_storage_readings add column if not exists submitted_by_user_id uuid references public.profiles(id) on delete set null;
alter table public.cold_storage_submissions drop constraint cold_storage_submissions_branch_id_supervisor_team_id_busin_key;
alter table public.cold_storage_submissions add constraint cold_storage_submissions_branch_revision_check check(branch_revision>=0);
create unique index cold_storage_submissions_branch_day_key on public.cold_storage_submissions(organization_id,branch_id,business_date);

alter table public.sales_tracking_reports
  add column if not exists branch_revision bigint not null default 0,
  add column if not exists updated_by_user_id uuid references public.profiles(id) on delete set null,
  add column if not exists submitted_by_user_id uuid references public.profiles(id) on delete set null;
alter table public.sales_tracking_reports drop constraint sales_tracking_reports_branch_id_supervisor_user_id_busines_key;
alter table public.sales_tracking_reports add constraint sales_tracking_reports_branch_revision_check check(branch_revision>=0);
create unique index sales_tracking_reports_branch_day_key on public.sales_tracking_reports(organization_id,branch_id,business_date);

drop index if exists public.branch_suppliers_team_name_key;
create unique index branch_suppliers_branch_name_key
  on public.branch_suppliers(organization_id,branch_id,lower(pg_catalog.btrim(supplier_name_en)));

comment on column public.checklist_submissions.supervisor_user_id is 'Original creator attribution; not branch-owned record identity.';
comment on column public.oil_tracking_submissions.supervisor_user_id is 'Original creator attribution; not branch-owned ledger identity.';
comment on column public.cold_storage_submissions.supervisor_user_id is 'Original creator attribution; not branch-owned ledger identity.';
comment on column public.sales_tracking_reports.supervisor_user_id is 'Original creator attribution; not branch-owned report identity.';
