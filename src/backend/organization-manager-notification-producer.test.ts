import { strict as assert } from "node:assert";
import { describe, it } from "node:test";
import { createOrganizationManagerNotificationProducer } from "./organization-manager-notification-producer";
import type { BackendConfig } from "./config";

const config: BackendConfig = {
  nodeEnv: "test", host: "127.0.0.1", port: 1, trustProxy: false,
  supabase: { url: "http://127.0.0.1", publishableKey: "test", secretKey: "service" },
  dailyAuditGrantSecret: "test-placeholder-long-enough-for-tests",
};

describe("Organization Manager notification producer runner", () => {
  it("is disabled unless explicitly opted in", async () => {
    const producer = createOrganizationManagerNotificationProducer(config);
    assert.equal(producer.enabled, false);
    assert.deepEqual(await producer.runBatch(), { enabled: false, claimed: 0, completed: 0, retried: 0, terminal: 0 });
  });

  it("claims, produces, and completes a lease without exposing payloads", async () => {
    const calls: string[] = [];
    const client = {
      async rpc(name: string, args: Record<string, unknown>) {
        calls.push(name);
        if (name === "claim_organization_manager_notification_evaluation_jobs") return {
          data: [{ job_id: "11111111-1111-4111-8111-111111111111", lease_token: "22222222-2222-4222-8222-222222222222", notification_category: "sales_tracking_missing", organization_id: "33333333-3333-4333-8333-333333333333", branch_id: "44444444-4444-4444-8444-444444444444", business_date: "2026-10-30", lease_expires_at: "2026-10-30T04:01:00Z" }], error: null };
        if (name === "produce_organization_manager_notification_evaluation_job") return {
          data: [{ job_id: args.p_job_id, result: "completed", error_code: null, created_count: 1 }], error: null,
        };
        return { data: [{ job_id: args.p_job_id, state: "completed" }], error: null };
      },
    };
    const producer = createOrganizationManagerNotificationProducer(config, { enabled: true, client });
    assert.deepEqual(await producer.runBatch({ category: "sales_tracking_missing" }), { enabled: true, claimed: 1, completed: 1, retried: 0, terminal: 0 });
    assert.deepEqual(calls, [
      "claim_organization_manager_notification_evaluation_jobs",
      "produce_organization_manager_notification_evaluation_job",
      "complete_organization_manager_notification_evaluation_job",
    ]);
  });
});
