import { createClient } from "@supabase/supabase-js";
import webPush from "web-push";
import { z } from "zod";
import type { BackendConfig } from "./config";

type PushRpcClient = {
  rpc(name: string, args: Record<string, unknown>): Promise<{ data: unknown; error: { code?: string } | null }>;
};

type PushTransport = {
  setVapidDetails(subject: string, publicKey: string, privateKey: string): void;
  sendNotification(subscription: { endpoint: string; keys: { p256dh: string; auth: string } }, payload?: string | Buffer, options?: unknown): Promise<unknown>;
};

const uuid = z.string().uuid();
const subscriptionRow = z.object({
  id: uuid,
  user_id: uuid,
  endpoint: z.string(),
  disabled_at: z.string().nullable(),
}).strict();
const recipientRow = z.object({
  subscription_id: uuid,
  user_id: uuid,
  endpoint: z.string(),
  p256dh: z.string(),
  auth: z.string(),
  organization_id: uuid,
  branch_id: uuid.nullable(),
  organization_name: z.string(),
  branch_name: z.string(),
  issue_title: z.string(),
}).strict();
const supervisorDeliveryRow = z.object({
  notification_id: uuid,
  subscription_id: uuid,
  recipient_user_id: uuid,
  endpoint: z.string(),
  p256dh: z.string(),
  auth: z.string(),
  organization_id: uuid,
  branch_id: uuid,
  business_date: z.string(),
  notification_type: z.enum(["oil_tracking_reminder", "cold_storage_reminder", "financial_closing_reminder", "financial_closing_overdue"]),
  checklist_type: z.enum(["oil_tracking", "cold_storage", "financial_closing"]),
  rule_key: z.enum(["oil_tracking_1800", "cold_storage_2000", "financial_closing_2200", "financial_closing_2300", "financial_closing_0200_overdue"]),
  severity: z.enum(["warning", "urgent"]),
  payload: z.record(z.string(), z.unknown()),
  created_at: z.string(),
}).strict();

export class MaintenancePushInputError extends Error {}
export class MaintenancePushAccessError extends Error {}
export class MaintenancePushConflictError extends Error {}
export class MaintenancePushUnavailableError extends Error {}

export type MaintenancePushService = {
  getPublicKey(): string | null;
  registerSubscription(input: {
    actorUserId: string;
    endpoint: string;
    p256dh: string;
    auth: string;
    userAgent?: string | null;
  }): Promise<unknown>;
  disableSubscription(input: {
    actorUserId: string;
    endpoint: string;
  }): Promise<unknown>;
  registerSupervisorSubscription(input: {
    actorUserId: string;
    endpoint: string;
    p256dh: string;
    auth: string;
    userAgent?: string | null;
  }): Promise<unknown>;
  notifyMaintenanceIssueCreated(input: {
    issueId: string;
    branchId: string | null;
    branchName: string;
    priority: string;
    title: string;
  }): Promise<void>;
  notifyDueSupervisorChecklistReminders(input: {
    asOf: Date;
  }): Promise<{ evaluated_at: string; deliveries_attempted: number; deliveries_sent: number }>;
};

const clientAuthOptions = {
  autoRefreshToken: false,
  detectSessionInUrl: false,
  persistSession: false,
} as const;

function mapRpcError(error: { code?: string } | null) {
  if (!error) return;
  if (error.code === "42501") throw new MaintenancePushAccessError();
  if (error.code === "23505") throw new MaintenancePushConflictError();
  if (error.code === "22023" || error.code === "23514") throw new MaintenancePushInputError();
  throw new MaintenancePushUnavailableError();
}

function deliveryStatusCode(error: unknown) {
  if (typeof error !== "object" || error === null || !("statusCode" in error)) return null;
  const value = (error as { statusCode?: unknown }).statusCode;
  return typeof value === "number" ? value : null;
}

function supervisorNotificationRoute(row: z.infer<typeof supervisorDeliveryRow>) {
  if (row.checklist_type === "oil_tracking") return "/branch-manager?view=checklist&checklist=haccp&category=temperature&subcategory=oil-tracking";
  if (row.checklist_type === "cold_storage") return "/branch-manager?view=checklist&checklist=haccp&category=temperature&subcategory=refrigerator-freezer";
  return "/branch-manager?view=checklist&checklist=financial_closing";
}

function supervisorNotificationCopy(row: z.infer<typeof supervisorDeliveryRow>) {
  if (row.notification_type === "oil_tracking_reminder") return { title: "Oil Tracking", body: "Oil Tracking is still incomplete." };
  if (row.notification_type === "cold_storage_reminder") return { title: "Cold Storage", body: "Cold Storage checks are still incomplete." };
  if (row.notification_type === "financial_closing_overdue") return { title: "Daily Financial Closing overdue", body: "Yesterday's Financial Closing is overdue." };
  if (row.rule_key === "financial_closing_2300") return { title: "Daily Financial Closing", body: "Financial Closing must be completed." };
  return { title: "Daily Financial Closing", body: "Daily Financial Closing is still incomplete." };
}

function maintenanceIssuePriorityLabel(priority: string) {
  if (priority === "urgent") return "Urgent";
  if (priority === "high") return "High";
  if (priority === "low") return "Low";
  return "Normal";
}

