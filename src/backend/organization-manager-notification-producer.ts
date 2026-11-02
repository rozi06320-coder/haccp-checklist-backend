import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { z } from "zod";
import type { BackendConfig } from "./config";

type RpcError = { code?: string; message?: string };
type ProducerRpcClient = {
  rpc(name: string, args: Record<string, unknown>): Promise<{ data: unknown; error: RpcError | null }>;
};

const uuid = z.string().uuid();
const claimRow = z.object({
  job_id: uuid, lease_token: uuid, notification_category: z.enum([
    "sales_tracking_missing", "maintenance_issue", "incomplete_branch_tasks",
  ]), organization_id: uuid, branch_id: uuid, business_date: z.string(), lease_expires_at: z.string(),
}).strict();
const producerRow = z.object({
  job_id: uuid, result: z.enum(["completed", "retryable_unknown", "terminal"]),
  error_code: z.string().nullable(), created_count: z.number().int().nonnegative(),
}).strict();
const completionRow = z.object({ job_id: uuid, state: z.enum(["completed", "retry", "failed"]) }).strict();

const schedulerRow = z.object({
  job_id: uuid,
  organization_id: uuid,
  branch_id: uuid,
  business_date: z.string(),
  notification_category: z.enum([
    "sales_tracking_missing", "maintenance_issue", "incomplete_branch_tasks",
  ]),
  enqueued: z.boolean(),
}).strict();

export type NotificationProducerRun = {
  enabled: boolean;
  claimed: number;
  completed: number;
  retried: number;
  terminal: number;
};

export type NotificationSchedulerRun = {
  enabled: boolean;
  enqueued: number;
  scanned: number;
};

export type NotificationCycleRun = {
  enabled: boolean;
  scheduler: NotificationSchedulerRun;
  producer: NotificationProducerRun;
};

export type OrganizationManagerNotificationProducer = {
  readonly enabled: boolean;
  runBatch(input?: { category?: NotificationCategory; signal?: AbortSignal }): Promise<NotificationProducerRun>;
  enqueueDueJobs(input?: { catchUpDays?: number; asOf?: string; signal?: AbortSignal }): Promise<NotificationSchedulerRun>;
  runCycle(input?: { catchUpDays?: number; signal?: AbortSignal }): Promise<NotificationCycleRun>;
};

export type NotificationCategory =
  | "sales_tracking_missing"
  | "maintenance_issue"
  | "incomplete_branch_tasks";

const categories: readonly NotificationCategory[] = [
  "sales_tracking_missing", "maintenance_issue", "incomplete_branch_tasks",
];

/**
 * Opt-in runner for Organization Manager notification evaluation and production.
 * Keeps production disabled unless explicitly opted in via configuration or options.
 */
