import assert from "node:assert/strict";
import https from "node:https";
import tls from "node:tls";
import { describe, it } from "node:test";
import { loadBackendConfig } from "./config";
import {
  createOrganizationManagerPushWorker,
  createDirectPushHttpsAgent,
  createSecureManagerPushTransport,
  assertSafePushRuntime,
  classifyPushRequestError,
  isPublicPushAddress,
  PushNetworkError,
  startOrganizationManagerPushWorker,
  type ManagerPushTransport,
} from "./organization-manager-push-worker";

const baseEnvironment = {
  NODE_ENV: "test",
  SUPABASE_URL: "http://127.0.0.1:54321",
  SUPABASE_PUBLISHABLE_KEY: "test-publishable",
  DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
} as const;

function enabledConfig() {
  return loadBackendConfig({
    ...baseEnvironment,
    ORGANIZATION_MANAGER_PUSH_WORKER_ENABLED: "true",
    SUPABASE_SECRET_KEY: "test-service-key",
    VAPID_PUBLIC_KEY: "test-public-key",
    VAPID_PRIVATE_KEY: "test-private-key",
    VAPID_SUBJECT: "mailto:push@example.invalid",
  });
}

const claim = {
  delivery_id: "10000000-0000-4000-8000-000000000001",
  lease_token: "20000000-0000-4000-8000-000000000001",
  notification_id: "30000000-0000-4000-8000-000000000001",
  subscription_id: "40000000-0000-4000-8000-000000000001",
  recipient_user_id: "50000000-0000-4000-8000-000000000001",
  organization_id: "60000000-0000-4000-8000-000000000001",
  event_type: "maintenance_issue_created",
  source_type: "maintenance_issue",
  source_id: "70000000-0000-4000-8000-000000000001",
  endpoint: "https://fcm.googleapis.com/fcm/send/private-token",
  p256dh: "private-p256dh",
  auth: "private-auth",
  attempt_count: 1,
  lease_expires_at: "2026-10-21T12:01:00.000Z",
};
const authorization = {
  authorized: true,
  delivery_id: claim.delivery_id,
  notification_id: claim.notification_id,
  event_type: claim.event_type,
  endpoint: claim.endpoint,
  p256dh: claim.p256dh,
  auth: claim.auth,
  topic: "30000000000040008000000000000001",
  lease_expires_at: claim.lease_expires_at,
};

function harness(input: {
  status?: number;
  sendError?: Error;
  authorized?: boolean;
  authorizationFails?: boolean;
  completionFails?: boolean;
} = {}) {
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  const sends: Array<Record<string, unknown>> = [];
  const logs: Array<Record<string, unknown>> = [];
  const client = { async rpc(name: string, args: Record<string, unknown>) {
    calls.push({ name, args });
    if (name === "claim_organization_manager_push_deliveries") return { data: [claim], error: null };
    if (name === "authorize_organization_manager_push_delivery" && input.authorizationFails)
      return { data: null, error: { code: "55000" } };
    if (name === "authorize_organization_manager_push_delivery") return {
      data: [{ ...authorization, authorized: input.authorized ?? true,
        ...(input.authorized === false ? { endpoint: null, p256dh: null, auth: null, topic: null, lease_expires_at: null } : {}) }],
      error: null,
    };
    if (input.completionFails) return { data: null, error: { code: "08006" } };
    return { data: [{ delivery_id: claim.delivery_id, state: "sent", next_attempt_at: "2026-10-21T12:00:00Z" }], error: null };
  } };
  const transport: ManagerPushTransport = { async prepare(request) {
    sends.push({ stage: "prepared", endpoint: request.endpoint });
    return { endpoint: request.endpoint, async send(sendRequest) {
      sends.push(sendRequest as unknown as Record<string, unknown>);
      if (input.sendError) throw input.sendError;
      return { statusCode: input.status ?? 201 };
    } };
  } };
  const worker = createOrganizationManagerPushWorker(enabledConfig(), {
    client, transport, logger: (event) => logs.push(event), concurrency: 2,
  });
  return { worker, calls, sends, logs };
}

