import { createClient } from "@supabase/supabase-js";
import webPush from "web-push";
import { z } from "zod";
import type { BackendConfig } from "./config";

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
  branch_id: uuid,
  organization_name: z.string(),
  branch_name: z.string(),
  issue_title: z.string(),
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
  notifyMaintenanceIssueCreated(input: {
    issueId: string;
    branchId: string;
    branchName: string;
    title: string;
  }): Promise<void>;
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

export function createMaintenancePushService(
  config: BackendConfig,
): MaintenancePushService {
  const enabled = Boolean(config.vapid?.publicKey && config.vapid.privateKey && config.vapid.subject);
  if (enabled) {
    webPush.setVapidDetails(config.vapid!.subject!, config.vapid!.publicKey!, config.vapid!.privateKey!);
  }
  if (!config.supabase.secretKey) {
    throw new Error("SUPABASE_SECRET_KEY is required by Maintenance push notifications.");
  }
  const supabase = createClient(config.supabase.url, config.supabase.secretKey, {
    auth: clientAuthOptions,
  });

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
          title: "New Maintenance Issue",
          body: `${recipient.organization_name} - ${input.title}`,
          url: "/maintenance",
        });
        return webPush.sendNotification({
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
  };
}
