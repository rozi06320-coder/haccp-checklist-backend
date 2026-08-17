import { randomUUID } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import { z } from "zod";
import { inspectEvidenceImage } from "./evidence";

export const BRANDING_BUCKET = "branding-assets";
export const MAX_BRANDING_BYTES = 5 * 1024 * 1024;
export const BRANDING_SIGNED_URL_SECONDS = 5 * 60;

const brandingPathSchema = z.string().regex(/^(organizations|branches)\/[0-9a-fA-F-]{36}\/logo\/[0-9a-fA-F-]{36}\.(jpg|png|webp)$/);
const organizationBrandingRowsSchema = z.array(z.object({
  id: z.uuid(),
  logo_path: z.string().nullable(),
}).passthrough()).max(1);
const branchBrandingRowsSchema = z.array(z.object({
  id: z.uuid(),
  logo_path: z.string().nullable(),
}).passthrough()).max(1);
const supervisorBrandingRowsSchema = z.array(z.object({
  branch_id: z.uuid(),
  organization_id: z.uuid(),
  branch_logo_path: z.string().nullable(),
  organization_logo_path: z.string().nullable(),
}).strict()).max(1);
const maintenanceBrandingRowSchema = z.object({
  organizations: z.object({
    logo_path: z.string().nullable(),
  }).strict(),
}).strict();

export class BrandingAccessError extends Error {}
export class BrandingInputError extends Error {}
export class BrandingUnavailableError extends Error {}

export type BrandingService = {
  signLogoPath(path: string | null): Promise<string | null>;
  uploadOrganizationLogo(input: {
    actorUserId: string;
    organizationId: string;
    bytes: Buffer;
    declaredMime: string;
    requestId: string;
  }): Promise<{ organization_id: string; organization_logo_url: string | null }>;
  uploadBranchLogo(input: {
    actorUserId: string;
    organizationId: string;
    branchId: string;
    bytes: Buffer;
    declaredMime: string;
    requestId: string;
  }): Promise<{ branch_id: string; branch_logo_url: string | null; branch_logo_configured: boolean }>;
  getManagementOrganizationBranding(actorUserId: string, organizationId: string): Promise<{
    organization_logo_url: string | null;
  }>;
  getMaintenanceOrganizationBranding(actorUserId: string, organizationId: string): Promise<{
    organization_logo_url: string | null;
  }>;
  getMaintenanceAccessOrganizationBranding(organizationId: string): Promise<{
    organization_logo_url: string | null;
  }>;
  getSupervisorBranchBranding(actorUserId: string, branchId: string): Promise<{
    branch_logo_url: string | null;
    organization_logo_url: string | null;
    effective_logo_url: string | null;
  }>;
};

type BrandingClient = {
  rpc: (name: string, args?: Record<string, unknown>) => PromiseLike<{ data: unknown; error: { code?: string } | null }>;
  from?: (table: string) => {
    select: (columns: string) => {
      eq: (column: string, value: unknown) => {
        eq: (column: string, value: unknown) => {
          eq: (column: string, value: unknown) => {
            maybeSingle: () => PromiseLike<{ data: unknown; error: { code?: string } | null }>;
          };
          maybeSingle: () => PromiseLike<{ data: unknown; error: { code?: string } | null }>;
        };
        maybeSingle: () => PromiseLike<{ data: unknown; error: { code?: string } | null }>;
      };
    };
  };
  storage: {
    from: (bucket: string) => {
      upload: (path: string, bytes: Buffer, options: Record<string, unknown>) => PromiseLike<{ data: unknown; error: unknown }>;
      remove: (paths: string[]) => PromiseLike<{ data: unknown; error: unknown }>;
      createSignedUrl: (path: string, seconds: number) => PromiseLike<{ data: { signedUrl?: string } | null; error: unknown }>;
    };
  };
};

const nonPersistentAuth = { autoRefreshToken: false, detectSessionInUrl: false, persistSession: false } as const;

export function createBrandingService(url: string, secretKey: string): BrandingService {
  const client = createClient(url, secretKey, { auth: nonPersistentAuth });
  return createBrandingServiceFromClient(client as unknown as BrandingClient);
}

