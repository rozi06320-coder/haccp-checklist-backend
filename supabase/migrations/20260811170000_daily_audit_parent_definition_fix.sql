-- Daily Audit draft/submit use checklist_submissions.definition_id=daily_audit_v1.
-- Register that canonical parent definition so the existing FK can accept it.
alter table public.checklist_definitions
  drop constraint checklist_definitions_id_check;
alter table public.checklist_definitions
  add constraint checklist_definitions_id_check
  check (id in ('kitchen_opening_v1','foh_opening_v1','staff_hygiene_v1','daily_audit_v1'));

alter table public.checklist_definitions
  drop constraint checklist_definitions_checklist_type_check;
alter table public.checklist_definitions
  add constraint checklist_definitions_checklist_type_check
  check (checklist_type in ('kitchen_opening','foh_opening','staff_hygiene','daily_audit'));

insert into public.checklist_definitions(id,checklist_type,version)
values ('daily_audit_v1','daily_audit',1)
on conflict do nothing;
