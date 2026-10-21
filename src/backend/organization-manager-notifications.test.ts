import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { loadBackendConfig } from "./config";
import {
  createOrganizationManagerNotificationService,
  ManagerNotificationInputError,
  ManagerNotificationRateLimitError,
} from "./organization-manager-notifications";

const config = loadBackendConfig({
  NODE_ENV: "test", SUPABASE_URL: "http://127.0.0.1:54321",
  SUPABASE_PUBLISHABLE_KEY: "test-publishable-placeholder",
  SUPABASE_SECRET_KEY: "test-secret-placeholder",
  DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
  VAPID_PUBLIC_KEY: "test-public-key", VAPID_PRIVATE_KEY: "test-private-key",
  VAPID_SUBJECT: "mailto:test@example.invalid",
});
const actor = "11000000-0000-4000-8000-000000000001";
const organization = "21000000-0000-4000-8000-000000000001";
const subscription = "31000000-0000-4000-8000-000000000001";

describe("Organization Manager notification service", () => {
  it("validates before RPC and consumes the durable limit before registration", async () => {
    const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
    const service = createOrganizationManagerNotificationService(config, { client: {
      async rpc(name, args) {
        calls.push({ name, args });
        if (name === "consume_organization_manager_push_rate_limit") return { data: { allowed: true }, error: null };
        return { data: [{ id: subscription, user_id: actor, endpoint: args.p_endpoint, disabled_at: null }], error: null };
      },
    } });
    await service.registerSubscription({
      actorUserId: actor, organizationId: organization,
      endpoint: "https://fcm.googleapis.com/fcm/send/manager-device",
      p256dh: "abcdefghijklmnopqrstuvwxyz", auth: "authsecret", clientIp: "203.0.113.8",
    });
    assert.deepEqual(calls.map((call) => call.name), [
      "consume_organization_manager_push_rate_limit", "register_organization_manager_push_subscription",
    ]);
    assert.match(String(calls[0]?.args.p_client_address_hash), /^[0-9a-f]{64}$/);
    assert.notEqual(calls[0]?.args.p_client_address_hash, "203.0.113.8");
  });

  it("rejects malicious endpoints without contacting Supabase", async () => {
    let called = false;
    const service = createOrganizationManagerNotificationService(config, { client: {
      async rpc() { called = true; return { data: null, error: null }; },
    } });
    await assert.rejects(() => service.registerSubscription({
      actorUserId: actor, organizationId: organization,
      endpoint: "https://127.0.0.1/internal", p256dh: "abcdefghijklmnopqrstuvwxyz",
      auth: "authsecret", clientIp: "203.0.113.8",
    }), ManagerNotificationInputError);
    assert.equal(called, false);
  });

  it("fails closed when the durable limiter denies a mutation", async () => {
    const service = createOrganizationManagerNotificationService(config, { client: {
      async rpc() { return { data: { allowed: false }, error: null }; },
    } });
    await assert.rejects(() => service.disableSubscription({
      actorUserId: actor, organizationId: organization,
      endpoint: "https://fcm.googleapis.com/fcm/send/manager-device", clientIp: "203.0.113.8",
    }), ManagerNotificationRateLimitError);
  });
});