export function createBrandingServiceFromClient(client: BrandingClient): BrandingService {
  const storage = client.storage.from(BRANDING_BUCKET);

  async function rpc(name: string, args: Record<string, unknown>) {
    const result = await client.rpc(name, args);
    if (result.error) {
      if (result.error.code === "22023") throw new BrandingInputError();
      if (result.error.code === "42501") throw new BrandingAccessError();
      throw new BrandingUnavailableError();
    }
    return result.data;
  }

  async function removeObject(path: string, requestId: string, stage: string) {
    const result = await storage.remove([path]);
    if (result.error) {
      console.warn("Branding storage compensation", { requestId, stage, category: "storage_cleanup_failed", status: 503 });
    }
  }

  async function signLogoPath(path: string | null) {
    if (!path) return null;
    const parsed = brandingPathSchema.safeParse(path);
    if (!parsed.success) throw new BrandingInputError();
    const result = await storage.createSignedUrl(parsed.data, BRANDING_SIGNED_URL_SECONDS);
    if (result.error || !result.data?.signedUrl) throw new BrandingUnavailableError();
    return result.data.signedUrl;
  }

  async function safeSignLogoPath(path: string | null) {
    try {
      return await signLogoPath(path);
    } catch {
      return null;
    }
  }

  async function getMaintenanceLogoPath(actorUserId: string, organizationId: string) {
    if (!client.from) throw new BrandingUnavailableError();
    const result = await client
      .from("maintenance_memberships")
      .select("organizations!inner(logo_path)")
      .eq("user_id", actorUserId)
      .eq("organization_id", organizationId)
      .eq("active", true)
      .maybeSingle();
    if (result.error) throw new BrandingUnavailableError();
    const row = maintenanceBrandingRowSchema.safeParse(result.data);
    if (!row.success) throw new BrandingAccessError();
    return row.data.organizations.logo_path;
  }

  async function getMaintenanceAccessLogoPath(organizationId: string) {
    if (!client.from) throw new BrandingUnavailableError();
    const result = await client
      .from("organizations")
      .select("logo_path")
      .eq("id", organizationId)
      .eq("active", true)
      .maybeSingle();
    if (result.error) throw new BrandingUnavailableError();
    const row = z.object({ logo_path: z.string().nullable() }).strict().safeParse(result.data);
    if (!row.success) throw new BrandingAccessError();
    return row.data.logo_path;
  }

  return {
    signLogoPath,
    async uploadOrganizationLogo(input) {
      let inspected: ReturnType<typeof inspectEvidenceImage>;
      try {
        inspected = inspectEvidenceImage(input.bytes, input.declaredMime);
      } catch {
        throw new BrandingInputError();
      }
      const objectPath = `organizations/${input.organizationId}/logo/${randomUUID()}.${inspected.extension}`;
      const upload = await storage.upload(objectPath, input.bytes, {
        contentType: inspected.mime,
        cacheControl: "300",
        upsert: false,
        metadata: { byteSize: String(input.bytes.length), mimeType: inspected.mime },
      });
      if (upload.error) throw new BrandingUnavailableError();
      try {
        const rows = organizationBrandingRowsSchema.parse(await rpc("update_internal_admin_organization_logo", {
          actor_user_id: input.actorUserId,
          target_organization_id: input.organizationId,
          object_path: objectPath,
        }));
        if (!rows[0]) throw new BrandingAccessError();
        return {
          organization_id: rows[0].id,
          organization_logo_url: await safeSignLogoPath(rows[0].logo_path),
        };
      } catch (error) {
        await removeObject(objectPath, input.requestId, "organization_logo_update_compensation");
        throw error;
      }
    },
    async uploadBranchLogo(input) {
      let inspected: ReturnType<typeof inspectEvidenceImage>;
      try {
        inspected = inspectEvidenceImage(input.bytes, input.declaredMime);
      } catch {
        throw new BrandingInputError();
      }
      const objectPath = `branches/${input.branchId}/logo/${randomUUID()}.${inspected.extension}`;
      const upload = await storage.upload(objectPath, input.bytes, {
        contentType: inspected.mime,
        cacheControl: "300",
        upsert: false,
        metadata: { byteSize: String(input.bytes.length), mimeType: inspected.mime },
      });
      if (upload.error) throw new BrandingUnavailableError();
      try {
        const rows = branchBrandingRowsSchema.parse(await rpc("update_internal_admin_branch_logo", {
          actor_user_id: input.actorUserId,
          target_organization_id: input.organizationId,
          target_branch_id: input.branchId,
          object_path: objectPath,
        }));
        if (!rows[0]) throw new BrandingAccessError();
        return {
          branch_id: rows[0].id,
          branch_logo_url: await safeSignLogoPath(rows[0].logo_path),
          branch_logo_configured: rows[0].logo_path !== null,
        };
      } catch (error) {
        await removeObject(objectPath, input.requestId, "branch_logo_update_compensation");
        throw error;
      }
    },
    async getManagementOrganizationBranding(actorUserId, organizationId) {
      const rows = z.array(z.object({
        organization_id: z.uuid(),
        organization_logo_path: z.string().nullable(),
      }).strict()).max(1).parse(await rpc("get_management_organization_branding", {
        actor_user_id: actorUserId,
        target_organization_id: organizationId,
      }));
      return { organization_logo_url: await safeSignLogoPath(rows[0]?.organization_logo_path ?? null) };
    },
    async getMaintenanceOrganizationBranding(actorUserId, organizationId) {
      return { organization_logo_url: await safeSignLogoPath(await getMaintenanceLogoPath(actorUserId, organizationId)) };
    },
    async getMaintenanceAccessOrganizationBranding(organizationId) {
      return { organization_logo_url: await safeSignLogoPath(await getMaintenanceAccessLogoPath(organizationId)) };
    },
    async getSupervisorBranchBranding(actorUserId, branchId) {
      const rows = supervisorBrandingRowsSchema.parse(await rpc("get_supervisor_branch_branding", {
        actor_user_id: actorUserId,
        target_branch_id: branchId,
      }));
      const row = rows[0];
      if (!row) throw new BrandingAccessError();
      const branchLogoUrl = await safeSignLogoPath(row.branch_logo_path);
      const organizationLogoUrl = await safeSignLogoPath(row.organization_logo_path);
      return {
        branch_logo_url: branchLogoUrl,
        organization_logo_url: organizationLogoUrl,
        effective_logo_url: branchLogoUrl ?? organizationLogoUrl,
      };
    },
  };
}
