import type { PinCrypto } from "./admin";

export type DailyAuditGrantIdentity = {
  organization_id: string;
  branch_id: string;
  original_branch_id: string;
  auditor_kind: "manual_access_user" | "organization_manager_pin";
  auditor_id: string;
  auditor_display_name: string;
  access_credential_version: string;
};

type BranchScope = { organization_id: string; active: boolean };
type CredentialScope = { active: boolean; credential_version: string; display_name: string };

function cookieValue(cookieHeader: string | undefined) {
  const entry = (cookieHeader ?? "").split(";").map((part) => part.trim()).find((part) => part.startsWith("audit_access="));
  return entry?.slice("audit_access=".length) || null;
}

export async function validateManualDailyAuditGrant(input: {
  cookies?: string;
  actorUserId: string;
  targetBranchId: string;
  pinCrypto: PinCrypto;
  getBranchScope: (branchId: string) => Promise<BranchScope | null>;
  getCredentialScope: (organizationId: string, accessUserId: string) => Promise<CredentialScope | null>;
}): Promise<DailyAuditGrantIdentity | null> {
  const token = cookieValue(input.cookies);
  if (!token || !input.pinCrypto.verifyManualDailyAuditGrant) return null;
  const grant = input.pinCrypto.verifyManualDailyAuditGrant(token, input.actorUserId);
  if (!grant) return null;
  const branch = await input.getBranchScope(input.targetBranchId);
  if (!branch?.active || branch.organization_id !== grant.organizationId) return null;
  const credential = await input.getCredentialScope(grant.organizationId, grant.auditorId);
  if (!credential?.active || credential.credential_version !== grant.credentialVersion) return null;
  return {
    organization_id: grant.organizationId,
    branch_id: input.targetBranchId,
    original_branch_id: grant.originalBranchId,
    auditor_kind: "manual_access_user",
    auditor_id: grant.auditorId,
    auditor_display_name: credential.display_name,
    access_credential_version: grant.credentialVersion,
  };
}

export async function validateDailyAuditGrant(input: {
  cookies?: string;
  actorUserId: string;
  targetBranchId: string;
  pinCrypto: PinCrypto;
  getBranchScope: (branchId: string) => Promise<BranchScope | null>;
  getCredentialScope: (organizationId: string, accessUserId: string) => Promise<CredentialScope | null>;
  getOrganizationManagerCredentialScope: (organizationId: string, managerUserId: string, credentialVersion: string, branchId: string) => Promise<CredentialScope | null>;
}): Promise<DailyAuditGrantIdentity | null> {
  const manual = await validateManualDailyAuditGrant(input);
  if (manual) return manual;
  const token = cookieValue(input.cookies);
  if (!token || !input.pinCrypto.verifyOrganizationManagerDailyAuditGrant) return null;
  const grant = input.pinCrypto.verifyOrganizationManagerDailyAuditGrant(token, input.actorUserId);
  if (!grant) return null;
  const branch = await input.getBranchScope(input.targetBranchId);
  if (!branch?.active || branch.organization_id !== grant.organizationId) return null;
  const credential = await input.getOrganizationManagerCredentialScope(grant.organizationId, grant.auditorId, grant.credentialVersion, input.targetBranchId);
  if (!credential?.active || credential.credential_version !== grant.credentialVersion) return null;
  return {
    organization_id: grant.organizationId,
    branch_id: input.targetBranchId,
    original_branch_id: grant.originalBranchId,
    auditor_kind: "organization_manager_pin",
    auditor_id: grant.auditorId,
    auditor_display_name: grant.auditorDisplayName,
    access_credential_version: grant.credentialVersion,
  };
}
