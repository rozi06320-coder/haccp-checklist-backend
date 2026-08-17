-- Phase B0: canonical Daily Audit definition only. No persistence or mutation RPCs.
alter table public.checklist_submissions drop constraint if exists checklist_submissions_type_check;
alter table public.checklist_submissions add constraint checklist_submissions_type_check
  check (checklist_type in ('kitchen_opening','foh_opening','staff_hygiene','daily_audit'));

create table public.daily_audit_item_definitions (
  item_id text primary key,
  item_number integer not null unique check (item_number between 1 and 13),
  item_label_en text not null check (item_label_en = btrim(item_label_en) and length(item_label_en) > 0),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

insert into public.daily_audit_item_definitions(item_id,item_number,item_label_en) values
 ('daily-audit-1',1,'Documented procedures are available and current.'),
 ('daily-audit-2',2,'Employees are aware of applicable procedures and work instructions.'),
 ('daily-audit-3',3,'Required records are complete, accurate, and maintained.'),
 ('daily-audit-4',4,'Receiving procedures are followed.'),
 ('daily-audit-5',5,'Materials are inspected before acceptance.'),
 ('daily-audit-6',6,'Storage procedures are implemented.'),
 ('daily-audit-7',7,'Materials are properly labeled and identified.'),
 ('daily-audit-8',8,'FIFO/FEFO is implemented where applicable.'),
 ('daily-audit-9',9,'Inventory records are accurate and up to date.'),
 ('daily-audit-10',10,'Non-conforming materials are identified and segregated.'),
 ('daily-audit-11',11,'Safety equipment is available and accessible.'),
 ('daily-audit-12',12,'Corrective actions from previous audits have been completed.'),
 ('daily-audit-13',13,'Applicable legal, regulatory, and company requirements are met.');

alter table public.daily_audit_item_definitions enable row level security;
revoke all on public.daily_audit_item_definitions from public, anon, authenticated;
grant select on public.daily_audit_item_definitions to service_role;