describe("Organization Manager push worker", () => {
  it("does no work and starts no poll loop while the server-only gate is false", async () => {
    let called = false;
    const worker = createOrganizationManagerPushWorker(loadBackendConfig(baseEnvironment), {
      client: { async rpc() { called = true; return { data: [], error: null }; } },
    });
    assert.deepEqual(await worker.runBatch(), {
      enabled: false, claimed: 0, sent: 0, retried: 0, terminal: 0, revoked: 0,
      authorizationUnknown: 0, completionUnknown: 0,
    });
    await startOrganizationManagerPushWorker({ worker }).stop();
    assert.equal(called, false);
  });

  it("claims, reauthorizes, sends generic copy, and completes with the lease token", async () => {
    const test = harness();
    const result = await test.worker.runBatch();
    assert.equal(result.sent, 1);
    assert.deepEqual(test.calls.map((item) => item.name), [
      "claim_organization_manager_push_deliveries",
      "authorize_organization_manager_push_delivery",
      "complete_organization_manager_push_delivery",
    ]);
    assert.equal(test.calls[2]!.args.p_lease_token, claim.lease_token);
    const sent = test.sends[1]!;
    assert.equal(sent.topic, authorization.topic);
    assert.doesNotMatch(String(sent.payload), /employee|financial|checklist answer|description|private-token|private-auth|private-p256dh/i);
    assert.deepEqual(Object.keys(test.logs[0]!).sort(), [
      "authorization_unknown", "claimed", "completion_unknown", "outcome", "retried", "revoked", "run_id", "sent", "terminal",
    ]);
    assert.doesNotMatch(JSON.stringify(test.logs), /private-token|private-auth|private-p256dh/);
  });

  it("does not send after final authorization revokes an active claim", async () => {
    const test = harness({ authorized: false });
    const result = await test.worker.runBatch();
    assert.equal(result.revoked, 1);
    assert.equal(test.sends.length, 1);
    assert.equal(test.sends[0]!.stage, "prepared");
    assert.equal(test.calls.some((item) => item.name === "complete_organization_manager_push_delivery"), false);
  });

  it("fails closed and leaves recovery to the lease when final authorization is unavailable", async () => {
    const test = harness({ authorizationFails: true });
    const result = await test.worker.runBatch();
    assert.equal(result.authorizationUnknown, 1);
    assert.equal(test.sends.length, 1);
    assert.equal(test.calls.some((item) => item.name === "complete_organization_manager_push_delivery"), false);
  });

  it("retries transient statuses and terminalizes redirects and expired endpoints without following them", async () => {
    for (const [status, expected] of [[503, "retry"], [302, "terminal"], [410, "terminal"]] as const) {
      const test = harness({ status });
      await test.worker.runBatch();
      const completion = test.calls.find((item) => item.name === "complete_organization_manager_push_delivery")!;
      assert.equal(completion.args.p_result, expected);
      assert.equal(completion.args.p_http_status, status);
      assert.equal(test.sends.length, 2);
    }
  });

  it("leaves an accepted delivery leased when database completion is unknown", async () => {
    const test = harness({ status: 201, completionFails: true });
    const result = await test.worker.runBatch();
    assert.equal(result.completionUnknown, 1);
    assert.equal(test.calls.filter((item) => item.name === "complete_organization_manager_push_delivery").length, 1);
  });

  it("maps bounded network errors to retry or terminal completion", async () => {
    for (const error of [new PushNetworkError(true, "request_timeout"), new PushNetworkError(false, "dns_destination_rejected")]) {
      const test = harness({ sendError: error });
      await test.worker.runBatch();
      const completion = test.calls.find((item) => item.name === "complete_organization_manager_push_delivery")!;
      assert.equal(completion.args.p_result, error.retryable ? "retry" : "terminal");
      assert.equal(completion.args.p_http_status, null);
    }
  });

  it("does not terminalize an active lease when clean shutdown cancels the request", async () => {
    const test = harness({ sendError: new PushNetworkError(false, "request_cancelled") });
    const result = await test.worker.runBatch();
    assert.equal(result.completionUnknown, 1);
    assert.equal(test.calls.some((item) => item.name === "complete_organization_manager_push_delivery"), false);
  });
});

