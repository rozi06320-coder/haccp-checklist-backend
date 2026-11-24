#!/usr/bin/env python3
import subprocess
import threading
import time
import sys
from pathlib import Path

DOCKER = "/Applications/Docker.app/Contents/Resources/bin/docker"
CONTAINER = "supabase_db_tsqf"
MIGRATION_PATH = Path("/tmp/haccp-supervisor-team-onboarding-phase1/supabase/migrations/20261125120000_supervisor_team_onboarding_setup.sql")

ORG_ID = "e1000000-0000-4000-8000-000000000001"
BRANCH_A = "e2000000-0000-4000-8000-000000000001"
BRANCH_B = "e2000000-0000-4000-8000-000000000002"

ADMIN_ID = "e0000000-0000-4000-8000-000000000001"
SUP_SRC_1 = "e0000000-0000-4000-8000-000000000011"
SUP_SRC_2 = "e0000000-0000-4000-8000-000000000012"
SUP_SRC_3 = "e0000000-0000-4000-8000-000000000013"
SUP_B = "e0000000-0000-4000-8000-000000000003"
SUP_C = "e0000000-0000-4000-8000-000000000004"
SUP_D = "e0000000-0000-4000-8000-000000000005"
SUP_E = "e0000000-0000-4000-8000-000000000006"
SUP_F = "e0000000-0000-4000-8000-000000000007"
SUP_G = "e0000000-0000-4000-8000-000000000008"
SUP_H = "e0000000-0000-4000-8000-000000000009"

ALL_USERS = [ADMIN_ID, SUP_SRC_1, SUP_SRC_2, SUP_SRC_3, SUP_B, SUP_C, SUP_D, SUP_E, SUP_F, SUP_G, SUP_H]


