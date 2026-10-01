import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { loadBackendConfig } from "./config";
import { createMaintenancePushService } from "./maintenance-push";

const config = loadBackendConfig({
  NODE_ENV: "test",
  SUPABASE_URL: "http://127.0.0.1:54321",
  SUPABASE_PUBLISHABLE_KEY: "test-publishable-placeholder",
  SUPABASE_SECRET_KEY: "test-secret",
  DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
  VAPID_PUBLIC_KEY: "test-public-key",
  VAPID_PRIVATE_KEY: "test-private-key",
  VAPID_SUBJECT: "mailto:test@example.invalid",
});

const request = {
  requestId: "49000000-0000-4000-8000-000000000001",
  organizationId: "29000000-0000-4000-8000-000000000001",
  branchId: "39000000-0000-4000-8000-000000000001",
  branchName: "Branch A",
  category: "kitchen" as const,
  createdAt: "2026-10-01T08:00:00.000Z",
};

describe("Purchasing push delivery service", () => {
  it("fans out once per endpoint, supports multiple devices, disables expired endpoints, and sends safe copy", async () => {
    const disabled: Record<string, unknown>[] = [];
    const sent: Array<{ endpoint: string; payload: Record<string, unknown> }> = [];
    const recipient = (subscriptionId: string, userId: string, endpoint: string) => ({
      subscription_id: subscriptionId,
      user_id: userId,
      endpoint,
      p256dh: "abcdefghijklmnopqrstuvwxyz",
      auth: "authsecret",
      organization_id: request.organizationId,
      branch_id: request.branchId,
      branch_name: request.branchName,
      category: request.category,
      request_created_at: request.createdAt,
    });
    const supabase = { async rpc(name: string, args: Record<string, unknown>) {
      if (name === "list_purchase_request_push_subscriptions") return { data: [
        recipient("59000000-0000-4000-8000-000000000001", "19000000-0000-4000-8000-000000000001", "https://push.example/buyer-a-phone"),
        recipient("59000000-0000-4000-8000-000000000002", "19000000-0000-4000-8000-000000000001", "https://push.example/buyer-a-laptop"),
        recipient("59000000-0000-4000-8000-000000000003", "19000000-0000-4000-8000-000000000002", "https://push.example/buyer-b-stale"),
        recipient("59000000-0000-4000-8000-000000000004", "19000000-0000-4000-8000-000000000002", "https://push.example/buyer-a-phone"),
      ], error: null };
      if (name === "disable_push_subscription_delivery") {
        disabled.push(args);
        return { data: true, error: null };
      }
      throw new Error(`unexpected RPC ${name}`);
    } };
    const webPush = {
      setVapidDetails() {},
      async sendNotification(subscription: { endpoint: string }, payload?: string | Buffer) {
        if (subscription.endpoint.endsWith("stale")) throw { statusCode: 410 };
        sent.push({ endpoint: subscription.endpoint, payload: JSON.parse(String(payload)) as Record<string, unknown> });
      },
    };
    const service = createMaintenancePushService(config, { supabase, webPush });
    await service.notifyPurchaseRequestCreated!(request);

    assert.deepEqual(sent.map((delivery) => delivery.endpoint).sort(), [
      "https://push.example/buyer-a-laptop",
      "https://push.example/buyer-a-phone",
    ]);
    assert.equal(disabled.length, 1);
    for (const delivery of sent) {
      assert.deepEqual(delivery.payload, {
        type: "purchase_request_created",
        request_id: request.requestId,
        organization_id: request.organizationId,
        branch_id: request.branchId,
        category: "kitchen",
        created_at: request.createdAt,
        title: "New Purchase Request",
        body: "Branch A submitted a new purchase request.",
        url: "/purchasing",
      });
      assert.doesNotMatch(JSON.stringify(delivery.payload), /Gloves|quantity|notes|photo|email|p256dh|authsecret|endpoint/i);
    }
  });

  it("uses the Purchasing registration RPC without creating another subscription model", async () => {
    const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
    const service = createMaintenancePushService(config, {
      supabase: { async rpc(name, args) {
        calls.push({ name, args });
        return { data: [{ id: "59000000-0000-4000-8000-000000000001", user_id: "19000000-0000-4000-8000-000000000001", endpoint: args.p_endpoint, disabled_at: null }], error: null };
      } },
      webPush: { setVapidDetails() {}, async sendNotification() {} },
    });
    await service.registerPurchasingSubscription!({ actorUserId: "19000000-0000-4000-8000-000000000001", endpoint: "https://push.example/buyer", p256dh: "abcdefghijklmnopqrstuvwxyz", auth: "authsecret", userAgent: "Browser" });
    assert.equal(calls[0]?.name, "register_purchasing_push_subscription");
  });
});
