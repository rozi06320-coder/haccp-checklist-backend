import { createClient } from "@supabase/supabase-js";
import { z } from "zod";
import {
  createHmac,
  randomBytes,
  scrypt as scryptCallback,
  timingSafeEqual,
} from "node:crypto";
import { employeeCountryCodes } from "../lib/employee-countries";

const operationalRoleSchema = z.enum(["kitchen", "dispatcher", "production", "front_of_house", "cleaner", "cashier"]);
const countryCodeSchema = z.enum(employeeCountryCodes).nullable();
const internalAdminBranchTeamStaffSchema = z.object({
  staff_id: z.string().uuid(),
  display_name: z.string(),
  company_name: z.string().nullable(),
  staff_code: z.string().nullable(),
  country_code: countryCodeSchema,
  employment_status: z.enum(["active", "inactive"]),
  assignment_id: z.string().uuid(),
  operational_team_id: z.string().uuid().nullable().optional(),
  operational_roles: z.array(operationalRoleSchema).min(1).max(2),
}).strict();

export type ProvisionedUser = { id: string };
export type CreateAuthUserInput = {
  email: string;
  password: string;
};
export type SupervisorTeamAssignmentInput = {
  operationalTeamId: string;
  assignmentRole: "primary" | "backup";
};
export type FinalizeProvisionedUserInput = {
  actorUserId: string;
  organizationId: string;
  newUserId: string;
  fullName: string;
  fullNameAr?: string | null;
  personCode?: string | null;
  phoneNumber?: string | null;
  countryCode?: string | null;
  iqamaNumber?: string | null;
  iqamaExpiryDate?: string | null;
  role: "staff" | "branch_manager";
  branchIds: string[];
  supervisorTeamAssignments?: SupervisorTeamAssignmentInput[];
};
export type FinalizeProvisionedMaintenanceUserInput = {
  actorUserId: string;
  organizationId: string;
  newUserId: string;
  fullName: string;
  fullNameAr?: string | null;
};
export type FinalizeProvisionedOrganizationManagerInput = {
  actorUserId: string;
  organizationId: string;
  newUserId: string;
  fullName: string;
  fullNameAr?: string | null;
};

export type ProvisioningAdmin = {
  createUser(input: CreateAuthUserInput): Promise<ProvisionedUser>;
  deleteUser(userId: string): Promise<void>;
  finalize(input: FinalizeProvisionedUserInput): Promise<void>;
  finalizeMaintenance?(input: FinalizeProvisionedMaintenanceUserInput): Promise<void>;
  finalizeOrganizationManager?(input: FinalizeProvisionedOrganizationManagerInput): Promise<void>;
};

export type ManagedUser = {
  id: string;
  full_name: string | null;
  full_name_ar?: string | null;
  person_code?: string | null;
  phone_number?: string | null;
  country_code?: string | null;
  iqama_number?: string | null;
  iqama_expiry_date?: string | null;
  email: string;
  role: "staff" | "branch_manager";
  branches: Array<{ id: string; name: string; name_ar?: string | null; code: string }>;
  disabled: boolean;
  must_change_password: boolean;
  created_at: string;
};

export type ManagedUserList = {
  users: ManagedUser[];
  total: number;
};
export type InternalAdminBranch = {
  id: string;
  organization_id?: string;
  name: string;
  name_ar?: string | null;
  code: string;
  timezone: string;
  active: boolean;
  logo_path?: string | null;
  logo_url?: string | null;
};
export type InternalAdminSupervisor = {
  id: string;
  full_name: string | null;
  full_name_ar?: string | null;
  person_code?: string | null;
  phone_number?: string | null;
  country_code?: string | null;
  iqama_number?: string | null;
  iqama_expiry_date?: string | null;
  email: string;
  branches: Array<{ id: string; name: string; name_ar?: string | null; code: string; active?: boolean }>;
  team_assignments?: Array<{
    team_id: string;
    team_name: string;
    branch_id: string;
    branch_name: string;
    branch_name_ar?: string | null;
    assignment_role: "primary" | "backup";
    active: boolean;
  }>;
  active: boolean;
  disabled: boolean;
  must_change_password: boolean;
  created_at: string;
};
export type UpdateInternalAdminSupervisorProfileInput = {
  actorUserId: string;
  organizationId: string;
  userId: string;
  fullName: string;
  fullNameAr?: string | null;
  personCode?: string | null;
  phoneNumber?: string | null;
  countryCode?: string | null;
  iqamaNumber?: string | null;
  iqamaExpiryDate?: string | null;
};
export type InternalAdminSupervisorProfile = {
  id: string;
  full_name: string;
  full_name_ar?: string | null;
  person_code?: string | null;
  phone_number?: string | null;
  country_code?: string | null;
  iqama_number?: string | null;
  iqama_expiry_date?: string | null;
  email: string;
  updated_at: string;
};
export type InternalAdminBranchTeam = {
  team_id: string;
  organization_id: string;
  team_name: string;
  company_name: string | null;
  branch_id: string;
  branch_name: string;
  branch_name_ar?: string | null;
  branch_code: string;
  supervisor_user_id: string | null;
  supervisor_name: string | null;
  supervisor_name_ar?: string | null;
  supervisor_email: string | null;
  supervisor_role: "branch_manager" | null;
  backup_supervisors: Array<{
    supervisor_user_id: string;
    supervisor_name: string | null;
    supervisor_name_ar?: string | null;
    supervisor_email: string;
    assignment_role: "backup";
  }>;
  active: boolean;
  operational_staff_count: number;
  staff: InternalAdminBranchTeamStaff[];
};
export type InternalAdminBranchTeamStaff = {
  staff_id: string;
  display_name: string;
  company_name: string | null;
  staff_code: string | null;
  country_code: string | null;
  employment_status: "active" | "inactive";
  assignment_id: string;
  operational_roles: Array<"kitchen" | "dispatcher" | "production" | "front_of_house" | "cleaner" | "cashier">;
};
export type ManagedBranch = {
  id: string;
  organization_id?: string;
  name: string;
  name_ar?: string | null;
  code: string;
  timezone: string;
  active: boolean;
};
export type InternalAdminOrganization = {
  id: string;
  name: string;
  name_ar?: string | null;
  slug?: string;
  active: boolean;
  logo_path?: string | null;
  logo_url?: string | null;
};
export type ManagedMaintenanceUser = {
  id: string;
  full_name: string | null;
  email: string;
  active: boolean;
  must_change_password: boolean;
  created_at: string;
  updated_at: string;
  updated_by_name: string | null;
};
export type InternalAdminOrganizationManager = {
  id: string;
  full_name: string | null;
  full_name_ar?: string | null;
  email: string;
  organization_id: string;
  organization_name: string;
  organization_name_ar?: string | null;
  active: boolean;
  must_change_password: boolean;
  disabled: boolean;
  created_at: string;
  updated_at: string;
};

