import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { describe, it } from "node:test";

const migrationUrl = new URL(
  "../../supabase/migrations/20261025130000_manager_issues_rpc_acl_hotfix.sql",
  import.meta.url,
);

const signatures = [
  "list_phase4a_managed_issues\\(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text\\)",
  "get_phase4a_managed_issue\\(uuid,uuid,uuid\\)",
  "list_oil_tracking_managed_issues\\(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text\\)",
  "get_oil_tracking_managed_issue\\(uuid,uuid,uuid\\)",
  "list_cold_storage_managed_issues\\(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text\\)",
  "get_cold_storage_managed_issue\\(uuid,uuid,uuid\\)",
  "list_sales_tracking_managed_issues\\(uuid,uuid,int,int,date,date,uuid,uuid,uuid,text,text,text\\)",
  "get_sales_tracking_managed_issue\\(uuid,uuid,uuid\\)",
];

describe("Manager Issues RPC ACL hotfix SQL boundary", () => {
  it("revokes every exact RPC signature from browser roles and preserves service_role", async () => {
    const sql = await readFile(migrationUrl, "utf8");
    for (const signature of signatures) {
      assert.match(
        sql,
        new RegExp(`revoke execute on function public\\.${signature}\\s+from public, anon, authenticated;`, "i"),
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
