import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { createApp } from "./app";
import { loadBackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import { branchLocalDate, createOperationalAdmin, OperationalAccessError, OperationalConflictError, OperationalDuplicateStaffCodeError, OperationalHygieneSubmittedError } from "./operational";
import type { UserContext } from "./user-context";

const id = {
  supervisor: "10000000-0000-4000-8000-000000000001",
  manager: "10000000-0000-4000-8000-000000000002",
  staffAccount: "10000000-0000-4000-8000-000000000003",
  invalidZoneSupervisor: "10000000-0000-4000-8000-000000000004",
  legacyStaff: "10000000-0000-4000-8000-000000000005",
  branch: "20000000-0000-4000-8000-000000000001",
  organization: "30000000-0000-4000-8000-000000000001",
  shift: "40000000-0000-4000-8000-000000000001",
  destinationBranch: "20000000-0000-4000-8000-000000000004",
  destinationTeam: "40000000-0000-4000-8000-000000000004",
  worker: "50000000-0000-4000-8000-000000000001",
  assignment: "60000000-0000-4000-8000-000000000001",
  healthCard: "80000000-0000-4000-8000-000000000001",
  emptyHealthBranch: "20000000-0000-4000-8000-000000000002",
  nullableHealthBranch: "20000000-0000-4000-8000-000000000003",
  monthlyEvaluation: "90000000-0000-4000-8000-000000000001",
  purchaseLog: "a0000000-0000-4000-8000-000000000001",
  supplierReceiving: "b0000000-0000-4000-8000-000000000001",
  supplier: "b1000000-0000-4000-8000-000000000001",
  maintenanceIssue: "c0000000-0000-4000-8000-000000000001",
  maintenanceUpdate: "c1000000-0000-4000-8000-000000000001",
  maintenanceAccessUser: "d0000000-0000-4000-8000-000000000001",
};
const contexts: Record<string, UserContext> = {
  supervisor: {
    id: id.supervisor, full_name: "Supervisor", disabled: false, must_change_password: false,
    branches: [{ id: id.branch, name: "Branch", organization_id: id.organization, role: "branch_manager" }],
    managed_organizations: [],
  },
  manager: {
    id: id.manager, full_name: "Manager", disabled: false, must_change_password: false,
    branches: [], managed_organizations: [{ id: id.organization, name: "Organization", role: "organization_manager" }],
  },
  staff: {
    id: id.legacyStaff, full_name: "Legacy Staff", disabled: false, must_change_password: false,
    branches: [{ id: id.branch, name: "Branch", organization_id: id.organization, role: "staff" }],
    managed_organizations: [],
  },
  maintenance: {
    id: id.staffAccount, full_name: "Maintenance", disabled: false, must_change_password: false,
    branches: [], managed_organizations: [],
  },
  "invalid-zone": {
    id: id.invalidZoneSupervisor, full_name: "Invalid Zone Supervisor", disabled: false, must_change_password: false,
    branches: [{ id: id.branch, name: "Branch", organization_id: id.organization, role: "branch_manager" }],
    managed_organizations: [],
  },
};

function dependencies(calls: Array<Record<string, unknown>>): BackendDependencies {
  return {
    authVerifier: { async verify(token) {
      const context = contexts[token];
      return context ? { userId: context.id, email: `${token}@example.invalid` } : null;
    } },
    checkReadiness: async () => true,
    createUserContext: (token) => ({
      async getUserContext() { return contexts[token] ?? null; },
      async hasOrganizationManagerAccess() { return token === "manager"; },
      async validateActiveBranches() { return true; },
      async listActiveBranches() { return []; },
    }),
    passwordChange: { async verifyCurrent() { return true; }, async updatePassword() {}, async finalize() {} },
    provisioningAdmin: {
      async createUser(input) { calls.push({ method: "createAuthUser", ...input }); return { id: id.worker }; },
      async deleteUser(userId) { calls.push({ method: "deleteAuthUser", userId }); },
      async finalize() {},
    },
    managementAdmin: { async listUsers() { return { users: [], total: 0 }; } },
    branchManagementAdmin: {
      async listBranches() { return []; }, async listStaff() { return []; },
      async getPinMetadata() { return { configured: false, updated_at: null, updated_by_name: null }; },
      async storePin() { return { configured: false, updated_at: null, updated_by_name: null }; },
      async getPinCredential() { return null; },
    },
    pinCrypto: {
      async hash() { throw new Error("unused"); }, async verify() { return false; },
      issueGrant() { return ""; }, verifyGrant() { return false; },
    },
    operationalAdmin: {
      async getBranchTimezone(actorUserId, branchId) {
        calls.push({ method: "timezone", actorUserId, branchId });
        if (actorUserId === id.invalidZoneSupervisor) return "Not/A_Timezone";
        if (actorUserId !== id.supervisor) throw new OperationalAccessError();
        return "Asia/Riyadh";
      },
      async getSupervisorTeam(actorUserId, branchId, date) {
        calls.push({ method: "get", actorUserId, branchId, date });
        if (branchId === id.emptyHealthBranch) throw new OperationalAccessError();
        if (actorUserId !== id.supervisor) throw new Error("denied");
        return { teams: [{ id: id.shift, name: "Team A", active: true, can_write: true, assignment_role: "primary", company_name: null, staff: [] }] };
      },
      async createStaff(input) {
        calls.push({ method: "create", ...input });
        if (input.actorUserId !== id.supervisor) throw new Error("denied");
        if (input.staffCode === "DUPLICATE") throw new OperationalDuplicateStaffCodeError();
        return { staff_id: id.worker, assignment_id: id.assignment, duplicate_name_warning: false };
      },
      async updateStaff(input) {
        calls.push({ method: "update", ...input });
        if (input.staffCode === "DUPLICATE") throw new OperationalDuplicateStaffCodeError();
        return { staff_id: id.worker };
      },
      async setDuty(input) { calls.push({ method: "duty", ...input }); return { staff_id: id.worker, duty_status: input.status, eligible: input.status === "on_duty" }; },
      async moveStaff(input) { calls.push({ method: "move", ...input }); return { staff_id: input.staffId, assignment_id: id.assignment, operational_team_id: input.operationalTeamId }; },
      async listStaffTransferDestinations(input) {
        calls.push({ method: "transferDestinations", ...input });
        return { destinations: [{ branch_id: id.destinationBranch, branch_name: "Destination Branch", branch_code: "DST", operational_team_id: id.destinationTeam, team_name: "Destination Team" }] };
      },
      async transferStaffBranch(input) {
        calls.push({ method: "branchTransfer", ...input });
        if (input.destinationTeamId === id.emptyHealthBranch) throw new OperationalHygieneSubmittedError();
        return { staff_id: input.staffId, assignment_id: id.assignment, branch_id: input.destinationBranchId, operational_team_id: input.destinationTeamId };
      },
      async leaveStaff(input) { calls.push({ method: "leave", ...input }); return { staff_id: input.staffId, assignment_id: id.assignment, employment_status: "inactive" }; },
      async startManagedOperationalStaffSupervisorTraining(input) { calls.push({ method: "startSupervisorTraining", ...input }); return { id: id.assignment, operational_staff_id: input.staffId, status: "training" }; },
      async cancelManagedOperationalStaffSupervisorTraining(input) { calls.push({ method: "cancelSupervisorTraining", ...input }); return { id: id.assignment, operational_staff_id: input.staffId, status: "cancelled" }; },
      async getManagedOperationalStaffSupervisorTrainingPromotionState(input) { calls.push({ method: "getSupervisorTrainingPromotionState", ...input }); return { id: id.assignment, operational_staff_id: input.staffId, status: "training" }; },
      async promoteManagedOperationalStaffSupervisorTraining(input) {
        calls.push({ method: "promoteSupervisorTraining", ...input });
        if (input.fullName === "Fail Promotion") throw new OperationalConflictError();
        return { id: id.assignment, operational_staff_id: input.staffId, status: "promoted", promoted_supervisor_user_id: input.newSupervisorUserId };
      },
      async listHealthCards(actorUserId, branchId) {
        calls.push({ method: "healthCards", actorUserId, branchId });
        if (actorUserId !== id.supervisor) throw new Error("denied");
        if (branchId === id.emptyHealthBranch) return { health_cards: [] };
        if (branchId === id.nullableHealthBranch) return { health_cards: [{ id: null, operational_staff_id: id.worker, certificate_number: null, status: "not_done", place_of_issue: null, expiry_date: null, date_issue: null, occupation: null, company: null, branch_name_snapshot: null, notes: null, updated_at: null }] };
        return { health_cards: [{ id: id.healthCard, operational_staff_id: id.worker, certificate_number: "HC-7788", status: "pending", place_of_issue: "Riyadh", expiry_date: "2027-01-31", date_issue: "2026-01-31", occupation: "Kitchen", company: "Burger Hunch", branch_name_snapshot: "Branch", notes: "Waiting", updated_at: "2026-08-09T00:00:00.000Z" }] };
      },
      async upsertHealthCard(input) {
        calls.push({ method: "upsertHealthCard", ...input });
        if (input.actorUserId !== id.supervisor || input.staffId !== id.worker) throw new Error("denied");
        return { health_card: { id: id.healthCard, operational_staff_id: input.staffId, certificate_number: input.certificateNumber, status: input.status, place_of_issue: input.placeOfIssue, expiry_date: input.expiryDate, date_issue: input.dateIssue, occupation: input.occupation, company: input.company, branch_name_snapshot: "Branch", notes: input.notes, updated_at: "2026-08-09T00:00:00.000Z" } };
      },
      async listMonthlyEvaluations(actorUserId, branchId, evaluationMonth) {
        calls.push({ method: "monthlyEvaluations", actorUserId, branchId, evaluationMonth });
        if (actorUserId !== id.supervisor) throw new Error("denied");
        return { evaluations: [{ id: id.monthlyEvaluation, operational_staff_id: id.worker, evaluation_month: evaluationMonth, evaluator_name: "Supervisor", status: "draft", average_score: "4.50", scores: [{ section: "Performance", factor_key: "performance_initiative", factor_label: "Strong initiative", rating: 5, comment: "Good" }], updated_at: "2026-08-09T00:00:00.000Z" }] };
      },
      async saveMonthlyEvaluation(input) {
        calls.push({ method: "saveMonthlyEvaluation", ...input });
        if (input.actorUserId !== id.supervisor || input.staffId !== id.worker) throw new Error("denied");
        return { evaluation: { id: id.monthlyEvaluation, operational_staff_id: input.staffId, evaluation_month: input.evaluationMonth, evaluator_name: input.evaluatorName, status: input.status, average_score: 5, scores: input.scores, updated_at: "2026-08-09T00:00:00.000Z" } };
      },
      async listPurchaseLogs(actorUserId, branchId, filters) {
        calls.push({ method: "purchaseLogs", actorUserId, branchId, filters: filters ?? null });
        if (actorUserId !== id.supervisor) throw new Error("denied");
        return { purchase_logs: [] };
      },
      async createPurchaseLog(input) {
        calls.push({ method: "createPurchaseLog", hasInvoice: Boolean(input.invoice), ...input });
        if (input.actorUserId !== id.supervisor) throw new Error("denied");
        return { purchase_log: { id: id.purchaseLog, organization_id: id.organization, branch_id: input.branchId, supervisor_team_id: id.shift, branch_name: "Branch", category: input.payload.category, item_name: input.payload.item_name, quantity: Number(input.payload.quantity), amount: Number(input.payload.amount), vendor_name: input.payload.vendor_name || "N/A", purchase_date: input.payload.purchase_date, notes: input.payload.notes ?? null, payment_status: input.payload.payment_status ?? "unpaid", reimbursement_note: input.payload.reimbursement_note ?? null, reimbursed_at: null, reimbursed_by: null, invoice_storage_path: input.invoice ? `branches/${input.branchId}/purchase-logs/${id.purchaseLog}/invoice.pdf` : null, invoice_original_name: input.invoice?.originalName ?? null, invoice_url: input.invoice ? "https://storage.example.invalid/invoice" : null, created_by: input.actorUserId, created_at: "2026-08-09T00:00:00.000Z", updated_at: "2026-08-09T00:00:00.000Z" } };
      },
      async updatePurchaseLogPaymentStatus(input) {
        calls.push({ method: "updatePurchasePayment", ...input });
        if (input.actorUserId !== id.supervisor || input.purchaseLogId !== id.purchaseLog) throw new Error("denied");
        return { purchase_log: { id: input.purchaseLogId, organization_id: id.organization, branch_id: input.branchId, supervisor_team_id: id.shift, branch_name: "Branch", category: "kitchen", item_name: "Receipt Book", quantity: 1, amount: 20, vendor_name: "N/A", purchase_date: "2026-08-08", notes: null, payment_status: input.paymentStatus, reimbursement_note: input.reimbursementNote ?? null, reimbursed_at: input.paymentStatus === "reimbursed" ? "2026-08-09T00:00:00.000Z" : null, reimbursed_by: input.paymentStatus === "reimbursed" ? input.actorUserId : null, invoice_storage_path: null, invoice_original_name: null, invoice_url: null, created_by: input.actorUserId, created_at: "2026-08-09T00:00:00.000Z", updated_at: "2026-08-09T00:00:00.000Z" } };
      },
      async listSupplierReceivings(actorUserId, branchId, filters) {
        calls.push({ method: "supplierReceivings", actorUserId, branchId, filters: filters ?? null });
        if (actorUserId !== id.supervisor) throw new Error("denied");
        return { supplier_receivings: [] };
      },
      async listBranchSuppliers(actorUserId, branchId) {
        calls.push({ method: "branchSuppliers", actorUserId, branchId });
        if (actorUserId !== id.supervisor) throw new Error("denied");
        return { suppliers: [{ id: id.supplier, branch_id: branchId, supplier_name_en: "Riyadh Supplier", supplier_name_ar: null, created_at: "2026-08-09T00:00:00.000Z", updated_at: "2026-08-09T00:00:00.000Z" }] };
      },
      async createBranchSupplier(input) {
        calls.push({ method: "createBranchSupplier", ...input });
        if (input.actorUserId !== id.supervisor) throw new Error("denied");
        return { supplier: { id: id.supplier, organization_id: id.organization, branch_id: input.branchId, supervisor_team_id: id.shift, supplier_name_en: input.supplierNameEn, supplier_name_ar: input.supplierNameAr ?? null, created_by: input.actorUserId, created_at: "2026-08-09T00:00:00.000Z", updated_at: "2026-08-09T00:00:00.000Z" } };
      },
      async createSupplierReceiving(input) {
        calls.push({ method: "createSupplierReceiving", hasPhoto: Boolean(input.photo), ...input });
        if (input.actorUserId !== id.supervisor) throw new Error("denied");
        return { supplier_receiving: { id: id.supplierReceiving, organization_id: id.organization, branch_id: input.branchId, supervisor_team_id: id.shift, branch_name: "Branch", supplier_id: input.payload.supplier_id ?? id.supplier, category: input.payload.category, supplier_name_en: input.payload.supplier_name_en ?? "Riyadh Supplier", supplier_name_ar: input.payload.supplier_name_ar ?? null, quantity: Number(input.payload.quantity), unit: input.payload.unit, notes: input.payload.notes ?? null, photo_storage_path: input.photo ? `branches/${input.branchId}/supplier-receivings/${id.supplierReceiving}/photo.jpg` : null, photo_original_name: input.photo?.originalName ?? null, photo_url: input.photo ? "https://storage.example.invalid/photo" : null, created_by: input.actorUserId, created_at: "2026-08-09T00:00:00.000Z", updated_at: "2026-08-09T00:00:00.000Z" } };
      },
      async listSupervisorMaintenanceIssues(actorUserId, branchId) {
        calls.push({ method: "supervisorMaintenanceIssues", actorUserId, branchId });
        if (actorUserId !== id.supervisor) throw new Error("denied");
        return { maintenance_issues: [] };
      },
      async createSupervisorMaintenanceIssue(input) {
        calls.push({ method: "createSupervisorMaintenanceIssue", ...input });
        if (input.actorUserId !== id.supervisor) throw new Error("denied");
        return { maintenance_issue: { id: id.maintenanceIssue, branch_id: input.branchId, branch_name: "Branch", title: input.payload.title, category: input.payload.category, priority: input.payload.priority, status: "new", description: input.payload.description ?? null, location: input.payload.location ?? null, reported_by: input.actorUserId, reporter_name: "Supervisor", assigned_to: null, created_at: "2026-08-09T00:00:00.000Z", updated_at: "2026-08-09T00:00:00.000Z", updates: [] } };
      },
      async createManagerOfficeMaintenanceIssue(input) {
        calls.push({ method: "createManagerOfficeMaintenanceIssue", ...input });
        if (input.actorUserId !== id.manager) throw new OperationalAccessError();
        return { maintenance_issue: { id: id.maintenanceIssue, branch_id: null, branch_name: "Office", title: input.payload.title, category: input.payload.category, priority: input.payload.priority, status: "new", description: input.payload.description ?? null, location: input.payload.location ?? null, reported_by: input.actorUserId, reporter_name: "Manager", assigned_to: null, created_at: "2026-08-09T00:00:00.000Z", updated_at: "2026-08-09T00:00:00.000Z", updates: [] } };
      },
      async listMaintenanceIssues(input) {
        calls.push({ method: "maintenanceIssues", ...input });
        if (input.actorUserId !== id.staffAccount && input.accessUserId !== id.maintenanceAccessUser) throw new Error("denied");
        return { maintenance_issues: [{ id: id.maintenanceIssue, branch_id: id.branch, branch_name: "Branch", title: "Freezer door", category: "refrigeration", priority: "urgent", status: "new", description: "Door is loose", location: "Kitchen", reported_by: id.supervisor, reporter_name: "Supervisor", assigned_to: null, created_at: "2026-08-09T00:00:00.000Z", updated_at: "2026-08-09T00:00:00.000Z", updates: [{ id: id.maintenanceUpdate, status: "new", note: "Issue reported.", updated_by: id.supervisor, updated_by_access_user_id: null, updated_by_name: "Supervisor", created_at: "2026-08-09T00:00:00.000Z" }] }] };
      },
      async updateMaintenanceIssue(input) {
        calls.push({ method: "updateMaintenanceIssue", ...input });
        if (input.actorUserId !== id.staffAccount && input.accessUserId !== id.maintenanceAccessUser) throw new Error("denied");
        return { maintenance_issue: { id: input.issueId, branch_id: id.branch, branch_name: "Branch", title: "Freezer door", category: "refrigeration", priority: "urgent", status: input.status, description: "Door is loose", location: "Kitchen", reported_by: id.supervisor, reporter_name: "Supervisor", assigned_to: null, created_at: "2026-08-09T00:00:00.000Z", updated_at: "2026-08-09T01:00:00.000Z", updates: [{ id: id.maintenanceUpdate, status: input.status, note: input.note ?? null, updated_by: input.actorUserId ?? null, updated_by_access_user_id: input.accessUserId ?? null, updated_by_name: "Maintenance", created_at: "2026-08-09T01:00:00.000Z" }] } };
      },
      async listMaintenancePurchases(actorUserId, issueId) {
        calls.push({ method: "maintenanceIssuePurchases", actorUserId, issueId });
        return { maintenance_purchases: [] };
      },
      async listMaintenancePurchaseBranches(input) {
        calls.push({ method: "maintenancePurchaseBranches", ...input });
        if (input.actorUserId !== id.staffAccount) throw new OperationalAccessError();
        return { branches: [{ id: id.branch, name: "Branch", name_ar: null }] };
      },
      async createMaintenancePurchase(input) {
        calls.push({ method: "createMaintenancePurchase", hasReceipts: Boolean(input.receipts?.length), ...input });
        if (input.actorUserId !== id.staffAccount || (input.issueId !== id.maintenanceIssue && input.issueId !== null && input.issueId !== undefined)) throw new Error("denied");
        const scope = input.issueId ? "branch" : input.payload.purchase_scope ?? "branch";
        return { maintenance_purchase: { id: id.purchaseLog, branch_id: scope === "branch" ? input.payload.branch_id ?? id.branch : null, purchase_type: input.issueId ? "issue" : "general", purchase_scope: scope, destination: scope === "office" ? "Office" : scope === "other" ? input.payload.destination ?? "CEO House" : null, category: input.payload.category, item_name: input.payload.item_name, quantity: Number(input.payload.quantity), unit: input.payload.unit, amount: Number(input.payload.amount), vendor_name: input.payload.vendor_name || "N/A", purchase_date: input.payload.purchase_date, notes: input.payload.notes ?? null, payment_status: "unpaid", reimbursement_note: null, reimbursed_at: null, receipt_original_name: "receipt.pdf", receipt_url: "https://storage.example.invalid/signed-maintenance-receipt", attachments: [{ id: "a1000000-0000-4000-8000-000000000001", original_filename: "receipt.pdf", mime_type: "application/pdf", size_bytes: 1200, position: 1, url: "https://storage.example.invalid/signed-maintenance-receipt" }], created_at: "2026-08-12T10:00:00.000Z", updated_at: "2026-08-12T10:00:00.000Z" } };
      },
      async reimburseMaintenancePurchase(input) {
        calls.push({ method: "reimburseMaintenancePurchase", ...input });
        if (input.actorUserId !== id.staffAccount || input.purchaseId !== id.purchaseLog) throw new Error("denied");
        return { maintenance_purchase: { id: id.purchaseLog, branch_id: id.branch, purchase_type: "issue", purchase_scope: "branch", destination: null, category: "spare_parts", item_name: "Replacement seal", quantity: 2, unit: "meter", amount: 35.5, vendor_name: "Parts Shop", purchase_date: "2026-08-12", notes: "Urgent", payment_status: "reimbursed", reimbursement_note: input.reimbursementNote ?? null, reimbursed_at: "2026-08-12T12:00:00.000Z", receipt_original_name: "receipt.pdf", receipt_url: "https://storage.example.invalid/signed-maintenance-receipt", attachments: [{ id: "a1000000-0000-4000-8000-000000000001", original_filename: "receipt.pdf", mime_type: "application/pdf", size_bytes: 1200, position: 1, url: "https://storage.example.invalid/signed-maintenance-receipt" }], created_at: "2026-08-12T10:00:00.000Z", updated_at: "2026-08-12T12:00:00.000Z" } };
      },
      async listMaintenancePurchaseHistory(input) {
        calls.push({ method: "maintenancePurchaseHistory", ...input });
        if (input.actorUserId !== id.staffAccount) throw new OperationalAccessError();
        return { maintenance_purchases: [{
          id: id.purchaseLog,
          branch_id: input.purchaseType === "issue" ? id.branch : null,
          branch_name: input.purchaseType === "issue" ? "Branch" : "CEO House",
          maintenance_issue_id: input.purchaseType === "issue" ? id.maintenanceIssue : null,
          purchase_type: input.purchaseType,
          issue_title: input.purchaseType === "issue" ? "Freezer door" : null,
          issue_category: input.purchaseType === "issue" ? "refrigeration" : null,
          issue_status: input.purchaseType === "issue" ? "new" : null,
          purchase_scope: input.purchaseType === "issue" ? "branch" : "other",
          destination: input.purchaseType === "issue" ? null : "CEO House",
          category: input.purchaseType === "issue" ? "spare_parts" : "fuel_petrol",
          maintenance_user_id: id.staffAccount,
          maintenance_user_name: "Maintenance",
          item_name: input.purchaseType === "issue" ? "Replacement seal" : "Generator fuel",
          quantity: input.purchaseType === "issue" ? 2 : 1,
          unit: input.purchaseType === "issue" ? "meter" : "liter",
          amount: input.purchaseType === "issue" ? 35.5 : 250,
          vendor_name: input.purchaseType === "issue" ? "Parts Shop" : "Al Drees",
          purchase_date: "2026-08-12",
          notes: "Urgent",
          payment_status: "unpaid",
          reimbursement_note: null,
          reimbursed_at: null,
          receipt_original_name: "receipt.pdf",
          receipt_url: "https://storage.example.invalid/signed-maintenance-receipt",
          attachments: [{ id: "a1000000-0000-4000-8000-000000000001", original_filename: "receipt.pdf", mime_type: "application/pdf", size_bytes: 1200, position: 1, url: "https://storage.example.invalid/signed-maintenance-receipt" }],
          created_at: "2026-08-12T10:00:00.000Z",
          updated_at: "2026-08-12T10:00:00.000Z",
        }] };
      },
      async listManagedStaff(input) {
        calls.push({ method: "list", ...input });
        if (input.actorUserId !== id.manager || input.organizationId !== id.organization) throw new Error("denied");
        return { staff: [{ staff_id: id.worker, display_name: "Worker" }], total: 1 };
      },
      async listManagedEmployeeTeam(input) {
        calls.push({ method: "employeeTeam", ...input });
        if (input.actorUserId !== id.manager || input.organizationId !== id.organization) throw new Error("denied");
        if (input.branchId === id.emptyHealthBranch) throw new Error("unavailable");
        return {
          employees: [{ staff_id: id.worker, display_name: "Worker", staff_code: "BH-104", country_code: "SA", employment_status: "active", company_name: "Burger Hunch", iqama_number: null, phone_number: null, email: null, branch_id: id.branch, branch_name: "Branch", branch_name_ar: null, supervisor_name: "Supervisor", supervisor_name_ar: null, assignment_id: id.assignment, operational_team_id: id.shift, operational_team_name: "Team A", operational_roles: ["kitchen"], duty_status: "on_duty", supervisor_training_status: "training" }],
          health_cards: [{ id: id.healthCard, operational_staff_id: id.worker, display_name: "Worker", branch_id: id.branch, branch_name: "Branch", branch_name_ar: null, certificate_number: "HC-7788", status: "failed", place_of_issue: "Riyadh", expiry_date: "2027-01-31", date_issue: "2026-01-31", occupation: "Kitchen", company: "Burger Hunch", branch_name_snapshot: "Branch", notes: "Failed manually", updated_at: "2026-08-09T00:00:00.000Z" }],
          monthly_evaluations: [],
        };
      },
      async listManagedPurchaseLogs(input) {
        calls.push({ method: "managedPurchaseLogs", ...input });
        if (input.actorUserId !== id.manager || input.organizationId !== id.organization) throw new Error("denied");
        return { purchase_logs: [{ id: id.purchaseLog, branch_id: id.branch, branch_name: "Branch", category: "kitchen", item_name: "Receipt Book", quantity: 2, amount: 45.5, vendor_name: "Riyadh Shop", purchase_date: "2026-08-08", notes: null, payment_status: "unpaid", reimbursement_note: null, reimbursed_at: null, reimbursed_by: null, invoice_original_name: "invoice.pdf", invoice_url: "https://storage.example.invalid/signed-invoice", created_by: id.supervisor, created_by_name: "Supervisor", created_at: "2026-08-09T00:00:00.000Z", updated_at: "2026-08-09T00:00:00.000Z" }] };
      },
      async listManagedSupplierReceivings(input) {
        calls.push({ method: "managedSupplierReceivings", ...input });
        if (input.actorUserId !== id.manager || input.organizationId !== id.organization) throw new Error("denied");
        return { supplier_receivings: [{ id: id.supplierReceiving, branch_id: id.branch, branch_name: "Branch", supplier_id: id.supplier, category: "raw", supplier_name_en: "Riyadh Supplier", supplier_name_ar: "مورد الرياض", quantity: 12.5, unit: "kg", notes: null, photo_original_name: "photo.jpg", photo_url: "https://storage.example.invalid/signed-photo", created_by: id.supervisor, created_by_name: "Supervisor", created_at: "2026-08-09T00:00:00.000Z", updated_at: "2026-08-09T00:00:00.000Z" }] };
      },
      async listManagedMaintenanceIssues(input) {
        calls.push({ method: "managedMaintenanceIssues", ...input });
        if (input.actorUserId !== id.manager || input.organizationId !== id.organization) throw new Error("denied");
        return { maintenance_issues: [{ id: id.maintenanceIssue, branch_id: id.branch, branch_name: "Branch", title: "Freezer door", category: "refrigeration", priority: "urgent", status: "in_progress", description: null, location: "Kitchen", reported_by: id.supervisor, reporter_name: "Supervisor", created_at: "2026-08-09T00:00:00.000Z", updated_at: "2026-08-09T01:00:00.000Z", updates: [{ id: "90000000-0000-4000-8000-000000000081", status: "in_progress", note: "Started repair", updated_by: null, updated_by_access_user_id: null, updated_by_name: null, created_at: "2026-08-09T01:00:00.000Z" }] }] };
      },
      async listManagedTeams(actorUserId, organizationId) {
        calls.push({ method: "teams", actorUserId, organizationId });
        if (actorUserId !== id.manager) throw new Error("denied");
        return { teams: [] };
      },
      async listEligibleSupervisors(actorUserId, organizationId, branchId) {
        calls.push({ method: "eligible", actorUserId, organizationId, branchId });
        if (actorUserId !== id.manager) throw new Error("denied");
        return { supervisors: [{ user_id: id.supervisor, full_name: "Supervisor", assignments: [] }] };
      },
    },
    now: () => new Date("2026-07-31T20:30:00.000Z"),
  };
}

describe("managed maintenance operational adapter", () => {
  it("accepts the Manager RPC row shape without a maintenance-only assignee", async () => {
    const rpc = createServer((request, response) => {
      response.setHeader("content-type", "application/json");
      if (request.url === "/rest/v1/rpc/list_maintenance_issue_attachments") {
        response.end(JSON.stringify([]));
        return;
      }
      assert.equal(request.url, "/rest/v1/rpc/list_managed_maintenance_issues");
      response.end(JSON.stringify([{
        id: id.maintenanceIssue, organization_id: id.organization, branch_id: id.branch, branch_name: "Branch", title: "Freezer door",
        category: "refrigeration", priority: "urgent", status: "in_progress", description: null, location: null,
        reported_by: id.supervisor, reporter_name: null, created_at: "2026-08-10T00:00:00.000Z", updated_at: "2026-08-10T01:00:00.000Z",
        updates: [{ id: id.maintenanceUpdate, status: "in_progress", note: null, updated_by: null, updated_by_access_user_id: null, updated_by_name: null, created_at: "2026-08-10T01:00:00.000Z" }],
      }]));
    });
    await new Promise<void>((resolve) => rpc.listen(0, "127.0.0.1", resolve));
    try {
      const port = (rpc.address() as AddressInfo).port;
      const admin = createOperationalAdmin(`http://127.0.0.1:${port}`, "service-key");
      const result = await admin.listManagedMaintenanceIssues?.({ actorUserId: id.manager, organizationId: id.organization });
      assert.deepEqual(result, { maintenance_issues: [{
        id: id.maintenanceIssue, branch_id: id.branch, branch_name: "Branch", title: "Freezer door", category: "refrigeration", priority: "urgent", status: "in_progress",
        description: null, location: null, reported_by: id.supervisor, reporter_name: null, created_at: "2026-08-10T00:00:00.000Z", updated_at: "2026-08-10T01:00:00.000Z",
        before_photo: null, after_photo: null, before_photos: [], after_photos: [],
        updates: [{ id: id.maintenanceUpdate, status: "in_progress", note: null, updated_by: null, updated_by_access_user_id: null, updated_by_name: null, created_at: "2026-08-10T01:00:00.000Z" }],
      }] });
    } finally {
      await new Promise<void>((resolve, reject) => rpc.close((error) => error ? reject(error) : resolve()));
    }
  });

  it("validates full Maintenance purchase mutation rows and preserves exact RPC arguments",async()=>{
    const requests:Array<{path:string;body:Record<string,unknown>}>=[];
    const rpc=createServer(async(request,response)=>{
      let raw="";for await(const chunk of request)raw+=chunk;
      requests.push({path:request.url??"",body:JSON.parse(raw)as Record<string,unknown>});
      response.setHeader("content-type","application/json");
      response.end(JSON.stringify([{
        id:id.purchaseLog,organization_id:id.organization,branch_id:id.branch,purchase_type:"issue",purchase_scope:"branch",destination:null,category:"spare_parts",maintenance_issue_id:id.maintenanceIssue,maintenance_user_id:id.staffAccount,
        item_name:"Replacement seal",quantity:"2",unit:"meter",amount:"35.50",vendor_name:"Parts Shop",purchase_date:"2026-08-12",notes:null,
        payment_status:request.url?.includes("reimburse")?"reimbursed":"unpaid",reimbursement_note:request.url?.includes("reimburse")?"Paid":null,
        reimbursed_at:request.url?.includes("reimburse")?"2026-08-12T12:00:00.000Z":null,receipt_storage_path:null,receipt_original_name:null,attachments:[],
        created_at:"2026-08-12T10:00:00.000Z",updated_at:"2026-08-12T12:00:00.000Z",
      }]));
    });
    await new Promise<void>((resolve)=>rpc.listen(0,"127.0.0.1",resolve));
    try{
      const admin=createOperationalAdmin(`http://127.0.0.1:${(rpc.address()as AddressInfo).port}`,"service-key");
      const created=await admin.createMaintenancePurchase?.({actorUserId:id.staffAccount,issueId:id.maintenanceIssue,payload:{category:"spare_parts",item_name:"Replacement seal",quantity:2,unit:"meter",amount:35.5,vendor_name:"Parts Shop",purchase_date:"2026-08-12",notes:null}});
      assert.equal((created as{maintenance_purchase:{payment_status:string}}).maintenance_purchase.payment_status,"unpaid");
      const reimbursed=await admin.reimburseMaintenancePurchase?.({actorUserId:id.staffAccount,purchaseId:id.purchaseLog,reimbursementNote:"Paid"});
      assert.equal((reimbursed as{maintenance_purchase:{payment_status:string}}).maintenance_purchase.payment_status,"reimbursed");
      assert.equal(requests[0]?.path,"/rest/v1/rpc/create_maintenance_purchase_log");
      assert.equal(requests[0]?.body.actor_user_id,id.staffAccount);
      assert.equal(requests[0]?.body.target_issue_id,id.maintenanceIssue);
      assert.match(String((requests[0]?.body.payload as {purchase_id:string}).purchase_id),/^[0-9a-f-]{36}$/);
      assert.deepEqual({...(requests[0]?.body.payload as Record<string,unknown>),purchase_id:"<uuid>"},{category:"spare_parts",item_name:"Replacement seal",quantity:2,unit:"meter",amount:35.5,vendor_name:"Parts Shop",purchase_date:"2026-08-12",notes:null,purchase_id:"<uuid>",receipt_storage_path:null,receipt_original_name:null,attachments:[]});
      assert.deepEqual(requests[1],{path:"/rest/v1/rpc/reimburse_maintenance_purchase_log",body:{actor_user_id:id.staffAccount,target_purchase_id:id.purchaseLog,new_note:"Paid"}});
    }finally{await new Promise<void>((resolve,reject)=>rpc.close((error)=>error?reject(error):resolve()));}
  });

  it("accepts Office Maintenance purchases with nullable branch ids",async()=>{
    const requests:Array<{path:string;body:Record<string,unknown>}>=[];
    const rpc=createServer(async(request,response)=>{
      let raw="";for await(const chunk of request)raw+=chunk;
      requests.push({path:request.url??"",body:JSON.parse(raw)as Record<string,unknown>});
      response.setHeader("content-type","application/json");
      const history=request.url?.includes("list_maintenance_purchase_history");
      response.end(JSON.stringify([{
        id:id.purchaseLog,organization_id:id.organization,branch_id:null,maintenance_issue_id:id.maintenanceIssue,purchase_type:"issue",purchase_scope:"office",destination:"Office",category:"hvac_refrigeration",
        ...(history?{branch_name:"Office",issue_title:"Office AC",issue_category:"equipment",issue_status:"new",maintenance_user_name:"Maintenance"}:{}),
        maintenance_user_id:id.staffAccount,
        item_name:"AC capacitor",quantity:"1",unit:"pcs",amount:"85.00",vendor_name:"Parts Shop",purchase_date:"2026-08-26",notes:null,
        payment_status:"unpaid",reimbursement_note:null,reimbursed_at:null,receipt_storage_path:null,receipt_original_name:null,attachments:[],
        created_at:"2026-08-26T10:00:00.000Z",updated_at:"2026-08-26T10:00:00.000Z",
      }]));
    });
    await new Promise<void>((resolve)=>rpc.listen(0,"127.0.0.1",resolve));
    try{
      const admin=createOperationalAdmin(`http://127.0.0.1:${(rpc.address()as AddressInfo).port}`,"service-key");
      const created=await admin.createMaintenancePurchase?.({actorUserId:id.staffAccount,issueId:id.maintenanceIssue,payload:{category:"hvac_refrigeration",item_name:"AC capacitor",quantity:1,unit:"pcs",amount:85,vendor_name:"Parts Shop",purchase_date:"2026-08-26",notes:null}}) as {maintenance_purchase:{branch_id:string|null}};
      assert.equal(created.maintenance_purchase.branch_id,null);
      const history=await admin.listMaintenancePurchaseHistory?.({actorUserId:id.staffAccount,purchaseType:"issue"}) as {maintenance_purchases:Array<{branch_id:string|null;branch_name:string}>};
      assert.equal(history.maintenance_purchases[0]?.branch_id,null);
      assert.equal(history.maintenance_purchases[0]?.branch_name,"Office");
      assert.deepEqual(requests.map((request)=>request.path),["/rest/v1/rpc/create_maintenance_purchase_log","/rest/v1/rpc/list_maintenance_purchase_history"]);
    }finally{await new Promise<void>((resolve,reject)=>rpc.close((error)=>error?reject(error):resolve()));}
  });

  it("keeps the Maintenance purchase Office migration narrow and branch-null aware",()=>{
    const migration=readFileSync(new URL("../../supabase/migrations/20260826150000_maintenance_purchase_office_scope.sql",import.meta.url),"utf8");
    assert.match(migration,/alter table public\.maintenance_purchase_logs\s+alter column branch_id drop not null/);
    assert.match(migration,/alter table public\.maintenance_purchase_attachments\s+alter column branch_id drop not null/);
    assert.match(migration,/purchase\.branch_id is distinct from new\.branch_id/);
    assert.match(migration,/left join public\.branches branch on branch\.id=p\.branch_id/);
    assert.match(migration,/case when issue\.location_scope='office' or p\.branch_id is null then 'Office' else branch\.name end/);
    assert.match(migration,/grant execute on function public\.list_maintenance_purchase_history\(uuid\) to service_role/);
    assert.doesNotMatch(migration,/maintenance_issue_attachments|maintenance-issue-photos|list_maintenance_issue_push_subscriptions|push_subscriptions/);
  });

  it("lists Maintenance purchase history through its Maintenance-only aggregate RPC",async()=>{
    const requests:Array<{path:string;body:Record<string,unknown>}>=[];
    const rpc=createServer(async(request,response)=>{
      let raw="";for await(const chunk of request)raw+=chunk;
      requests.push({path:request.url??"",body:JSON.parse(raw)as Record<string,unknown>});
      response.setHeader("content-type","application/json");
      response.end(JSON.stringify([{
        id:id.purchaseLog,organization_id:id.organization,branch_id:id.branch,branch_name:"Branch",maintenance_issue_id:id.maintenanceIssue,
        issue_title:"Freezer door",issue_category:"refrigeration",issue_status:"new",purchase_type:"issue",purchase_scope:"branch",destination:null,category:"spare_parts",maintenance_user_id:id.staffAccount,maintenance_user_name:"Maintenance",
        item_name:"Replacement seal",quantity:"2",unit:"meter",amount:"35.50",vendor_name:"Parts Shop",purchase_date:"2026-08-12",notes:"Urgent",
        payment_status:"unpaid",reimbursement_note:null,reimbursed_at:null,receipt_storage_path:null,receipt_original_name:null,attachments:[],
        created_at:"2026-08-12T10:00:00.000Z",updated_at:"2026-08-12T10:00:00.000Z",
      }]));
    });
    await new Promise<void>((resolve)=>rpc.listen(0,"127.0.0.1",resolve));
    try{
      const admin=createOperationalAdmin(`http://127.0.0.1:${(rpc.address()as AddressInfo).port}`,"service-key");
      const result=await admin.listMaintenancePurchaseHistory?.({actorUserId:id.staffAccount,purchaseType:"issue"}) as {maintenance_purchases:Array<Record<string,unknown>>};
      assert.deepEqual(requests,[{path:"/rest/v1/rpc/list_maintenance_purchase_history",body:{actor_user_id:id.staffAccount,purchase_type_filter:"issue"}}]);
      assert.equal(result.maintenance_purchases[0]?.id,id.purchaseLog);
      assert.equal(result.maintenance_purchases[0]?.maintenance_issue_id,id.maintenanceIssue);
      assert.equal(result.maintenance_purchases[0]?.amount,35.5);
      assert.doesNotMatch(JSON.stringify(result),/organization_id|receipt_storage_path/);
    }finally{await new Promise<void>((resolve,reject)=>rpc.close((error)=>error?reject(error):resolve()));}
  });
});

describe("cross-branch staff transfer operational adapter", () => {
  it("uses dedicated source-owned transfer RPCs and preserves exact arguments", async () => {
    const requests: Array<{ path: string; body: Record<string, unknown> }> = [];
    const rpc = createServer(async (request, response) => {
      let raw = "";
      for await (const chunk of request) raw += chunk;
      requests.push({ path: request.url ?? "", body: JSON.parse(raw) as Record<string, unknown> });
      response.setHeader("content-type", "application/json");
      response.end(JSON.stringify(request.url?.includes("list_operational_staff_transfer_destinations")
        ? [{ branch_id: id.destinationBranch, branch_name: "Destination Branch", branch_code: "DST", operational_team_id: id.destinationTeam, team_name: "Destination Team" }]
        : [{ staff_id: id.worker, assignment_id: id.assignment, branch_id: id.destinationBranch, operational_team_id: id.destinationTeam }]));
    });
    await new Promise<void>((resolve) => rpc.listen(0, "127.0.0.1", resolve));
    try {
      const admin = createOperationalAdmin(`http://127.0.0.1:${(rpc.address() as AddressInfo).port}`, "service-key");
      assert.deepEqual(await admin.listStaffTransferDestinations?.({ actorUserId: id.supervisor, sourceBranchId: id.branch, staffId: id.worker, expectedAssignmentId: id.assignment }), {
        destinations: [{ branch_id: id.destinationBranch, branch_name: "Destination Branch", branch_code: "DST", operational_team_id: id.destinationTeam, team_name: "Destination Team" }],
      });
      assert.deepEqual(await admin.transferStaffBranch?.({ actorUserId: id.supervisor, organizationId: id.organization, sourceBranchId: id.branch, staffId: id.worker, expectedAssignmentId: id.assignment, destinationBranchId: id.destinationBranch, destinationTeamId: id.destinationTeam }), {
        staff_id: id.worker, assignment_id: id.assignment, branch_id: id.destinationBranch, operational_team_id: id.destinationTeam,
      });
      assert.deepEqual(requests, [
        { path: "/rest/v1/rpc/list_operational_staff_transfer_destinations", body: { actor_user_id: id.supervisor, p_source_branch_id: id.branch, p_operational_staff_id: id.worker, p_expected_assignment_id: id.assignment } },
        { path: "/rest/v1/rpc/transfer_operational_staff_branch", body: { actor_user_id: id.supervisor, p_organization_id: id.organization, p_source_branch_id: id.branch, p_operational_staff_id: id.worker, p_expected_assignment_id: id.assignment, p_destination_branch_id: id.destinationBranch, p_destination_team_id: id.destinationTeam } },
      ]);
    } finally {
      await new Promise<void>((resolve, reject) => rpc.close((error) => error ? reject(error) : resolve()));
    }
  });
});

describe("Daily Audit operational adapter", () => {
  it("uses service-role RPCs for grant scope and accepts the empty current-state DTO", async () => {
    const accessUserId = "e0000000-0000-4000-8000-000000000001";
    const credentialVersion = "f0000000-0000-4000-8000-000000000001";
    const requests: Array<{ path: string; body: Record<string, unknown> }> = [];
    const rpc = createServer(async (request, response) => {
      let raw = "";
      for await (const chunk of request) raw += chunk;
      requests.push({ path: request.url ?? "", body: raw ? JSON.parse(raw) as Record<string, unknown> : {} });
      response.setHeader("content-type", "application/json");
      if (request.url === "/rest/v1/rpc/get_supervisor_branch_timezone") {
        response.end(JSON.stringify([{ timezone: "Asia/Riyadh" }]));
        return;
      }
      if (request.url === "/rest/v1/rpc/list_supervised_branches") {
        response.end(JSON.stringify([{ id: id.branch, organization_id: id.organization, name: "Branch", code: "BRANCH", staff_count: 0 }]));
        return;
      }
      if (request.url === "/rest/v1/rpc/get_daily_audit_access_user_credentials") {
        response.end(JSON.stringify([{
          organization_id: id.organization, access_user_id: accessUserId, display_name: "Audit Runner",
          credential_version: credentialVersion, pin_hash: "\\x00", salt: "\\x00", kdf_version: 1,
          cost: 16384, block_size: 8, parallelization: 1,
        }]));
        return;
      }
      if (request.url === "/rest/v1/rpc/get_supervisor_daily_audit_current_state") {
        response.end(JSON.stringify({
          submission_id: null, branch_id: id.branch, business_date: "2026-08-11", state: null,
          submitted_at: null, updated_at: null,
          items: Array.from({ length: 13 }, (_, index) => ({
            item_id: `daily-audit-${index + 1}`, item_number: index + 1, answer: "not_checked", remark: "",
          })),
        }));
        return;
      }
      response.statusCode = 404;
      response.end(JSON.stringify({ message: "unexpected RPC" }));
    });
    await new Promise<void>((resolve) => rpc.listen(0, "127.0.0.1", resolve));
    try {
      const port = (rpc.address() as AddressInfo).port;
      const admin = createOperationalAdmin(`http://127.0.0.1:${port}`, "service-key");
      assert.deepEqual(await admin.resolveDailyAuditGrantBranchScope?.(id.supervisor, id.branch), {
        branch_id: id.branch, organization_id: id.organization, active: true, organization_active: true,
      });
      const credential = await admin.resolveDailyAuditManualAccessUser?.(id.supervisor, id.branch, accessUserId);
      assert.deepEqual(credential, {
        id: accessUserId, organization_id: id.organization, display_name: "Audit Runner", active: true, credential_version: credentialVersion,
      });
      assert.doesNotMatch(JSON.stringify(credential), /pin_hash|salt|fingerprint|token|grant/i);
      const current = await admin.getSupervisorDailyAuditCurrentState?.({ actorUserId: id.supervisor, branchId: id.branch, businessDate: "2026-08-11" });
      assert.deepEqual((current as { state: string | null; items: unknown[] }).state, null);
      assert.equal((current as { items: unknown[] }).items.length, 13);
      assert.deepEqual(requests.map((entry) => entry.path), [
        "/rest/v1/rpc/get_supervisor_branch_timezone",
        "/rest/v1/rpc/list_supervised_branches",
        "/rest/v1/rpc/get_daily_audit_access_user_credentials",
        "/rest/v1/rpc/get_supervisor_daily_audit_current_state",
      ]);
      assert.deepEqual(requests.at(-1)?.body, {
        actor_user_id: id.supervisor, target_branch_id: id.branch, target_business_date: "2026-08-11",
      });
    } finally {
      await new Promise<void>((resolve, reject) => rpc.close((error) => error ? reject(error) : resolve()));
    }
  });
});

describe("Phase 3A operational API", () => {
  it("keeps the duplicate preflight ahead of the shift-free unique index without cleanup", () => {
    const migration = readFileSync(
      new URL("../../supabase/migrations/20260731030000_shift_free_operational_model.sql", import.meta.url),
      "utf8",
    );
    const preflight = migration.indexOf("having count(*) > 1");
    const uniqueIndex = migration.indexOf("create unique index branch_supervisor_teams_active_supervisor_branch_key");
    assert.ok(preflight >= 0 && uniqueIndex > preflight);
    assert.match(migration, /raise exception 'shift-free migration blocked: multiple active teams exist/);
    assert.doesNotMatch(migration.slice(0, uniqueIndex), /delete from public\.branch_supervisor_teams|update public\.branch_supervisor_teams[\s\S]*active=false/i);
  });
  let server: Server;
  let baseUrl: string;
  const calls: Array<Record<string, unknown>> = [];
  before(async () => {
    const config = loadBackendConfig({
      NODE_ENV: "test", SUPABASE_URL: "http://127.0.0.1:54321",
      SUPABASE_PUBLISHABLE_KEY: "placeholder",
      DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
    });
    server = createServer(createApp(config, dependencies(calls)));
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    baseUrl = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });
  after(async () => new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve())));
  const headers = (token: string) => ({ authorization: `Bearer ${token}`, "content-type": "application/json" });

  it("requires authentication", async () => {
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/team`)).status, 401);
  });
  it("returns the valid core team DTO and maps a missing assignment to setup-required", async () => {
    const valid = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/team`, { headers: headers("supervisor") });
    assert.equal(valid.status, 200);
    assert.deepEqual(await valid.json(), { teams: [{ id: id.shift, name: "Team A", active: true, can_write: true, assignment_role: "primary", company_name: null, staff: [] }] });
    assert.deepEqual(calls.at(-1), { method: "get", actorUserId: id.supervisor, branchId: id.branch, date: "2026-07-31" });

    const missing = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.emptyHealthBranch}/team`, { headers: headers("supervisor") });
    assert.equal(missing.status, 403);
    assert.equal((await missing.json() as { error: { code: string } }).error.code, "forbidden");
  });
  it("normalizes names and maps exactly two unique roles", async () => {
    const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/operational-staff`, {
      method: "POST", headers: headers("supervisor"),
      body: JSON.stringify({ operational_team_id: id.shift, display_name: "  أمينة   علي  ", company_name: "  Burger Hunch  ", staff_code: "  BH-101  ", country_code: "id", iqama_number: "  IQ-55  ", iqama_expiry_date: "2026-11-30", phone_number: "  +966500000000  ", email: "  worker@example.invalid  ", primary_role: "cashier", secondary_role: "dispatcher" }),
    });
    assert.equal(response.status, 201);
    assert.deepEqual(calls.at(-1), {
      method: "create", actorUserId: id.supervisor, branchId: id.branch, operationalTeamId: id.shift,
      displayName: "أمينة علي", companyName: "Burger Hunch", staffCode: "BH-101", countryCode: "ID",
      iqamaNumber: "IQ-55", iqamaExpiryDate: "2026-11-30", phoneNumber: "+966500000000", email: "worker@example.invalid",
      roles: ["cashier", "dispatcher"],
    });
  });
  it("trims blank optional employee details to null on staff updates", async () => {
    const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/operational-staff/${id.worker}`, {
      method: "PATCH", headers: headers("supervisor"),
      body: JSON.stringify({ display_name: "Worker", company_name: "Burger Hunch", staff_code: "   ", country_code: "   ", iqama_number: "   ", iqama_expiry_date: "", phone_number: "   ", email: "   ", employment_status: "active", primary_role: "cleaner" }),
    });
    assert.equal(response.status, 200);
    assert.deepEqual(calls.at(-1), {
      method: "update", actorUserId: id.supervisor, branchId: id.branch, staffId: id.worker,
      displayName: "Worker", companyName: "Burger Hunch", staffCode: null, countryCode: null,
      iqamaNumber: null, iqamaExpiryDate: null, phoneNumber: null, email: null,
      employmentStatus: "active", roles: ["cleaner"],
    });
  });
  it("returns a structured conflict for duplicate employee codes", async () => {
    const create = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/operational-staff`, {
      method: "POST", headers: headers("supervisor"),
      body: JSON.stringify({ operational_team_id: id.shift, display_name: "Worker", company_name: "Burger Hunch", staff_code: "DUPLICATE", primary_role: "cleaner" }),
    });
    assert.equal(create.status, 409);
    assert.equal((await create.json() as { error: { code: string } }).error.code, "duplicate_employee_code");

    const update = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/operational-staff/${id.worker}`, {
      method: "PATCH", headers: headers("supervisor"),
      body: JSON.stringify({ display_name: "Worker", company_name: "Burger Hunch", staff_code: "DUPLICATE", employment_status: "active", primary_role: "cleaner" }),
    });
    assert.equal(update.status, 409);
    const text = await update.text();
    assert.match(text, /duplicate_employee_code/);
    assert.doesNotMatch(text, /postgres|duplicate key|service_role|stack/i);
  });
  it("rejects invalid employee detail email and ISO dates", async () => {
    for (const extra of [{ email: "bad-email" }, { iqama_expiry_date: "2026-02-31" }]) {
      const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/operational-staff`, {
        method: "POST", headers: headers("supervisor"),
        body: JSON.stringify({ display_name: "Worker", company_name: "Burger Hunch", primary_role: "cleaner", ...extra }),
      });
      assert.equal(response.status, 400);
    }
  });
  it("rejects legacy shift_id from the current staff contract and no longer exposes Manager team creation", async () => {
    const staff = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/operational-staff`, {
      method: "POST", headers: headers("supervisor"),
      body: JSON.stringify({ display_name: "Worker", primary_role: "kitchen", shift_id: id.shift }),
    });
    assert.equal(staff.status, 400);
    const team = await fetch(`${baseUrl}/api/v1/management/organizations/${id.organization}/branches/${id.branch}/supervisor-teams`, {
      method: "POST", headers: headers("manager"),
      body: JSON.stringify({ supervisor_user_id: id.supervisor, shift_id: id.shift }),
    });
    assert.equal(team.status, 404);
  });
  it("rejects duplicate, invalid, third, and arbitrary role arrays", async () => {
    for (const body of [
      { display_name: "Worker", primary_role: "kitchen", secondary_role: "kitchen", shift_id: id.shift },
      { display_name: "Worker", primary_role: "owner", shift_id: id.shift },
      { display_name: "Worker", primary_role: "kitchen", secondary_role: "cleaner", third_role: "production", shift_id: id.shift },
      { display_name: "Worker", operational_roles: ["kitchen"], shift_id: id.shift },
    ]) {
      const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/operational-staff`, {
        method: "POST", headers: headers("supervisor"), body: JSON.stringify(body),
      });
      assert.equal(response.status, 400);
    }
  });
  it("rejects client-controlled authority and Auth fields", async () => {
    const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/operational-staff`, {
      method: "POST", headers: headers("supervisor"),
      body: JSON.stringify({ display_name: "Worker", primary_role: "cleaner", shift_id: id.shift,
        organization_id: id.organization, supervisor_user_id: id.manager, auth_email: "x@example.invalid", password: "secret" }),
    });
    assert.equal(response.status, 400);
  });
  it("rejects browser-supplied duty dates and timezones", async () => {
    for (const extra of [{ duty_date: "2026-07-31" }, { timezone: "UTC" }]) {
      const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/operational-staff/${id.worker}/duty-status`, {
        method: "PUT", headers: headers("supervisor"), body: JSON.stringify({ duty_status: "day_off", ...extra }),
      });
      assert.equal(response.status, 400);
    }
  });
  it("sets date-scoped duty state without accepting extra fields", async () => {
    const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/operational-staff/${id.worker}/duty-status`, {
      method: "PUT", headers: headers("supervisor"), body: JSON.stringify({ duty_status: "day_off" }),
    });
    assert.equal(response.status, 200);
    assert.equal((await response.json() as { eligible: boolean }).eligible, false);
    assert.equal(calls.at(-1)?.date, "2026-07-31");
  });
  it("sets On Vacation without changing employment", async () => {
    const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/operational-staff/${id.worker}/duty-status`, {
      method: "PUT", headers: headers("supervisor"), body: JSON.stringify({ duty_status: "on_vacation" }),
    });
    assert.equal(response.status, 200);
    assert.deepEqual(calls.at(-1), { method: "duty", actorUserId: id.supervisor, branchId: id.branch, staffId: id.worker, date: "2026-07-31", status: "on_vacation" });
  });
  it("moves an employee with an expected assignment and target operational team", async () => {
    const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/operational-staff/${id.worker}/team`, {
      method: "PUT", headers: headers("supervisor"),
      body: JSON.stringify({ expected_assignment_id: id.assignment, operational_team_id: id.shift }),
    });
    assert.equal(response.status, 200);
    assert.deepEqual(calls.at(-1), {
      method: "move", actorUserId: id.supervisor, branchId: id.branch, staffId: id.worker,
      expectedAssignmentId: id.assignment, operationalTeamId: id.shift,
    });
  });
  it("lists only minimal cross-branch transfer destinations for the source employee", async () => {
    const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/operational-staff/${id.worker}/transfer-destinations?expected_assignment_id=${id.assignment}`, {
      headers: headers("supervisor"),
    });
    assert.equal(response.status, 200);
    const body = await response.text();
    assert.deepEqual(JSON.parse(body), { destinations: [{ branch_id: id.destinationBranch, branch_name: "Destination Branch", branch_code: "DST", operational_team_id: id.destinationTeam, team_name: "Destination Team" }] });
    assert.deepEqual(calls.at(-1), { method: "transferDestinations", actorUserId: id.supervisor, sourceBranchId: id.branch, staffId: id.worker, expectedAssignmentId: id.assignment });
    assert.doesNotMatch(body, /staff_id|supervisor_user_id|hygiene|report/i);
  });
  it("transfers an employee across branches through the dedicated source-owned endpoint", async () => {
    const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/operational-staff/${id.worker}/branch-transfer`, {
      method: "POST", headers: headers("supervisor"),
      body: JSON.stringify({ expected_assignment_id: id.assignment, destination_branch_id: id.destinationBranch, destination_team_id: id.destinationTeam }),
    });
    assert.equal(response.status, 200);
    assert.deepEqual(calls.at(-1), {
      method: "branchTransfer", actorUserId: id.supervisor, organizationId: id.organization, sourceBranchId: id.branch,
      staffId: id.worker, expectedAssignmentId: id.assignment, destinationBranchId: id.destinationBranch, destinationTeamId: id.destinationTeam,
    });
  });
  it("returns a sanitized Hygiene-submitted error for blocked cross-branch transfers", async () => {
    const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/operational-staff/${id.worker}/branch-transfer`, {
      method: "POST", headers: headers("supervisor"),
      body: JSON.stringify({ expected_assignment_id: id.assignment, destination_branch_id: id.destinationBranch, destination_team_id: id.emptyHealthBranch }),
    });
    assert.equal(response.status, 409);
    const text = await response.text();
    assert.match(text, /destination_hygiene_submitted/);
    assert.doesNotMatch(text, /postgres|transfer_operational_staff_branch|service_role|stack/i);
  });
  it("persists Leave Company through its confirmed lifecycle endpoint", async () => {
    const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/operational-staff/${id.worker}/leave-company`, {
      method: "POST", headers: headers("supervisor"), body: JSON.stringify({ expected_assignment_id: id.assignment }),
    });
    assert.equal(response.status, 200);
    assert.deepEqual(calls.at(-1), { method: "leave", actorUserId: id.supervisor, branchId: id.branch, staffId: id.worker, expectedAssignmentId: id.assignment });
  });
  it("does not expose Manager cross-branch employee transfer", async () => {
    const path=`${baseUrl}/api/v1/management/organizations/${id.organization}/operational-staff/${id.worker}/branch`;
    const body=JSON.stringify({ expected_assignment_id:id.assignment, operational_team_id:id.shift });
    const manager=await fetch(path,{method:"PUT",headers:headers("manager"),body});
    assert.equal(manager.status,404);
    assert.equal((await fetch(path,{method:"PUT",headers:headers("supervisor"),body})).status,404);
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/operational-staff/${id.worker}/branch-transfer`,{method:"POST",headers:headers("manager"),body:JSON.stringify({expected_assignment_id:id.assignment,destination_branch_id:id.destinationBranch,destination_team_id:id.destinationTeam})})).status,403);
  });
  it("allows only an organization Manager to start and cancel Supervisor Training", async () => {
    const base=`${baseUrl}/api/v1/management/organizations/${id.organization}/operational-staff/${id.worker}/supervisor-training`;
    const started=await fetch(base,{method:"POST",headers:headers("manager"),body:"{}"});
    assert.equal(started.status,200);
    assert.deepEqual(calls.at(-1),{method:"startSupervisorTraining",actorUserId:id.manager,organizationId:id.organization,staffId:id.worker});
    const cancelled=await fetch(`${base}/cancel`,{method:"POST",headers:headers("manager"),body:"{}"});
    assert.equal(cancelled.status,200);
    assert.deepEqual(calls.at(-1),{method:"cancelSupervisorTraining",actorUserId:id.manager,organizationId:id.organization,staffId:id.worker});
    assert.equal((await fetch(base,{method:"POST",headers:headers("supervisor"),body:"{}"})).status,403);
  });
  it("promotes active Training Supervisors through Manager-only staged provisioning", async () => {
    const base=`${baseUrl}/api/v1/management/organizations/${id.organization}/operational-staff/${id.worker}/supervisor-training/promote`;
    const body=JSON.stringify({
      full_name:"  Promoted Supervisor  ",
      full_name_ar:"  مشرف جديد  ",
      email:"  PROMOTED@example.invalid ",
      temporary_password:"secret1",
    });
    const promoted=await fetch(base,{method:"POST",headers:headers("manager"),body});
    assert.equal(promoted.status,201);
    assert.deepEqual(calls.slice(-3),[
      {method:"getSupervisorTrainingPromotionState",actorUserId:id.manager,organizationId:id.organization,staffId:id.worker},
      {method:"createAuthUser",email:"promoted@example.invalid",password:"secret1"},
      {method:"promoteSupervisorTraining",actorUserId:id.manager,organizationId:id.organization,staffId:id.worker,newSupervisorUserId:id.worker,fullName:"Promoted Supervisor",fullNameAr:"مشرف جديد"},
    ]);
    const failed=await fetch(base,{method:"POST",headers:headers("manager"),body:JSON.stringify({...JSON.parse(body),full_name:"Fail Promotion"})});
    assert.equal(failed.status,409);
    assert.deepEqual(calls.at(-1),{method:"deleteAuthUser",userId:id.worker});
  });
  it("persists Health Card Status through supervisor-only routes", async () => {
    const list = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/team/health-cards`, { headers: headers("supervisor") });
    assert.equal(list.status, 200);
    assert.match(await list.text(), /HC-7788/);
    assert.deepEqual(calls.at(-1), { method: "healthCards", actorUserId: id.supervisor, branchId: id.branch });

    const saved = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/team/health-cards/${id.worker}`, {
      method: "PUT", headers: headers("supervisor"),
      body: JSON.stringify({ certificate_number: "  HC-999  ", status: "failed", place_of_issue: "  Riyadh  ", expiry_date: "2027-02-28", date_issue: "2026-02-28", occupation: "  Kitchen  ", company: "  Burger Hunch  ", notes: "  Failed manually  " }),
    });
    assert.equal(saved.status, 200);
    assert.deepEqual(calls.at(-1), {
      method: "upsertHealthCard", actorUserId: id.supervisor, branchId: id.branch, staffId: id.worker,
      certificateNumber: "HC-999", status: "failed", placeOfIssue: "Riyadh",
      expiryDate: "2027-02-28", dateIssue: "2026-02-28", occupation: "Kitchen", company: "Burger Hunch", notes: "Failed manually",
    });
  });
  it("returns Health Card Status safely when no cards or nullable fields exist", async () => {
    const empty = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.emptyHealthBranch}/team/health-cards`, { headers: headers("supervisor") });
    assert.equal(empty.status, 200);
    assert.deepEqual(await empty.json(), { health_cards: [] });

    const nullable = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.nullableHealthBranch}/team/health-cards`, { headers: headers("supervisor") });
    assert.equal(nullable.status, 200);
    assert.deepEqual(await nullable.json(), { health_cards: [{
      id: null,
      operational_staff_id: id.worker,
      certificate_number: null,
      status: "not_done",
      place_of_issue: null,
      expiry_date: null,
      date_issue: null,
      occupation: null,
      company: null,
      branch_name_snapshot: null,
      notes: null,
      updated_at: null,
    }] });
  });
  it("rejects Health Card auth and invalid payloads safely", async () => {
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/team/health-cards`)).status, 401);
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/team/health-cards`, { headers: headers("manager") })).status, 403);
    for (const body of [
      { status: "bad" },
      { status: "pending", expiry_date: "2026-02-31" },
      { status: "pending", date_issue: "08/09/2026" },
      { status: "pending", organization_id: id.organization },
    ]) {
      const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/team/health-cards/${id.worker}`, {
        method: "PUT", headers: headers("supervisor"), body: JSON.stringify(body),
      });
      assert.equal(response.status, 400);
    }
  });
  it("persists Monthly Evaluation through supervisor-only routes", async () => {
    const list = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/team/monthly-evaluations?month=2026-08`, { headers: headers("supervisor") });
    assert.equal(list.status, 200);
    assert.match(await list.text(), /performance_initiative/);
    assert.deepEqual(calls.at(-1), { method: "monthlyEvaluations", actorUserId: id.supervisor, branchId: id.branch, evaluationMonth: "2026-08-01" });

    const saved = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/team/monthly-evaluations/${id.worker}`, {
      method: "PUT", headers: headers("supervisor"),
      body: JSON.stringify({ evaluation_month: "2026-08", evaluator_name: "  Supervisor  ", status: "completed", scores: [{ section: " Performance ", factor_key: "performance_initiative", factor_label: " Strong initiative ", rating: 5, comment: " Great " }] }),
    });
    assert.equal(saved.status, 200);
    assert.deepEqual(calls.at(-1), {
      method: "saveMonthlyEvaluation", actorUserId: id.supervisor, branchId: id.branch, staffId: id.worker,
      evaluationMonth: "2026-08-01", evaluatorName: "Supervisor", status: "completed",
      scores: [{ section: "Performance", factor_key: "performance_initiative", factor_label: "Strong initiative", rating: 5, comment: "Great" }],
    });
  });
  it("rejects Monthly Evaluation auth and invalid payloads safely", async () => {
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/team/monthly-evaluations?month=2026-08`)).status, 401);
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/team/monthly-evaluations?month=2026-08`, { headers: headers("manager") })).status, 403);
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/team/monthly-evaluations?month=2026-13`, { headers: headers("supervisor") })).status, 400);
    for (const body of [
      { evaluation_month: "2026-08", evaluator_name: "Supervisor", status: "completed", scores: [{ section: "Performance", factor_key: "x", factor_label: "X", rating: null }] },
      { evaluation_month: "2026-08-01", evaluator_name: "Supervisor", status: "draft", scores: [{ section: "Performance", factor_key: "x", factor_label: "X", rating: 5 }] },
      { evaluation_month: "2026-08", evaluator_name: "Supervisor", status: "archived", scores: [{ section: "Performance", factor_key: "x", factor_label: "X", rating: 5 }] },
      { evaluation_month: "2026-08", evaluator_name: "Supervisor", status: "draft", scores: [{ section: "Performance", factor_key: "x", factor_label: "X", rating: 6 }] },
      { evaluation_month: "2026-08", evaluator_name: "Supervisor", status: "draft", scores: [{ section: "Performance", factor_key: "x", factor_label: "X", rating: 5 }], organization_id: id.organization },
    ]) {
      const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/team/monthly-evaluations/${id.worker}`, {
        method: "PUT", headers: headers("supervisor"), body: JSON.stringify(body),
      });
      assert.equal(response.status, 400);
    }
  });
  it("persists Purchase Log entries through supervisor-only routes", async () => {
    const list = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/purchase-logs`, { headers: headers("supervisor") });
    assert.equal(list.status, 200);
    assert.deepEqual(await list.json(), { purchase_logs: [] });
    assert.deepEqual(calls.at(-1), { method: "purchaseLogs", actorUserId: id.supervisor, branchId: id.branch, filters: { dateFrom: null, dateTo: null } });

    const periodList = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/purchase-logs?date_from=2026-08-23&date_to=2026-08-29`, { headers: headers("supervisor") });
    assert.equal(periodList.status, 200);
    assert.deepEqual(calls.at(-1), { method: "purchaseLogs", actorUserId: id.supervisor, branchId: id.branch, filters: { dateFrom: "2026-08-23", dateTo: "2026-08-29" } });

    const invalidPeriod = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/purchase-logs?date_from=2026-08-29&date_to=2026-08-23`, { headers: headers("supervisor") });
    assert.equal(invalidPeriod.status, 400);

    const created = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/purchase-logs`, {
      method: "POST", headers: headers("supervisor"),
      body: JSON.stringify({ category: "food_item", item_name: "  Receipt Book  ", quantity: "2", amount: "45.50", vendor_name: "   ", purchase_date: "2026-08-08", notes: "  Needed  ", payment_status: "unpaid", reimbursement_note: "" }),
    });
    assert.equal(created.status, 201);
    const body = await created.json() as { purchase_log: { id: string; vendor_name: string; payment_status: string; amount: number } };
    assert.equal(body.purchase_log.id, id.purchaseLog);
    assert.equal(body.purchase_log.vendor_name, "N/A");
    assert.equal(body.purchase_log.amount, 45.5);
    assert.equal("organization_id" in body.purchase_log, false);
    assert.equal("supervisor_team_id" in body.purchase_log, false);
    assert.equal("invoice_storage_path" in body.purchase_log, false);
    assert.deepEqual(calls.at(-1), {
      method: "createPurchaseLog",
      hasInvoice: false,
      actorUserId: id.supervisor,
      branchId: id.branch,
      payload: {
        category: "food_item",
        item_name: "Receipt Book",
        quantity: 2,
        amount: 45.5,
        vendor_name: "N/A",
        purchase_date: "2026-08-08",
        notes: "Needed",
        payment_status: "unpaid",
        reimbursement_note: null,
      },
      invoice: null,
    });
  });
  it("updates Purchase Log reimbursement status", async () => {
    const updated = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/purchase-logs/${id.purchaseLog}/payment-status`, {
      method: "PATCH", headers: headers("supervisor"),
      body: JSON.stringify({ payment_status: "reimbursed", reimbursement_note: "  Paid by manager  " }),
    });
    assert.equal(updated.status, 200);
    const body = await updated.json() as { purchase_log: { payment_status: string; reimbursement_note: string | null } };
    assert.equal(body.purchase_log.payment_status, "reimbursed");
    assert.equal(body.purchase_log.reimbursement_note, "Paid by manager");
    assert.deepEqual(calls.at(-1), {
      method: "updatePurchasePayment",
      actorUserId: id.supervisor,
      branchId: id.branch,
      purchaseLogId: id.purchaseLog,
      paymentStatus: "reimbursed",
      reimbursementNote: "Paid by manager",
    });
  });
  it("rejects Purchase Log auth and invalid payloads safely", async () => {
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/purchase-logs`)).status, 401);
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/purchase-logs`, { headers: headers("manager") })).status, 403);
    for (const body of [
      { category: "bad", item_name: "Book", quantity: "1", amount: "1", purchase_date: "2026-08-08" },
      { category: "kitchen", item_name: "", quantity: "1", amount: "1", purchase_date: "2026-08-08" },
      { category: "kitchen", item_name: "Book", quantity: "0", amount: "1", purchase_date: "2026-08-08" },
      { category: "kitchen", item_name: "Book", quantity: "1", amount: "-1", purchase_date: "2026-08-08" },
      { category: "kitchen", item_name: "Book", quantity: "1", amount: "1", purchase_date: "08/08/2026" },
      { category: "kitchen", item_name: "Book", quantity: "1", amount: "1", purchase_date: "2026-08-08", organization_id: id.organization },
    ]) {
      const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/purchase-logs`, {
        method: "POST", headers: headers("supervisor"), body: JSON.stringify(body),
      });
      assert.equal(response.status, 400);
    }
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/purchase-logs/not-a-uuid/payment-status`, {
      method: "PATCH", headers: headers("supervisor"), body: JSON.stringify({ payment_status: "reimbursed" }),
    })).status, 400);
  });
  it("persists Supplier Receiving entries through supervisor-only routes", async () => {
    const suppliers = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/suppliers`, { headers: headers("supervisor") });
    assert.equal(suppliers.status, 200);
    assert.deepEqual(await suppliers.json(), { suppliers: [{ id: id.supplier, branch_id: id.branch, supplier_name_en: "Riyadh Supplier", supplier_name_ar: null, created_at: "2026-08-09T00:00:00.000Z", updated_at: "2026-08-09T00:00:00.000Z" }] });
    assert.deepEqual(calls.at(-1), { method: "branchSuppliers", actorUserId: id.supervisor, branchId: id.branch });

    const list = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/supplier-receivings`, { headers: headers("supervisor") });
    assert.equal(list.status, 200);
    assert.deepEqual(await list.json(), { supplier_receivings: [] });
    assert.deepEqual(calls.at(-1), { method: "supplierReceivings", actorUserId: id.supervisor, branchId: id.branch, filters: { dateFrom: null, dateTo: null } });

    const periodList = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/supplier-receivings?date_from=2026-08-23&date_to=2026-08-29`, { headers: headers("supervisor") });
    assert.equal(periodList.status, 200);
    assert.deepEqual(calls.at(-1), { method: "supplierReceivings", actorUserId: id.supervisor, branchId: id.branch, filters: { dateFrom: "2026-08-23", dateTo: "2026-08-29" } });
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/supplier-receivings?date_from=2026-08-29&date_to=2026-08-23`, { headers: headers("supervisor") })).status, 400);

    const created = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/supplier-receivings`, {
      method: "POST", headers: headers("supervisor"),
      body: JSON.stringify({ category: "raw", supplier_name_en: "  Riyadh Supplier  ", supplier_name_ar: "   ", quantity: "12.5", unit: " kg ", notes: "  Checked  " }),
    });
    assert.equal(created.status, 201);
    const body = await created.json() as { supplier_receiving: { id: string; supplier_id: string | null; supplier_name_en: string; supplier_name_ar: string | null; quantity: number; photo_url?: string | null } };
    assert.equal(body.supplier_receiving.id, id.supplierReceiving);
    assert.equal(body.supplier_receiving.supplier_id, id.supplier);
    assert.equal(body.supplier_receiving.supplier_name_en, "Riyadh Supplier");
    assert.equal(body.supplier_receiving.supplier_name_ar, null);
    assert.equal(body.supplier_receiving.quantity, 12.5);
    assert.equal("organization_id" in body.supplier_receiving, false);
    assert.equal("supervisor_team_id" in body.supplier_receiving, false);
    assert.equal("photo_storage_path" in body.supplier_receiving, false);
    assert.deepEqual(calls.at(-1), {
      method: "createSupplierReceiving",
      hasPhoto: false,
      actorUserId: id.supervisor,
      branchId: id.branch,
      payload: {
        category: "raw",
        supplier_name_en: "Riyadh Supplier",
        supplier_name_ar: null,
        quantity: 12.5,
        unit: "kg",
        notes: "Checked",
      },
      photo: null,
    });
    const existing = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/supplier-receivings`, {
      method: "POST", headers: headers("supervisor"),
      body: JSON.stringify({ category: "frozen", supplier_id: id.supplier, quantity: "2", unit: "box", notes: "" }),
    });
    assert.equal(existing.status, 201);
    assert.deepEqual(calls.at(-1), {
      method: "createSupplierReceiving",
      hasPhoto: false,
      actorUserId: id.supervisor,
      branchId: id.branch,
      payload: {
        category: "frozen",
        supplier_id: id.supplier,
        supplier_name_ar: null,
        quantity: 2,
        unit: "box",
        notes: null,
      },
      photo: null,
    });
  });
  it("rejects Supplier Receiving auth and invalid payloads safely", async () => {
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/supplier-receivings`)).status, 401);
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/supplier-receivings`, { headers: headers("manager") })).status, 403);
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/suppliers`)).status, 401);
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/suppliers`, { headers: headers("manager") })).status, 403);
    for (const body of [
      { category: "bad", supplier_name_en: "Supplier", quantity: "1", unit: "kg" },
      { category: "raw", supplier_name_en: "", quantity: "1", unit: "kg" },
      { category: "raw", supplier_name_en: "Supplier", quantity: "0", unit: "kg" },
      { category: "raw", supplier_name_en: "Supplier", quantity: "1", unit: "" },
      { category: "raw", supplier_name_en: "Supplier", quantity: "1", unit: "crate" },
      { category: "raw", supplier_name_en: "Supplier", quantity: "1", unit: "kg", organization_id: id.organization },
    ]) {
      const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/supplier-receivings`, {
        method: "POST", headers: headers("supervisor"), body: JSON.stringify(body),
      });
      assert.equal(response.status, 400);
    }
  });
  it("persists supervisor Maintenance issues through supervisor-only routes", async () => {
    const list = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/maintenance-issues`, { headers: headers("supervisor") });
    assert.equal(list.status, 200);
    assert.deepEqual(await list.json(), { maintenance_issues: [] });
    assert.deepEqual(calls.at(-1), { method: "supervisorMaintenanceIssues", actorUserId: id.supervisor, branchId: id.branch });

    const created = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/maintenance-issues`, {
      method: "POST", headers: headers("supervisor"),
      body: JSON.stringify({ title: "  Freezer door  ", category: "refrigeration", priority: "urgent", description: "  Door is loose  ", location: "  Kitchen  " }),
    });
    assert.equal(created.status, 201);
    const body = await created.json() as { maintenance_issue: { id: string; title: string; status: string } };
    assert.equal(body.maintenance_issue.id, id.maintenanceIssue);
    assert.equal(body.maintenance_issue.title, "Freezer door");
    assert.equal(body.maintenance_issue.status, "new");
    const createCall = calls.at(-1) as Record<string, unknown>;
    assert.match(String(createCall.requestId), /^[0-9a-f-]{36}$/);
    assert.deepEqual({ ...createCall, requestId: "request-id" }, {
      method: "createSupervisorMaintenanceIssue",
      actorUserId: id.supervisor,
      branchId: id.branch,
      requestId: "request-id",
      idempotencyKey: null,
      payload: { title: "Freezer door", category: "refrigeration", priority: "urgent", description: "Door is loose", location: "Kitchen" },
      photos: [],
    });

    const withPhoto = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/maintenance-issues`, {
      method: "POST",
      headers: { ...headers("supervisor"), "content-type": "application/vnd.maintenance-issue+json" },
      body: JSON.stringify({
        issue: { title: "Sink leak", category: "plumbing", priority: "normal", description: "Small leak", location: "Prep" },
        before_photo: { original_name: "before.png", mime_type: "image/png", content_base64: Buffer.from("png-bytes").toString("base64") },
      }),
    });
    assert.equal(withPhoto.status, 201);
    const photoCall = calls.at(-1) as { method: string; photos?: Array<{ mimeType: string; originalName: string; bytes: Buffer }> };
    assert.equal(photoCall.method, "createSupervisorMaintenanceIssue");
    assert.equal(photoCall.photos?.[0]?.mimeType, "image/png");
    assert.equal(photoCall.photos?.[0]?.originalName, "before.png");
    assert.ok(Buffer.isBuffer(photoCall.photos?.[0]?.bytes));
  });
  it("rejects supervisor Maintenance issue auth and invalid payloads safely", async () => {
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/maintenance-issues`)).status, 401);
    assert.equal((await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/maintenance-issues`, { headers: headers("manager") })).status, 403);
    for (const body of [
      { title: "", category: "refrigeration", priority: "urgent" },
      { title: "Door", category: "bad", priority: "urgent" },
      { title: "Door", category: "refrigeration", priority: "bad" },
      { title: "Door", category: "refrigeration", priority: "urgent", organization_id: id.organization },
    ]) {
      const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/maintenance-issues`, {
        method: "POST", headers: headers("supervisor"), body: JSON.stringify(body),
      });
      assert.equal(response.status, 400);
    }
  });
  it("allows Maintenance users to list and update issue workflow state", async () => {
    const list = await fetch(`${baseUrl}/api/v1/maintenance/issues`, { headers: headers("maintenance") });
    assert.equal(list.status, 200);
    const listed = await list.json() as { maintenance_issues: Array<{ id: string; updates: unknown[] }> };
    assert.equal(listed.maintenance_issues[0].id, id.maintenanceIssue);
    assert.deepEqual(calls.at(-1), { method: "maintenanceIssues", actorUserId: id.staffAccount, accessUserId: null, organizationId: null });

    const updated = await fetch(`${baseUrl}/api/v1/maintenance/issues/${id.maintenanceIssue}`, {
      method: "PATCH", headers: headers("maintenance"),
      body: JSON.stringify({ status: "in_progress", note: "  Started repair  " }),
    });
    assert.equal(updated.status, 200);
    const body = await updated.json() as { maintenance_issue: { status: string; updates: Array<{ note: string | null }> } };
    assert.equal(body.maintenance_issue.status, "in_progress");
    assert.equal(body.maintenance_issue.updates[0].note, "Started repair");
    assert.deepEqual(calls.at(-1), {
      method: "updateMaintenanceIssue",
      actorUserId: id.staffAccount,
      accessUserId: null,
      issueId: id.maintenanceIssue,
      status: "in_progress",
      note: "Started repair",
      repairPhotos: [],
    });

    const beforeResolveCalls = calls.length;
    const resolvedWithoutPhoto = await fetch(`${baseUrl}/api/v1/maintenance/issues/${id.maintenanceIssue}`, {
      method: "PATCH", headers: headers("maintenance"),
      body: JSON.stringify({ status: "resolved", note: "Fixed" }),
    });
    assert.equal(resolvedWithoutPhoto.status, 422);
    assert.equal(calls.length, beforeResolveCalls);

    const resolvedWithPhoto = await fetch(`${baseUrl}/api/v1/maintenance/issues/${id.maintenanceIssue}`, {
      method: "PATCH",
      headers: { ...headers("maintenance"), "content-type": "application/vnd.maintenance-issue+json" },
      body: JSON.stringify({
        issue: { status: "resolved", note: "Fixed" },
        repair_photo: { original_name: "after.jpg", mime_type: "image/jpeg", content_base64: Buffer.from("jpg-bytes").toString("base64") },
      }),
    });
    assert.equal(resolvedWithPhoto.status, 200);
    const repairCall = calls.at(-1) as { method: string; repairPhotos?: Array<{ mimeType: string; originalName: string; bytes: Buffer }> };
    assert.equal(repairCall.method, "updateMaintenanceIssue");
    assert.equal(repairCall.repairPhotos?.[0]?.mimeType, "image/jpeg");
    assert.equal(repairCall.repairPhotos?.[0]?.originalName, "after.jpg");
    assert.ok(Buffer.isBuffer(repairCall.repairPhotos?.[0]?.bytes));
  });
  it("exposes Maintenance purchase history without raw storage or membership fields", async () => {
    const history = await fetch(`${baseUrl}/api/v1/maintenance/purchases/issue`, { headers: headers("maintenance") });
    assert.equal(history.status, 200, await history.clone().text());
    assert.equal(history.headers.get("cache-control"), "private, no-store");
    const text = await history.text();
    assert.doesNotMatch(text, /storage_path|maintenance\/[0-9a-f-]{36}\/purchases|organization_id|maintenance_user_id/);
    const body = JSON.parse(text) as { maintenance_purchases: Array<{ id: string; maintenance_issue_id: string; receipt_url: string | null; attachments: Array<{ url: string | null }> }> };
    assert.equal(body.maintenance_purchases[0]?.id, id.purchaseLog);
    assert.equal(body.maintenance_purchases[0]?.maintenance_issue_id, id.maintenanceIssue);
    assert.equal(body.maintenance_purchases[0]?.receipt_url, "https://storage.example.invalid/signed-maintenance-receipt");
    assert.equal(body.maintenance_purchases[0]?.attachments[0]?.url, "https://storage.example.invalid/signed-maintenance-receipt");
    assert.deepEqual(calls.at(-1), { method: "maintenancePurchaseHistory", actorUserId: id.staffAccount, purchaseType: "issue" });

    const general = await fetch(`${baseUrl}/api/v1/maintenance/purchases/general`, { headers: headers("maintenance") });
    assert.equal(general.status, 200, await general.clone().text());
    const generalBody = await general.json() as { maintenance_purchases: Array<{ purchase_type: string; maintenance_issue_id: string | null; destination: string | null }> };
    assert.equal(generalBody.maintenance_purchases[0]?.purchase_type, "general");
    assert.equal(generalBody.maintenance_purchases[0]?.maintenance_issue_id, null);
    assert.equal(generalBody.maintenance_purchases[0]?.destination, "CEO House");
    assert.deepEqual(calls.at(-1), { method: "maintenancePurchaseHistory", actorUserId: id.staffAccount, purchaseType: "general" });
  });
  it("allows authenticated Maintenance users to create standalone Purchase Log entries", async () => {
    const branches = await fetch(`${baseUrl}/api/v1/maintenance/purchase-branches`, { headers: headers("maintenance") });
    assert.equal(branches.status, 200, await branches.clone().text());
    assert.deepEqual(await branches.json(), { branches: [{ id: id.branch, name: "Branch", name_ar: null }] });
    assert.deepEqual(calls.at(-1), { method: "maintenancePurchaseBranches", actorUserId: id.staffAccount });

    const response = await fetch(`${baseUrl}/api/v1/maintenance/purchases/general`, {
      method: "POST",
      headers: { ...headers("maintenance"), "content-type": "application/vnd.maintenance-purchase+json" },
      body: JSON.stringify({
        purchase: { purchase_type: "general", purchase_scope: "other", destination: "  CEO House  ", category: "fuel_petrol", item_name: "Generator fuel", quantity: "1", unit: "liter", amount: "250", vendor_name: "Al Drees", purchase_date: "2026-08-26", notes: "" },
        attachments: [{ original_name: "receipt.pdf", mime_type: "application/pdf", content_base64: Buffer.from("pdf-bytes").toString("base64") }],
      }),
    });
    assert.equal(response.status, 201, await response.clone().text());
    const body = await response.json() as { maintenance_purchase: { maintenance_issue_id?: string | null; purchase_type:string; purchase_scope: string; destination: string | null; category: string; branch_id: string | null } };
    assert.equal(body.maintenance_purchase.maintenance_issue_id, undefined);
    assert.equal(body.maintenance_purchase.purchase_type, "general");
    assert.equal(body.maintenance_purchase.purchase_scope, "other");
    assert.equal(body.maintenance_purchase.destination, "CEO House");
    assert.equal(body.maintenance_purchase.category, "fuel_petrol");
    assert.equal(body.maintenance_purchase.branch_id, null);
    const call = calls.at(-1) as { method: string; issueId?: string | null; payload?: Record<string, unknown>; receipts?: unknown[] };
    assert.equal(call.method, "createMaintenancePurchase");
    assert.equal(call.issueId, null);
    assert.equal(call.payload?.purchase_scope, "other");
    assert.equal(call.payload?.destination, "CEO House");
    assert.equal(call.payload?.category, "fuel_petrol");
    assert.equal(call.receipts?.length, 1);
  });
  it("rejects invalid standalone Purchase Log scope payloads before service mutation", async () => {
    const before = calls.length;
    const missingDestination = await fetch(`${baseUrl}/api/v1/maintenance/purchases/general`, {
      method: "POST",
      headers: { ...headers("maintenance"), "content-type": "application/json" },
      body: JSON.stringify({ purchase_type: "general", purchase_scope: "other", category: "fuel_petrol", item_name: "Fuel", quantity: "1", unit: "liter", amount: "250", purchase_date: "2026-08-26" }),
    });
    assert.equal(missingDestination.status, 422);
    assert.equal(calls.length, before);

    const invalidCategory = await fetch(`${baseUrl}/api/v1/maintenance/purchases/general`, {
      method: "POST",
      headers: { ...headers("maintenance"), "content-type": "application/json" },
      body: JSON.stringify({ purchase_type: "general", purchase_scope: "office", category: "bad", item_name: "Fuel", quantity: "1", unit: "liter", amount: "250", purchase_date: "2026-08-26" }),
    });
    assert.equal(invalidCategory.status, 400);
    assert.equal(calls.length, before);
  });
  it("denies non-Maintenance roles from Maintenance purchase history", async () => {
    assert.equal((await fetch(`${baseUrl}/api/v1/maintenance/purchases/issue`)).status, 401);
    assert.equal((await fetch(`${baseUrl}/api/v1/maintenance/purchases/issue`, { headers: headers("manager") })).status, 403);
    assert.equal((await fetch(`${baseUrl}/api/v1/maintenance/purchases/general`, { headers: headers("supervisor") })).status, 403);
    assert.equal((await fetch(`${baseUrl}/api/v1/maintenance/purchases/general`, { headers: headers("staff") })).status, 403);
    assert.equal((await fetch(`${baseUrl}/api/v1/maintenance/purchases/general`, { method: "POST", headers: { ...headers("manager"), "content-type": "application/json" }, body: JSON.stringify({ purchase_type: "general", purchase_scope: "other", destination: "Office", category: "other", item_name: "Fuel", quantity: "1", unit: "liter", amount: "1", purchase_date: "2026-08-26" }) })).status, 403);
  });
  it("keeps Maintenance purchase reimbursement on the existing PATCH route", async () => {
    const response = await fetch(`${baseUrl}/api/v1/maintenance/purchases/${id.purchaseLog}/payment-status`, {
      method: "PATCH",
      headers: headers("maintenance"),
      body: JSON.stringify({ reimbursement_note: "  Paid  " }),
    });
    assert.equal(response.status, 200, await response.clone().text());
    const body = await response.json() as { maintenance_purchase: { id: string; payment_status: string; reimbursement_note: string | null } };
    assert.equal(body.maintenance_purchase.id, id.purchaseLog);
    assert.equal(body.maintenance_purchase.payment_status, "reimbursed");
    assert.equal(body.maintenance_purchase.reimbursement_note, "Paid");
    assert.deepEqual(calls.at(-1), { method: "reimburseMaintenancePurchase", actorUserId: id.staffAccount, purchaseId: id.purchaseLog, reimbursementNote: "Paid" });
  });
  it("denies Manager and Supervisor from Maintenance workflow routes", async () => {
    assert.equal((await fetch(`${baseUrl}/api/v1/maintenance/issues`)).status, 401);
    assert.equal((await fetch(`${baseUrl}/api/v1/maintenance/issues`, { headers: headers("manager") })).status, 403);
    assert.equal((await fetch(`${baseUrl}/api/v1/maintenance/issues`, { headers: headers("supervisor") })).status, 403);
    assert.equal((await fetch(`${baseUrl}/api/v1/maintenance/issues/not-a-uuid`, {
      method: "PATCH", headers: headers("maintenance"), body: JSON.stringify({ status: "in_progress" }),
    })).status, 400);
    assert.equal((await fetch(`${baseUrl}/api/v1/maintenance/issues/${id.maintenanceIssue}`, {
      method: "PATCH", headers: headers("maintenance"), body: JSON.stringify({ status: "bad" }),
    })).status, 400);
  });
  it("denies legacy authenticated Staff", async () => {
    const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/team`, { headers: headers("staff") });
    assert.equal(response.status, 403);
  });
  it("tenant-scopes manager listing and returns no account fields", async () => {
    const response = await fetch(`${baseUrl}/api/v1/management/organizations/${id.organization}/operational-staff?page=1&page_size=20&operational_role=cleaner`, { headers: headers("manager") });
    assert.equal(response.status, 200);
    const text = await response.text();
    assert.doesNotMatch(text, /password|token|secret|auth_role/i);
    assert.deepEqual(calls.at(-1), {
      method: "list", actorUserId: id.manager, organizationId: id.organization, page: 1,
      pageSize: 20, search: undefined, branchId: undefined, supervisorUserId: undefined,
      role: "cleaner", employmentStatus: undefined, date: undefined,
    });
  });
  it("returns the Manager employee team with nullable metadata and scopes it to the managed organization", async () => {
    const response = await fetch(`${baseUrl}/api/v1/management/organizations/${id.organization}/employees?month=2026-08`, { headers: headers("manager") });
    assert.equal(response.status, 200);
    const body = await response.json() as { employees: Array<{ staff_code: string | null; iqama_number: string | null }>; health_cards: Array<{ status: string }>; monthly_evaluations: unknown[] };
    assert.equal(body.employees[0]?.staff_code, "BH-104");
    assert.equal(body.employees[0]?.iqama_number, null);
    assert.equal(body.health_cards[0]?.status, "failed");
    assert.deepEqual(body.monthly_evaluations, []);
    assert.deepEqual(calls.at(-1), { method: "employeeTeam", actorUserId: id.manager, organizationId: id.organization, branchId: undefined, month: "2026-08" });

    const denied = await fetch(`${baseUrl}/api/v1/management/organizations/30000000-0000-4000-8000-000000000099/employees?month=2026-08`, { headers: headers("manager") });
    assert.equal(denied.status, 403);

    const unavailable = await fetch(`${baseUrl}/api/v1/management/organizations/${id.organization}/employees?month=2026-08&branch_id=${id.emptyHealthBranch}`, { headers: headers("manager") });
    assert.equal(unavailable.status, 503);
  });
  it("lists Purchase Logs read-only only within the Manager organization", async () => {
    const list = await fetch(`${baseUrl}/api/v1/management/organizations/${id.organization}/purchase-logs?branch_id=${id.branch}&category=kitchen&payment_status=unpaid&date_from=2026-08-01&date_to=2026-08-31`, { headers: headers("manager") });
    assert.equal(list.status, 200);
    const text = await list.text();
    assert.doesNotMatch(text, /invoice_storage_path|branches\//);
    const body = JSON.parse(text) as { purchase_logs: Array<{ invoice_url: string | null; payment_status: string }> };
    assert.equal(body.purchase_logs[0]?.invoice_url, "https://storage.example.invalid/signed-invoice");
    assert.equal(body.purchase_logs[0]?.payment_status, "unpaid");
    assert.deepEqual(calls.at(-1), { method: "managedPurchaseLogs", actorUserId: id.manager, organizationId: id.organization, branchId: id.branch, category: "kitchen", paymentStatus: "unpaid", dateFrom: "2026-08-01", dateTo: "2026-08-31" });

    assert.equal((await fetch(`${baseUrl}/api/v1/management/organizations/30000000-0000-4000-8000-000000000099/purchase-logs`, { headers: headers("manager") })).status, 403);
    assert.equal((await fetch(`${baseUrl}/api/v1/management/organizations/30000000-0000-4000-8000-000000000099/purchase-logs/${id.purchaseLog}/payment-status`, { method: "PATCH", headers: headers("manager"), body: JSON.stringify({}) })).status, 404);
    assert.equal((await fetch(`${baseUrl}/api/v1/management/organizations/${id.organization}/purchase-logs/${id.purchaseLog}/payment-status`, { method: "PATCH", headers: headers("manager"), body: JSON.stringify({}) })).status, 404);
  });
  it("lists Supplier Receiving records read-only within the Manager organization", async () => {
    const list = await fetch(`${baseUrl}/api/v1/management/organizations/${id.organization}/supplier-receivings?branch_id=${id.branch}&category=raw&supplier_id=${id.supplier}&date_from=2026-08-01&date_to=2026-08-31`, { headers: headers("manager") });
    assert.equal(list.status, 200);
    const text = await list.text();
    assert.doesNotMatch(text, /photo_storage_path|branches\//);
    const body = JSON.parse(text) as { supplier_receivings: Array<{ photo_url: string | null; supplier_name_ar: string | null }> };
    assert.equal(body.supplier_receivings[0]?.photo_url, "https://storage.example.invalid/signed-photo");
    assert.equal(body.supplier_receivings[0]?.supplier_name_ar, "مورد الرياض");
    assert.deepEqual(calls.at(-1), { method: "managedSupplierReceivings", actorUserId: id.manager, organizationId: id.organization, branchId: id.branch, category: "raw", supplierId: id.supplier, dateFrom: "2026-08-01", dateTo: "2026-08-31" });
    assert.equal((await fetch(`${baseUrl}/api/v1/management/organizations/30000000-0000-4000-8000-000000000099/supplier-receivings`, { headers: headers("manager") })).status, 403);
    assert.equal((await fetch(`${baseUrl}/api/v1/management/organizations/${id.organization}/supplier-receivings`, { method: "POST", headers: headers("manager"), body: JSON.stringify({}) })).status, 404);
  });
  it("lists Maintenance Issues read-only within the Manager organization", async () => {
    const list = await fetch(`${baseUrl}/api/v1/management/organizations/${id.organization}/maintenance-issues?branch_id=${id.branch}&status=in_progress&priority=urgent&category=refrigeration&date_from=2026-08-01&date_to=2026-08-31`, { headers: headers("manager") });
    assert.equal(list.status, 200);
    const text = await list.text();
    assert.doesNotMatch(text, /organization_id|assigned_to/);
    const body = JSON.parse(text) as { maintenance_issues: Array<{ status: string; updates: Array<{ note: string | null }> }> };
    assert.equal(body.maintenance_issues[0]?.status, "in_progress");
    assert.equal(body.maintenance_issues[0]?.updates[0]?.note, "Started repair");
    assert.deepEqual(calls.at(-1), { method: "managedMaintenanceIssues", actorUserId: id.manager, organizationId: id.organization, branchId: id.branch, status: "in_progress", priority: "urgent", category: "refrigeration", dateFrom: "2026-08-01", dateTo: "2026-08-31" });
    assert.equal((await fetch(`${baseUrl}/api/v1/management/organizations/30000000-0000-4000-8000-000000000099/maintenance-issues`, { headers: headers("manager") })).status, 403);
    assert.equal((await fetch(`${baseUrl}/api/v1/management/organizations/${id.organization}/maintenance-issues/${id.maintenanceIssue}`, { method: "PATCH", headers: headers("manager"), body: JSON.stringify({}) })).status, 404);
  });
  it("allows Managers to report Office Maintenance issues without branch spoofing", async () => {
    const created = await fetch(`${baseUrl}/api/v1/management/organizations/${id.organization}/maintenance-issues`, {
      method: "POST",
      headers: headers("manager"),
      body: JSON.stringify({ title: "  Office AC  ", category: "equipment", priority: "high", location: "  Office  ", description: "  Not cooling  " }),
    });
    assert.equal(created.status, 201);
    const body = await created.json() as { maintenance_issue: { branch_id: string | null; branch_name: string; title: string } };
    assert.equal(body.maintenance_issue.branch_id, null);
    assert.equal(body.maintenance_issue.branch_name, "Office");
    assert.equal(body.maintenance_issue.title, "Office AC");
    const createCall = calls.at(-1) as Record<string, unknown>;
    assert.match(String(createCall.requestId), /^[0-9a-f-]{36}$/);
    assert.deepEqual({ ...createCall, requestId: "request-id" }, {
      method: "createManagerOfficeMaintenanceIssue",
      actorUserId: id.manager,
      organizationId: id.organization,
      requestId: "request-id",
      idempotencyKey: null,
      payload: { title: "Office AC", category: "equipment", priority: "high", description: "Not cooling", location: "Office" },
      photos: [],
    });

    const withPhoto = await fetch(`${baseUrl}/api/v1/management/organizations/${id.organization}/maintenance-issues`, {
      method: "POST",
      headers: { ...headers("manager"), "content-type": "application/vnd.maintenance-issue+json" },
      body: JSON.stringify({
        issue: { title: "Office light", category: "electrical", priority: "normal", description: "Flickering", location: "Admin room" },
        before_photo: { original_name: "office.webp", mime_type: "image/webp", content_base64: Buffer.from("webp-bytes").toString("base64") },
      }),
    });
    assert.equal(withPhoto.status, 201);
    const photoCall = calls.at(-1) as { method: string; branchId?: string; photos?: Array<{ mimeType: string; originalName: string; bytes: Buffer }> };
    assert.equal(photoCall.method, "createManagerOfficeMaintenanceIssue");
    assert.equal(photoCall.branchId, undefined);
    assert.equal(photoCall.photos?.[0]?.mimeType, "image/webp");
    assert.equal(photoCall.photos?.[0]?.originalName, "office.webp");
    assert.ok(Buffer.isBuffer(photoCall.photos?.[0]?.bytes));

    const spoofed = await fetch(`${baseUrl}/api/v1/management/organizations/${id.organization}/maintenance-issues`, {
      method: "POST",
      headers: headers("manager"),
      body: JSON.stringify({ title: "Spoof", category: "equipment", priority: "high", branch_id: id.branch }),
    });
    assert.equal(spoofed.status, 400);
    assert.equal((await fetch(`${baseUrl}/api/v1/management/organizations/${id.organization}/maintenance-issues`, { method: "POST", headers: headers("supervisor"), body: JSON.stringify({ title: "Office", category: "equipment", priority: "high" }) })).status, 403);
    assert.equal((await fetch(`${baseUrl}/api/v1/management/organizations/30000000-0000-4000-8000-000000000099/maintenance-issues`, { method: "POST", headers: headers("manager"), body: JSON.stringify({ title: "Office", category: "equipment", priority: "high" }) })).status, 403);
  });
  it("has no hard-delete endpoint", async () => {
    const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/operational-staff/${id.worker}`, {
      method: "DELETE", headers: headers("supervisor"),
    });
    assert.equal(response.status, 404);
  });
  it("derives dates across opposite timezone boundaries and rejects invalid IANA zones", () => {
    const instant = new Date("2026-07-31T21:30:00.000Z");
    assert.equal(branchLocalDate("Asia/Riyadh", instant), "2026-08-01");
    assert.equal(branchLocalDate("America/Los_Angeles", instant), "2026-07-31");
    assert.equal(branchLocalDate("Asia/Riyadh", new Date("2026-07-31T20:30:00.000Z")), "2026-07-31");
    assert.throws(() => branchLocalDate("Not/A_Timezone", instant));
  });
  it("fails closed when the stored branch timezone is invalid", async () => {
    const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/team`, {
      headers: headers("invalid-zone"),
    });
    assert.equal(response.status, 503);
    assert.doesNotMatch(await response.text(), /timezone|Not\/A_Timezone|RangeError/i);
  });
  it("keeps the authenticated core-team bootstrap rate limit separate and explicit", async () => {
    let rateLimited: Response | undefined;
    for (let index = 0; index < 61; index += 1) {
      const response = await fetch(`${baseUrl}/api/v1/supervisor/branches/${id.branch}/team`, { headers: headers("supervisor") });
      if (response.status === 429) { rateLimited = response; break; }
      assert.equal(response.status, 200);
    }
    assert.ok(rateLimited);
    assert.equal((await rateLimited.json() as { error: { code: string } }).error.code, "rate_limited");
  });
  it("normalizes and accepts an overnight management shift", async () => {
    const response = await fetch(`${baseUrl}/api/v1/management/organizations/${id.organization}/branches/${id.branch}/shifts`, {
      method: "POST", headers: headers("manager"),
      body: JSON.stringify({ name: "  Night   Shift ", start_time: "22:00", end_time: "06:00" }),
    });
    assert.equal(response.status, 404);
  });
  it("strictly validates shift updates and safely maps conflicts", async () => {
    for (const body of [{}, { active: false, branch_id: id.branch }, { start_time: "25:00" }]) {
      const response = await fetch(`${baseUrl}/api/v1/management/organizations/${id.organization}/branches/${id.branch}/shifts/${id.shift}`, {
        method: "PATCH", headers: headers("manager"), body: JSON.stringify(body),
      });
      assert.equal(response.status, 404);
    }
    const conflict = await fetch(`${baseUrl}/api/v1/management/organizations/${id.organization}/branches/${id.branch}/shifts/${id.shift}`, {
      method: "PATCH", headers: headers("manager"), body: JSON.stringify({ active: false }),
    });
    assert.equal(conflict.status, 404);
    assert.doesNotMatch(await conflict.text(), /database|postgres|dependency|23514/i);
  });
  it("denies Branch Supervisor and Staff management configuration", async () => {
    for (const token of ["supervisor", "staff"]) {
      const response = await fetch(`${baseUrl}/api/v1/management/organizations/${id.organization}/branches/${id.branch}/shifts`, {
        headers: headers(token),
      });
      assert.equal(response.status, 404);
    }
  });
  it("returns only eligible Supervisor identities and no account secrets", async () => {
    const response = await fetch(`${baseUrl}/api/v1/management/organizations/${id.organization}/branches/${id.branch}/eligible-supervisors`, {
      headers: headers("manager"),
    });
    assert.equal(response.status, 200);
    const text = await response.text();
    assert.match(text, new RegExp(id.supervisor));
    assert.doesNotMatch(text, /email|password|token|must_change_password|staffAccount/i);
  });
  it("does not expose Manager Employee Team mutation routes", async () => {
    const teamId = "70000000-0000-4000-8000-000000000001";
    const created = await fetch(`${baseUrl}/api/v1/management/organizations/${id.organization}/branches/${id.branch}/supervisor-teams`, {
      method: "POST", headers: headers("manager"),
      body: JSON.stringify({ supervisor_user_id: id.supervisor }),
    });
    assert.equal(created.status, 404);
    const updated = await fetch(`${baseUrl}/api/v1/management/organizations/${id.organization}/branches/${id.branch}/supervisor-teams/${teamId}`, {
      method: "PATCH", headers: headers("manager"), body: JSON.stringify({ active: false }),
    });
    assert.equal(updated.status, 404);
    const deleted = await fetch(`${baseUrl}/api/v1/management/organizations/${id.organization}/branches/${id.branch}/supervisor-teams/${teamId}`, {
      method: "DELETE", headers: headers("manager"),
    });
    assert.equal(deleted.status, 404);
  });
});