export type ManagementAdmin = {
  listOrganizationsForInternalAdmin?(actorUserId: string): Promise<Array<{
    id: string;
    name: string;
    name_ar?: string | null;
    active: boolean;
    logo_path?: string | null;
    logo_url?: string | null;
  }>>;
  createOrganizationForInternalAdmin?(input: {
    actorUserId: string;
    name: string;
    nameAr?: string | null;
  }): Promise<InternalAdminOrganization>;
  updateOrganizationForInternalAdmin?(input: {
    actorUserId: string;
    organizationId: string;
    name: string;
    nameAr?: string | null;
  }): Promise<InternalAdminOrganization>;
  deactivateOrganizationForInternalAdmin?(input: {
    actorUserId: string;
    organizationId: string;
  }): Promise<InternalAdminOrganization>;
  reactivateOrganizationForInternalAdmin?(input: {
    actorUserId: string;
    organizationId: string;
  }): Promise<InternalAdminOrganization>;
  listBranchesForInternalAdmin?(actorUserId: string, organizationId: string): Promise<InternalAdminBranch[]>;
  updateBranchForInternalAdmin?(input: {
    actorUserId: string;
    organizationId: string;
    branchId: string;
    name: string;
    nameAr?: string | null;
    timezone: string;
  }): Promise<InternalAdminBranch>;
  deactivateBranchForInternalAdmin?(input: {
    actorUserId: string;
    organizationId: string;
    branchId: string;
  }): Promise<InternalAdminBranch>;
  reactivateBranchForInternalAdmin?(input: {
    actorUserId: string;
    organizationId: string;
    branchId: string;
  }): Promise<InternalAdminBranch>;
  listOrganizationManagersForInternalAdmin?(actorUserId: string, organizationId: string): Promise<InternalAdminOrganizationManager[]>;
  deactivateOrganizationManagerForInternalAdmin?(input: {
    actorUserId: string;
    organizationId: string;
    userId: string;
  }): Promise<void>;
  reactivateOrganizationManagerForInternalAdmin?(input: {
    actorUserId: string;
    organizationId: string;
    userId: string;
  }): Promise<void>;
  grantExistingOrganizationManagerForInternalAdmin?(input: {
    actorUserId: string;
    organizationId: string;
    email: string;
  }): Promise<void>;
  listSupervisorsForInternalAdmin?(actorUserId: string, organizationId: string): Promise<InternalAdminSupervisor[]>;
  updateSupervisorProfileForInternalAdmin?(input: UpdateInternalAdminSupervisorProfileInput): Promise<InternalAdminSupervisorProfile>;
  deactivateSupervisorForInternalAdmin?(input: {
    actorUserId: string;
    organizationId: string;
    userId: string;
  }): Promise<void>;
  reactivateSupervisorForInternalAdmin?(input: {
    actorUserId: string;
    organizationId: string;
    userId: string;
  }): Promise<void>;
  grantExistingSupervisorForInternalAdmin?(input: {
    actorUserId: string;
    organizationId: string;
    email: string;
    branchIds: string[];
    supervisorTeamAssignments: SupervisorTeamAssignmentInput[];
  }): Promise<void>;
  listBranchTeamsForInternalAdmin?(actorUserId: string, organizationId: string): Promise<InternalAdminBranchTeam[]>;
  createBranchTeamForInternalAdmin?(input: {
    actorUserId: string;
    organizationId: string;
    teamName: string;
    companyName: string;
    branchId: string;
    primarySupervisorUserId: string;
    backupSupervisorUserId?: string | null;
    initialStaff?: Array<{
      displayName: string;
      companyName: string;
      staffCode?: string | null;
      countryCode?: string | null;
      roles: Array<"kitchen" | "dispatcher" | "production" | "front_of_house" | "cleaner" | "cashier">;
    }>;
  }): Promise<InternalAdminBranchTeam>;
  createBranchTeamStaffForInternalAdmin?(input: {
    actorUserId: string;
    organizationId: string;
    teamId: string;
    displayName: string;
    companyName: string;
    staffCode?: string | null;
    countryCode?: string | null;
    roles: Array<"kitchen" | "dispatcher" | "production" | "front_of_house" | "cleaner" | "cashier">;
  }): Promise<{ staff_id: string; assignment_id: string; duplicate_name_warning: boolean }>;
  listUsers(input: {
    actorUserId: string;
    organizationId: string;
    page: number;
    pageSize: number;
    search?: string;
    role?: "staff" | "branch_manager";
    branchId?: string;
    lifecycle?: "active" | "password_change_required" | "disabled";
  }): Promise<ManagedUserList>;
  createBranch?(input: {
    actorUserId: string;
    organizationId: string;
    name: string;
    nameAr?: string | null;
    timezone: string;
    active: boolean;
  }): Promise<ManagedBranch>;
  createBranchForInternalAdmin?(input: {
    actorUserId: string;
    organizationId: string;
    name: string;
    nameAr?: string | null;
    timezone: string;
    active: boolean;
  }): Promise<ManagedBranch>;
  listMaintenanceUsers?(actorUserId: string, organizationId: string): Promise<ManagedMaintenanceUser[]>;
  deactivateMaintenanceUser?(input: {
    actorUserId: string;
    organizationId: string;
    userId: string;
  }): Promise<void>;
  reactivateMaintenanceUser?(input: {
    actorUserId: string;
    organizationId: string;
    userId: string;
  }): Promise<void>;
  grantExistingMaintenanceUser?(input: {
    actorUserId: string;
    organizationId: string;
    email: string;
  }): Promise<void>;
};

export type SupervisedBranch = {
  id: string; organization_id: string; name: string; code: string; staff_count: number;
};
export type BranchStaffMember = {
  id: string; full_name: string | null; role: "staff" | "branch_manager";
  disabled: boolean; must_change_password: boolean;
};
export type DailyAuditAccessMetadata = {
  configured: boolean; updated_at: string | null; updated_by_name: string | null;
};
export type PinCredential = {
  pin_hash: string; salt: string; kdf_version: number; cost: number;
  block_size: number; parallelization: number; credential_version?: string;
};
export type ManagerPinMetadata = {
  manager_user_id: string;
  full_name: string | null;
  email: string;
  account_status: "active" | "password_change_required";
  configured: boolean;
  updated_at: string | null;
  updated_by_name: string | null;
};
export type ManagerPinCredential = PinCredential & {
  organization_id: string;
  manager_user_id: string;
  display_name: string;
  credential_version: string;
};
export type DailyAuditUserAccess = {
  id: string;
  organization_id: string;
  display_name: string;
  active: boolean;
  created_at: string;
  updated_at: string;
  updated_by_name: string | null;
};
export type MaintenanceAccessUser = {
  id: string;
  organization_id: string;
  display_name: string;
  active: boolean;
  created_at: string;
  updated_at: string;
  updated_by_name: string | null;
};
export type MaintenanceAccessCredential = PinCredential & {
  organization_id: string;
  organization_name: string;
  access_user_id: string;
  display_name: string;
  credential_version: string;
};
export type MaintenanceAccessSession = {
  organization_id: string;
  organization_name: string;
  access_user_id: string;
  display_name: string;
};
export type DailyAuditAccessUserCredential = PinCredential & {
  organization_id: string;
  access_user_id: string;
  display_name: string;
  credential_version: string;
};
export type DailyAuditPinAdmin = {
  listManagers(actorUserId: string, organizationId: string): Promise<ManagerPinMetadata[]>;
  storeManagerPin(input: {
    actorUserId: string;
    organizationId: string;
    managerUserId: string;
    credential: PinCredential;
    fingerprint: string;
  }): Promise<{ manager_user_id: string; configured: true; updated_at: string; updated_by_name: string | null }>;
  listCredentials(actorUserId: string, branchId: string): Promise<ManagerPinCredential[]>;
  recordGrant(input: { actorUserId: string; branchId: string; managerUserId: string; credentialVersion: string }): Promise<void>;
  validateGrant(input: { actorUserId: string; branchId: string; managerUserId: string; credentialVersion: string }): Promise<boolean>;
  listAccessUsers?(actorUserId: string, organizationId: string): Promise<DailyAuditUserAccess[]>;
  createAccessUser?(input: { actorUserId: string; organizationId: string; displayName: string; credential: PinCredential }): Promise<void>;
  revokeAccessUser?(input: { actorUserId: string; organizationId: string; accessUserId: string }): Promise<void>;
  listAccessUserCredentials?(actorUserId: string, branchId: string): Promise<DailyAuditAccessUserCredential[]>;
  listManagersForInternalAdmin?(actorUserId: string, organizationId: string): Promise<ManagerPinMetadata[]>;
  storeManagerPinForInternalAdmin?(input: {
    actorUserId: string;
    organizationId: string;
    managerUserId: string;
    credential: PinCredential;
    fingerprint: string;
  }): Promise<{ manager_user_id: string; configured: true; updated_at: string; updated_by_name: string | null }>;
  listAccessUsersForInternalAdmin?(actorUserId: string, organizationId: string): Promise<DailyAuditUserAccess[]>;
  createAccessUserForInternalAdmin?(input: { actorUserId: string; organizationId: string; displayName: string; credential: PinCredential }): Promise<void>;
  revokeAccessUserForInternalAdmin?(input: { actorUserId: string; organizationId: string; accessUserId: string }): Promise<void>;
};
export type MaintenanceAccessAdmin = {
  listAccessUsers(actorUserId: string, organizationId: string): Promise<MaintenanceAccessUser[]>;
  createAccessUser(input: { actorUserId: string; organizationId: string; displayName: string; credential: PinCredential }): Promise<void>;
  deactivateAccessUser(input: { actorUserId: string; organizationId: string; accessUserId: string }): Promise<void>;
  getAccessCredential(input: { organizationIdentifier: string; displayName: string }): Promise<MaintenanceAccessCredential | null>;
  validateAccessGrant(input: { organizationId: string; accessUserId: string; credentialVersion: string }): Promise<MaintenanceAccessSession | null>;
};
export type BranchManagementAdmin = {
  listBranches(actorUserId: string): Promise<SupervisedBranch[]>;
  listStaff(actorUserId: string, branchId: string): Promise<BranchStaffMember[]>;
  getPinMetadata(actorUserId: string, branchId: string): Promise<DailyAuditAccessMetadata>;
  storePin(input: { actorUserId: string; branchId: string; credential: PinCredential }): Promise<DailyAuditAccessMetadata>;
  getPinCredential(actorUserId: string, branchId: string): Promise<PinCredential | null>;
};
export type PinCrypto = {
  hash(pin: string): Promise<PinCredential>;
  verify(pin: string, credential: PinCredential): Promise<boolean>;
  fingerprint?(pin: string): string;
  issueManagerGrant?(userId: string, branchId: string, organizationId: string, managerUserId: string, credentialVersion: string, now?: number): string;
  verifyManagerGrant?(grant: string, userId: string, branchId: string, organizationId: string, managerUserId: string, credentialVersion: string, now?: number): boolean;
  issueMaintenanceGrant?(organizationId: string, accessUserId: string, credentialVersion: string, now?: number): string;
  verifyMaintenanceGrant?(grant: string, now?: number): { organizationId: string; accessUserId: string; credentialVersion: string } | null;
  issueGrant(userId: string, branchId: string, credentialVersion: string, now?: number): string;
  verifyGrant(grant: string, userId: string, branchId: string, credentialVersion: string, now?: number): boolean;
  issueManualDailyAuditGrant?(input: { actorUserId: string; organizationId: string; originalBranchId: string; auditorId: string; auditorDisplayName: string; credentialVersion: string; now?: number }): string;
  verifyManualDailyAuditGrant?(grant: string, actorUserId: string, now?: number): { organizationId: string; originalBranchId: string; auditorId: string; auditorDisplayName: string; credentialVersion: string; issuedAt: number; expiresAt: number } | null;
  issueOrganizationManagerDailyAuditGrant?(input: { actorUserId: string; organizationId: string; originalBranchId: string; auditorId: string; auditorDisplayName: string; credentialVersion: string; now?: number }): string;
  verifyOrganizationManagerDailyAuditGrant?(grant: string, actorUserId: string, now?: number): { organizationId: string; originalBranchId: string; auditorId: string; auditorDisplayName: string; credentialVersion: string; issuedAt: number; expiresAt: number } | null;
};