export function createMaintenancePushService(
  config: BackendConfig,
  options: { supabase?: PushRpcClient; webPush?: PushTransport } = {},
): MaintenancePushService {
  const enabled = Boolean(config.vapid?.publicKey && config.vapid.privateKey && config.vapid.subject);
  const pushTransport = options.webPush ?? webPush;
  if (enabled) {
    pushTransport.setVapidDetails(config.vapid!.subject!, config.vapid!.publicKey!, config.vapid!.privateKey!);
  }
  if (!config.supabase.secretKey) {
    throw new Error("SUPABASE_SECRET_KEY is required by Maintenance push notifications.");
  }
  const supabase: PushRpcClient = options.supabase ?? createClient(config.supabase.url, config.supabase.secretKey, {
    auth: clientAuthOptions,
  }) as unknown as PushRpcClient;

  async function rpcRows<T>(name: string, args: Record<string, unknown>, schema: z.ZodType<T>) {
    const { data, error } = await supabase.rpc(name, args);
    mapRpcError(error);
    return z.array(schema).parse(data ?? []);
  }

  async function disableDelivery(subscriptionId: string, endpoint: string) {
    await supabase.rpc("disable_push_subscription_delivery", {
      target_subscription_id: subscriptionId,
      target_endpoint: endpoint,
    });
  }

  return {
    getPublicKey() {
      return enabled ? config.vapid!.publicKey! : null;
    },
    async registerSubscription(input) {
      const rows = await rpcRows("register_maintenance_push_subscription", {
        actor_user_id: input.actorUserId,
        p_endpoint: input.endpoint,
        p_p256dh: input.p256dh,
        p_auth: input.auth,
        p_user_agent: input.userAgent ?? null,
      }, subscriptionRow);
      return { subscription: rows[0] ?? null };
    },
    async disableSubscription(input) {
      const rows = await rpcRows("disable_maintenance_push_subscription", {
        actor_user_id: input.actorUserId,
        p_endpoint: input.endpoint,
      }, subscriptionRow);
      return { subscription: rows[0] ?? null };
    },
    async registerSupervisorSubscription(input) {
      const rows = await rpcRows("register_supervisor_push_subscription", {
        actor_user_id: input.actorUserId,
        p_endpoint: input.endpoint,
        p_p256dh: input.p256dh,
        p_auth: input.auth,
        p_user_agent: input.userAgent ?? null,
      }, subscriptionRow);
      return { subscription: rows[0] ?? null };
    },
    async notifyMaintenanceIssueCreated(input) {
      if (!enabled) return;
      const recipients = await rpcRows("list_maintenance_issue_push_subscriptions", {
        target_issue_id: input.issueId,
      }, recipientRow).catch(() => []);
      const sentEndpoints = new Set<string>();
      const deliveries = recipients.flatMap((recipient) => {
        if (sentEndpoints.has(recipient.endpoint)) return [];
        sentEndpoints.add(recipient.endpoint);
        const payload = JSON.stringify({
          type: "maintenance_issue_created",
          issue_id: input.issueId,
          branch_id: input.branchId,
          priority: input.priority,
          title: "New Maintenance Issue",
          body: `${recipient.branch_name || input.branchName} · ${maintenanceIssuePriorityLabel(input.priority)} priority\n${input.title}`,
          url: "/maintenance",
        });
        return pushTransport.sendNotification({
          endpoint: recipient.endpoint,
          keys: { p256dh: recipient.p256dh, auth: recipient.auth },
        }, payload, { TTL: 60 * 60 }).catch(async (error: unknown) => {
          const status = deliveryStatusCode(error);
          if (status === 404 || status === 410) {
            await disableDelivery(recipient.subscription_id, recipient.endpoint);
          }
        });
      });
      await Promise.allSettled(deliveries);
    },
    async notifyDueSupervisorChecklistReminders(input) {
      const evaluatedAt = input.asOf.toISOString();
      const deliveries = await rpcRows("list_supervisor_notification_push_deliveries", {
        as_of: evaluatedAt,
      }, supervisorDeliveryRow);
      if (!enabled) return { evaluated_at: evaluatedAt, deliveries_attempted: 0, deliveries_sent: 0 };

      let attempted = 0;
      let sent = 0;
      const seen = new Set<string>();
      await Promise.allSettled(deliveries.map(async (delivery) => {
        const key = `${delivery.notification_id}:${delivery.endpoint}`;
        if (seen.has(key)) return;
        seen.add(key);
        attempted += 1;
        const copy = supervisorNotificationCopy(delivery);
        const payload = JSON.stringify({
          type: "supervisor_checklist_reminder",
          notification_id: delivery.notification_id,
          branch_id: delivery.branch_id,
          checklist_type: delivery.checklist_type,
          rule_key: delivery.rule_key,
          severity: delivery.severity,
          title: copy.title,
          body: copy.body,
          url: supervisorNotificationRoute(delivery),
        });
        try {
          const { error: attemptError } = await supabase.rpc("mark_supervisor_notification_push_attempted", {
            target_notification_id: delivery.notification_id,
            target_subscription_id: delivery.subscription_id,
            target_endpoint: delivery.endpoint,
          });
          if (attemptError) return;
          await pushTransport.sendNotification({
            endpoint: delivery.endpoint,
            keys: { p256dh: delivery.p256dh, auth: delivery.auth },
          }, payload, { TTL: 60 * 60 });
          const { error } = await supabase.rpc("mark_supervisor_notification_push_sent", {
            target_notification_id: delivery.notification_id,
            target_subscription_id: delivery.subscription_id,
            target_endpoint: delivery.endpoint,
          });
          if (!error) sent += 1;
        } catch (error: unknown) {
          const status = deliveryStatusCode(error);
          if (status === 404 || status === 410) {
            await disableDelivery(delivery.subscription_id, delivery.endpoint);
          }
        }
      }));
      return { evaluated_at: evaluatedAt, deliveries_attempted: attempted, deliveries_sent: sent };
    },
  };
}
