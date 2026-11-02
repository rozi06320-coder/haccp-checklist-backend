import { strict as assert } from "node:assert";
import { describe, it } from "node:test";
import {
  createOrganizationManagerNotificationProducer,
  startOrganizationManagerNotificationScheduler,
} from "./organization-manager-notification-producer";
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
    assert.deepEqual(await producer.enqueueDueJobs(), { enabled: false, enqueued: 0, scanned: 0 });
    assert.deepEqual(await producer.runCycle(), {
      enabled: false,
      scheduler: { enabled: false, enqueued: 0, scanned: 0 },
      producer: { enabled: false, claimed: 0, completed: 0, retried: 0, terminal: 0 },
    });
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

  it("enqueues due evaluation jobs with bounded catchUpDays", async () => {
    let capturedArgs: Record<string, unknown> | null = null;
    const client = {
      async rpc(name: string, args: Record<string, unknown>) {
        if (name === "enqueue_due_organization_manager_notification_evaluation_jobs") {
          capturedArgs = args;
          return {
            data: [
              {
                job_id: "11111111-1111-4111-8111-111111111111",
                organization_id: "33333333-3333-4333-8333-333333333333",
                branch_id: "44444444-4444-4444-8444-444444444444",
                business_date: "2026-11-01",
                notification_category: "sales_tracking_missing",
                enqueued: true,
              },
              {
                job_id: "22222222-2222-4222-8222-222222222222",
                organization_id: "33333333-3333-4333-8333-333333333333",
                branch_id: "44444444-4444-4444-8444-444444444444",
                business_date: "2026-11-01",
                notification_category: "maintenance_issue",
                enqueued: false, // Already existed
              },
            ],
            error: null,
          };
        }
        return { data: [], error: null };
      },
    };
    const producer = createOrganizationManagerNotificationProducer(config, { enabled: true, client });
    const result = await producer.enqueueDueJobs({ catchUpDays: 10 }); // exceeds max 7, should be clamped to 7
    assert.equal(capturedArgs?.p_catch_up_days, 7);
    assert.deepEqual(result, { enabled: true, enqueued: 1, scanned: 2 });
  });

  it("executes complete cycle of enqueueing and producing", async () => {
    const executedRpcs: string[] = [];
    const client = {
      async rpc(name: string, args: Record<string, unknown>) {
        executedRpcs.push(name);
        if (name === "enqueue_due_organization_manager_notification_evaluation_jobs") {
          return { data: [], error: null };
        }
        if (name === "claim_organization_manager_notification_evaluation_jobs") {
          return { data: [], error: null };
        }
        return { data: [], error: null };
      },
    };
    const producer = createOrganizationManagerNotificationProducer(config, { enabled: true, client });
    const cycleResult = await producer.runCycle({ catchUpDays: 3 });
    assert.deepEqual(cycleResult, {
      enabled: true,
      scheduler: { enabled: true, enqueued: 0, scanned: 0 },
      producer: { enabled: true, claimed: 0, completed: 0, retried: 0, terminal: 0 },
    });
    assert.ok(executedRpcs.includes("enqueue_due_organization_manager_notification_evaluation_jobs"));
    assert.ok(executedRpcs.includes("claim_organization_manager_notification_evaluation_jobs"));
  });

  it("starts and gracefully stops scheduler background loop", async () => {
    let cycles = 0;
    const client = {
      async rpc() {
        cycles += 1;
        return { data: [], error: null };
      },
    };
    const producer = createOrganizationManagerNotificationProducer(config, { enabled: true, client });
    const scheduler = startOrganizationManagerNotificationScheduler({
      producer,
      pollIntervalMs: 50,
      catchUpDays: 3,
    });
    // Allow at least 1 cycle to execute
    await new Promise((resolve) => setTimeout(resolve, 80));
    await scheduler.stop();
    assert.ok(cycles > 0);
  });
});
