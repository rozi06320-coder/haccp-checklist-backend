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
  branches: z.object({
    id: z.uuid(),
    name: z.string(),
    organization_id: z.uuid(),
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
  return {
    async getUserContext(userId) {
      const [profileResult, branchResult, organizationResult] = await Promise.all([
        client
          .from("profiles")
          .select("id, full_name, must_change_password, disabled_at")
          .eq("id", userId)
          .maybeSingle(),
        client
          .from("branch_memberships")
          .select("role, branches!inner(id, name, organization_id)")
          .eq("user_id", userId),
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

      if (!profile.success) return null;
      if (!branches.success || !organizations.success) {
        throw new UserContextQueryError();
      }

      return {
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
    },

    async isInternalAdmin(userId) {
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
    },

    async hasOrganizationManagerAccess(userId, organizationId) {
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
    },

    async validateActiveBranches(organizationId, branchIds) {
      const { data, error } = await client
        .from("branches")
        .select("id")
        .eq("organization_id", organizationId)
        .eq("active", true)
        .in("id", branchIds);
      if (error) throw new UserContextQueryError();
      return data.length === branchIds.length;
    },

    async listActiveBranches(organizationId) {
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
    },
  };
}
