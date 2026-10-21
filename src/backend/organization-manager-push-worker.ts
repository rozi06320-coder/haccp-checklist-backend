import { promises as dns } from "node:dns";
import https from "node:https";
import { BlockList } from "node:net";
import tls from "node:tls";
import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import webPush from "web-push";
import { z } from "zod";
import type { BackendConfig } from "./config";
import { isAllowedBrowserPushEndpoint } from "./push-endpoint";

type RpcError = { code?: string };
type PushWorkerRpcClient = {
  rpc(name: string, args: Record<string, unknown>): Promise<{ data: unknown; error: RpcError | null }>;
};

type ResolvedAddress = { address: string; family: 4 | 6 };
export type PushDnsResolver = (hostname: string) => Promise<readonly ResolvedAddress[]>;
export type PreparedManagerPushDestination = {
  readonly endpoint: string;
  send(input: { p256dh: string; auth: string; topic: string; payload: string; signal: AbortSignal }): Promise<{ statusCode: number }>;
};
export type ManagerPushTransport = {
  prepare(input: { endpoint: string; signal: AbortSignal }): Promise<PreparedManagerPushDestination>;
};

const privateIpv4Destinations = new BlockList();
const nonGlobalIpv6Destinations = new BlockList();
const globalIpv6Destinations = new BlockList();
for (const [network, prefix] of [
  ["0.0.0.0", 8], ["10.0.0.0", 8], ["100.64.0.0", 10], ["127.0.0.0", 8],
  ["169.254.0.0", 16], ["172.16.0.0", 12], ["192.0.0.0", 24], ["192.0.2.0", 24],
  ["192.88.99.0", 24], ["192.168.0.0", 16], ["198.18.0.0", 15], ["198.51.100.0", 24],
  ["203.0.113.0", 24], ["224.0.0.0", 4], ["240.0.0.0", 4],
] as const) privateIpv4Destinations.addSubnet(network, prefix, "ipv4");
globalIpv6Destinations.addSubnet("2000::", 3, "ipv6");
for (const [network, prefix] of [
  ["2001::", 23], ["2001:db8::", 32], ["2002::", 16],
  ["2620:4f:8000::", 48], ["3fff::", 20],
] as const) nonGlobalIpv6Destinations.addSubnet(network, prefix, "ipv6");

export function isPublicPushAddress(address: string, family: 4 | 6): boolean {
  return family === 4
    ? !privateIpv4Destinations.check(address, "ipv4")
    : globalIpv6Destinations.check(address, "ipv6") && !nonGlobalIpv6Destinations.check(address, "ipv6");
}

export function assertSafePushRuntime(
  environment: NodeJS.ProcessEnv = process.env,
  execArguments: readonly string[] = process.execArgv,
): void {
  if (environment.NODE_TLS_REJECT_UNAUTHORIZED === "0"
    || environment.NODE_USE_ENV_PROXY === "1"
    || /(?:^|\s)--use-env-proxy(?:\s|$)/.test(environment.NODE_OPTIONS ?? "")
    || execArguments.includes("--use-env-proxy")) {
    throw new Error("Organization Manager push worker runtime security configuration is unsafe.");
  }
}

export function createDirectPushHttpsAgent(): https.Agent {
  return new https.Agent({ keepAlive: false, maxSockets: 8, rejectUnauthorized: true });
}

export class PushNetworkError extends Error {
  constructor(readonly retryable: boolean, readonly category: string) {
    super(category);
    this.name = "PushNetworkError";
  }
}

export function classifyPushRequestError(error: NodeJS.ErrnoException): PushNetworkError {
  const tlsRejected = ["DEPTH_ZERO_SELF_SIGNED_CERT", "SELF_SIGNED_CERT_IN_CHAIN",
    "ERR_TLS_CERT_ALTNAME_INVALID", "UNABLE_TO_VERIFY_LEAF_SIGNATURE", "CERT_HAS_EXPIRED"].includes(error.code ?? "");
  return new PushNetworkError(error.name !== "AbortError" && !tlsRejected,
    error.name === "AbortError" ? "request_cancelled" : tlsRejected ? "tls_rejected" : "request_error");
}

