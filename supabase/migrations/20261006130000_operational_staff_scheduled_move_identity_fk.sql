alter table public.operational_staff_scheduled_team_moves
  drop constraint operational_staff_scheduled_moves_staff_fkey;

alter table public.operational_staff_scheduled_team_moves
  add constraint operational_staff_scheduled_moves_staff_fkey
  foreign key(operational_staff_id,organization_id)
  references public.operational_staff(id,organization_id)
  on delete restrict;
