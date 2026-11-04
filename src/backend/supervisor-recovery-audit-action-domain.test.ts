import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

const baselinePath = path.resolve("supabase/migrations/20261103100000_atomic_access_role_transition.sql");
const recoveryPath = path.resolve("supabase/migrations/20261104090000_supervisor_operational_recovery_classification.sql");

function actionSet(sql: string): Set<string> {
  const match = sql.match(/action in \((.*?)\)\s*\)/s);
  assert.ok(match, "audit action CHECK constraint must be present");
  return new Set([...match[1].matchAll(/'([^']+)'/g)].map(([, action]) => action));
}

describe("Supervisor recovery audit-action compatibility", () => {
  it("retains every baseline action and adds only the three recovery actions", async () => {
    const [baseline, recovery] = await Promise.all([
      readFile(baselinePath, "utf8"),
      readFile(recoveryPath, "utf8"),
    ]);
    const baselineActions = actionSet(baseline);
    const recoveryActions = actionSet(recovery);
    assert.deepEqual([...baselineActions].filter((action) => !recoveryActions.has(action)), []);
    assert.deepEqual(
      [...recoveryActions].filter((action) => !baselineActions.has(action)).sort(),
      [
        "supervisor_classification_changed",
        "supervisor_operational_access_restored",
        "training_membership_deactivated_for_supervisor_restore",
      ],
    );
  });
});