function deadline<T>(promise: Promise<T>, milliseconds: number, category: string): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new PushNetworkError(true, category)), milliseconds);
    timer.unref();
    promise.then(
      (value) => { clearTimeout(timer); resolve(value); },
      () => { clearTimeout(timer); reject(new PushNetworkError(true, category)); },
    );
  });
}

export function createSecureManagerPushTransport(input: {
  vapid: { subject: string; publicKey: string; privateKey: string };
  resolver?: PushDnsResolver;
  requestTimeoutMs?: number;
  dnsTimeoutMs?: number;
  responseLimitBytes?: number;
  agent?: https.Agent;
  requester?: typeof https.request;
}): ManagerPushTransport {
  const resolver: PushDnsResolver = input.resolver ?? (async (hostname) =>
    (await dns.lookup(hostname, { all: true, verbatim: true }))
      .filter((item): item is { address: string; family: 4 | 6 } => item.family === 4 || item.family === 6));
  const requestTimeoutMs = input.requestTimeoutMs ?? 5_000;
  const dnsTimeoutMs = input.dnsTimeoutMs ?? 2_000;
  const responseLimitBytes = input.responseLimitBytes ?? 8_192;
  const agent = input.agent ?? createDirectPushHttpsAgent();
  const requester = input.requester ?? https.request;

  return {
    async prepare(request) {
      if (!isAllowedBrowserPushEndpoint(request.endpoint)) throw new PushNetworkError(false, "endpoint_rejected");
      const target = new URL(request.endpoint);
      const addresses = await deadline(resolver(target.hostname), dnsTimeoutMs, "dns_unavailable");
      if (addresses.length === 0 || addresses.some((item) => !isPublicPushAddress(item.address, item.family))) {
        throw new PushNetworkError(false, "dns_destination_rejected");
      }
      const selected = addresses[0]!;
      return { endpoint: request.endpoint, async send(sendRequest) {
        const details = webPush.generateRequestDetails({
          endpoint: request.endpoint,
          keys: { p256dh: sendRequest.p256dh, auth: sendRequest.auth },
        }, sendRequest.payload, {
          TTL: 3_600, urgency: "normal", topic: sendRequest.topic, vapidDetails: input.vapid,
        });
        return await new Promise<{ statusCode: number }>((resolve, reject) => {
        let settled = false;
        let timer: NodeJS.Timeout | undefined;
        const finishReject = (error: PushNetworkError) => {
          if (settled) return;
          settled = true;
          if (timer) clearTimeout(timer);
          reject(error);
        };

        const outgoing = requester({
          agent,
          protocol: "https:",
          hostname: target.hostname,
          port: 443,
          servername: target.hostname,
          rejectUnauthorized: true,
          checkServerIdentity: tls.checkServerIdentity,
          method: "POST",
          path: `${target.pathname}${target.search}`,
          headers: details.headers,
          signal: sendRequest.signal,
          lookup: (_hostname, _options, callback) => callback(null, selected.address, selected.family),
        }, (response) => {
          let responseBytes = 0;
          response.on("data", (chunk: Buffer) => {
            responseBytes += chunk.length;
            if (responseBytes > responseLimitBytes) {
              response.destroy();
              outgoing.destroy();
              finishReject(new PushNetworkError(false, "response_too_large"));
            }
          });
          response.on("end", () => {
            if (settled) return;
            settled = true;
            if (timer) clearTimeout(timer);
            resolve({ statusCode: response.statusCode ?? 503 });
          });
          response.on("error", () => finishReject(new PushNetworkError(true, "response_error")));
        });
        outgoing.on("error", (error: NodeJS.ErrnoException) => {
          finishReject(classifyPushRequestError(error));
        });
        timer = setTimeout(() => {
          outgoing.destroy();
          finishReject(new PushNetworkError(true, "request_timeout"));
        }, requestTimeoutMs);
        timer.unref();
        outgoing.end(details.body ?? undefined);
        });
      } };
    },
  };
}