export type PasswordChangeService = {
  verifyCurrent(email: string, password: string): Promise<boolean>;
  updatePassword(userId: string, password: string): Promise<void>;
  finalize(userId: string): Promise<void>;
};

export class AdminConflictError extends Error {}
export class AdminDuplicatePersonCodeError extends Error {}
export class AdminDuplicateStaffCodeError extends Error {}
export class AdminAccessError extends Error {}
export class AdminInputError extends Error {}
export class AdminNotFoundError extends Error {}
export class AdminOperationError extends Error {}
export class ProvisioningStageError extends AdminOperationError {
  constructor(
    readonly stage: "auth_create" | "database_finalize" | "auth_compensation",
    readonly category: "operation_failed" | "invalid_response" | "rpc_failed",
    readonly status: number | null = null,
    readonly databaseCode: string | null = null,
  ) {
    super("Provisioning operation failed.");
    this.name = "ProvisioningStageError";
  }
}

export function createManagementAdmin(
  url: string,
  secretKey: string,
): ManagementAdmin {
  const admin = createClient(url, secretKey, { auth: nonPersistentAuth });
  return {
    async listOrganizationsForInternalAdmin(actorUserId) {
      const { data, error } = await admin.rpc("list_internal_admin_organizations", {
        actor_user_id: actorUserId,
      });
      if (error) {
        if (error.code === "42501") throw new AdminAccessError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
          id: z.string().uuid(),
          name: z.string(),
          name_ar: z.string().nullable().optional(),
          active: z.boolean(),
          logo_path: z.string().nullable().optional(),
        }).strict()).max(200).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
      return rows.data;
    },
    async createOrganizationForInternalAdmin(input) {
      const { data, error } = await admin.rpc("create_internal_admin_organization", {
        actor_user_id: input.actorUserId,
        organization_name: input.name,
        organization_name_ar: input.nameAr ?? null,
      });
      if (error) {
        if (error.code === "23505") throw new AdminConflictError();
        if (error.code === "42501") throw new AdminAccessError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        id: z.string().uuid(),
        name: z.string(),
        name_ar: z.string().nullable().optional(),
        slug: z.string(),
        active: z.literal(true),
      }).strict()).length(1).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
      return rows.data[0];
    },
    async updateOrganizationForInternalAdmin(input) {
      const { data, error } = await admin.rpc("update_internal_admin_organization", {
        p_actor_user_id: input.actorUserId,
        p_organization_id: input.organizationId,
        p_organization_name: input.name,
        p_organization_name_ar: input.nameAr ?? null,
      });
      if (error) {
        if (error.code === "23505") throw new AdminConflictError();
        if (error.code === "42501") throw new AdminAccessError();
        if (error.code === "P0002") throw new AdminNotFoundError();
        if (error.code === "22023") throw new AdminInputError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        id: z.string().uuid(),
        name: z.string(),
        name_ar: z.string().nullable().optional(),
        slug: z.string(),
        active: z.boolean(),
      }).strict()).length(1).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
      return rows.data[0];
    },
    async deactivateOrganizationForInternalAdmin(input) {
      const { data, error } = await admin.rpc("deactivate_internal_admin_organization", {
        p_actor_user_id: input.actorUserId,
        p_organization_id: input.organizationId,
      });
      if (error) {
        if (error.code === "42501") throw new AdminAccessError();
        if (error.code === "P0002") throw new AdminNotFoundError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        id: z.string().uuid(),
        name: z.string(),
        name_ar: z.string().nullable().optional(),
        slug: z.string(),
        active: z.literal(false),
      }).strict()).length(1).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
      return rows.data[0];
    },
    async reactivateOrganizationForInternalAdmin(input) {
      const { data, error } = await admin.rpc("reactivate_internal_admin_organization", {
        p_actor_user_id: input.actorUserId,
        p_organization_id: input.organizationId,
      });
      if (error) {
        if (error.code === "42501") throw new AdminAccessError();
        if (error.code === "P0002") throw new AdminNotFoundError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        id: z.string().uuid(),
        name: z.string(),
        name_ar: z.string().nullable().optional(),
        slug: z.string(),
        active: z.literal(true),
      }).strict()).length(1).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
      return rows.data[0];
    },
    async listBranchesForInternalAdmin(actorUserId, organizationId) {
      const { data, error } = await admin.rpc("list_internal_admin_branches", {
        actor_user_id: actorUserId,
        target_organization_id: organizationId,
      });
      if (error || !Array.isArray(data)) {
        if (error?.code === "42501") throw new AdminAccessError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        id: z.string().uuid(),
        name: z.string(),
        name_ar: z.string().nullable().optional(),
        code: z.string(),
        timezone: z.string(),
        active: z.boolean(),
        logo_path: z.string().nullable(),
      }).strict()).max(500).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
      return rows.data;
    },
    async listOrganizationManagersForInternalAdmin(actorUserId, organizationId) {
      const { data, error } = await admin.rpc("list_internal_admin_organization_managers", {
        actor_user_id: actorUserId,
        target_organization_id: organizationId,
      });
      if (error || !Array.isArray(data)) {
        if (error?.code === "42501") throw new AdminAccessError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        id: z.string().uuid(),
        full_name: z.string().nullable(),
        full_name_ar: z.string().nullable().optional(),
        email: z.string().email(),
        organization_id: z.string().uuid(),
        organization_name: z.string(),
        organization_name_ar: z.string().nullable().optional(),
        active: z.boolean(),
        must_change_password: z.boolean(),
        disabled: z.boolean(),
        created_at: z.string(),
        updated_at: z.string(),
      }).strict()).max(500).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
      return rows.data;
    },
    async deactivateOrganizationManagerForInternalAdmin(input) {
      const { data, error } = await admin.rpc("deactivate_organization_manager", {
        actor_user_id: input.actorUserId,
        target_organization_id: input.organizationId,
        target_user_id: input.userId,
      });
      if (error) {
        if (error.code === "42501") throw new AdminAccessError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        id: z.string().uuid(),
        full_name: z.string().nullable(),
        email: z.string().email(),
        active: z.literal(false),
        updated_at: z.string(),
      }).strict()).length(1).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
    },
    async reactivateOrganizationManagerForInternalAdmin(input) {
      const { data, error } = await admin.rpc("reactivate_organization_manager", {
        actor_user_id: input.actorUserId,
        target_organization_id: input.organizationId,
        target_user_id: input.userId,
      });
      if (error) {
        if (error.code === "42501") throw new AdminAccessError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        id: z.string().uuid(),
        full_name: z.string().nullable(),
        email: z.string().email(),
        active: z.literal(true),
        updated_at: z.string(),
      }).strict()).length(1).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
    },
    async grantExistingOrganizationManagerForInternalAdmin(input) {
      const { data, error } = await admin.rpc("grant_existing_organization_manager", {
        actor_user_id: input.actorUserId,
        target_organization_id: input.organizationId,
        target_email: input.email,
      });
      if (error) {
        if (error.code === "42501") throw new AdminAccessError();
        if (error.code === "P0002") throw new AdminNotFoundError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        id: z.string().uuid(),
        full_name: z.string().nullable(),
        email: z.string().email(),
        active: z.literal(true),
        updated_at: z.string(),
      }).strict()).length(1).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
    },
    async listSupervisorsForInternalAdmin(actorUserId, organizationId) {
      const { data, error } = await admin.rpc("list_internal_admin_supervisors", {
        actor_user_id: actorUserId,
        target_organization_id: organizationId,
      });
      if (error || !Array.isArray(data)) {
        if (error?.code === "42501") throw new AdminAccessError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        id: z.string().uuid(),
        full_name: z.string().nullable(),
        full_name_ar: z.string().nullable().optional(),
        person_code: z.string().nullable().optional(),
        phone_number: z.string().nullable().optional(),
        country_code: countryCodeSchema.optional(),
        iqama_number: z.string().nullable().optional(),
        iqama_expiry_date: z.string().nullable().optional(),
        email: z.string().email(),
        branches: z.array(z.object({
          id: z.string().uuid(),
          name: z.string(),
          name_ar: z.string().nullable().optional(),
          code: z.string(),
          active: z.boolean().optional(),
        }).strict()).max(50),
        team_assignments: z.array(z.object({
          team_id: z.string().uuid(),
          team_name: z.string(),
          branch_id: z.string().uuid(),
          branch_name: z.string(),
          branch_name_ar: z.string().nullable().optional(),
          assignment_role: z.enum(["primary", "backup"]),
          active: z.boolean(),
        }).strict()).max(100).optional(),
        active: z.boolean(),
        disabled: z.boolean(),
        must_change_password: z.boolean(),
        created_at: z.string(),
      }).strict()).max(500).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
      return rows.data;
    },
    async updateSupervisorProfileForInternalAdmin(input) {
      const { data, error } = await admin.rpc("update_internal_admin_supervisor_profile", {
        p_actor_user_id: input.actorUserId,
        p_organization_id: input.organizationId,
        p_supervisor_user_id: input.userId,
        p_full_name: input.fullName,
        p_full_name_ar: input.fullNameAr ?? null,
        p_person_code: input.personCode ?? null,
        p_phone_number: input.phoneNumber ?? null,
        p_country_code: input.countryCode ?? null,
        p_iqama_number: input.iqamaNumber ?? null,
        p_iqama_expiry_date: input.iqamaExpiryDate ?? null,
      });
      if (error || !Array.isArray(data)) {
        if (error?.code === "42501") throw new AdminAccessError();
        if (error?.code === "23505" && /profiles_person_code/i.test(error.message)) throw new AdminDuplicatePersonCodeError();
        if (error?.code === "23505" || error?.code === "23514" || error?.code === "22023") throw new AdminConflictError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        id: z.string().uuid(),
        full_name: z.string(),
        full_name_ar: z.string().nullable().optional(),
        person_code: z.string().nullable().optional(),
        phone_number: z.string().nullable().optional(),
        country_code: countryCodeSchema.optional(),
        iqama_number: z.string().nullable().optional(),
        iqama_expiry_date: z.string().nullable().optional(),
        email: z.string().email(),
        updated_at: z.string(),
      }).strict()).length(1).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
      return rows.data[0];
    },
    async deactivateSupervisorForInternalAdmin(input) {
      const { data, error } = await admin.rpc("deactivate_internal_admin_supervisor", {
        actor_user_id: input.actorUserId,
        target_organization_id: input.organizationId,
        target_user_id: input.userId,
      });
      if (error) {
        if (error.code === "42501") throw new AdminAccessError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        id: z.string().uuid(),
        full_name: z.string().nullable(),
        email: z.string().email(),
        active: z.literal(false),
        updated_at: z.string(),
      }).strict()).length(1).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
    },
    async reactivateSupervisorForInternalAdmin(input) {
      const { data, error } = await admin.rpc("reactivate_internal_admin_supervisor", {
        actor_user_id: input.actorUserId,
        target_organization_id: input.organizationId,
        target_user_id: input.userId,
      });
      if (error) {
        if (error.code === "42501") throw new AdminAccessError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        id: z.string().uuid(),
        full_name: z.string().nullable(),
        email: z.string().email(),
        active: z.literal(true),
        updated_at: z.string(),
      }).strict()).length(1).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
    },
    async grantExistingSupervisorForInternalAdmin(input) {
      const { data, error } = await admin.rpc("grant_existing_branch_supervisor", {
        actor_user_id: input.actorUserId,
        target_organization_id: input.organizationId,
        target_email: input.email,
        target_branch_ids: input.branchIds,
        target_team_assignments: input.supervisorTeamAssignments.map((assignment) => ({
          operational_team_id: assignment.operationalTeamId,
          assignment_role: assignment.assignmentRole,
        })),
      });
      if (error) {
        if (error.code === "42501") throw new AdminAccessError();
        if (error.code === "P0002") throw new AdminNotFoundError();
        if (error.code === "23505" || error.code === "23514" || error.code === "22023") throw new AdminConflictError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        id: z.string().uuid(),
        full_name: z.string().nullable(),
        email: z.string().email(),
        active: z.literal(true),
        updated_at: z.string(),
      }).strict()).length(1).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
    },
    async listBranchTeamsForInternalAdmin(actorUserId, organizationId) {
      const { data, error } = await admin.rpc("list_internal_admin_branch_teams", {
        actor_user_id: actorUserId,
        target_organization_id: organizationId,
      });
      if (error || !Array.isArray(data)) {
        if (error?.code === "42501") throw new AdminAccessError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        team_id: z.string().uuid(),
        organization_id: z.string().uuid(),
        team_name: z.string(),
        company_name: z.string().nullable(),
        branch_id: z.string().uuid(),
        branch_name: z.string(),
        branch_name_ar: z.string().nullable().optional(),
        branch_code: z.string(),
        supervisor_user_id: z.string().uuid().nullable(),
        supervisor_name: z.string().nullable(),
        supervisor_name_ar: z.string().nullable().optional(),
        supervisor_email: z.string().email().nullable(),
        supervisor_role: z.literal("branch_manager").nullable(),
        backup_supervisors: z.array(z.object({
          supervisor_user_id: z.string().uuid(),
          supervisor_name: z.string().nullable(),
          supervisor_name_ar: z.string().nullable().optional(),
          supervisor_email: z.string().email(),
          assignment_role: z.literal("backup"),
        }).strict()).max(50),
        active: z.boolean(),
        operational_staff_count: z.number().int().nonnegative(),
        staff: z.array(internalAdminBranchTeamStaffSchema).max(500),
      }).strict()).max(500).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
      return rows.data;
    },
    async createBranchTeamForInternalAdmin(input) {
      const { data, error } = await admin.rpc("create_internal_admin_operational_team", {
        actor_user_id: input.actorUserId,
        target_organization_id: input.organizationId,
        target_branch_id: input.branchId,
        new_team_name: input.teamName,
        new_company_name: input.companyName,
        target_primary_supervisor_user_id: input.primarySupervisorUserId,
        target_backup_supervisor_user_id: input.backupSupervisorUserId ?? null,
        initial_staff: (input.initialStaff ?? []).map((staff) => ({
          display_name: staff.displayName,
          company_name: staff.companyName,
          staff_code: staff.staffCode ?? null,
          country_code: staff.countryCode ?? null,
          operational_roles: staff.roles,
        })),
      });
      if (error) {
        if (error.code === "42501") throw new AdminAccessError();
        if (error.code === "23505" && /employee code/i.test(error.message)) throw new AdminDuplicateStaffCodeError();
        if (error.code === "23505" || error.code === "23514") throw new AdminConflictError();
        if (error.code === "22023") throw new AdminConflictError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        team_id: z.string().uuid(),
        organization_id: z.string().uuid(),
        team_name: z.string(),
        company_name: z.string().nullable(),
        branch_id: z.string().uuid(),
        branch_name: z.string(),
        branch_name_ar: z.string().nullable().optional(),
        branch_code: z.string(),
        supervisor_user_id: z.string().uuid().nullable(),
        supervisor_name: z.string().nullable(),
        supervisor_name_ar: z.string().nullable().optional(),
        supervisor_email: z.string().email().nullable(),
        supervisor_role: z.literal("branch_manager").nullable(),
        backup_supervisors: z.array(z.object({
          supervisor_user_id: z.string().uuid(),
          supervisor_name: z.string().nullable(),
          supervisor_name_ar: z.string().nullable().optional(),
          supervisor_email: z.string().email(),
          assignment_role: z.literal("backup"),
        }).strict()).max(50),
        active: z.boolean(),
        operational_staff_count: z.number().int().nonnegative(),
        staff: z.array(internalAdminBranchTeamStaffSchema).max(500).default([]),
      }).strict()).length(1).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
      return rows.data[0];
    },
    async createBranchTeamStaffForInternalAdmin(input) {
      const { data, error } = await admin.rpc("create_internal_admin_branch_team_staff", {
        actor_user_id: input.actorUserId,
        target_organization_id: input.organizationId,
        target_team_id: input.teamId,
        new_display_name: input.displayName,
        new_company_name: input.companyName,
        new_staff_code: input.staffCode ?? null,
        new_country_code: input.countryCode ?? null,
        new_operational_roles: input.roles,
      });
      if (error) {
        if (error.code === "42501") throw new AdminAccessError();
        if (error.code === "23505" && /employee code/i.test(error.message)) throw new AdminDuplicateStaffCodeError();
        if (error.code === "23505" || error.code === "23514" || error.code === "22023") throw new AdminConflictError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        staff_id: z.string().uuid(),
        assignment_id: z.string().uuid(),
        duplicate_name_warning: z.boolean(),
      }).strict()).length(1).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
      return rows.data[0];
    },
    async listUsers(input) {
      const { data, error } = await admin.rpc("list_managed_organization_users", {
        actor_user_id: input.actorUserId,
        target_organization_id: input.organizationId,
        requested_page: input.page,
        requested_page_size: input.pageSize,
        search_term: input.search ?? null,
        role_filter: input.role ?? null,
        branch_filter: input.branchId ?? null,
        lifecycle_filter: input.lifecycle ?? null,
      });
      if (error || !Array.isArray(data)) throw new AdminOperationError();
      const schema = z.array(z.object({
        id: z.string().uuid(),
        full_name: z.string().nullable(),
        full_name_ar: z.string().nullable().optional(),
        person_code: z.string().nullable().optional(),
        phone_number: z.string().nullable().optional(),
        country_code: countryCodeSchema.optional(),
        iqama_number: z.string().nullable().optional(),
        iqama_expiry_date: z.string().nullable().optional(),
        email: z.string().email(),
        role: z.enum(["staff", "branch_manager"]),
        branches: z.array(z.object({
          id: z.string().uuid(),
          name: z.string(),
          name_ar: z.string().nullable().optional(),
          code: z.string(),
        })).max(50),
        disabled: z.boolean(),
        must_change_password: z.boolean(),
        created_at: z.string(),
        total_count: z.number().int().nonnegative(),
      }));
      const rows = schema.safeParse(data);
      if (!rows.success) throw new AdminOperationError();
      return {
        total: rows.data[0]?.total_count ?? 0,
        users: rows.data.map((row) => ({
          id: row.id,
          full_name: row.full_name,
          full_name_ar: row.full_name_ar ?? null,
          person_code: row.person_code ?? null,
          phone_number: row.phone_number ?? null,
          country_code: row.country_code ?? null,
          iqama_number: row.iqama_number ?? null,
          iqama_expiry_date: row.iqama_expiry_date ?? null,
          email: row.email,
          role: row.role,
          branches: row.branches,
          disabled: row.disabled,
          must_change_password: row.must_change_password,
          created_at: row.created_at,
        })),
      };
    },
    async createBranch(input) {
      const { data, error } = await admin.rpc("create_managed_branch", {
        actor_user_id: input.actorUserId,
        target_organization_id: input.organizationId,
        branch_name: input.name,
        branch_name_ar: input.nameAr ?? null,
        branch_timezone: input.timezone,
        branch_active: input.active,
      });
      if (error) {
        if (error.code === "23505") throw new AdminConflictError();
        if (error.code === "42501") throw new AdminAccessError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        id: z.string().uuid(),
        name: z.string(),
        name_ar: z.string().nullable().optional(),
        code: z.string(),
        timezone: z.string(),
        active: z.boolean(),
      }).strict()).length(1).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
      return rows.data[0];
    },
    async createBranchForInternalAdmin(input) {
      const { data, error } = await admin.rpc("create_internal_admin_branch", {
        p_actor_user_id: input.actorUserId,
        p_organization_id: input.organizationId,
        p_branch_name: input.name,
        p_branch_name_ar: input.nameAr ?? null,
        p_branch_timezone: input.timezone,
        p_branch_active: input.active,
      });
      if (error) {
        if (error.code === "23505") throw new AdminConflictError();
        if (error.code === "42501") throw new AdminAccessError();
        if (error.code === "P0002") throw new AdminNotFoundError();
        if (error.code === "22023") throw new AdminInputError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        id: z.string().uuid(),
        organization_id: z.string().uuid(),
        name: z.string(),
        name_ar: z.string().nullable().optional(),
        code: z.string(),
        timezone: z.string(),
        active: z.boolean(),
      }).strict()).length(1).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
      return rows.data[0];
    },
    async updateBranchForInternalAdmin(input) {
      const { data, error } = await admin.rpc("update_internal_admin_branch", {
        p_actor_user_id: input.actorUserId,
        p_organization_id: input.organizationId,
        p_branch_id: input.branchId,
        p_branch_name: input.name,
        p_branch_name_ar: input.nameAr ?? null,
        p_branch_timezone: input.timezone,
      });
      if (error) {
        if (error.code === "23505") throw new AdminConflictError();
        if (error.code === "42501") throw new AdminAccessError();
        if (error.code === "P0002") throw new AdminNotFoundError();
        if (error.code === "22023") throw new AdminInputError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        id: z.string().uuid(),
        organization_id: z.string().uuid(),
        name: z.string(),
        name_ar: z.string().nullable().optional(),
        code: z.string(),
        timezone: z.string(),
        active: z.boolean(),
      }).strict()).length(1).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
      return rows.data[0];
    },
    async deactivateBranchForInternalAdmin(input) {
      const { data, error } = await admin.rpc("deactivate_internal_admin_branch", {
        p_actor_user_id: input.actorUserId,
        p_organization_id: input.organizationId,
        p_branch_id: input.branchId,
      });
      if (error) {
        if (error.code === "42501") throw new AdminAccessError();
        if (error.code === "P0002") throw new AdminNotFoundError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        id: z.string().uuid(),
        organization_id: z.string().uuid(),
        name: z.string(),
        name_ar: z.string().nullable().optional(),
        code: z.string(),
        timezone: z.string(),
        active: z.literal(false),
      }).strict()).length(1).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
      return rows.data[0];
    },
    async reactivateBranchForInternalAdmin(input) {
      const { data, error } = await admin.rpc("reactivate_internal_admin_branch", {
        p_actor_user_id: input.actorUserId,
        p_organization_id: input.organizationId,
        p_branch_id: input.branchId,
      });
      if (error) {
        if (error.code === "42501") throw new AdminAccessError();
        if (error.code === "P0002") throw new AdminNotFoundError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        id: z.string().uuid(),
        organization_id: z.string().uuid(),
        name: z.string(),
        name_ar: z.string().nullable().optional(),
        code: z.string(),
        timezone: z.string(),
        active: z.literal(true),
      }).strict()).length(1).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
      return rows.data[0];
    },
    async listMaintenanceUsers(actorUserId, organizationId) {
      const { data, error } = await admin.rpc("list_managed_maintenance_users", {
        actor_user_id: actorUserId,
        target_organization_id: organizationId,
      });
      if (error || !Array.isArray(data)) {
        if (error?.code === "42501") throw new AdminAccessError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        id: z.string().uuid(),
        full_name: z.string().nullable(),
        full_name_ar: z.string().nullable().optional(),
        email: z.string().email(),
        active: z.boolean(),
        must_change_password: z.boolean(),
        created_at: z.string(),
        updated_at: z.string(),
        updated_by_name: z.string().nullable(),
      }).strict()).max(500).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
      return rows.data;
    },
    async deactivateMaintenanceUser(input) {
      const { data, error } = await admin.rpc("deactivate_maintenance_user", {
        actor_user_id: input.actorUserId,
        target_organization_id: input.organizationId,
        target_user_id: input.userId,
      });
      if (error) {
        if (error.code === "42501") throw new AdminAccessError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        id: z.string().uuid(),
        full_name: z.string().nullable(),
        email: z.string().email(),
        active: z.literal(false),
        updated_at: z.string(),
      }).strict()).length(1).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
    },
    async reactivateMaintenanceUser(input) {
      const { data, error } = await admin.rpc("reactivate_maintenance_user", {
        actor_user_id: input.actorUserId,
        target_organization_id: input.organizationId,
        target_user_id: input.userId,
      });
      if (error) {
        if (error.code === "42501") throw new AdminAccessError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        id: z.string().uuid(),
        full_name: z.string().nullable(),
        email: z.string().email(),
        active: z.literal(true),
        updated_at: z.string(),
      }).strict()).length(1).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
    },
    async grantExistingMaintenanceUser(input) {
      const { data, error } = await admin.rpc("grant_existing_maintenance_user", {
        actor_user_id: input.actorUserId,
        target_organization_id: input.organizationId,
        target_email: input.email,
      });
      if (error) {
        if (error.code === "42501") throw new AdminAccessError();
        if (error.code === "P0002") throw new AdminNotFoundError();
        throw new AdminOperationError();
      }
      const rows = z.array(z.object({
        id: z.string().uuid(),
        full_name: z.string().nullable(),
        email: z.string().email(),
        active: z.literal(true),
        updated_at: z.string(),
      }).strict()).length(1).safeParse(data);
      if (!rows.success) throw new AdminOperationError();
    },
  };
}