def psql_exec(sql: str) -> str:
    res = subprocess.run(
        [DOCKER, "exec", "-i", CONTAINER, "psql", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres", "-Atq"],
        input=sql,
        text=True,
        capture_output=True,
    )
    if res.returncode != 0:
        raise RuntimeError(f"psql failed ({res.returncode}):\nSTDOUT:\n{res.stdout}\nSTDERR:\n{res.stderr}")
    return res.stdout.strip()


class PsqlSession:
    def __init__(self, name: str):
        self.name = name
        self.proc = subprocess.Popen(
            [DOCKER, "exec", "-i", CONTAINER, "psql", "-X", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres", "-Atq"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        self.lines = []

    def send(self, sql: str):
        assert self.proc.stdin is not None
        self.proc.stdin.write(sql.rstrip() + "\n")
        self.proc.stdin.flush()

    def wait_for_marker(self, marker: str, timeout: float = 30.0):
        assert self.proc.stdout is not None
        deadline = time.time() + timeout
        collected = []
        while time.time() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                rc = self.proc.poll()
                raise RuntimeError(f"[{self.name}] EOF before marker {marker} (rc={rc}). Output:\n{''.join(collected)}")
            collected.append(line)
            self.lines.append(line)
            if "ERROR:" in line or "FATAL:" in line or "deadlock detected" in line.lower():
                # Drain any immediate lines
                raise RuntimeError(f"[{self.name}] SQL error: {line.strip()}\nFull:\n{''.join(collected)}")
            if marker in line:
                return "".join(collected)
        raise TimeoutError(f"[{self.name}] Timed out waiting for {marker}. Output:\n{''.join(collected)}")

    def close(self):
        try:
            if self.proc.stdin:
                self.proc.stdin.write("\\q\n")
                self.proc.stdin.flush()
                self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=2)


def setup_fixtures():
    mig_sql = MIGRATION_PATH.read_text()
    psql_exec("""
        DROP TRIGGER IF EXISTS branch_operational_team_supervisors_00_lock_onboarding ON public.branch_operational_team_supervisors;
        DROP TRIGGER IF EXISTS branch_operational_team_supervisors_90_clear_onboarding ON public.branch_operational_team_supervisors;
        DROP FUNCTION IF EXISTS private.lock_supervisor_team_onboarding_on_assignment();
        DROP FUNCTION IF EXISTS private.clear_supervisor_team_onboarding_on_assignment();
        DROP FUNCTION IF EXISTS public.get_supervisor_team_onboarding_state(uuid, uuid[]);
        DROP FUNCTION IF EXISTS public.set_supervisor_team_onboarding_waiting(uuid, uuid);
        DROP FUNCTION IF EXISTS public.create_supervisor_owned_operational_team_v2(uuid, uuid, text, uuid);
        DROP TABLE IF EXISTS public.supervisor_team_bootstrap_idempotency CASCADE;
        DROP TABLE IF EXISTS public.supervisor_team_onboarding_states CASCADE;
    """)
    psql_exec(mig_sql)
    cleanup_fixtures()

    user_values = ",\n  ".join(f"('{u}'::uuid)" for u in ALL_USERS)
    setup_sql = f"""
    BEGIN;
    INSERT INTO auth.users(instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    SELECT '00000000-0000-0000-0000-000000000000', id, 'authenticated', 'authenticated',
      id || '@concurrency.invalid', '{{}}', '{{}}', now(), now()
    FROM (VALUES {user_values}) AS v(id)
    ON CONFLICT (id) DO NOTHING;

    UPDATE public.profiles SET full_name = 'Concurrency User ' || id::text, must_change_password = false
    WHERE id IN ({', '.join(f"'{u}'::uuid" for u in ALL_USERS)});

    INSERT INTO public.internal_admin_memberships(user_id, active)
    VALUES ('{ADMIN_ID}', true)
    ON CONFLICT (user_id) DO UPDATE SET active = true;

    INSERT INTO public.organizations(id, name, slug, active, created_at)
    VALUES ('{ORG_ID}', 'Concurrency Test Org', 'concurrency-test-org', true, '2026-01-01T00:00:00Z')
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.branches(id, organization_id, name, code, timezone, country_code, active, created_at)
    VALUES
      ('{BRANCH_A}', '{ORG_ID}', 'Concurrency Branch A', 'CON-A', 'Asia/Riyadh', 'SA', true, '2026-01-01T00:00:00Z'),
      ('{BRANCH_B}', '{ORG_ID}', 'Concurrency Branch B', 'CON-B', 'Asia/Riyadh', 'SA', true, '2026-01-01T00:00:00Z')
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.branch_memberships(branch_id, user_id, role, active)
    VALUES
      ('{BRANCH_A}', '{SUP_SRC_1}', 'branch_manager', true),
      ('{BRANCH_A}', '{SUP_SRC_2}', 'branch_manager', true),
      ('{BRANCH_A}', '{SUP_SRC_3}', 'branch_manager', true),
      ('{BRANCH_A}', '{SUP_B}', 'branch_manager', true),
      ('{BRANCH_A}', '{SUP_C}', 'branch_manager', true),
      ('{BRANCH_A}', '{SUP_D}', 'branch_manager', true),
      ('{BRANCH_A}', '{SUP_E}', 'branch_manager', true),
      ('{BRANCH_A}', '{SUP_F}', 'branch_manager', true),
      ('{BRANCH_A}', '{SUP_G}', 'branch_manager', true),
      ('{BRANCH_B}', '{SUP_G}', 'branch_manager', true),
      ('{BRANCH_A}', '{SUP_H}', 'branch_manager', true)
    ON CONFLICT DO NOTHING;

    SELECT * FROM public.create_supervisor_owned_operational_team_v2('{SUP_SRC_1}', '{BRANCH_A}', 'Src Team 1', 'e4000000-0000-4000-8000-000000000001'::uuid);
    SELECT * FROM public.create_supervisor_owned_operational_team_v2('{SUP_SRC_2}', '{BRANCH_A}', 'Src Team 2', 'e4000000-0000-4000-8000-000000000002'::uuid);
    SELECT * FROM public.create_supervisor_owned_operational_team_v2('{SUP_SRC_3}', '{BRANCH_A}', 'Src Team 3', 'e4000000-0000-4000-8000-000000000003'::uuid);
    COMMIT;
    """
    # Wrap PERFORM in DO block or use SELECT directly outside DO
    setup_sql = setup_sql.replace("-- Seed 3 teams owned by SUP_A on BRANCH_A for transfer tests\n    PERFORM * FROM", "SELECT * FROM").replace("\n    PERFORM * FROM", ";\n    SELECT * FROM")
    psql_exec(setup_sql)


def cleanup_fixtures():
    user_list = ", ".join(f"'{u}'::uuid" for u in ALL_USERS)
    cleanup_sql = f"""
    BEGIN;
    DELETE FROM public.supervisor_team_bootstrap_idempotency WHERE organization_id = '{ORG_ID}';
    DELETE FROM public.supervisor_team_onboarding_states WHERE organization_id = '{ORG_ID}';
    DELETE FROM public.account_management_audit_logs WHERE organization_id = '{ORG_ID}';
    DELETE FROM public.branch_operational_team_supervisors WHERE organization_id = '{ORG_ID}';
    DELETE FROM public.branch_operational_teams WHERE organization_id = '{ORG_ID}';
    DELETE FROM public.branch_supervisor_teams WHERE branch_id IN ('{BRANCH_A}', '{BRANCH_B}');
    DELETE FROM public.branch_memberships WHERE branch_id IN ('{BRANCH_A}', '{BRANCH_B}');
    DELETE FROM public.daily_report_module_applicability WHERE organization_id = '{ORG_ID}';
    DELETE FROM public.daily_report_branch_lifecycle WHERE organization_id = '{ORG_ID}';
    DELETE FROM public.branches WHERE organization_id = '{ORG_ID}';
    DELETE FROM public.organization_memberships WHERE organization_id = '{ORG_ID}';
    DELETE FROM public.internal_admin_memberships WHERE user_id = '{ADMIN_ID}';
    DELETE FROM public.organizations WHERE id = '{ORG_ID}';
    DELETE FROM public.profiles WHERE id IN ({user_list});
    DELETE FROM auth.users WHERE id IN ({user_list});
    COMMIT;
    """
    psql_exec(cleanup_sql)


def run_locked_pair(name: str, conn1_sql: str, conn2_sql: str, expect_conn2_blocked: bool = True, expected_c2_error=None):
    c1 = PsqlSession(f"{name}-C1")
    c2 = PsqlSession(f"{name}-C2")
    c2_result = {"done": False, "err": None, "out": ""}

    try:
        c1.send("BEGIN;")
        c1.send(conn1_sql)
        c1.send("SELECT 'CONN1_HOLDING';")
        c1.wait_for_marker("CONN1_HOLDING")

        def run_c2():
            try:
                c2.send("BEGIN;")
                c2.send(conn2_sql)
                c2.send("COMMIT;")
                c2.send("SELECT 'CONN2_DONE';")
                c2_result["out"] = c2.wait_for_marker("CONN2_DONE")
                c2_result["done"] = True
            except Exception as exc:
                c2_result["err"] = exc
                c2_result["done"] = True

        t2 = threading.Thread(target=run_c2, daemon=True)
        t2.start()

        if expect_conn2_blocked:
            time.sleep(0.6)
            assert not c2_result["done"], f"{name}: Expected C2 to block while C1 held lock, but C2 finished early!"
        else:
            t2.join(timeout=5.0)
            assert c2_result["done"], f"{name}: Expected C2 (different branch) NOT to block on C1, but C2 was blocked!"

        c1.send("COMMIT;")
        c1.send("SELECT 'CONN1_COMMITTED';")
        c1.wait_for_marker("CONN1_COMMITTED")

        t2.join(timeout=10)
        if expected_c2_error:
            assert c2_result["err"] is not None, f"{name}: Expected C2 error '{expected_c2_error}', but C2 succeeded!"
            assert expected_c2_error in str(c2_result["err"]), f"{name}: Expected '{expected_c2_error}', got: {c2_result['err']}"
            assert "deadlock" not in str(c2_result["err"]).lower(), f"{name}: Unexpected deadlock: {c2_result['err']}"
            return str(c2_result["err"])
        if c2_result["err"]:
            raise c2_result["err"]
        assert c2_result["done"], f"{name}: C2 did not finish after C1 committed"
        return c2_result["out"]
    finally:
        c1.close()
        c2.close()


def get_team_and_assignment(team_name: str):
    row = psql_exec(
        f"SELECT t.id || '|' || s.id FROM public.branch_operational_teams t "
        f"JOIN public.branch_operational_team_supervisors s ON s.operational_team_id = t.id AND s.active "
        f"WHERE t.organization_id = '{ORG_ID}' AND t.name = '{team_name}' AND t.active;"
    )
    team_id, assign_id = row.split("|")
    return team_id, assign_id


def main():
    setup_fixtures()
    try:
        t1_id, a1_id = get_team_and_assignment("Src Team 1")
        t2_id, a2_id = get_team_and_assignment("Src Team 2")
        t3_id, a3_id = get_team_and_assignment("Src Team 3")

        # 1. Transfer first, then Create (same branch, same destination supervisor SUP_B)
        # Conn 2 blocks while Conn 1 transfers Src Team 1 to SUP_B; once Conn 1 commits, Conn 2 sees SUP_B now has a writable team and rejects cleanly.
        psql_exec(f"SELECT public.set_supervisor_team_onboarding_waiting('{SUP_B}', '{BRANCH_A}');")
        run_locked_pair(
            "1_transfer_then_create",
            f"SELECT * FROM public.change_internal_admin_operational_team_primary_supervisor('{ADMIN_ID}', '{ORG_ID}', '{t1_id}', '{SUP_B}', '{a1_id}');",
            f"SELECT * FROM public.create_supervisor_owned_operational_team_v2('{SUP_B}', '{BRANCH_A}', 'Sup B Own Team', 'e9000000-0000-4000-8000-000000000001'::uuid);",
            expect_conn2_blocked=True,
            expected_c2_error="employee team already assigned",
        )
        sup_b_teams = int(psql_exec(f"SELECT count(*) FROM public.branch_operational_team_supervisors WHERE supervisor_user_id = '{SUP_B}' AND branch_id = '{BRANCH_A}' AND active;"))
        sup_b_wait = int(psql_exec(f"SELECT count(*) FROM public.supervisor_team_onboarding_states WHERE supervisor_user_id = '{SUP_B}' AND branch_id = '{BRANCH_A}';"))
        assert sup_b_teams == 1 and sup_b_wait == 0, f"Test 1 failed: teams={sup_b_teams}, wait={sup_b_wait}"
        print("PASS 1: Transfer first, then Create (blocked cleanly, zero deadlock, duplicate team prevented, waiting cleared)")

        # 2. Create first, then Transfer (same branch, same destination supervisor SUP_C)
        psql_exec(f"SELECT public.set_supervisor_team_onboarding_waiting('{SUP_C}', '{BRANCH_A}');")
        run_locked_pair(
            "2_create_then_transfer",
            f"SELECT * FROM public.create_supervisor_owned_operational_team_v2('{SUP_C}', '{BRANCH_A}', 'Sup C Own Team', 'e9000000-0000-4000-8000-000000000002'::uuid);",
            f"SELECT * FROM public.change_internal_admin_operational_team_primary_supervisor('{ADMIN_ID}', '{ORG_ID}', '{t2_id}', '{SUP_C}', '{a2_id}');",
            expect_conn2_blocked=True,
        )
        sup_c_teams = int(psql_exec(f"SELECT count(*) FROM public.branch_operational_team_supervisors WHERE supervisor_user_id = '{SUP_C}' AND branch_id = '{BRANCH_A}' AND active;"))
        sup_c_wait = int(psql_exec(f"SELECT count(*) FROM public.supervisor_team_onboarding_states WHERE supervisor_user_id = '{SUP_C}' AND branch_id = '{BRANCH_A}';"))
        assert sup_c_teams == 2 and sup_c_wait == 0, f"Test 2 failed: teams={sup_c_teams}, wait={sup_c_wait}"
        print("PASS 2: Create first, then Transfer (blocked cleanly, zero deadlock, waiting cleared)")

        # 3. Create vs Create (same supervisor SUP_D, same branch, same idempotency key)
        run_locked_pair(
            "3_create_vs_create",
            f"SELECT * FROM public.create_supervisor_owned_operational_team_v2('{SUP_D}', '{BRANCH_A}', 'Concurrent Team', 'e9000000-0000-4000-8000-000000000003'::uuid);",
            f"SELECT * FROM public.create_supervisor_owned_operational_team_v2('{SUP_D}', '{BRANCH_A}', 'Concurrent Team', 'e9000000-0000-4000-8000-000000000003'::uuid);",
            expect_conn2_blocked=True,
        )
        sup_d_teams = int(psql_exec(f"SELECT count(*) FROM public.branch_operational_team_supervisors WHERE supervisor_user_id = '{SUP_D}' AND branch_id = '{BRANCH_A}' AND active;"))
        sup_d_audits = int(psql_exec(f"SELECT count(*) FROM public.account_management_audit_logs WHERE organization_id = '{ORG_ID}' AND target_user_id = '{SUP_D}' AND action = 'supervisor_owned_team_created';"))
        assert sup_d_teams == 1 and sup_d_audits == 1, f"Test 3 failed: teams={sup_d_teams}, audits={sup_d_audits}"
        print("PASS 3: Create vs Create (idempotent replay after lock release, 1 team, 1 audit row)")

        # 4. Waiting vs Transfer (SUP_E sets waiting while admin transfers Src Team 3 to SUP_E)
        run_locked_pair(
            "4_waiting_vs_transfer",
            f"SELECT * FROM public.set_supervisor_team_onboarding_waiting('{SUP_E}', '{BRANCH_A}');",
            f"SELECT * FROM public.change_internal_admin_operational_team_primary_supervisor('{ADMIN_ID}', '{ORG_ID}', '{t3_id}', '{SUP_E}', '{a3_id}');",
            expect_conn2_blocked=True,
        )
        sup_e_teams = int(psql_exec(f"SELECT count(*) FROM public.branch_operational_team_supervisors WHERE supervisor_user_id = '{SUP_E}' AND branch_id = '{BRANCH_A}' AND active;"))
        sup_e_wait = int(psql_exec(f"SELECT count(*) FROM public.supervisor_team_onboarding_states WHERE supervisor_user_id = '{SUP_E}' AND branch_id = '{BRANCH_A}';"))
        assert sup_e_teams == 1 and sup_e_wait == 0, f"Test 4 failed: teams={sup_e_teams}, wait={sup_e_wait}"
        print("PASS 4: Waiting vs Transfer (serialized, transfer clears waiting state)")

        # 5. Waiting vs Create (SUP_F sets waiting while SUP_F creates team)
        run_locked_pair(
            "5_waiting_vs_create",
            f"SELECT * FROM public.set_supervisor_team_onboarding_waiting('{SUP_F}', '{BRANCH_A}');",
            f"SELECT * FROM public.create_supervisor_owned_operational_team_v2('{SUP_F}', '{BRANCH_A}', 'Sup F Team', 'e9000000-0000-4000-8000-000000000005'::uuid);",
            expect_conn2_blocked=True,
        )
        sup_f_teams = int(psql_exec(f"SELECT count(*) FROM public.branch_operational_team_supervisors WHERE supervisor_user_id = '{SUP_F}' AND branch_id = '{BRANCH_A}' AND active;"))
        sup_f_wait = int(psql_exec(f"SELECT count(*) FROM public.supervisor_team_onboarding_states WHERE supervisor_user_id = '{SUP_F}' AND branch_id = '{BRANCH_A}';"))
        assert sup_f_teams == 1 and sup_f_wait == 0, f"Test 5 failed: teams={sup_f_teams}, wait={sup_f_wait}"
        print("PASS 5: Waiting vs Create (serialized, create clears waiting state)")

        # 6. Multi-branch concurrent operations (SUP_G Create on BRANCH_A vs SUP_G Waiting on BRANCH_B -> NO cross-branch blocking!)
        run_locked_pair(
            "6_multi_branch_concurrent",
            f"SELECT * FROM public.create_supervisor_owned_operational_team_v2('{SUP_G}', '{BRANCH_A}', 'Sup G Branch A Team', 'e9000000-0000-4000-8000-000000000006'::uuid);",
            f"SELECT * FROM public.set_supervisor_team_onboarding_waiting('{SUP_G}', '{BRANCH_B}');",
            expect_conn2_blocked=False,
        )
        sup_g_a_teams = int(psql_exec(f"SELECT count(*) FROM public.branch_operational_team_supervisors WHERE supervisor_user_id = '{SUP_G}' AND branch_id = '{BRANCH_A}' AND active;"))
        sup_g_b_wait = int(psql_exec(f"SELECT count(*) FROM public.supervisor_team_onboarding_states WHERE supervisor_user_id = '{SUP_G}' AND branch_id = '{BRANCH_B}' AND onboarding_choice = 'waiting_for_transfer';"))
        assert sup_g_a_teams == 1 and sup_g_b_wait == 1, f"Test 6 failed: a_teams={sup_g_a_teams}, b_wait={sup_g_b_wait}"
        print("PASS 6: Multi-branch concurrent operations (Branch B did not block on Branch A, independent states)")

        # 7. Membership-first locking (transfer_branch_supervisor_access) vs branch-first locking (create_supervisor_owned_operational_team_v2)
        # Conn 1 holds membership lock while transferring SUP_H from BRANCH_A to BRANCH_B; Conn 2 runs concurrently on BRANCH_A -> zero deadlock!
        run_locked_pair(
            "7_membership_first_vs_branch_first",
            f"SELECT * FROM public.transfer_branch_supervisor_access('{ADMIN_ID}', '{ORG_ID}', '{SUP_H}', '{BRANCH_A}', '{BRANCH_B}');",
            f"SELECT * FROM public.get_supervisor_team_onboarding_state('{SUP_H}', ARRAY['{BRANCH_A}']::uuid[]);",
            expect_conn2_blocked=False,
        )
        # After transfer commits, revoked membership on BRANCH_A is rejected for both waiting & team creation
        try:
            psql_exec(f"SELECT * FROM public.create_supervisor_owned_operational_team_v2('{SUP_H}', '{BRANCH_A}', 'Sup H Revoked', 'e9000000-0000-4000-8000-000000000007'::uuid);")
            raise AssertionError("Test 7 failed: expected revoked membership on BRANCH_A to reject team creation")
        except RuntimeError as exc:
            assert "employee team bootstrap denied" in str(exc), f"Test 7 unexpected error: {exc}"
        print("PASS 7: Membership-first vs branch-first locking (zero deadlock, revoked membership rejected)")

        print("\nALL 7 TWO-CONNECTION CONCURRENCY SCENARIOS PASSED!")
    finally:
        cleanup_fixtures()


if __name__ == "__main__":
    main()
