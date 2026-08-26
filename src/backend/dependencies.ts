import { createClient } from "@supabase/supabase-js";
import type { BackendConfig } from "./config";
import {
  createPasswordChangeService,
  createManagementAdmin,
  createBranchManagementAdmin,
  createDailyAuditPinAdmin,
  createMaintenanceAccessAdmin,
  createTrainingBranchAccessAdmin,
  createPinCrypto,
  createProvisioningAdmin,
  type ManagementAdmin,
  type BranchManagementAdmin,
  type DailyAuditPinAdmin,
  type MaintenanceAccessAdmin,
  type TrainingBranchAccessAdmin,
  type PinCrypto,
  type PasswordChangeService,
  type ProvisioningAdmin,
} from "./admin";
import {
  createUserContextRepository,
  type UserContextRepository,
} from "./user-context";
import { createOperationalAdmin, type OperationalAdmin } from "./operational";
import { createChecklistPersistence, type ChecklistPersistence } from "./checklist-persistence";
import { createEvidenceService, type EvidenceService } from "./evidence";
import { createBrandingService, type BrandingService } from "./branding";
import { createMaintenancePushService, type MaintenancePushService } from "./maintenance-push";

export type AuthVerifier = {
  verify(token: string): Promise<{ userId: string; email: string } | null>;
};

type ClaimsAuthClient = {
  auth: {
    getClaims(token: string): Promise<{
      data: { claims: Record<string, unknown> } | null;
      error: unknown;
    }>;
  };
};

export type UserContextRepositoryFactory = (
  token: string,
) => UserContextRepository;

export type BackendDependencies = {
  authVerifier: AuthVerifier;
  checkReadiness: () => Promise<boolean>;
  createUserContext: UserContextRepositoryFactory;
  passwordChange: PasswordChangeService;
  provisioningAdmin: ProvisioningAdmin;
  managementAdmin: ManagementAdmin;
  branchManagementAdmin: BranchManagementAdmin;
  dailyAuditPinAdmin?: DailyAuditPinAdmin;
  maintenanceAccessAdmin?: MaintenanceAccessAdmin;
  trainingBranchAccessAdmin?: TrainingBranchAccessAdmin;
  pinCrypto: PinCrypto;
  operationalAdmin?: OperationalAdmin;
  checklistPersistence?: ChecklistPersistence;
  evidenceService?: EvidenceService;
  brandingService?: BrandingService;
  maintenancePush?: MaintenancePushService;
  now?: () => Date;
};

const clientAuthOptions = {
  autoRefreshToken: false,
  detectSessionInUrl: false,
  persistSession: false,
} as const;

export function createSupabaseClaimsAuthVerifier(
  authClient: ClaimsAuthClient,
): AuthVerifier {
  return {
    async verify(token) {
      try {
        const { data, error } = await authClient.auth.getClaims(token);
        if (error || !data?.claims) {
          return null;
        }

        const { sub, email, role, is_anonymous } = data.claims;
        if (
          typeof sub !== "string" ||
          !sub.trim() ||
          typeof email !== "string" ||
          !email.trim() ||
          (role !== undefined && role !== "authenticated") ||
          is_anonymous === true
        ) {
          return null;
        }

        return { userId: sub, email };
      } catch {
        return null;
      }
    },
  };
}

export function createDefaultDependencies(
  config: BackendConfig,
): BackendDependencies {
  if (!config.supabase.secretKey) {
    throw new Error("SUPABASE_SECRET_KEY is required by the production dependency factory.");
  }
  const authClient = createClient(
    config.supabase.url,
    config.supabase.publishableKey,
    { auth: clientAuthOptions },
  );

  return {
    passwordChange: createPasswordChangeService(
      config.supabase.url,
      config.supabase.publishableKey,
      config.supabase.secretKey,
    ),
    provisioningAdmin: createProvisioningAdmin(
      config.supabase.url,
      config.supabase.secretKey,
    ),
    managementAdmin: createManagementAdmin(
      config.supabase.url,
      config.supabase.secretKey,
    ),
    branchManagementAdmin: createBranchManagementAdmin(config.supabase.url, config.supabase.secretKey),
    dailyAuditPinAdmin: createDailyAuditPinAdmin(config.supabase.url, config.supabase.secretKey),
    maintenanceAccessAdmin: createMaintenanceAccessAdmin(config.supabase.url, config.supabase.secretKey),
    trainingBranchAccessAdmin: createTrainingBranchAccessAdmin(config.supabase.url, config.supabase.secretKey),
    pinCrypto: createPinCrypto(config.dailyAuditGrantSecret),
    operationalAdmin: createOperationalAdmin(config.supabase.url, config.supabase.secretKey),
    checklistPersistence: createChecklistPersistence(config.supabase.url, config.supabase.secretKey),
    evidenceService: createEvidenceService(config.supabase.url, config.supabase.secretKey),
    brandingService: createBrandingService(config.supabase.url, config.supabase.secretKey),
    maintenancePush: createMaintenancePushService(config),
    now: () => new Date(),
    authVerifier: createSupabaseClaimsAuthVerifier(authClient),
    async checkReadiness() {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 3_000);

      try {
        const response = await fetch(
          new URL("/auth/v1/health", config.supabase.url),
          {
            headers: { apikey: config.supabase.publishableKey },
            signal: controller.signal,
          },
        );
        return response.ok;
      } catch {
        return false;
      } finally {
        clearTimeout(timeout);
      }
    },
    createUserContext(token) {
      return createUserContextRepository(
        createClient(
          config.supabase.url,
          config.supabase.publishableKey,
          {
            auth: clientAuthOptions,
            global: { headers: { Authorization: `Bearer ${token}` } },
          },
        ),
      );
    },
  };
}