const bytea = z.string().regex(/^\\x[0-9a-f]+$/i);
const pinCredentialSchema = z.object({
  pin_hash: bytea, salt: bytea, kdf_version: z.literal(1), cost: z.literal(16384),
  block_size: z.literal(8), parallelization: z.literal(1), credential_version: z.string().uuid(),
});
const pinMetadataSchema = z.object({
  configured: z.boolean(), updated_at: z.string().nullable(), updated_by_name: z.string().nullable(),
});

export function createDailyAuditPinAdmin(url: string, secretKey: string): DailyAuditPinAdmin {
  const admin = createClient(url, secretKey, { auth: nonPersistentAuth });
  async function rpc(name: string, input: Record<string, unknown>) {
    const result = await admin.rpc(name, input);
    if (result.error) {
      if (result.error.code === "23505") throw new AdminConflictError();
      if (result.error.code === "42501") throw new AdminAccessError();
      throw new AdminOperationError();
    }
    if (!Array.isArray(result.data)) throw new AdminOperationError();
    return result.data;
  }
  const metadata = z.object({
    manager_user_id: z.string().uuid(), full_name: z.string().nullable(), email: z.string().email(),
    account_status: z.enum(["active", "password_change_required"]), configured: z.boolean(),
    updated_at: z.string().nullable(), updated_by_name: z.string().nullable(),
  }).strict();
  const userAccess = z.object({
    id: z.string().uuid(), organization_id: z.string().uuid(), display_name: z.string(),
    active: z.boolean(), created_at: z.string(), updated_at: z.string(), updated_by_name: z.string().nullable(),
  }).strict();
  const accessUserCredential = pinCredentialSchema.extend({
    organization_id: z.string().uuid(), access_user_id: z.string().uuid(), display_name: z.string(),
  }).strict();
  const credential = pinCredentialSchema.extend({
    organization_id: z.string().uuid(), manager_user_id: z.string().uuid(), display_name: z.string().min(1).max(120),
  }).strict();
  return {
    async listManagers(actorUserId, organizationId) {
      return z.array(metadata).max(100).parse(await rpc("list_organization_manager_daily_audit_pins", {
        actor_user_id: actorUserId, target_organization_id: organizationId,
      }));
    },
    async storeManagerPin(input) {
      const rows = z.array(z.object({
        manager_user_id: z.string().uuid(), configured: z.literal(true),
        updated_at: z.string(), updated_by_name: z.string().nullable(),
      }).strict()).length(1).parse(await rpc("store_organization_manager_daily_audit_pin", {
        actor_user_id: input.actorUserId, target_organization_id: input.organizationId,
        target_manager_user_id: input.managerUserId, new_pin_hash: input.credential.pin_hash,
        new_salt: input.credential.salt, new_pin_fingerprint: input.fingerprint,
        new_kdf_version: input.credential.kdf_version, new_cost: input.credential.cost,
        new_block_size: input.credential.block_size,
        new_parallelization: input.credential.parallelization,
      }));
      return rows[0];
    },
    async listCredentials(actorUserId, branchId) {
      return z.array(credential).max(100).parse(await rpc("get_organization_manager_daily_audit_credentials", {
        actor_user_id: actorUserId, target_branch_id: branchId,
      }));
    },
    async recordGrant(input) {
      const rows = await rpc("record_organization_manager_daily_audit_access_grant", {
        actor_user_id: input.actorUserId, target_branch_id: input.branchId,
        target_manager_user_id: input.managerUserId, target_credential_version: input.credentialVersion,
      });
      if (rows.length !== 1) throw new AdminOperationError();
    },
    async validateGrant(input) {
      const result = await admin.rpc("validate_organization_manager_daily_audit_grant", {
        actor_user_id: input.actorUserId, target_branch_id: input.branchId,
        target_manager_user_id: input.managerUserId, target_credential_version: input.credentialVersion,
      });
      if (result.error || typeof result.data !== "boolean") throw new AdminOperationError();
      return result.data;
    },
    async listAccessUsers(actorUserId, organizationId) {
      return z.array(userAccess).max(500).parse(await rpc("list_daily_audit_access_users", {
        actor_user_id: actorUserId, target_organization_id: organizationId,
      }));
    },
    async createAccessUser(input) {
      const rows = await rpc("create_daily_audit_access_user", {
        actor_user_id: input.actorUserId, target_organization_id: input.organizationId,
        access_display_name: input.displayName,
        new_pin_hash: input.credential.pin_hash, new_salt: input.credential.salt,
        new_kdf_version: input.credential.kdf_version, new_cost: input.credential.cost,
        new_block_size: input.credential.block_size, new_parallelization: input.credential.parallelization,
      });
      if (rows.length !== 1) throw new AdminOperationError();
    },
    async revokeAccessUser(input) {
      const rows = await rpc("revoke_daily_audit_access_user", {
        actor_user_id: input.actorUserId, target_organization_id: input.organizationId,
        target_access_user_id: input.accessUserId,
      });
      if (rows.length !== 1) throw new AdminOperationError();
    },
    async listAccessUserCredentials(actorUserId, branchId) {
      return z.array(accessUserCredential).max(100).parse(await rpc("get_daily_audit_access_user_credentials", {
        actor_user_id: actorUserId, target_branch_id: branchId,
      }));
    },
    async listManagersForInternalAdmin(actorUserId, organizationId) {
      return z.array(metadata).max(100).parse(await rpc("list_internal_admin_daily_audit_pins", {
        actor_user_id: actorUserId, target_organization_id: organizationId,
      }));
    },
    async storeManagerPinForInternalAdmin(input) {
      const rows = z.array(z.object({
        manager_user_id: z.string().uuid(), configured: z.literal(true),
        updated_at: z.string(), updated_by_name: z.string().nullable(),
      }).strict()).length(1).parse(await rpc("store_internal_admin_daily_audit_pin", {
        actor_user_id: input.actorUserId, target_organization_id: input.organizationId,
        target_manager_user_id: input.managerUserId, new_pin_hash: input.credential.pin_hash,
        new_salt: input.credential.salt, new_pin_fingerprint: input.fingerprint,
        new_kdf_version: input.credential.kdf_version, new_cost: input.credential.cost,
        new_block_size: input.credential.block_size,
        new_parallelization: input.credential.parallelization,
      }));
      return rows[0];
    },
    async listAccessUsersForInternalAdmin(actorUserId, organizationId) {
      return z.array(userAccess).max(500).parse(await rpc("list_internal_admin_daily_audit_access_users", {
        actor_user_id: actorUserId, target_organization_id: organizationId,
      }));
    },
    async createAccessUserForInternalAdmin(input) {
      const rows = await rpc("create_internal_admin_daily_audit_access_user", {
        actor_user_id: input.actorUserId, target_organization_id: input.organizationId,
        access_display_name: input.displayName,
        new_pin_hash: input.credential.pin_hash, new_salt: input.credential.salt,
        new_kdf_version: input.credential.kdf_version, new_cost: input.credential.cost,
        new_block_size: input.credential.block_size, new_parallelization: input.credential.parallelization,
      });
      if (rows.length !== 1) throw new AdminOperationError();
    },
    async revokeAccessUserForInternalAdmin(input) {
      const rows = await rpc("revoke_internal_admin_daily_audit_access_user", {
        actor_user_id: input.actorUserId, target_organization_id: input.organizationId,
        target_access_user_id: input.accessUserId,
      });
      if (rows.length !== 1) throw new AdminOperationError();
    },
  };
}

