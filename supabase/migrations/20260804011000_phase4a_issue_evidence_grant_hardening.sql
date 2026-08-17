-- Evidence table mutations are available only through the narrow SECURITY DEFINER RPCs.
revoke all on table public.checklist_issue_evidence from service_role;
