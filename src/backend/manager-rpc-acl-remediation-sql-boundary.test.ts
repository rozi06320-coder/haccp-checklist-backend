import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";

const migrationUrl = new URL(
  "../../supabase/migrations/20261026010000_manager_rpc_acl_remediation.sql",
  import.meta.url,
);

const signatures = [
  "cancel_managed_operational_staff_supervisor_training\\(uuid,\\s*uuid,\\s*uuid\\)",
  "get_cold_storage_managed_report_detail\\(uuid,\\s*uuid,\\s*uuid\\)",
  "get_managed_annual_evaluation_detail\\(uuid,\\s*uuid,\\s*uuid\\)",
  "get_managed_annual_evaluation_workspace\\(uuid,\\s*uuid,\\s*integer,\\s*uuid,\\s*text,\\s*uuid,\\s*text\\)",
  "get_managed_daily_audit_report_detail\\(uuid,\\s*uuid,\\s*uuid\\)",
  "get_managed_supervisor_training_promotion_state\\(uuid,\\s*uuid,\\s*uuid\\)",
  "get_management_organization_branding\\(uuid,\\s*uuid\\)",
  "get_oil_tracking_managed_report_detail\\(uuid,\\s*uuid,\\s*uuid\\)",
  "grant_existing_organization_manager\\(uuid,\\s*uuid,\\s*text\\)",
  "list_cold_storage_managed_reports\\(uuid,\\s*uuid,\\s*integer,\\s*integer,\\s*date,\\s*date,\\s*uuid,\\s*uuid,\\s*text,\\s*text\\)",
  "list_internal_admin_organization_managers\\(uuid,\\s*uuid\\)",
  "list_managed_branch_shifts\\(uuid,\\s*uuid,\\s*uuid\\)",
  "list_managed_daily_audit_reports\\(uuid,\\s*uuid,\\s*integer,\\s*integer,\\s*date,\\s*date,\\s*uuid,\\s*uuid,\\s*text,\\s*text\\)",
  "list_managed_maintenance_users\\(uuid,\\s*uuid\\)",
  "list_managed_operational_staff\\(uuid,\\s*uuid,\\s*integer,\\s*integer,\\s*text,\\s*uuid,\\s*uuid,\\s*text,\\s*text,\\s*date\\)",
  "list_managed_organization_users\\(uuid,\\s*uuid,\\s*integer,\\s*integer,\\s*text,\\s*text,\\s*uuid,\\s*text\\)",
  "list_oil_tracking_managed_reports\\(uuid,\\s*uuid,\\s*integer,\\s*integer,\\s*date,\\s*date,\\s*uuid,\\s*uuid,\\s*text,\\s*text\\)",
  "list_organization_manager_daily_audit_pins\\(uuid,\\s*uuid\\)",
  "list_phase4a_managed_reports\\(uuid,\\s*uuid,\\s*integer,\\s*integer,\\s*date,\\s*date,\\s*uuid,\\s*uuid,\\s*text,\\s*text,\\s*text\\)",
];

describe("19 Manager RPC ACL remediation SQL boundary", () => {
  it("covers exactly 19 Manager-related RPC signatures", () => {
    assert.equal(signatures.length, 19);
  });

  it("revokes every exact RPC signature from browser roles and preserves service_role", async () => {
    const sql = await readFile(migrationUrl, "utf8");
    for (const signature of signatures) {
      assert.match(
        sql,
        new RegExp(`revoke execute on function public\\.${signature}\\s+from public,\\s*anon,\\s*authenticated;`, "i"),
      );
      assert.match(
        sql,
        new RegExp(`grant execute on function public\\.${signature}\\s+to service_role;`, "i"),
      );
    }
  });

  it("contains privilege-only DDL and does not change business data or function bodies", async () => {
    const sql = await readFile(migrationUrl, "utf8");
    assert.doesNotMatch(sql, /\b(insert|update|delete|truncate|merge)\b/i);
    assert.doesNotMatch(sql, /\b(create|alter|drop)\s+(?:or\s+replace\s+)?(?:function|table|trigger|policy)\b/i);
    assert.doesNotMatch(sql, /alter\s+default\s+privileges/i);
  });
});