export function createMaintenanceAccessAdmin(url: string, secretKey: string): MaintenanceAccessAdmin {
  const admin = createClient(url, secretKey, { auth: nonPersistentAuth });
  async function rpc(name: string, input: Record<string, unknown>) {
    const result = await admin.rpc(name, input);
    if (result.error) {
      if (result.error.code === "23505") throw new AdminConflictError();
      if (result.error.code === "42501") throw new AdminAccessError();
      throw new AdminOperationError();
    }
    if (!Array.isArray(result.data)) throw new AdminOperationError();
    return result.data;
  }
  const accessUser = z.object({
    id: z.string().uuid(), organization_id: z.string().uuid(), display_name: z.string(),
    active: z.boolean(), created_at: z.string(), updated_at: z.string(), updated_by_name: z.string().nullable(),
  }).strict();
  const credential = pinCredentialSchema.extend({
    organization_id: z.string().uuid(), organization_name: z.string(),
    access_user_id: z.string().uuid(), display_name: z.string(),
  }).strict();
  const session = z.object({
    organization_id: z.string().uuid(), organization_name: z.string(),
    access_user_id: z.string().uuid(), display_name: z.string(),
  }).strict();
  return {
    async listAccessUsers(actorUserId, organizationId) {
      return z.array(accessUser).max(500).parse(await rpc("list_maintenance_access_users", {
        actor_user_id: actorUserId, target_organization_id: organizationId,
      }));
    },
    async createAccessUser(input) {
      const rows = await rpc("create_maintenance_access_user", {
        actor_user_id: input.actorUserId, target_organization_id: input.organizationId,
        access_display_name: input.displayName,
        new_pin_hash: input.credential.pin_hash, new_salt: input.credential.salt,
        new_kdf_version: input.credential.kdf_version, new_cost: input.credential.cost,
        new_block_size: input.credential.block_size, new_parallelization: input.credential.parallelization,
      });
      if (rows.length !== 1) throw new AdminOperationError();
    },
    async deactivateAccessUser(input) {
      const rows = await rpc("deactivate_maintenance_access_user", {
        actor_user_id: input.actorUserId, target_organization_id: input.organizationId,
        target_access_user_id: input.accessUserId,
      });
      if (rows.length !== 1) throw new AdminOperationError();
    },
    async getAccessCredential(input) {
      const rows = z.array(credential).max(1).parse(await rpc("get_maintenance_access_user_credentials", {
        organization_identifier: input.organizationIdentifier,
        access_display_name: input.displayName,
      }));
      return rows[0] ?? null;
    },
    async validateAccessGrant(input) {
      const rows = z.array(session).max(1).parse(await rpc("validate_maintenance_access_grant", {
        target_organization_id: input.organizationId,
        target_access_user_id: input.accessUserId,
        target_credential_version: input.credentialVersion,
      }));
      return rows[0] ?? null;
    },
  };
}