describe("secure push network boundary", () => {
  it("rejects private, loopback, link-local, documentation and mapped addresses", () => {
    for (const address of ["10.0.0.1", "127.0.0.1", "169.254.169.254", "192.0.2.1", "198.51.100.2", "203.0.113.3"])
      assert.equal(isPublicPushAddress(address, 4), false, address);
    for (const address of ["::1", "::2", "::127.0.0.1", "fc00::1", "fe80::1", "2001:db8::1",
      "::ffff:127.0.0.1", "64:ff9b:1::7f00:1", "2002:7f00:1::", "2001::1", "2001:2::1",
      "2620:4f:8000::1", "3fff::1"])
      assert.equal(isPublicPushAddress(address, 6), false, address);
    assert.equal(isPublicPushAddress("8.8.8.8", 4), true);
    assert.equal(isPublicPushAddress("2606:4700:4700::1111", 6), true);
  });

  it("fails before any request when DNS resolves a provider host to a private address", async () => {
    const transport = createSecureManagerPushTransport({
      vapid: { subject: "mailto:push@example.invalid", publicKey: "public", privateKey: "private" },
      resolver: async () => [{ address: "127.0.0.1", family: 4 }],
      dnsTimeoutMs: 20,
    });
    await assert.rejects(() => transport.prepare({
      endpoint: claim.endpoint, signal: new AbortController().signal,
    }), (error: unknown) => error instanceof PushNetworkError && error.category === "dns_destination_rejected");
  });

  it("bounds DNS resolution time", async () => {
    const transport = createSecureManagerPushTransport({
      vapid: { subject: "mailto:push@example.invalid", publicKey: "public", privateKey: "private" },
      resolver: async () => await new Promise<never>(() => undefined),
      dnsTimeoutMs: 5,
    });
    await assert.rejects(() => transport.prepare({
      endpoint: claim.endpoint, signal: new AbortController().signal,
    }), (error: unknown) => error instanceof PushNetworkError && error.category === "dns_unavailable");
  });

  it("fails closed when Node proxy or insecure TLS modes could override the worker boundary", () => {
    for (const environment of [
      { NODE_USE_ENV_PROXY: "1" },
      { NODE_OPTIONS: "--use-env-proxy" },
      { NODE_TLS_REJECT_UNAUTHORIZED: "0" },
    ]) assert.throws(() => assertSafePushRuntime(environment, []), /unsafe/);
    assert.throws(() => assertSafePushRuntime({}, ["--use-env-proxy"]), /unsafe/);
    assert.doesNotThrow(() => assertSafePushRuntime({ HTTPS_PROXY: "http://127.0.0.1:9", HTTP_PROXY: "http://127.0.0.1:9" }, []));
  });

  it("uses a dedicated direct TLS agent with mandatory certificate verification", () => {
    const agent = createDirectPushHttpsAgent();
    assert.notEqual(agent, https.globalAgent);
    assert.equal(agent.options.rejectUnauthorized, true);
    assert.ok(tls.checkServerIdentity("wrong.invalid", {
      subject: { CN: "fcm.googleapis.com" }, subjectaltname: "DNS:fcm.googleapis.com",
    } as tls.PeerCertificate));
    for (const code of ["DEPTH_ZERO_SELF_SIGNED_CERT", "SELF_SIGNED_CERT_IN_CHAIN", "ERR_TLS_CERT_ALTNAME_INVALID"]) {
      const classified = classifyPushRequestError(Object.assign(new Error("certificate rejected"), { code }));
      assert.equal(classified.category, "tls_rejected");
      assert.equal(classified.retryable, false);
    }
  });

  it("rejects a mixed public/private rebinding answer before final authorization", async () => {
    const transport = createSecureManagerPushTransport({
      vapid: { subject: "mailto:push@example.invalid", publicKey: "public", privateKey: "private" },
      resolver: async () => [{ address: "8.8.8.8", family: 4 }, { address: "127.0.0.1", family: 4 }],
    });
    await assert.rejects(() => transport.prepare({ endpoint: claim.endpoint, signal: new AbortController().signal }),
      (error: unknown) => error instanceof PushNetworkError && error.category === "dns_destination_rejected");
  });
});
