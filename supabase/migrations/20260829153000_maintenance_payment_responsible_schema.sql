-- Compatibility foundation for Maintenance payment method and responsible person.
-- This migration is schema-only by design: old backend revisions can keep
-- inserting rows without the new nullable fields, and RPC/API return shapes are
-- updated in a later phase.

alter table public.maintenance_purchase_logs
  add column if not exists payment_method text null;

alter table public.maintenance_issues
  add column if not exists responsible_person_name text null;

do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_constraint constraint_row
    where constraint_row.conname = 'maintenance_purchase_logs_payment_method_check'
      and constraint_row.conrelid = 'public.maintenance_purchase_logs'::regclass
  ) then
    alter table public.maintenance_purchase_logs
      add constraint maintenance_purchase_logs_payment_method_check check (
        payment_method is null
        or payment_method in ('cash', 'credit_card', 'pay_later')
      );
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_constraint constraint_row
    where constraint_row.conname = 'maintenance_issues_responsible_person_name_check'
      and constraint_row.conrelid = 'public.maintenance_issues'::regclass
  ) then
    alter table public.maintenance_issues
      add constraint maintenance_issues_responsible_person_name_check check (
        responsible_person_name is null
        or (
          responsible_person_name = pg_catalog.btrim(responsible_person_name)
          and pg_catalog.char_length(responsible_person_name) between 1 and 100
        )
      );
  end if;
end $$;