export function createBranchManagementAdmin(url: string, secretKey: string): BranchManagementAdmin {
  const admin = createClient(url, secretKey, { auth: nonPersistentAuth });
  async function rpc(name: string, input: Record<string, unknown>) {
    const result = await admin.rpc(name, input);
    if (result.error || !Array.isArray(result.data)) throw new AdminOperationError();
    return result.data;
  }
  return {
    async listBranches(actorUserId) {
      return z.array(z.object({
        id: z.string().uuid(), organization_id: z.string().uuid(), name: z.string(),
        code: z.string(), staff_count: z.number().int().nonnegative(),
      })).max(200).parse(await rpc("list_supervised_branches", { actor_user_id: actorUserId }));
    },
    async listStaff(actorUserId, branchId) {
      return z.array(z.object({
        id: z.string().uuid(), full_name: z.string().nullable(),
        role: z.enum(["staff", "branch_manager"]), disabled: z.boolean(),
        must_change_password: z.boolean(),
      })).max(500).parse(await rpc("list_supervised_branch_staff", {
        actor_user_id: actorUserId, target_branch_id: branchId,
      }));
    },
    async getPinMetadata(actorUserId, branchId) {
      const rows = z.array(pinMetadataSchema).length(1).parse(await rpc("get_daily_audit_pin_metadata", {
        actor_user_id: actorUserId, target_branch_id: branchId,
      }));
      return rows[0];
    },
    async storePin(input) {
      const rows = z.array(pinMetadataSchema).length(1).parse(await rpc("store_daily_audit_pin", {
        actor_user_id: input.actorUserId, target_branch_id: input.branchId,
        new_pin_hash: input.credential.pin_hash, new_salt: input.credential.salt,
        new_kdf_version: input.credential.kdf_version, new_cost: input.credential.cost,
        new_block_size: input.credential.block_size,
        new_parallelization: input.credential.parallelization,
      }));
      return rows[0];
    },
    async getPinCredential(actorUserId, branchId) {
      const rows = z.array(pinCredentialSchema).max(1).parse(await rpc("get_daily_audit_pin_credential", {
        actor_user_id: actorUserId, target_branch_id: branchId,
      }));
      return rows[0] ?? null;
    },
  };
}

