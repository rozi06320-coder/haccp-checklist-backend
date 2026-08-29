import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";

const profileSchema = z.object({
  id: z.uuid(),
  full_name: z.string().nullable(),
  must_change_password: z.boolean(),
  disabled_at: z.string().nullable(),
});

const internalAdminProfileSchema = z.object({
  id: z.uuid(),
  must_change_password: z.boolean(),
  disabled_at: z.string().nullable(),
});

const branchMembershipSchema = z.object({
  role: z.enum(["staff", "branch_manager"]),
  active: z.boolean(),
  branches: z.object({
    id: z.uuid(),
    name: z.string(),
    organization_id: z.uuid(),
    active: z.boolean(),
    organizations: z.object({
      active: z.boolean(),
    }),
  }),
});

const organizationMembershipSchema = z.object({
  role: z.literal("organization_manager"),
  organizations: z.object({
    id: z.uuid(),
    name: z.string(),
  }),
});

export type UserContext = {
  id: string;
  full_name: string | null;
  must_change_password: boolean;
  disabled: boolean;
  branches: Array<{
    id: string;
    name: string;
    organization_id: string;
    role: "staff" | "branch_manager";
  }>;
  managed_organizations: Array<{
    id: string;
    name: string;
    role: "organization_manager";
  }>;
};

export type UserContextRepository = {
  getUserContext(userId: string): Promise<UserContext | null>;
  isInternalAdmin?(userId: string): Promise<boolean>;
  hasOrganizationManagerAccess(
    userId: string,
    organizationId: string,
  ): Promise<boolean>;
  validateActiveBranches(
    organizationId: string,
    branchIds: string[],
  ): Promise<boolean>;
  listActiveBranches(organizationId: string): Promise<Array<{
    id: string;
    name: string;
    name_ar?: string | null;
    code: string;
  }>>;
};

class UserContextQueryError extends Error {
  constructor() {
    super("User context query failed.");
    this.name = "UserContextQueryError";
  }
}

export function createUserContextRepository(
  client: SupabaseClient,
): UserContextRepository {
  type ActiveBranch = Awaited<ReturnType<UserContextRepository["listActiveBranches"]>>[number];

  const userContextPromises = new Map<string, Promise<UserContext | null>>();
  const resolvedUserContexts = new Map<string, UserContext | null>();
  const internalAdminPromises = new Map<string, Promise<boolean>>();
  const organizationManagerAccessPromises = new Map<string, Promise<boolean>>();
  const activeBranchValidationPromises = new Map<string, Promise<boolean>>();
  const activeBranchesPromises = new Map<string, Promise<ActiveBranch[]>>();

  function cachePromise<T>(cache: Map<string, Promise<T>>, key: string, load: () => Promise<T>) {
    const cached = cache.get(key);
    if (cached) return cached;
    const promise = load().catch((error: unknown) => {
      cache.delete(key);
      throw error;
    });
    cache.set(key, promise);
    return promise;
  }

  function accessKey(userId: string, organizationId: string) {
    return JSON.stringify([userId, organizationId]);
  }

  function activeBranchValidationKey(organizationId: string, branchIds: string[]) {
    return JSON.stringify([organizationId, [...branchIds].sort()]);
  }

  return {
    async getUserContext(userId) {
      return cachePromise(userContextPromises, userId, async () => {
        const [profileResult, branchResult, organizationResult] = await Promise.all([
          client
            .from("profiles")
            .select("id, full_name, must_change_password, disabled_at")
            .eq("id", userId)
            .maybeSingle(),
          client
            .from("branch_memberships")
            .select("role, active, branches!inner(id, name, organization_id, active, organizations!inner(active))")
            .eq("user_id", userId)
            .eq("active", true)
            .eq("branches.active", true)
            .eq("branches.organizations.active", true),
          client
            .from("organization_memberships")
            .select("role, organizations!inner(id, name)")
            .eq("user_id", userId)
            .eq("role", "organization_manager")
            .eq("active", true),
        ]);

        if (profileResult.error || branchResult.error || organizationResult.error) {
          throw new UserContextQueryError();
        }

        const profile = profileSchema.safeParse(profileResult.data);
        const branches = z
          .array(branchMembershipSchema)
          .safeParse(branchResult.data);
        const organizations = z
          .array(organizationMembershipSchema)
          .safeParse(organizationResult.data);

        if (!profile.success) {
          resolvedUserContexts.set(userId, null);
          return null;
        }
        if (!branches.success || !organizations.success) {
          throw new UserContextQueryError();
        }

        const context = {
          id: profile.data.id,
          full_name: profile.data.full_name,
          must_change_password: profile.data.must_change_password,
          disabled: profile.data.disabled_at !== null,
          branches: branches.data.map((membership) => ({
            id: membership.branches.id,
            name: membership.branches.name,
            organization_id: membership.branches.organization_id,
            role: membership.role,
          })),
          managed_organizations: organizations.data.map((membership) => ({
            id: membership.organizations.id,
            name: membership.organizations.name,
            role: membership.role,
          })),
        };
        resolvedUserContexts.set(userId, context);
        return context;
      });
    },

    async isInternalAdmin(userId) {
      return cachePromise(internalAdminPromises, userId, async () => {
        const [profileResult, membershipResult] = await Promise.all([
          client
            .from("profiles")
            .select("id, must_change_password, disabled_at")
            .eq("id", userId)
            .maybeSingle(),
          client
            .from("internal_admin_memberships")
            .select("user_id")
            .eq("user_id", userId)
            .eq("active", true)
            .maybeSingle(),
        ]);
        if (profileResult.error || membershipResult.error) throw new UserContextQueryError();
        const profile = internalAdminProfileSchema.safeParse(profileResult.data);
        return profile.success
          && profile.data.disabled_at === null
          && !profile.data.must_change_password
          && membershipResult.data?.user_id === userId;
      });
    },

    async hasOrganizationManagerAccess(userId, organizationId) {
      return cachePromise(organizationManagerAccessPromises, accessKey(userId, organizationId), async () => {
        const resolvedContext = resolvedUserContexts.get(userId);
        if (resolvedContext) {
          return resolvedContext.managed_organizations.some((organization) => organization.id === organizationId);
        }

        const { data, error } = await client
          .from("organization_memberships")
          .select("organization_id")
          .eq("user_id", userId)
          .eq("organization_id", organizationId)
          .eq("role", "organization_manager")
          .eq("active", true)
          .maybeSingle();

        if (error) throw new UserContextQueryError();
        return data?.organization_id === organizationId;
      });
    },

    async validateActiveBranches(organizationId, branchIds) {
      return cachePromise(
        activeBranchValidationPromises,
        activeBranchValidationKey(organizationId, branchIds),
        async () => {
          const { data, error } = await client
            .from("branches")
            .select("id")
            .eq("organization_id", organizationId)
            .eq("active", true)
            .in("id", branchIds);
          if (error) throw new UserContextQueryError();
          return data.length === branchIds.length;
        },
      );
    },

    async listActiveBranches(organizationId) {
      return cachePromise(activeBranchesPromises, organizationId, async () => {
        const { data, error } = await client
          .from("branches")
          .select("id, name, name_ar, code")
          .eq("organization_id", organizationId)
          .eq("active", true)
          .order("name")
          .order("id")
          .limit(200);
        if (error) throw new UserContextQueryError();
        return z.array(z.object({
          id: z.uuid(),
          name: z.string(),
          name_ar: z.string().nullable().optional(),
          code: z.string(),
        })).parse(data);
      });
    },
  };
}