const uuid = z.string().uuid();
const claimSchema = z.object({
  delivery_id: uuid, lease_token: uuid, notification_id: uuid, subscription_id: uuid,
  recipient_user_id: uuid, organization_id: uuid, event_type: z.string(), source_type: z.string().nullable(),
  source_id: uuid.nullable(), endpoint: z.string(), p256dh: z.string(), auth: z.string(),
  attempt_count: z.number().int().min(1).max(5), lease_expires_at: z.string(),
}).strict();
const authorizationSchema = z.object({
  authorized: z.boolean(), delivery_id: uuid, notification_id: uuid, event_type: z.string(),
  endpoint: z.string().nullable(), p256dh: z.string().nullable(), auth: z.string().nullable(),
  topic: z.string().nullable(), lease_expires_at: z.string().nullable(),
}).strict();

export type ManagerPushWorkerRun = {
  enabled: boolean;
  claimed: number;
  sent: number;
  retried: number;
  terminal: number;
  revoked: number;
  authorizationUnknown: number;
  completionUnknown: number;
};

export type OrganizationManagerPushWorker = {
  readonly enabled: boolean;
  runBatch(signal?: AbortSignal): Promise<ManagerPushWorkerRun>;
};

export function createOrganizationManagerPushWorker(
  config: BackendConfig,
  options: {
    client?: PushWorkerRpcClient;
    transport?: ManagerPushTransport;
    concurrency?: number;
    batchSize?: number;
    logger?: (event: Record<string, unknown>) => void;
  } = {},
): OrganizationManagerPushWorker {
  const enabled = config.organizationManagerPushWorkerEnabled === true;
  if (!enabled) {
    return { enabled: false, async runBatch() {
      return { enabled: false, claimed: 0, sent: 0, retried: 0, terminal: 0, revoked: 0,
        authorizationUnknown: 0, completionUnknown: 0 };
    } };
  }
  if (!config.supabase.secretKey || !config.vapid?.subject || !config.vapid.publicKey || !config.vapid.privateKey) {
    throw new Error("Organization Manager push worker configuration is incomplete.");
  }
  assertSafePushRuntime();

  const client = options.client ?? createClient(config.supabase.url, config.supabase.secretKey, {
    auth: { autoRefreshToken: false, detectSessionInUrl: false, persistSession: false },
  }) as unknown as PushWorkerRpcClient;
  const transport = options.transport ?? createSecureManagerPushTransport({ vapid: {
    subject: config.vapid.subject, publicKey: config.vapid.publicKey, privateKey: config.vapid.privateKey,
  } });
  const concurrency = Math.max(1, Math.min(options.concurrency ?? 4, 8));
  const batchSize = Math.max(1, Math.min(options.batchSize ?? 20, 100));
  const workerId = randomUUID();
  const logger = options.logger ?? ((event) => console.info("ORGANIZATION_MANAGER_PUSH_WORKER", event));

  async function rpc(name: string, args: Record<string, unknown>) {
    const result = await client.rpc(name, args);
    if (result.error) throw new Error(`rpc_${result.error.code ?? "failed"}`);
    return result.data;
  }

  async function complete(deliveryId: string, leaseToken: string, result: "sent" | "retry" | "terminal", status: number | null) {
    await rpc("complete_organization_manager_push_delivery", {
      p_delivery_id: deliveryId, p_lease_token: leaseToken, p_result: result, p_http_status: status,
    });
  }

  return {
    enabled: true,
    async runBatch(signal = new AbortController().signal) {
      const runId = randomUUID();
      const stats: ManagerPushWorkerRun = {
        enabled: true, claimed: 0, sent: 0, retried: 0, terminal: 0, revoked: 0,
        authorizationUnknown: 0, completionUnknown: 0,
      };
      const rows = z.array(claimSchema).parse(await rpc("claim_organization_manager_push_deliveries", {
        p_worker_id: workerId, p_limit: batchSize, p_lease_seconds: 60,
      }) ?? []);
      stats.claimed = rows.length;

      let cursor = 0;
      const processNext = async (): Promise<void> => {
        while (!signal.aborted) {
          const row = rows[cursor++];
          if (!row) return;
          let destination: PreparedManagerPushDestination;
          try {
            destination = await transport.prepare({ endpoint: row.endpoint, signal });
          } catch (error) {
            const outcome = error instanceof PushNetworkError && !error.retryable ? "terminal" : "retry";
            try {
              await complete(row.delivery_id, row.lease_token, outcome, null);
              stats[outcome === "retry" ? "retried" : "terminal"] += 1;
            } catch { stats.completionUnknown += 1; }
            continue;
          }
          let authorizationRows: z.infer<typeof authorizationSchema>[];
          try {
            authorizationRows = z.array(authorizationSchema).parse(await rpc(
              "authorize_organization_manager_push_delivery",
              { p_delivery_id: row.delivery_id, p_lease_token: row.lease_token },
            ) ?? []);
          } catch {
            // Never send when the final lease-bound decision is unavailable.
            // A still-active lease is recovered by the database after expiry.
            stats.authorizationUnknown += 1;
            continue;
          }
          const authorization = authorizationRows[0];
          if (!authorization?.authorized) { stats.revoked += 1; continue; }
          if (authorization.event_type !== "maintenance_issue_created"
            || !authorization.endpoint || !authorization.p256dh || !authorization.auth || !authorization.topic) {
            try { await complete(row.delivery_id, row.lease_token, "terminal", null); stats.terminal += 1; }
            catch { stats.completionUnknown += 1; }
            continue;
          }
          if (authorization.endpoint !== destination.endpoint) {
            try { await complete(row.delivery_id, row.lease_token, "terminal", null); stats.terminal += 1; }
            catch { stats.completionUnknown += 1; }
            continue;
          }

          const payload = JSON.stringify({
            type: "maintenance_issue_created",
            notification_id: authorization.notification_id,
            title: "New maintenance issue",
            body: "A new maintenance issue requires review.",
            url: "/organization-manager?view=maintenance",
          });
          try {
            // The lease-bound authorization is deliberately the final awaited
            // operation before the prepared socket is created.
            const response = await destination.send({
              p256dh: authorization.p256dh, auth: authorization.auth,
              topic: authorization.topic, payload, signal,
            });
            const outcome = response.statusCode >= 200 && response.statusCode < 300 ? "sent"
              : response.statusCode === 404 || response.statusCode === 410 ? "terminal"
              : response.statusCode === 408 || response.statusCode === 425 || response.statusCode === 429 || response.statusCode >= 500
                ? "retry" : "terminal";
            try {
              await complete(row.delivery_id, row.lease_token, outcome, response.statusCode);
              stats[outcome === "sent" ? "sent" : outcome === "retry" ? "retried" : "terminal"] += 1;
            } catch { stats.completionUnknown += 1; }
          } catch (error) {
            if (error instanceof PushNetworkError && error.category === "request_cancelled") {
              // Shutdown is not a delivery failure. Leave the lease for safe
              // at-least-once recovery rather than terminalizing the message.
              stats.completionUnknown += 1;
              continue;
            }
            const outcome = error instanceof PushNetworkError && !error.retryable ? "terminal" : "retry";
            try {
              await complete(row.delivery_id, row.lease_token, outcome, null);
              stats[outcome === "retry" ? "retried" : "terminal"] += 1;
            } catch { stats.completionUnknown += 1; }
          }
        }
      };

      await Promise.all(Array.from({ length: Math.min(concurrency, rows.length) }, () => processNext()));
      logger({ run_id: runId, outcome: "batch_complete", claimed: stats.claimed, sent: stats.sent,
        retried: stats.retried, terminal: stats.terminal, revoked: stats.revoked,
        authorization_unknown: stats.authorizationUnknown,
        completion_unknown: stats.completionUnknown });
      return stats;
    },
  };
}

export function startOrganizationManagerPushWorker(input: {
  worker: OrganizationManagerPushWorker;
  pollIntervalMs?: number;
  logger?: (event: Record<string, unknown>) => void;
}) {
  let stopping = false;
  let current: AbortController | null = null;
  let wake: (() => void) | null = null;
  const stopped = input.worker.enabled ? (async () => {
    while (!stopping) {
      current = new AbortController();
      try { await input.worker.runBatch(current.signal); }
      catch { input.logger?.({ outcome: "batch_failed" }); }
      current = null;
      if (!stopping) await new Promise<void>((resolve) => {
        wake = resolve;
        const timer = setTimeout(resolve, input.pollIntervalMs ?? 5_000);
        timer.unref();
      });
      wake = null;
    }
  })() : Promise.resolve();

  return {
    async stop() {
      stopping = true;
      current?.abort();
      wake?.();
      await stopped;
    },
  };
}