function scrypt(pin: string, salt: Buffer, length: number, options: { N: number; r: number; p: number; maxmem: number }) {
  return new Promise<Buffer>((resolve, reject) => {
    scryptCallback(pin, salt, length, options, (error, derivedKey) => {
      if (error) reject(error);
      else resolve(derivedKey);
    });
  });
}
function fromBytea(value: string) { return Buffer.from(value.slice(2), "hex"); }
export function createPinCrypto(signingSecret: string): PinCrypto {
  const grantSchema = z.object({
    aud: z.literal("daily-audit-verification"),
    sub: z.string().uuid(),
    bid: z.string().uuid(),
    iat: z.number().int().nonnegative(),
    exp: z.number().int().positive(),
    ver: z.string().uuid(),
  }).strict();
  const managerGrantSchema = grantSchema.extend({
    oid: z.string().uuid(), mid: z.string().uuid(),
  }).strict();
  const manualDailyAuditGrantSchema = z.object({
    aud: z.literal("daily-audit-verification"), ver: z.literal("v2"), sub: z.string().uuid(),
    oid: z.string().uuid(), bid: z.string().uuid(), kind: z.literal("manual_access_user"),
    uid: z.string().uuid(), name: z.string().min(1).max(120), iat: z.number().int().nonnegative(), exp: z.number().int().positive(),
    cv: z.string().uuid(),
  }).strict();
  const organizationManagerDailyAuditGrantSchema = z.object({
    aud: z.literal("daily-audit-verification"), ver: z.literal("v2"), sub: z.string().uuid(),
    oid: z.string().uuid(), bid: z.string().uuid(), kind: z.literal("organization_manager_pin"),
    uid: z.string().uuid(), name: z.string().min(1).max(120), iat: z.number().int().nonnegative(), exp: z.number().int().positive(),
    cv: z.string().uuid(),
  }).strict();
  const maintenanceGrantSchema = z.object({
    aud: z.literal("maintenance-access"),
    oid: z.string().uuid(),
    uid: z.string().uuid(),
    iat: z.number().int().nonnegative(),
    exp: z.number().int().positive(),
    ver: z.string().uuid(),
  }).strict();
  function sign(payload: object) {
    const encoded = Buffer.from(JSON.stringify(payload)).toString("base64url");
    const signature = createHmac("sha256", signingSecret).update(encoded).digest("base64url");
    return `${encoded}.${signature}`;
  }
  function parseSigned(grant: string) {
    const parts = grant.split(".");
    if (parts.length !== 2) return null;
    const [encoded, signature] = parts;
    const expected = createHmac("sha256", signingSecret).update(encoded).digest();
    const actual = Buffer.from(signature, "base64url");
    if (expected.length !== actual.length || !timingSafeEqual(expected, actual)) return null;
    return JSON.parse(Buffer.from(encoded, "base64url").toString("utf8"));
  }
  return {
    async hash(pin) {
      const salt = randomBytes(16);
      const hash = await scrypt(pin, salt, 32, { N: 16384, r: 8, p: 1, maxmem: 32 * 1024 * 1024 });
      return { pin_hash: `\\x${hash.toString("hex")}`, salt: `\\x${salt.toString("hex")}`, kdf_version: 1, cost: 16384, block_size: 8, parallelization: 1 };
    },
    async verify(pin, credential) {
      try {
        const expected = fromBytea(credential.pin_hash);
        const actual = await scrypt(pin, fromBytea(credential.salt), expected.length, {
          N: credential.cost, r: credential.block_size, p: credential.parallelization,
          maxmem: 32 * 1024 * 1024,
        });
        return expected.length === actual.length && timingSafeEqual(expected, actual);
      } catch { return false; }
    },
    fingerprint(pin) {
      return `\\x${createHmac("sha256", signingSecret).update("daily-audit-pin-fingerprint:v1\0").update(pin).digest("hex")}`;
    },
    issueManagerGrant(userId, branchId, organizationId, managerUserId, credentialVersion, now = Date.now()) {
      return sign({ aud: "daily-audit-verification", sub: userId, bid: branchId, oid: organizationId,
        mid: managerUserId, iat: now, exp: now + 5 * 60_000, ver: credentialVersion });
    },
    verifyManagerGrant(grant, userId, branchId, organizationId, managerUserId, credentialVersion, now = Date.now()) {
      try {
        const parsed = managerGrantSchema.safeParse(parseSigned(grant));
        if (!parsed.success) return false;
        const value = parsed.data;
        return value.sub===userId && value.bid===branchId && value.oid===organizationId &&
          value.mid===managerUserId && value.ver===credentialVersion && value.iat<=now && value.exp>now &&
          value.exp-value.iat>0 && value.exp-value.iat<=5*60_000;
      } catch { return false; }
    },
    issueMaintenanceGrant(organizationId, accessUserId, credentialVersion, now = Date.now()) {
      return sign({
        aud: "maintenance-access",
        oid: organizationId,
        uid: accessUserId,
        iat: now,
        exp: now + 8 * 60 * 60_000,
        ver: credentialVersion,
      });
    },
    verifyMaintenanceGrant(grant, now = Date.now()) {
      try {
        const parsed = maintenanceGrantSchema.safeParse(parseSigned(grant));
        if (!parsed.success) return null;
        const value = parsed.data;
        if (value.iat > now || value.exp <= now || value.exp - value.iat <= 0 || value.exp - value.iat > 8 * 60 * 60_000) {
          return null;
        }
        return { organizationId: value.oid, accessUserId: value.uid, credentialVersion: value.ver };
      } catch { return null; }
    },
    issueGrant(userId, branchId, credentialVersion, now = Date.now()) {
      const payload = JSON.stringify({
        aud: "daily-audit-verification",
        sub: userId,
        bid: branchId,
        iat: now,
        exp: now + 5 * 60_000,
        ver: credentialVersion,
      });
      const encoded = Buffer.from(payload).toString("base64url");
      const signature = createHmac("sha256", signingSecret).update(encoded).digest("base64url");
      return `${encoded}.${signature}`;
    },
    issueManualDailyAuditGrant(input) {
      return sign({aud:"daily-audit-verification",ver:"v2",sub:input.actorUserId,oid:input.organizationId,bid:input.originalBranchId,kind:"manual_access_user",uid:input.auditorId,name:input.auditorDisplayName,iat:input.now??Date.now(),exp:(input.now??Date.now())+5*60_000,cv:input.credentialVersion});
    },
    verifyManualDailyAuditGrant(grant, actorUserId, now = Date.now()) {
      try { const parsed=manualDailyAuditGrantSchema.safeParse(parseSigned(grant)); if(!parsed.success)return null; const value=parsed.data; if(value.sub!==actorUserId||value.iat>now||value.exp<=now||value.exp-value.iat<=0||value.exp-value.iat>5*60_000)return null; return {organizationId:value.oid,originalBranchId:value.bid,auditorId:value.uid,auditorDisplayName:value.name,credentialVersion:value.cv,issuedAt:value.iat,expiresAt:value.exp}; } catch { return null; }
    },
    issueOrganizationManagerDailyAuditGrant(input) {
      return sign({aud:"daily-audit-verification",ver:"v2",sub:input.actorUserId,oid:input.organizationId,bid:input.originalBranchId,kind:"organization_manager_pin",uid:input.auditorId,name:input.auditorDisplayName,iat:input.now??Date.now(),exp:(input.now??Date.now())+5*60_000,cv:input.credentialVersion});
    },
    verifyOrganizationManagerDailyAuditGrant(grant, actorUserId, now = Date.now()) {
      try { const parsed=organizationManagerDailyAuditGrantSchema.safeParse(parseSigned(grant)); if(!parsed.success)return null; const value=parsed.data; if(value.sub!==actorUserId||value.iat>now||value.exp<=now||value.exp-value.iat<=0||value.exp-value.iat>5*60_000)return null; return {organizationId:value.oid,originalBranchId:value.bid,auditorId:value.uid,auditorDisplayName:value.name,credentialVersion:value.cv,issuedAt:value.iat,expiresAt:value.exp}; } catch { return null; }
    },
    verifyGrant(grant, userId, branchId, credentialVersion, now = Date.now()) {
      try {
        const parts = grant.split(".");
        if (parts.length !== 2) return false;
        const [encoded, signature] = parts;
        const expected = createHmac("sha256", signingSecret).update(encoded).digest();
        const actual = Buffer.from(signature, "base64url");
        if (expected.length !== actual.length || !timingSafeEqual(expected, actual)) return false;
        const parsed = grantSchema.safeParse(JSON.parse(Buffer.from(encoded, "base64url").toString("utf8")));
        if (!parsed.success) return false;
        const value = parsed.data;
        return value.sub === userId && value.bid === branchId && value.ver === credentialVersion &&
          value.iat <= now && value.exp > now && value.exp - value.iat > 0 &&
          value.exp - value.iat <= 5 * 60_000;
      } catch { return false; }
    },
  };
}

