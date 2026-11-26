#!/usr/bin/env python3
"""Real two-connection concurrent upsert test for public.upsert_supervisor_health_card."""

import concurrent.futures
import subprocess
import uuid


def run_psql(sql: str) -> str:
    proc = subprocess.run(
        ["docker", "exec", "-i", "supabase_db_tsqf", "psql", "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1", "-qAt"],
        input=sql,
        text=True,
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"psql failed ({proc.returncode}): {proc.stderr}")
    return proc.stdout.strip()


def main() -> None:
    org_id = str(uuid.uuid4())
    branch_id = str(uuid.uuid4())
    sup_id = str(uuid.uuid4())
    legacy_team_id = str(uuid.uuid4())

    setup_sql = f"""
    INSERT INTO public.organizations(id, name, slug, active)
    VALUES ('{org_id}', 'Concurrent HC Org', 'conc-hc-{org_id[:8]}', true);

    INSERT INTO public.branches(id, organization_id, name, code, timezone, active)
    VALUES ('{branch_id}', '{org_id}', 'Concurrent HC Branch', 'CHC1', 'Asia/Riyadh', true);

    INSERT INTO auth.users(id, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, aud, role)
    VALUES ('{sup_id}', 'conc-hc-{sup_id[:8]}@test.local', 'x', now(), '{{}}', '{{}}', 'authenticated', 'authenticated');

    INSERT INTO public.profiles(id, full_name, must_change_password)
    VALUES ('{sup_id}', 'Concurrent Sup', false)
    ON CONFLICT (id) DO UPDATE SET full_name = EXCLUDED.full_name, must_change_password = false, disabled_at = null;

    INSERT INTO public.branch_memberships(user_id, branch_id, role, active)
    VALUES ('{sup_id}', '{branch_id}', 'branch_manager', true);

    INSERT INTO public.branch_supervisor_teams(id, organization_id, branch_id, supervisor_user_id, active)
    VALUES ('{legacy_team_id}', '{org_id}', '{branch_id}', '{sup_id}', true);
    """

    cleanup_sql = f"""
    DELETE FROM public.supervisor_health_cards WHERE organization_id = '{org_id}';
    DELETE FROM public.daily_report_module_applicability WHERE branch_id = '{branch_id}';
    DELETE FROM public.daily_report_branch_lifecycle WHERE branch_id = '{branch_id}';
    DELETE FROM public.branch_operational_team_supervisors WHERE organization_id = '{org_id}';
    DELETE FROM public.branch_operational_teams WHERE organization_id = '{org_id}';
    DELETE FROM public.branch_supervisor_teams WHERE organization_id = '{org_id}';
    DELETE FROM public.branch_memberships WHERE branch_id = '{branch_id}';
    DELETE FROM public.branches WHERE id = '{branch_id}';
    DELETE FROM public.organizations WHERE id = '{org_id}';
    DELETE FROM public.profiles WHERE id = '{sup_id}';
    DELETE FROM auth.users WHERE id = '{sup_id}';
    """

    run_psql(setup_sql)
    try:
        def worker(cert: str, status: str) -> str:
            return run_psql(
                f"""
                SELECT status || ':' || coalesce(certificate_number, '')
                FROM public.upsert_supervisor_health_card(
                    '{sup_id}'::uuid,
                    '{branch_id}'::uuid,
                    '{sup_id}'::uuid,
                    '{{"status":"{status}","certificate_number":"{cert}"}}'::jsonb
                );
                """
            )

        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            f1 = pool.submit(worker, "CERT-A", "pending")
            f2 = pool.submit(worker, "CERT-B", "passed")
            r1 = f1.result()
            r2 = f2.result()

        row_count = run_psql(
            f"SELECT count(*) FROM public.supervisor_health_cards WHERE organization_id = '{org_id}' AND supervisor_user_id = '{sup_id}';"
        )
        assert row_count == "1", f"Expected exactly 1 row, got {row_count}"
        print(f"PASS: two-connection concurrent upsert succeeded (conn1={r1}, conn2={r2}, row_count={row_count})")
    finally:
        run_psql(cleanup_sql)


if __name__ == "__main__":
    main()
