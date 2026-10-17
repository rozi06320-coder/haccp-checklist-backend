begin;
select plan(10);

select function_returns('public','get_training_employee_baladiyah_draft_preview',array['uuid','uuid','uuid'],'setof record','employee preview RPC exists');
select function_returns('public','authorize_training_employee_baladiyah_draft_preview_media',array['uuid','uuid','uuid','uuid'],'setof record','employee preview media RPC exists');
select ok((select prosecdef from pg_catalog.pg_proc where oid='public.get_training_employee_baladiyah_draft_preview(uuid,uuid,uuid)'::regprocedure),'preview RPC is SECURITY DEFINER');
select ok((select proconfig @> array['search_path=""'] from pg_catalog.pg_proc where oid='public.get_training_employee_baladiyah_draft_preview(uuid,uuid,uuid)'::regprocedure),'preview RPC has empty search path');
select ok((select prosecdef from pg_catalog.pg_proc where oid='public.authorize_training_employee_baladiyah_draft_preview_media(uuid,uuid,uuid,uuid)'::regprocedure),'media RPC is SECURITY DEFINER');
select ok((select proconfig @> array['search_path=""'] from pg_catalog.pg_proc where oid='public.authorize_training_employee_baladiyah_draft_preview_media(uuid,uuid,uuid,uuid)'::regprocedure),'media RPC has empty search path');
select ok(has_function_privilege('service_role','public.get_training_employee_baladiyah_draft_preview(uuid,uuid,uuid)','execute'),'service role can execute preview RPC');
select ok(not has_function_privilege('anon','public.get_training_employee_baladiyah_draft_preview(uuid,uuid,uuid)','execute') and not has_function_privilege('authenticated','public.get_training_employee_baladiyah_draft_preview(uuid,uuid,uuid)','execute'),'browser roles cannot execute preview RPC');
select ok(has_function_privilege('service_role','public.authorize_training_employee_baladiyah_draft_preview_media(uuid,uuid,uuid,uuid)','execute'),'service role can execute media RPC');
select ok(not has_function_privilege('anon','public.authorize_training_employee_baladiyah_draft_preview_media(uuid,uuid,uuid,uuid)','execute') and not has_function_privilege('authenticated','public.authorize_training_employee_baladiyah_draft_preview_media(uuid,uuid,uuid,uuid)','execute'),'browser roles cannot execute media RPC');

select * from finish();
rollback;