const nonPersistentAuth = {
  autoRefreshToken: false,
  detectSessionInUrl: false,
  persistSession: false,
} as const;

export function createPasswordChangeService(
  url: string,
  publishableKey: string,
  secretKey: string,
): PasswordChangeService {
  const admin = createClient(url, secretKey, { auth: nonPersistentAuth });

  return {
    async verifyCurrent(email, password) {
      // A fresh client prevents the verification session from being retained or
      // shared with another request.
      const verifier = createClient(url, publishableKey, {
        auth: nonPersistentAuth,
      });
      const { error } = await verifier.auth.signInWithPassword({ email, password });
      return !error;
    },
    async updatePassword(userId, password) {
      const { error } = await admin.auth.admin.updateUserById(userId, { password });
      if (error) throw new AdminOperationError();
    },
    async finalize(userId) {
      const { error } = await admin.rpc("finalize_password_change", {
        p_user_id: userId,
      });
      if (error) throw new AdminOperationError();
    },
  };
}

export function createProvisioningAdmin(url: string, secretKey: string): ProvisioningAdmin {
  const client = createClient(url, secretKey, {
    auth: nonPersistentAuth,
  });

  return {
    async createUser(input) {
      const { data, error } = await client.auth.admin.createUser({
        email: input.email,
        password: input.password,
        email_confirm: true,
      });
      if (error) {
        if (error.status === 422 || error.status === 409) throw new AdminConflictError();
        throw new ProvisioningStageError("auth_create", "operation_failed", error.status ?? null);
      }
      if (!data.user?.id) throw new ProvisioningStageError("auth_create", "invalid_response");
      return { id: data.user.id };
    },
    async deleteUser(userId) {
      const { error } = await client.auth.admin.deleteUser(userId);
      if (error) throw new ProvisioningStageError("auth_compensation", "operation_failed", error.status ?? null);
    },
    async finalize(input) {
      const { error } = await client.rpc("finalize_provisioned_supervisor", {
        p_actor_user_id: input.actorUserId,
        p_organization_id: input.organizationId,
        p_new_user_id: input.newUserId,
        p_full_name: input.fullName,
        p_full_name_ar: input.fullNameAr ?? null,
        p_branch_ids: input.branchIds,
        p_team_assignments: (input.supervisorTeamAssignments ?? []).map((assignment) => ({
          operational_team_id: assignment.operationalTeamId,
          assignment_role: assignment.assignmentRole,
        })),
        p_person_code: input.personCode ?? null,
        p_phone_number: input.phoneNumber ?? null,
        p_country_code: input.countryCode ?? null,
        p_iqama_number: input.iqamaNumber ?? null,
        p_iqama_expiry_date: input.iqamaExpiryDate ?? null,
      });
      if (error) {
        if (error.code === "42501") throw new AdminAccessError();
        if (error.code === "23505" && /profiles_person_code/i.test(error.message)) throw new AdminDuplicatePersonCodeError();
        if (error.code === "23505" || error.code === "23514" || error.code === "22023") throw new AdminConflictError();
        throw new ProvisioningStageError("database_finalize", "rpc_failed", null, error.code ?? null);
      }
    },
    async finalizeMaintenance(input) {
      const { error } = await client.rpc("finalize_provisioned_maintenance_user", {
        p_actor_user_id: input.actorUserId,
        p_organization_id: input.organizationId,
        p_new_user_id: input.newUserId,
        p_full_name: input.fullName,
        p_full_name_ar: input.fullNameAr ?? null,
      });
      if (error) throw new ProvisioningStageError("database_finalize", "rpc_failed");
    },
    async finalizeOrganizationManager(input) {
      const { error } = await client.rpc("finalize_provisioned_organization_manager", {
        p_actor_user_id: input.actorUserId,
        p_organization_id: input.organizationId,
        p_new_user_id: input.newUserId,
        p_full_name: input.fullName,
        p_full_name_ar: input.fullNameAr ?? null,
      });
      if (error) throw new ProvisioningStageError("database_finalize", "rpc_failed");
    },
  };
}
