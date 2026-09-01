create extension if not exists pg_cron;

do $migration$
declare
  activation_signature regprocedure :=
    pg_catalog.to_regprocedure('public.apply_due_operational_staff_team_moves(uuid,uuid)');
  schedule_signature regprocedure :=
    pg_catalog.to_regprocedure('cron.schedule(text,text,text)');
  alter_signature regprocedure :=
    pg_catalog.to_regprocedure('cron.alter_job(bigint,text,text,text,text,boolean)');
  scheduled_job_id bigint;
begin
  if activation_signature is null then
    raise exception 'scheduled team move activation function is unavailable'
      using errcode='P0001';
  end if;

  if schedule_signature is null or alter_signature is null then
    raise exception 'pg_cron scheduling functions are unavailable'
      using errcode='P0001';
  end if;

  select cron.schedule(
    'operational-staff-scheduled-team-moves',
    '* * * * *',
    'select public.apply_due_operational_staff_team_moves(null::uuid, null::uuid);'
  )
  into scheduled_job_id;

  perform cron.alter_job(scheduled_job_id, active := true);
end
$migration$;
