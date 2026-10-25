-- Manager Issues RPCs are called only by the backend with its service-role
-- credential. They accept an actor UUID because the backend has already
-- authenticated the request, so browser roles must never execute them
-- directly and supply an arbitrary actor identity.

revoke execute on function public.list_phase4a_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)
  from public, anon, authenticated;
revoke execute on function public.get_phase4a_managed_issue(uuid,uuid,uuid)
  from public, anon, authenticated;

revoke execute on function public.list_oil_tracking_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)
  from public, anon, authenticated;
revoke execute on function public.get_oil_tracking_managed_issue(uuid,uuid,uuid)
  from public, anon, authenticated;

revoke execute on function public.list_cold_storage_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)
  from public, anon, authenticated;
revoke execute on function public.get_cold_storage_managed_issue(uuid,uuid,uuid)
  from public, anon, authenticated;

revoke execute on function public.list_sales_tracking_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)
  from public, anon, authenticated;
revoke execute on function public.get_sales_tracking_managed_issue(uuid,uuid,uuid)
  from public, anon, authenticated;

grant execute on function public.list_phase4a_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)
  to service_role;
grant execute on function public.get_phase4a_managed_issue(uuid,uuid,uuid)
  to service_role;

grant execute on function public.list_oil_tracking_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)
  to service_role;
grant execute on function public.get_oil_tracking_managed_issue(uuid,uuid,uuid)
  to service_role;

grant execute on function public.list_cold_storage_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)
  to service_role;
grant execute on function public.get_cold_storage_managed_issue(uuid,uuid,uuid)
  to service_role;

grant execute on function public.list_sales_tracking_managed_issues(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text)
  to service_role;
grant execute on function public.get_sales_tracking_managed_issue(uuid,uuid,uuid)
  to service_role;