export function createOrganizationManagerNotificationProducer(
  config: BackendConfig,
  options: { client?: ProducerRpcClient; enabled?: boolean; batchSize?: number; leaseSeconds?: number } = {},
): OrganizationManagerNotificationProducer {
  const enabled = options.enabled === true;
  if (!enabled) return {
    enabled: false,
    async runBatch() { return { enabled: false, claimed: 0, completed: 0, retried: 0, terminal: 0 }; },
    async enqueueDueJobs() { return { enabled: false, enqueued: 0, scanned: 0 }; },
    async runCycle() {
      return {
        enabled: false,
        scheduler: { enabled: false, enqueued: 0, scanned: 0 },
        producer: { enabled: false, claimed: 0, completed: 0, retried: 0, terminal: 0 },
      };
    },
  };
  if (!config.supabase.secretKey) throw new Error("SUPABASE_SECRET_KEY is required by the notification producer.");
  const client = options.client ?? createClient(config.supabase.url, config.supabase.secretKey, {
    auth: { autoRefreshToken: false, detectSessionInUrl: false, persistSession: false },
  }) as unknown as ProducerRpcClient;
  const workerId = randomUUID();
  const batchSize = Math.max(1, Math.min(options.batchSize ?? 20, 100));
  const leaseSeconds = Math.max(30, Math.min(options.leaseSeconds ?? 120, 600));

  async function rpc(name: string, args: Record<string, unknown>): Promise<unknown> {
    let result: Awaited<ReturnType<ProducerRpcClient["rpc"]>>;
    try { result = await client.rpc(name, args); } catch { throw new Error("notification producer RPC unavailable"); }
    if (result.error) throw new Error(`notification producer RPC failed:${result.error.code ?? "unknown"}`);
    return result.data;
  }

  async function enqueueDueJobs(input: { catchUpDays?: number; asOf?: string; signal?: AbortSignal } = {}): Promise<NotificationSchedulerRun> {
    if (input.signal?.aborted) throw new Error("notification producer run cancelled");
    const catchUpDays = Math.max(1, Math.min(input.catchUpDays ?? 3, 7));
    const rows = z.array(schedulerRow).parse(await rpc("enqueue_due_organization_manager_notification_evaluation_jobs", {
      p_catch_up_days: catchUpDays,
      p_as_of: input.asOf ?? null,
    }) ?? []);
    const enqueued = rows.filter((r) => r.enqueued).length;
    return { enabled: true, enqueued, scanned: rows.length };
  }

  async function runBatch(input: { category?: NotificationCategory; signal?: AbortSignal } = {}): Promise<NotificationProducerRun> {
    if (input.signal?.aborted) throw new Error("notification producer run cancelled");
    let claimed = 0; let completed = 0; let retried = 0; let terminal = 0;
    const selected = input.category ? [input.category] : categories;
    for (const category of selected) {
      const rows = z.array(claimRow).parse(await rpc("claim_organization_manager_notification_evaluation_jobs", {
        p_worker_id: workerId, p_notification_category: category,
        p_limit: batchSize, p_lease_seconds: leaseSeconds,
      }) ?? []);
      claimed += rows.length;
      for (const job of rows) {
        if (input.signal?.aborted) throw new Error("notification producer run cancelled");
        let outcome: z.infer<typeof producerRow>;
        try {
          const produced = z.array(producerRow).parse(await rpc("produce_organization_manager_notification_evaluation_job", {
            p_job_id: job.job_id, p_lease_token: job.lease_token,
          }) ?? []);
          if (produced.length !== 1) throw new Error("invalid producer result");
          outcome = produced[0]!;
        } catch {
          outcome = { job_id: job.job_id, result: "retryable_unknown", error_code: "producer_unavailable", created_count: 0 };
        }
        const state = outcome.result === "completed" ? "completed" : outcome.result === "retryable_unknown" ? "retryable_unknown" : "terminal";
        const completedRows = completionRow.array().parse(await rpc("complete_organization_manager_notification_evaluation_job", {
          p_job_id: job.job_id, p_lease_token: job.lease_token,
          p_result: state, p_error_code: outcome.error_code,
        }) ?? []);
        if (completedRows.length !== 1) throw new Error("notification producer completion unavailable");
        if (state === "completed") completed += 1;
        else if (state === "retryable_unknown") retried += 1;
        else terminal += 1;
      }
    }
    return { enabled: true, claimed, completed, retried, terminal };
  }

  async function runCycle(input: { catchUpDays?: number; signal?: AbortSignal } = {}): Promise<NotificationCycleRun> {
    if (input.signal?.aborted) throw new Error("notification producer run cancelled");
    const scheduler = await enqueueDueJobs({ catchUpDays: input.catchUpDays, signal: input.signal });
    const producer = await runBatch({ signal: input.signal });
    return { enabled: true, scheduler, producer };
  }

  return {
    enabled: true,
    runBatch,
    enqueueDueJobs,
    runCycle,
  };
}

export function startOrganizationManagerNotificationScheduler(input: {
  producer: OrganizationManagerNotificationProducer;
  pollIntervalMs?: number;
  catchUpDays?: number;
  logger?: (event: Record<string, unknown>) => void;
}) {
  let stopping = false;
  let current: AbortController | null = null;
  let wake: (() => void) | null = null;
  const stopped = input.producer.enabled ? (async () => {
    while (!stopping) {
      current = new AbortController();
      try {
        const result = await input.producer.runCycle({
          catchUpDays: input.catchUpDays,
          signal: current.signal,
        });
        input.logger?.({ outcome: "cycle_complete", ...result });
      } catch (error) {
        if (!stopping) {
          input.logger?.({ outcome: "cycle_failed", error: error instanceof Error ? error.message : "unknown" });
        }
      }
      current = null;
      if (!stopping) await new Promise<void>((resolve) => {
        wake = resolve;
        const timer = setTimeout(resolve, input.pollIntervalMs ?? 60_000);
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
