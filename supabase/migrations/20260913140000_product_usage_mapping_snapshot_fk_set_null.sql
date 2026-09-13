-- Migration: 20260913140000_product_usage_mapping_snapshot_fk_set_null.sql
-- Description: Allow recipe usage mappings to be replaced by cascading deletion to historical snapshots as SET NULL

alter table public.branch_product_sales_usage_snapshots
  drop constraint if exists branch_product_sales_usage_snapshots_recipe_mapping_id_fkey;

alter table public.branch_product_sales_usage_snapshots
  add constraint branch_product_sales_usage_snapshots_recipe_mapping_id_fkey
  foreign key (recipe_mapping_id)
  references public.branch_product_usage_mappings(id)
  on delete set null;
