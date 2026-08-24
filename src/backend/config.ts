import { z } from "zod";

const trustProxySetting = z
  .enum(["false", "loopback"])
  .default("false")
  .transform((value) => (value === "loopback" ? "loopback" : false));

function isStrongEncodedGrantSecret(value: string) {
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(value) || value.length % 4 !== 0) {
    return false;
  }

  const decoded = Buffer.from(value, "base64");
  return (
    decoded.length >= 32 &&
    decoded.toString("base64") === value &&
    new Set(decoded).size >= 16
  );
}

const environmentSchema = z
  .object({
    NODE_ENV: z
      .enum(["development", "test", "production"])
      .default("development"),
    API_HOST: z.string().trim().min(1).default("127.0.0.1"),
    API_PORT: z.coerce.number().int().min(1).max(65_535).default(3001),
    API_TRUST_PROXY: trustProxySetting,
    SUPABASE_URL: z.url(),
    SUPABASE_PUBLISHABLE_KEY: z.string().trim().min(1).max(8_192),
    SUPABASE_SECRET_KEY: z.string().trim().min(1).max(8_192).optional(),
    DAILY_AUDIT_GRANT_SECRET: z.string().min(32).max(4_096),
    VAPID_PUBLIC_KEY: z.string().trim().min(1).max(4_096).optional(),
    VAPID_PRIVATE_KEY: z.string().trim().min(1).max(4_096).optional(),
    VAPID_SUBJECT: z.string().trim().min(1).max(512).optional(),
    SUPERVISOR_NOTIFICATION_SCHEDULER_SECRET: z.string().min(32).max(4_096).optional(),
  })
  .superRefine((environment, context) => {
    const protocol = new URL(environment.SUPABASE_URL).protocol;
    if (protocol !== "http:" && protocol !== "https:") {
      context.addIssue({
        code: "custom",
        path: ["SUPABASE_URL"],
        message: "must use HTTP or HTTPS",
      });
    }

    if (
      environment.NODE_ENV === "test"
        ? !environment.DAILY_AUDIT_GRANT_SECRET.startsWith("test-")
        : !isStrongEncodedGrantSecret(environment.DAILY_AUDIT_GRANT_SECRET)
    ) {
      context.addIssue({
        code: "custom",
        path: ["DAILY_AUDIT_GRANT_SECRET"],
        message:
          environment.NODE_ENV === "test"
            ? "must use an explicit non-production test placeholder"
            : "must be canonical base64 encoding of at least 32 high-diversity bytes",
      });
    }
  });

export type BackendConfig = {
  nodeEnv: "development" | "test" | "production";
  host: string;
  port: number;
  trustProxy: false | "loopback";
  supabase: {
    url: string;
    publishableKey: string;
    secretKey?: string;
  };
  dailyAuditGrantSecret: string;
  vapid?: {
    publicKey?: string;
    privateKey?: string;
    subject?: string;
  };
  supervisorNotificationSchedulerSecret?: string;
};

export class BackendConfigurationError extends Error {
  constructor(issues: readonly { path: PropertyKey[]; message: string }[]) {
    const fields = issues
      .map((issue) => String(issue.path[0] ?? "environment"))
      .filter((field, index, all) => all.indexOf(field) === index)
      .join(", ");

    super(`Invalid backend configuration: ${fields}.`);
    this.name = "BackendConfigurationError";
  }
}

export function loadBackendConfig(
  environment: NodeJS.ProcessEnv = process.env,
): BackendConfig {
  const result = environmentSchema.safeParse(environment);

  if (!result.success) {
    throw new BackendConfigurationError(result.error.issues);
  }

  return {
    nodeEnv: result.data.NODE_ENV,
    host: result.data.API_HOST,
    port: result.data.API_PORT,
    trustProxy: result.data.API_TRUST_PROXY,
    supabase: {
      url: result.data.SUPABASE_URL,
      publishableKey: result.data.SUPABASE_PUBLISHABLE_KEY,
      secretKey: result.data.SUPABASE_SECRET_KEY,
    },
    dailyAuditGrantSecret: result.data.DAILY_AUDIT_GRANT_SECRET,
    vapid: {
      publicKey: result.data.VAPID_PUBLIC_KEY,
      privateKey: result.data.VAPID_PRIVATE_KEY,
      subject: result.data.VAPID_SUBJECT,
    },
    supervisorNotificationSchedulerSecret: result.data.SUPERVISOR_NOTIFICATION_SCHEDULER_SECRET,
  };
}
