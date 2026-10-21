import { createHmac } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { z } from "zod";
import type { BackendConfig } from "./config";
import { isAllowedBrowserPushEndpoint } from "./push-endpoint";

type RpcError = { code?: string; message?: string };
type ManagerNotificationRpcClient = {
  rpc(name: string, args: Record<string, unknown>): Promise<{ data: unknown; error: RpcError | null }>;
};

const uuid = z.string().uuid();
const subscriptionSchema = z.object({
  id: uuid, user_id: uuid, endpoint: z.string(), disabled_at: z.string().nullable(),
}).strict();
const notificationSchema = z.object({
  id: uuid,
  organization_id: uuid,
  event_type: z.enum([
    "maintenance_issue_created", "haccp_issue_submitted", "hygiene_issue_submitted",
    "daily_audit_issue_submitted", "cash_monitoring_submitted", "financial_closing_overdue",
  ]),
  source_type: z.enum([
    "maintenance_issue", "checklist_submission", "sales_tracking_report", "financial_closing_report",
  ]).nullable(),
  source_id: uuid.nullable(),
  occurrence_key: z.string().min(1).max(200),
  read_at: z.string().nullable(),
  created_at: z.string(),
}).strict();
const readSchema = z.object({ id: uuid, read_at: z.string() }).strict();

export class ManagerNotificationAccessError extends Error {}
export class ManagerNotificationConflictError extends Error {}
export class ManagerNotificationInputError extends Error {}
export class ManagerNotificationRateLimitError extends Error {}
export class ManagerNotificationUnavailableError extends Error {}

export type OrganizationManagerNotificationService = {
  getPublicKey(input: { actorUserId: string; organizationId: string }): Promise<string | null>;
  registerSubscription(input: {
    actorUserId: string; organizationId: string; endpoint: string; p256dh: string;
    auth: string; userAgent?: string | null; clientIp: string;
  }): Promise<unknown>;
  disableSubscription(input: {
    actorUserId: string; organizationId: string; endpoint: string; clientIp: string;
  }): Promise<unknown>;
  listNotifications(input: {
    actorUserId: string; organizationId: string; before?: string | null; limit: number;
  }): Promise<unknown>;
  markRead(input: {
    actorUserId: string; organizationId: string; notificationId: string; clientIp: string;
  }): Promise<unknown>;
};

const authOptions = { autoRefreshToken: false, detectSessionInUrl: false, persistSession: false } as const;

function mappedError(error: RpcError): Error {
  if (error.code === "42501") return new ManagerNotificationAccessError();
  if (error.code === "23505") return new ManagerNotificationConflictError();
  if (error.code === "22023" || error.code === "23514") return new ManagerNotificationInputError();
  return new ManagerNotificationUnavailableError();
}

export function createOrganizationManagerNotificationService(
  config: BackendConfig,
  options: { client?: ManagerNotificationRpcClient } = {},
): OrganizationManagerNotificationService {
  if (!config.supabase.secretKey) throw new Error("SUPABASE_SECRET_KEY is required by manager notifications.");
  const client = options.client ?? createClient(config.supabase.url, config.supabase.secretKey, {
    auth: authOptions,
  }) as unknown as ManagerNotificationRpcClient;
  const enabled = Boolean(config.vapid?.publicKey && config.vapid.privateKey && config.vapid.subject);

  function addressHash(clientIp: string) {
    return createHmac("sha256", config.dailyAuditGrantSecret)
      .update("organization-manager-push-ip\0", "utf8")
      .update(clientIp, "utf8")
      .digest("hex");
  }

  async function rpc(name: string, args: Record<string, unknown>) {
    let result: Awaited<ReturnType<ManagerNotificationRpcClient["rpc"]>>;
    try { result = await client.rpc(name, args); } catch { throw new ManagerNotificationUnavailableError(); }
    if (result.error) throw mappedError(result.error);
    return result.data;
  }

  async function consumeRateLimit(input: {
    actorUserId: string; organizationId: string; clientIp: string;
    operation: "register" | "disable" | "mark_read";
  }) {
    const data = await rpc("consume_organization_manager_push_rate_limit", {
      p_actor_user_id: input.actorUserId,
      p_organization_id: input.organizationId,
      p_client_address_hash: addressHash(input.clientIp),
      p_operation: input.operation,
    });
    if (!data || typeof data !== "object" || (data as { allowed?: unknown }).allowed !== true) {
      throw new ManagerNotificationRateLimitError();
    }
  }

  return {
    async getPublicKey(input) {
      const authorized = await rpc("authorize_organization_manager_push_access", {
        p_actor_user_id: input.actorUserId, p_organization_id: input.organizationId,
      });
      if (authorized !== true) throw new ManagerNotificationAccessError();
      return enabled ? config.vapid!.publicKey! : null;
    },
    async registerSubscription(input) {
      if (!isAllowedBrowserPushEndpoint(input.endpoint)) throw new ManagerNotificationInputError();
      await consumeRateLimit({ ...input, operation: "register" });
      const rows = z.array(subscriptionSchema).parse(await rpc("register_organization_manager_push_subscription", {
        p_actor_user_id: input.actorUserId,
        p_organization_id: input.organizationId,
        p_endpoint: input.endpoint,
        p_p256dh: input.p256dh,
        p_auth: input.auth,
        p_user_agent: input.userAgent ?? null,
      }) ?? []);
      return { subscription: rows[0] ?? null };
    },
    async disableSubscription(input) {
      await consumeRateLimit({ ...input, operation: "disable" });
      const rows = z.array(subscriptionSchema).parse(await rpc("disable_organization_manager_push_subscription", {
        p_actor_user_id: input.actorUserId,
        p_organization_id: input.organizationId,
        p_endpoint: input.endpoint,
      }) ?? []);
      return { subscription: rows[0] ?? null };
    },
    async listNotifications(input) {
      const rows = z.array(notificationSchema).parse(await rpc("list_organization_manager_notifications", {
        p_actor_user_id: input.actorUserId,
        p_organization_id: input.organizationId,
        p_before: input.before ?? null,
        p_limit: input.limit,
      }) ?? []);
      return { notifications: rows };
    },
    async markRead(input) {
      await consumeRateLimit({ ...input, operation: "mark_read" });
      const rows = z.array(readSchema).parse(await rpc("mark_organization_manager_notification_read", {
        p_actor_user_id: input.actorUserId,
        p_organization_id: input.organizationId,
        p_notification_id: input.notificationId,
      }) ?? []);
      if (!rows[0]) throw new ManagerNotificationAccessError();
      return { notification: rows[0] };
    },
  };
}
