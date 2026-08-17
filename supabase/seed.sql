insert into public.organizations (id, name, slug)
values (
  '00000000-0000-4000-8000-000000000001',
  'Burger Hunch Demo',
  'burger-hunch-demo'
)
on conflict (id) do update
set name = excluded.name,
    slug = excluded.slug;

insert into public.branches (id, organization_id, name, code, timezone, active)
values
  (
    '00000000-0000-4000-8000-000000000101',
    '00000000-0000-4000-8000-000000000001',
    'Demo Riyadh North',
    'DEMO-RUH-N',
    'Asia/Riyadh',
    true
  ),
  (
    '00000000-0000-4000-8000-000000000102',
    '00000000-0000-4000-8000-000000000001',
    'Demo Riyadh South',
    'DEMO-RUH-S',
    'Asia/Riyadh',
    true
  )
on conflict (id) do update
set organization_id = excluded.organization_id,
    name = excluded.name,
    code = excluded.code,
    timezone = excluded.timezone,
    active = excluded.active;
