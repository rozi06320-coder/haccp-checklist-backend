-- Phase B1: Daily Audit result storage and read-only current-state RPC.
create table public.daily_audit_item_results (
  id uuid primary key default gen_random_uuid(),
  submission_id uuid not null,
  organization_id uuid not null,
  branch_id uuid not null,
  item_id text not null references public.daily_audit_item_definitions(item_id) on delete restrict,
  item_number integer not null check (item_number between 1 and 13),
  answer text not null check (answer in ('not_checked','compliant','non_compliant')),
  remark text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (submission_id,item_id),
  foreign key (submission_id,organization_id,branch_id)
    references public.checklist_submissions(id,organization_id,branch_id) on delete restrict
);
create index daily_audit_item_results_org_branch_idx on public.daily_audit_item_results(organization_id,branch_id);
create index daily_audit_item_results_submission_idx on public.daily_audit_item_results(submission_id);
create index daily_audit_item_results_item_idx on public.daily_audit_item_results(item_id);
alter table public.daily_audit_item_results enable row level security;
revoke all on public.daily_audit_item_results from public,anon,authenticated;

create or replace function public.get_supervisor_daily_audit_current_state(
  actor_user_id uuid,target_branch_id uuid,target_business_date date
) returns jsonb language plpgsql security definer set search_path='' as $$
declare c record; s public.checklist_submissions%rowtype;
begin
  select * into strict c from private.phase4a_actor_context(actor_user_id,target_branch_id);
  select * into s from public.checklist_submissions
    where organization_id=c.organization_id and branch_id=target_branch_id and supervisor_team_id=c.team_id
      and business_date=target_business_date and checklist_type='daily_audit'
    order by case state when 'submitted' then 0 else 1 end,updated_at desc limit 1;
  return jsonb_build_object(
    'submission_id',case when s.id is null then null else s.id end,
    'branch_id',target_branch_id,'business_date',target_business_date,
    'state',case when s.id is null then null else s.state end,
    'submitted_at',s.submitted_at,'updated_at',s.updated_at,
    'items',coalesce((select jsonb_agg(jsonb_build_object('item_id',d.item_id,'item_number',d.item_number,'answer',coalesce(r.answer,'not_checked'),'remark',coalesce(r.remark,'')) order by d.item_number)
      from public.daily_audit_item_definitions d left join public.daily_audit_item_results r on r.submission_id=s.id and r.item_id=d.item_id where d.active),
      (select jsonb_agg(jsonb_build_object('item_id',d.item_id,'item_number',d.item_number,'answer','not_checked','remark','') order by d.item_number) from public.daily_audit_item_definitions d where d.active))
  );
end; $$;
revoke all on function public.get_supervisor_daily_audit_current_state(uuid,uuid,date) from public,anon,authenticated;
grant execute on function public.get_supervisor_daily_audit_current_state(uuid,uuid,date) to service_role;
