import { createHash } from "node:crypto";
import { createClient } from "@supabase/supabase-js";
import type {
  DailyBusinessReportBranch,
  DailyBusinessReportBranchModules,
  DailyBusinessReportEligibilitySnapshot,
  DailyBusinessReportMaintenanceItem,
  DailyBusinessReportMaintenanceSummary,
  DailyBusinessReportModuleItem,
  DailyBusinessReportPayload,
  DailyBusinessReportPreview,
  DailyBusinessReportRecord,
  DailyBusinessReportSalesTrackingModuleItem,
  DailyBusinessReportSummary,
} from "../lib/contracts/daily-business-report";
import type { ManagementSalesTrackingPeriodSummary } from "../lib/contracts/management-sales-tracking-period";
import {
  ChecklistAccessError,
  ChecklistConflictError,
  ChecklistInputError,
  ChecklistNotFoundError,
  type ChecklistPersistence,
} from "./checklist-persistence";

export class DailyBusinessReportError extends Error {
  readonly code: "bad_request" | "forbidden" | "not_found" | "service_unavailable" | "conflict";
  readonly status: number;

  constructor(
    message: string,
    code: "bad_request" | "forbidden" | "not_found" | "service_unavailable" | "conflict" = "bad_request",
    status: number = 400,
  ) {
    super(message);
    this.name = "DailyBusinessReportError";
    this.code = code;
    this.status = status;
  }
}

export class DailyBusinessReportAccessError extends DailyBusinessReportError {
  constructor(message = "Daily business report access denied") {
    super(message, "forbidden", 403);
    this.name = "DailyBusinessReportAccessError";
  }
}

export class DailyBusinessReportNotFoundError extends DailyBusinessReportError {
  constructor(message = "Daily business report not found") {
    super(message, "not_found", 404);
    this.name = "DailyBusinessReportNotFoundError";
  }
}

export class DailyBusinessReportUnavailableError extends DailyBusinessReportError {
  constructor(message = "Daily business report service unavailable") {
    super(message, "service_unavailable", 503);
    this.name = "DailyBusinessReportUnavailableError";
  }
}

export type BranchContext = {
  id: string;
  name: string;
  name_ar?: string | null;
  code: string;
  timezone: string;
  active: boolean;
  currency_code?: "SAR" | "AED";
};

export type ReconciliationModuleApplicability = {
  branchId: string;
  moduleKey: string;
  required: boolean;
  requirementBasis: string;
};

export type OperationalDutyStatus = {
  assignmentId: string;
  dutyStatus: string;
};

export type OperationalTeamRoster = {
  teamId: string;
  branchId: string;
  active: boolean;
  hasOnDutyStaff: boolean;
};

export type SubmissionRecord = {
  id: string;
  organizationId: string;
  branchId: string;
  businessDate: string;
  checklistType: string;
  state: string;
  submittedAt: string | null;
  operationalTeamId?: string | null;
  issueCount: number;
};

export type ColdStorageRecord = {
  id: string;
  organizationId: string;
  branchId: string;
  businessDate: string;
  state: string;
  submittedAt: string | null;
  activeEquipmentCount: number;
  issueCount: number;
  slotsComplete?: boolean;
};

export type OilTrackingRecord = {
  id: string;
  organizationId: string;
  branchId: string;
  businessDate: string;
  state: string;
  submittedAt: string | null;
  inUseFryersCount: number;
  issueCount: number;
  phasesComplete?: boolean;
};

export type SalesTrackingCaseRecord = {
  caseId: string;
  reportId: string;
  organizationId: string;
  branchId: string;
  businessDate: string;
  state: string;
  submittedAt: string | null;
  currencyCode: "SAR" | "AED";
  actualTotal: string | number;
  posTotal: string | number;
  variance: string | number;
  issueCount: number;
};

export type MaintenanceIssueRecord = {
  id: string;
  organizationId: string;
  branchId: string;
  businessDate: string;
  title: string;
  category: string;
  priority: string;
  status: string;
  createdAt: string;
};

export type ReconciliationDataSources = {
  branches: BranchContext[];
  moduleApplicabilities?: ReconciliationModuleApplicability[];
  operationalTeams?: OperationalTeamRoster[];
  checklistSubmissions?: SubmissionRecord[];
  coldStorageSubmissions?: ColdStorageRecord[];
  oilTrackingSubmissions?: OilTrackingRecord[];
  salesTrackingCases?: SalesTrackingCaseRecord[];
  maintenanceIssues?: MaintenanceIssueRecord[];
  salesPeriodSummary?: ManagementSalesTrackingPeriodSummary;
};

/**
 * Calculates the authoritative local close time for a business date in a specific IANA timezone:
 * 04:00 on the following calendar day (business_date + 1 day).
 */
export function calculateBranchCloseAt(businessDate: string, timezone: string): Date {
  const [yearStr, monthStr, dayStr] = businessDate.split("-");
  const year = Number.parseInt(yearStr, 10);
  const month = Number.parseInt(monthStr, 10) - 1;
  const day = Number.parseInt(dayStr, 10);

  // Next calendar day at 04:00 local time
  const nextDay = new Date(Date.UTC(year, month, day + 1, 4, 0, 0));

  // Determine the timezone offset for the target timezone on that target date
  try {
    const formatter = new Intl.DateTimeFormat("en-US", {
      timeZone: timezone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hour12: false,
    });
    // Format a reference timestamp around nextDay to get exact offset
    const parts = formatter.formatToParts(nextDay);
    const pYear = Number(parts.find((p) => p.type === "year")?.value);
    const pMonth = Number(parts.find((p) => p.type === "month")?.value) - 1;
    const pDay = Number(parts.find((p) => p.type === "day")?.value);
    const pHour = Number(parts.find((p) => p.type === "hour")?.value);
    const pMin = Number(parts.find((p) => p.type === "minute")?.value);

    // Difference between local formatted time and UTC
    const localUtc = Date.UTC(pYear, pMonth, pDay, pHour, pMin);
    const offsetMs = localUtc - nextDay.getTime();
    return new Date(nextDay.getTime() - offsetMs);
  } catch {
    // Fallback: default to Asia/Riyadh UTC+3 if IANA lookup fails
    return new Date(Date.UTC(year, month, day + 1, 1, 0, 0));
  }
}

/**
 * Builds the canonical payload and preview for a Daily Business Report
 * strictly matching PostgreSQL Phase 1 foundation requirements.
 */
export function buildDailyBusinessReportPayload(
  organizationId: string,
  businessDate: string,
  sources: ReconciliationDataSources,
  options: { now?: Date; allowOpenPreview?: boolean } = {},
): {
  payload: DailyBusinessReportPayload;
  eligibilitySnapshot: DailyBusinessReportEligibilitySnapshot;
  isClosed: boolean;
  earliestOpenBranchCloseAt: string | null;
  maintenanceSummary: DailyBusinessReportMaintenanceSummary;
} {
  const now = options.now ?? new Date();
  const activeBranches = sources.branches.filter((b) => b.active);

  let earliestOpenClose: Date | null = null;
  let allBranchesClosed = true;

  // Build eligibility snapshot
  const eligibilityBranches = activeBranches.map((branch) => {
    const closeAt = calculateBranchCloseAt(businessDate, branch.timezone);
    if (now.getTime() < closeAt.getTime()) {
      allBranchesClosed = false;
      if (!earliestOpenClose || closeAt.getTime() < earliestOpenClose.getTime()) {
        earliestOpenClose = closeAt;
      }
    }

    const defaultModules = [
      { module_key: "kitchen_opening" as const, required: true, requirement_basis: "static" as const },
      { module_key: "foh_opening" as const, required: true, requirement_basis: "static" as const },
      { module_key: "staff_hygiene" as const, required: true, requirement_basis: "eligible_operational_staff" as const },
      { module_key: "daily_audit" as const, required: true, requirement_basis: "static" as const },
      { module_key: "cold_storage" as const, required: true, requirement_basis: "eligible_cold_storage_equipment" as const },
      { module_key: "oil_tracking" as const, required: true, requirement_basis: "eligible_oil_tracking_fryers" as const },
      { module_key: "sales_tracking" as const, required: true, requirement_basis: "static" as const },
    ];

    const modules = defaultModules.map((dm) => {
      const custom = sources.moduleApplicabilities?.find(
        (ma) => ma.branchId === branch.id && ma.moduleKey === dm.module_key,
      );
      if (sources.moduleApplicabilities && sources.moduleApplicabilities.length > 0 && !custom) {
        throw new DailyBusinessReportUnavailableError(
          `Missing authoritative module applicability for branch ${branch.id} module ${dm.module_key}`,
        );
      }
      return {
        module_key: dm.module_key,
        required: custom ? custom.required : dm.required,
        requirement_basis: custom ? (custom.requirementBasis as any) : dm.requirement_basis,
      };
    });

    return {
      branch_id: branch.id,
      timezone: branch.timezone,
      close_at: closeAt.toISOString(),
      modules,
    };
  });

  const eligibilitySnapshot: DailyBusinessReportEligibilitySnapshot = {
    policy_version: "daily-business-report-v1",
    branches: eligibilityBranches,
  };

  // Reconcile each branch
  const branchPayloads: DailyBusinessReportBranch[] = [];

  for (const branch of activeBranches) {
    const branchEligibility = eligibilityBranches.find((b) => b.branch_id === branch.id)!;
    const branchClosed = now.getTime() >= new Date(branchEligibility.close_at).getTime();

    // 1. Kitchen Opening
    const koApp = branchEligibility.modules.find((m) => m.module_key === "kitchen_opening")!;
    const koSub = sources.checklistSubmissions?.find(
      (s) =>
        s.branchId === branch.id &&
        s.businessDate === businessDate &&
        s.checklistType === "kitchen_opening" &&
        s.state === "submitted",
    );
    const koRequired = koApp.required;
    const koExpected = koRequired ? 1 : 0;
    const koSubmittedIds = koSub ? [koSub.id] : [];
    const koSubmittedCount = koSubmittedIds.length;
    const koIssueCount = koSub ? koSub.issueCount : 0;
    const koStatus = resolveModuleStatus({
      branchClosed,
      runtimeRequired: koRequired,
      expectedCount: koExpected,
      submittedCount: koSubmittedCount,
      issueCount: koIssueCount,
      allowUnavailable: options.allowOpenPreview ?? false,
    });
    const kitchen_opening: DailyBusinessReportModuleItem = {
      status: koStatus,
      required: koRequired,
      requirement_basis: koApp.requirement_basis,
      expected_count: koExpected,
      submitted_count: koSubmittedCount,
      missing_count: koStatus === "unavailable" ? 0 : koRequired ? Math.max(koExpected - koSubmittedCount, 0) : 0,
      issue_count: koStatus === "unavailable" ? 0 : koIssueCount,
      source_report_ids: koSubmittedIds,
      detail_path: koSub ? `/management/reports/${koSub.id}` : null,
    };

    // 2. FOH Opening
    const fohApp = branchEligibility.modules.find((m) => m.module_key === "foh_opening")!;
    const fohSub = sources.checklistSubmissions?.find(
      (s) =>
        s.branchId === branch.id &&
        s.businessDate === businessDate &&
        s.checklistType === "foh_opening" &&
        s.state === "submitted",
    );
    const fohRequired = fohApp.required;
    const fohExpected = fohRequired ? 1 : 0;
    const fohSubmittedIds = fohSub ? [fohSub.id] : [];
    const fohSubmittedCount = fohSubmittedIds.length;
    const fohIssueCount = fohSub ? fohSub.issueCount : 0;
    const fohStatus = resolveModuleStatus({
      branchClosed,
      runtimeRequired: fohRequired,
      expectedCount: fohExpected,
      submittedCount: fohSubmittedCount,
      issueCount: fohIssueCount,
      allowUnavailable: options.allowOpenPreview ?? false,
    });
    const foh_opening: DailyBusinessReportModuleItem = {
      status: fohStatus,
      required: fohRequired,
      requirement_basis: fohApp.requirement_basis,
      expected_count: fohExpected,
      submitted_count: fohSubmittedCount,
      missing_count: fohStatus === "unavailable" ? 0 : fohRequired ? Math.max(fohExpected - fohSubmittedCount, 0) : 0,
      issue_count: fohStatus === "unavailable" ? 0 : fohIssueCount,
      source_report_ids: fohSubmittedIds,
      detail_path: fohSub ? `/management/reports/${fohSub.id}` : null,
    };

    // 3. Staff Hygiene (eligible operational staff basis)
    const hygieneApp = branchEligibility.modules.find((m) => m.module_key === "staff_hygiene")!;
    const branchTeams = sources.operationalTeams?.filter((t) => t.branchId === branch.id && t.active && t.hasOnDutyStaff) ?? [];
    const eligibleTeamsCount = branchTeams.length;
    const hygieneRequired = hygieneApp.required && eligibleTeamsCount > 0;
    const hygieneExpected = hygieneRequired ? eligibleTeamsCount : 0;
    const hygieneSubs = sources.checklistSubmissions?.filter(
      (s) =>
        s.branchId === branch.id &&
        s.businessDate === businessDate &&
        s.checklistType === "staff_hygiene" &&
        s.state === "submitted" &&
        branchTeams.some((t) => t.teamId === s.operationalTeamId),
    ) ?? [];
    const hygieneSubmittedIds = hygieneSubs.map((s) => s.id).sort();
    const hygieneSubmittedCount = hygieneSubmittedIds.length;
    const hygieneIssueCount = hygieneSubs.reduce((acc, s) => acc + s.issueCount, 0);
    const hygieneStatus = resolveModuleStatus({
      branchClosed,
      runtimeRequired: hygieneRequired,
      expectedCount: hygieneExpected,
      submittedCount: hygieneSubmittedCount,
      issueCount: hygieneIssueCount,
      allowUnavailable: options.allowOpenPreview ?? false,
    });
    const staff_hygiene: DailyBusinessReportModuleItem = {
      status: hygieneStatus,
      required: hygieneRequired,
      requirement_basis: hygieneApp.requirement_basis,
      expected_count: hygieneExpected,
      submitted_count: hygieneSubmittedCount,
      missing_count: hygieneStatus === "unavailable" ? 0 : hygieneRequired ? Math.max(hygieneExpected - hygieneSubmittedCount, 0) : 0,
      issue_count: hygieneStatus === "unavailable" ? 0 : hygieneIssueCount,
      source_report_ids: hygieneSubmittedIds,
      detail_path: hygieneSubs.length === 1 ? `/management/reports/${hygieneSubs[0].id}` : null,
    };

    // 4. Daily Audit (branch-shared)
    const auditApp = branchEligibility.modules.find((m) => m.module_key === "daily_audit")!;
    const auditSub = sources.checklistSubmissions?.find(
      (s) =>
        s.branchId === branch.id &&
        s.businessDate === businessDate &&
        s.checklistType === "daily_audit" &&
        s.state === "submitted",
    );
    const auditRequired = auditApp.required;
    const auditExpected = auditRequired ? 1 : 0;
    const auditSubmittedIds = auditSub ? [auditSub.id] : [];
    const auditSubmittedCount = auditSubmittedIds.length;
    const auditIssueCount = auditSub ? auditSub.issueCount : 0;
    const auditStatus = resolveModuleStatus({
      branchClosed,
      runtimeRequired: auditRequired,
      expectedCount: auditExpected,
      submittedCount: auditSubmittedCount,
      issueCount: auditIssueCount,
      allowUnavailable: options.allowOpenPreview ?? false,
    });
    const daily_audit: DailyBusinessReportModuleItem = {
      status: auditStatus,
      required: auditRequired,
      requirement_basis: auditApp.requirement_basis,
      expected_count: auditExpected,
      submitted_count: auditSubmittedCount,
      missing_count: auditStatus === "unavailable" ? 0 : auditRequired ? Math.max(auditExpected - auditSubmittedCount, 0) : 0,
      issue_count: auditStatus === "unavailable" ? 0 : auditIssueCount,
      source_report_ids: auditSubmittedIds,
      detail_path: auditSub ? `/management/reports/${auditSub.id}` : null,
    };

    // 5. Cold Storage (eligible cold storage equipment basis)
    const coldApp = branchEligibility.modules.find((m) => m.module_key === "cold_storage")!;
    const coldSub = sources.coldStorageSubmissions?.find(
      (s) => s.branchId === branch.id && s.businessDate === businessDate,
    );
    const coldEquipmentCount = coldSub ? coldSub.activeEquipmentCount : 1; // default to 1 if no submission yet
    const coldRequired = coldApp.required && (coldSub === undefined || coldEquipmentCount > 0);
    const coldExpected = coldRequired ? 1 : 0;
    const coldSubmitted = coldSub && coldSub.state === "submitted" && coldSub.slotsComplete !== false;
    const coldSubmittedIds = coldSubmitted ? [coldSub.id] : [];
    const coldSubmittedCount = coldSubmittedIds.length;
    const coldIssueCount = coldSubmitted ? coldSub.issueCount : 0;
    const coldStatus = resolveModuleStatus({
      branchClosed,
      runtimeRequired: coldRequired,
      expectedCount: coldExpected,
      submittedCount: coldSubmittedCount,
      issueCount: coldIssueCount,
      allowUnavailable: options.allowOpenPreview ?? false,
    });
    const cold_storage: DailyBusinessReportModuleItem = {
      status: coldStatus,
      required: coldRequired,
      requirement_basis: coldApp.requirement_basis,
      expected_count: coldExpected,
      submitted_count: coldSubmittedCount,
      missing_count: coldStatus === "unavailable" ? 0 : coldRequired ? Math.max(coldExpected - coldSubmittedCount, 0) : 0,
      issue_count: coldStatus === "unavailable" ? 0 : coldIssueCount,
      source_report_ids: coldSubmittedIds,
      detail_path: coldSub ? `/management/cold-storage/reports/${coldSub.id}` : null,
    };

    // 6. Oil Tracking (eligible fryers basis)
    const oilApp = branchEligibility.modules.find((m) => m.module_key === "oil_tracking")!;
    const oilSub = sources.oilTrackingSubmissions?.find(
      (s) => s.branchId === branch.id && s.businessDate === businessDate,
    );
    const oilFryersCount = oilSub ? oilSub.inUseFryersCount : 1;
    const oilRequired = oilApp.required && (oilSub === undefined || oilFryersCount > 0);
    const oilExpected = oilRequired ? 1 : 0;
    const oilSubmitted = oilSub && oilSub.state === "submitted" && oilSub.phasesComplete !== false;
    const oilSubmittedIds = oilSubmitted ? [oilSub.id] : [];
    const oilSubmittedCount = oilSubmittedIds.length;
    const oilIssueCount = oilSubmitted ? oilSub.issueCount : 0;
    const oilStatus = resolveModuleStatus({
      branchClosed,
      runtimeRequired: oilRequired,
      expectedCount: oilExpected,
      submittedCount: oilSubmittedCount,
      issueCount: oilIssueCount,
      allowUnavailable: options.allowOpenPreview ?? false,
    });
    const oil_tracking: DailyBusinessReportModuleItem = {
      status: oilStatus,
      required: oilRequired,
      requirement_basis: oilApp.requirement_basis,
      expected_count: oilExpected,
      submitted_count: oilSubmittedCount,
      missing_count: oilStatus === "unavailable" ? 0 : oilRequired ? Math.max(oilExpected - oilSubmittedCount, 0) : 0,
      issue_count: oilStatus === "unavailable" ? 0 : oilIssueCount,
      source_report_ids: oilSubmittedIds,
      detail_path: oilSub ? `/management/oil-tracking/reports/${oilSub.id}` : null,
    };

    // 7. Sales Tracking (authoritative report cases)
    const salesApp = branchEligibility.modules.find((m) => m.module_key === "sales_tracking")!;
    const salesCase = sources.salesTrackingCases?.find(
      (c) => c.branchId === branch.id && c.businessDate === businessDate && c.state === "submitted",
    );
    const salesRequired = salesApp.required;
    const salesExpected = salesRequired ? 1 : 0;
    const salesSubmittedIds = salesCase ? [salesCase.reportId] : [];
    const salesSubmittedCount = salesSubmittedIds.length;
    const salesIssueCount = salesCase ? salesCase.issueCount : 0;
    const salesStatus = resolveModuleStatus({
      branchClosed,
      runtimeRequired: salesRequired,
      expectedCount: salesExpected,
      submittedCount: salesSubmittedCount,
      issueCount: salesIssueCount,
      allowUnavailable: options.allowOpenPreview ?? false,
    });
    const sales_tracking: DailyBusinessReportSalesTrackingModuleItem = {
      status: salesStatus,
      required: salesRequired,
      requirement_basis: salesApp.requirement_basis,
      expected_count: salesExpected,
      submitted_count: salesSubmittedCount,
      missing_count: salesStatus === "unavailable" ? 0 : salesRequired ? Math.max(salesExpected - salesSubmittedCount, 0) : 0,
      issue_count: salesStatus === "unavailable" ? 0 : salesIssueCount,
      source_report_ids: salesSubmittedIds,
      detail_path: salesCase ? `/management/sales-tracking?branch_id=${branch.id}&date_from=${businessDate}&date_to=${businessDate}` : null,
      cash_monitoring_source_report_id: salesCase ? salesCase.reportId : null,
    };

    const modules: DailyBusinessReportBranchModules = {
      kitchen_opening,
      foh_opening,
      staff_hygiene,
      daily_audit,
      cold_storage,
      oil_tracking,
      sales_tracking,
    };

    branchPayloads.push({
      branch_id: branch.id,
      modules,
    });
  }

  // Aggregate summary
  let required_count = 0;
  let submitted_count = 0;
  let missing_count = 0;
  let issue_count = 0;
  let not_applicable_count = 0;
  let unavailable_count = 0;

  for (const b of branchPayloads) {
    for (const mod of Object.values(b.modules)) {
      required_count += mod.expected_count;
      submitted_count += mod.submitted_count;
      missing_count += mod.missing_count;
      issue_count += mod.issue_count;
      if (mod.status === "not_applicable") not_applicable_count += 1;
      if (mod.status === "unavailable") unavailable_count += 1;
    }
  }

  const summary: DailyBusinessReportSummary = {
    required_count,
    submitted_count,
    missing_count,
    issue_count,
    not_applicable_count,
    unavailable_count,
  };

  const payload: DailyBusinessReportPayload = {
    organization_id: organizationId,
    business_date: businessDate,
    summary,
    branches: branchPayloads,
  };

  // Maintenance summary
  const branchIds = new Set(activeBranches.map((b) => b.id));
  const orgIssues = sources.maintenanceIssues?.filter((i) => branchIds.has(i.branchId) && i.businessDate === businessDate) ?? [];
  const maintenanceSummary: DailyBusinessReportMaintenanceSummary = {
    total_issues: orgIssues.length,
    urgent_count: orgIssues.filter((i) => i.priority === "urgent").length,
    high_count: orgIssues.filter((i) => i.priority === "high").length,
    medium_count: orgIssues.filter((i) => i.priority === "medium").length,
    low_count: orgIssues.filter((i) => i.priority === "low").length,
    in_progress_count: orgIssues.filter((i) => i.status === "in_progress").length,
    resolved_count: orgIssues.filter((i) => i.status === "resolved").length,
    items: orgIssues.map((i) => ({
      id: i.id,
      branch_id: i.branchId,
      title: i.title,
      category: i.category,
      priority: i.priority,
      status: i.status,
      created_at: i.createdAt,
    })),
  };

  return {
    payload,
    eligibilitySnapshot,
    isClosed: allBranchesClosed,
    earliestOpenBranchCloseAt: earliestOpenClose ? (earliestOpenClose as Date).toISOString() : null,
    maintenanceSummary,
  };
}

function resolveModuleStatus(input: {
  branchClosed: boolean;
  runtimeRequired: boolean;
  expectedCount: number;
  submittedCount: number;
  issueCount: number;
  allowUnavailable: boolean;
}): "submitted" | "missing" | "issues_detected" | "not_applicable" | "unavailable" {
  if (!input.runtimeRequired && input.submittedCount === 0) {
    return "not_applicable";
  }
  if (input.submittedCount >= input.expectedCount && input.expectedCount > 0) {
    return input.issueCount > 0 ? "issues_detected" : "submitted";
  }
  if (!input.branchClosed && input.allowUnavailable) {
    return "unavailable";
  }
  return "missing";
}

/**
 * Computes a deterministic source watermark representing the state of all constituent submissions.
 */
/**
 * Computes a deterministic canonical payload hash matching PostgreSQL encoding.
 */
export function computeCanonicalPayloadHash(payload: DailyBusinessReportPayload): string {
  const stringifyDeterministic = (val: any): string => {
    if (val === null || typeof val !== "object") {
      return JSON.stringify(val);
    }
    if (Array.isArray(val)) {
      return "[" + val.map(stringifyDeterministic).join(",") + "]";
    }
    const keys = Object.keys(val).sort();
    return "{" + keys.map((k) => JSON.stringify(k) + ":" + stringifyDeterministic(val[k])).join(",") + "}";
  };
  return createHash("sha256").update(stringifyDeterministic(payload), "utf8").digest("hex");
}

export function computeSourceWatermark(payload: DailyBusinessReportPayload): string {
  const allIds: string[] = [];
  for (const branch of payload.branches) {
    for (const mod of Object.values(branch.modules)) {
      for (const id of mod.source_report_ids) {
        allIds.push(id);
      }
    }
  }
  allIds.sort();
  return createHash("sha256")
    .update(`${payload.organization_id}:${payload.business_date}:${allIds.join(",")}`)
    .digest("hex");
}

export type ClaimedJob = {
  job_id: string;
  lease_token: string;
  organization_id: string;
  business_date: string;
  due_at: string;
  source_watermark: string;
  attempt_count: number;
  lease_expires_at: string;
};

/**
 * Report Generator worker handling atomic lease-bound finalization.
 */
export class DailyBusinessReportGenerator {
  constructor(
    private readonly persistence: ChecklistPersistence,
    private readonly dataSourceProvider: (
      orgId: string,
      bDate: string,
      actorUserId?: string | null,
      jobContext?: { jobId?: string; leaseToken?: string } | null,
    ) => Promise<ReconciliationDataSources>,
    private readonly nowProvider: () => Date = () => new Date(),
  ) {}

  async processClaimedJob(job: ClaimedJob, workerId: string): Promise<{ success: boolean; revision?: number; error?: string }> {
    const serverNow = this.nowProvider();
    const leaseExpires = new Date(job.lease_expires_at);

    // Verify active lease
    if (serverNow.getTime() >= leaseExpires.getTime()) {
      return { success: false, error: "lease_expired" };
    }

    try {
      // 1. Fetch sources and construct payload using authorized server lease
      const sources = await this.dataSourceProvider(
        job.organization_id,
        job.business_date,
        null,
        { jobId: job.job_id, leaseToken: job.lease_token },
      );
      const { payload } = buildDailyBusinessReportPayload(job.organization_id, job.business_date, sources, {
        now: serverNow,
        allowOpenPreview: false,
      });

      // 2. Check current report revision to determine generation reason
      const existing = await this.persistence.getDailyBusinessReport?.({
        actorUserId: workerId,
        organizationId: job.organization_id,
        businessDate: job.business_date,
      });

      const currentRevision = existing?.revision ?? 0;
      const generationReason = currentRevision === 0 ? "initial" : "late_submission";

      // 3. Atomically finalize report revision and complete the job
      const result = await this.persistence.finalizeDailyBusinessReportJob?.({
        jobId: job.job_id,
        leaseToken: job.lease_token,
        organizationId: job.organization_id,
        businessDate: job.business_date,
        schemaVersion: 1,
        sourceCutoffAt: serverNow.toISOString(),
        payload,
        sourceWatermark: job.source_watermark,
        generationReason,
      });

      return {
        success: true,
        revision: result?.revision,
      };
    } catch (error: any) {
      // Release job lease with retry or failed
      const cleanError = (error?.message ?? "unknown_error").slice(0, 80).replace(/[^a-z0-9_:-]/gi, "_").toLowerCase();
      try {
        await this.persistence.releaseDailyBusinessReportJob?.({
          jobId: job.job_id,
          leaseToken: job.lease_token,
          result: "retry",
          errorCode: cleanError || "reconciliation_failed",
        });
      } catch {
        // Suppress secondary release errors
      }
      return {
        success: false,
        error: error?.message ?? "reconciliation_failed",
      };
    }
  }

  async runOnce(options: { workerId?: string; limit?: number; leaseSeconds?: number } = {}): Promise<number> {
    const workerId = options.workerId ?? "00000000-0000-4000-8000-000000000001";
    const limit = options.limit ?? 10;
    const leaseSeconds = options.leaseSeconds ?? 120;

    const claimed = (await this.persistence.claimDailyBusinessReportJobs?.({ workerId, limit, leaseSeconds })) ?? [];
    let processed = 0;
    for (const job of claimed) {
      const result = await this.processClaimedJob(job, workerId);
      if (!result.success && result.error === "lease_expired") {
        await this.persistence.requeueDailyBusinessReportJob?.({
          actorUserId: workerId,
          jobId: job.job_id,
          expectedWatermark: job.source_watermark,
          recoveryReason: "lease_expired",
        });
      }
      processed += 1;
    }
    return processed;
  }
}

export type DailyBusinessReportService = {
  getReportPreview(input: {
    actorUserId: string;
    organizationId: string;
    businessDate: string;
    requestId?: string | null;
  }): Promise<DailyBusinessReportPreview>;
  generateReport?(input: {
    workerId: string;
    jobId: string;
    leaseToken: string;
    organizationId: string;
    businessDate: string;
    sourceWatermark: string;
  }): Promise<{ success: boolean; revision?: number; error?: string }>;
};

export type DailyBusinessReportServiceOptions = {
  dataSourceProvider?: (
    orgId: string,
    bDate: string,
    actorUserId?: string | null,
    jobContext?: { jobId?: string; leaseToken?: string } | null,
    requestId?: string | null,
  ) => Promise<ReconciliationDataSources>;
  nowProvider?: () => Date;
  diagnosticLogger?: (event: DailyBusinessReportDiagnosticEvent) => void;
};

export type DailyBusinessReportDiagnosticEvent = {
  requestId: string | null;
  source: string;
  outcome: "success" | "failure";
  category: "query" | "empty_result" | "query_error" | "authorization" | "unavailable";
  durationMs: number;
};

function defaultDailyBusinessReportDiagnosticLogger(event: DailyBusinessReportDiagnosticEvent): void {
  // Deliberately exclude SQL, parameters, identities, and returned data.
  const line = "DAILY_BUSINESS_REPORT_SOURCE_DIAGNOSTIC " + JSON.stringify(event);
  if (event.outcome === "failure") console.warn(line);
  else console.info(line);
}

export function createDailyBusinessReportSourceReader(
  diagnosticLogger: (event: DailyBusinessReportDiagnosticEvent) => void = defaultDailyBusinessReportDiagnosticLogger,
) {
  return async function readSource<T>(
    requestId: string | null,
    source: string,
    operation: () => Promise<{ data: T | null; error: { code?: string | null } | null }>,
  ): Promise<T> {
    const startedAt = performance.now();
    try {
      const result = await operation();
      if (result.error || !Array.isArray(result.data)) {
        diagnosticLogger({
          requestId,
          source,
          outcome: "failure",
          category: "query_error",
          durationMs: Math.round((performance.now() - startedAt) * 100) / 100,
        });
        throw new DailyBusinessReportUnavailableError(`Daily Business Report source unavailable: ${source}`);
      }
      diagnosticLogger({
        requestId,
        source,
        outcome: "success",
        category: result.data.length === 0 ? "empty_result" : "query",
        durationMs: Math.round((performance.now() - startedAt) * 100) / 100,
      });
      return result.data as T;
    } catch (error) {
      if (error instanceof DailyBusinessReportError) throw error;
      diagnosticLogger({
        requestId,
        source,
        outcome: "failure",
        category: "unavailable",
        durationMs: Math.round((performance.now() - startedAt) * 100) / 100,
      });
      throw new DailyBusinessReportUnavailableError(`Daily Business Report source unavailable: ${source}`);
    }
  };
}

export function createDailyBusinessReportService(
  url: string,
  secretKey: string,
  checklistPersistence?: ChecklistPersistence,
  options?: DailyBusinessReportServiceOptions,
): DailyBusinessReportService {
  const client = createClient(url, secretKey, {
    auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
  });
  const diagnosticLogger = options?.diagnosticLogger ?? defaultDailyBusinessReportDiagnosticLogger;

  const readSource = createDailyBusinessReportSourceReader(diagnosticLogger);

  const defaultDataSourceProvider = async (
    organizationId: string,
    businessDate: string,
    actorUserId?: string | null,
    jobContext?: { jobId?: string; leaseToken?: string } | null,
    requestId?: string | null,
  ): Promise<ReconciliationDataSources> => {
    // 0. Fetch authoritative module applicability & branch lifecycle via SECURITY DEFINER RPC
    let moduleApplicabilities: ReconciliationModuleApplicability[] | undefined;
    let activeBranchIdsFromLifecycle: Set<string> | null = null;

    if (checklistPersistence?.getDailyReportAuthoritativeApplicability) {
      const startedAt = performance.now();
      let rows;
      try {
        rows = await checklistPersistence.getDailyReportAuthoritativeApplicability({
          actorUserId: actorUserId ?? null,
          organizationId,
          businessDate,
          jobId: jobContext?.jobId ?? null,
          leaseToken: jobContext?.leaseToken ?? null,
        });
        diagnosticLogger({
          requestId: requestId ?? null,
          source: "authoritative_applicability",
          outcome: "success",
          category: rows.length === 0 ? "empty_result" : "query",
          durationMs: Math.round((performance.now() - startedAt) * 100) / 100,
        });
      } catch (error) {
        diagnosticLogger({
          requestId: requestId ?? null,
          source: "authoritative_applicability",
          outcome: "failure",
          category: error instanceof DailyBusinessReportAccessError || error instanceof ChecklistAccessError ? "authorization" : "query_error",
          durationMs: Math.round((performance.now() - startedAt) * 100) / 100,
        });
        throw error;
      }
      activeBranchIdsFromLifecycle = new Set(rows.map((r) => r.branch_id));
      moduleApplicabilities = rows.map((r) => ({
        branchId: r.branch_id,
        moduleKey: r.module_key,
        required: r.required,
        requirementBasis: r.requirement_basis,
      }));
    }

    // 1. Fetch active branches
    const branchRows = await readSource(requestId ?? null, "branches", async () => {
      const result = await client
        .from("branches")
        .select("id, name, name_ar, code, timezone, active")
        .eq("organization_id", organizationId);
      return { data: result.data as any[] | null, error: result.error };
    });
    const branches: BranchContext[] = branchRows.map((b: any) => ({
      id: b.id,
      name: b.name,
      name_ar: b.name_ar,
      code: b.code,
      timezone: b.timezone,
      active: activeBranchIdsFromLifecycle ? activeBranchIdsFromLifecycle.has(b.id) : b.active,
    }));

    const activeBranchIds = branches.filter((b) => b.active).map((b) => b.id);

    // 2. Fetch checklist submissions
    let checklistSubmissions: SubmissionRecord[] = [];
    if (activeBranchIds.length > 0) {
      const cSubs = await readSource(requestId ?? null, "checklist_submissions", async () => {
        const result = await client
          .from("checklist_submissions")
          .select("id, organization_id, branch_id, business_date, checklist_type, state, submitted_at, operational_team_id")
          .eq("organization_id", organizationId)
          .eq("business_date", businessDate)
          .in("branch_id", activeBranchIds);
        return { data: result.data as any[] | null, error: result.error };
      });

      if (Array.isArray(cSubs)) {
        checklistSubmissions = cSubs.map((s: any) => ({
          id: s.id,
          organizationId: s.organization_id,
          branchId: s.branch_id,
          businessDate: s.business_date,
          checklistType: s.checklist_type,
          state: s.state,
          submittedAt: s.submitted_at,
          operationalTeamId: s.operational_team_id,
          issueCount: 0,
        }));
      }
    }

    // 3. Fetch cold storage submissions
    let coldStorageSubmissions: ColdStorageRecord[] = [];
    if (activeBranchIds.length > 0) {
      const coldSubs = await readSource(requestId ?? null, "cold_storage_submissions", async () => {
        const result = await client
          .from("cold_storage_submissions")
          .select("id, organization_id, branch_id, business_date, state, updated_at")
          .eq("organization_id", organizationId)
          .eq("business_date", businessDate)
          .in("branch_id", activeBranchIds);
        return { data: result.data as any[] | null, error: result.error };
      });

      if (Array.isArray(coldSubs)) {
        coldStorageSubmissions = coldSubs.map((s: any) => ({
          id: s.id,
          organizationId: s.organization_id,
          branchId: s.branch_id,
          businessDate: s.business_date,
          state: s.state,
          submittedAt: s.updated_at ?? null,
          activeEquipmentCount: 1,
          issueCount: 0,
        }));
      }
    }

    // 4. Fetch oil tracking submissions
    let oilTrackingSubmissions: OilTrackingRecord[] = [];
    if (activeBranchIds.length > 0) {
      const oilSubs = await readSource(requestId ?? null, "oil_tracking_submissions", async () => {
        const result = await client
          .from("oil_tracking_submissions")
          .select("id, organization_id, branch_id, business_date, state, opening_submitted_at, closing_submitted_at")
          .eq("organization_id", organizationId)
          .eq("business_date", businessDate)
          .in("branch_id", activeBranchIds);
        return { data: result.data as any[] | null, error: result.error };
      });

      if (Array.isArray(oilSubs)) {
        oilTrackingSubmissions = oilSubs.map((s: any) => ({
          id: s.id,
          organizationId: s.organization_id,
          branchId: s.branch_id,
          businessDate: s.business_date,
          state: s.state,
          submittedAt: s.closing_submitted_at ?? s.opening_submitted_at ?? null,
          inUseFryersCount: 1,
          issueCount: 0,
        }));
      }
    }

    // 5. Fetch sales tracking cases
    let salesTrackingCases: SalesTrackingCaseRecord[] = [];
    if (activeBranchIds.length > 0) {
      const salesCases = await readSource(requestId ?? null, "sales_tracking_report_cases", async () => {
        if (!checklistPersistence?.getDailyBusinessReportSalesCases) {
          return { data: null, error: { code: "DBR_RPC_UNAVAILABLE" } };
        }
        try {
          const rows = await checklistPersistence.getDailyBusinessReportSalesCases({
            actorUserId: actorUserId ?? null,
            organizationId,
            businessDate,
            branchIds: activeBranchIds,
            jobId: jobContext?.jobId ?? null,
            leaseToken: jobContext?.leaseToken ?? null,
          });
          return { data: rows as any[] | null, error: null };
        } catch {
          return { data: null, error: { code: "DBR_RPC_QUERY_ERROR" } };
        }
      });

      if (Array.isArray(salesCases)) {
        salesTrackingCases = salesCases.map((c: any) => ({
          caseId: c.case_id,
          reportId: c.authoritative_report_id,
          organizationId: c.organization_id,
          branchId: c.branch_id,
          businessDate: c.business_date,
          state: c.report_state,
          submittedAt: c.submitted_at ?? null,
          currencyCode: c.currency_code ?? "SAR",
          actualTotal: 0,
          posTotal: 0,
          variance: 0,
          issueCount: 0,
        }));
      }
    }

    // 6. Fetch operational teams for staff hygiene
    let operationalTeams: OperationalTeamRoster[] = [];
    if (activeBranchIds.length > 0) {
      const teams = await readSource(requestId ?? null, "branch_operational_teams", async () => {
        const result = await client
          .from("branch_operational_teams")
          .select("id, branch_id, active")
          .eq("organization_id", organizationId)
          .in("branch_id", activeBranchIds)
          .eq("active", true);
        return { data: result.data as any[] | null, error: result.error };
      });

      if (Array.isArray(teams)) {
        operationalTeams = teams.map((t: any) => ({
          teamId: t.id,
          branchId: t.branch_id,
          active: t.active,
          hasOnDutyStaff: true,
        }));
      }
    }

    // 7. Fetch maintenance issues
    let maintenanceIssues: MaintenanceIssueRecord[] = [];
    const mIssues = await readSource(requestId ?? null, "maintenance_issues", async () => {
      const result = await client
        .from("maintenance_issues")
        .select("id, organization_id, branch_id, title, category, priority, status, created_at")
        .eq("organization_id", organizationId)
        .gte("created_at", `${businessDate}T00:00:00.000Z`)
        .lte("created_at", `${businessDate}T23:59:59.999Z`);
      return { data: result.data as any[] | null, error: result.error };
    });
    if (Array.isArray(mIssues)) {
      maintenanceIssues = mIssues.map((m: any) => ({
        id: m.id,
        organizationId: m.organization_id,
        branchId: m.branch_id,
        businessDate: businessDate,
        title: m.title,
        category: m.category,
        priority: m.priority,
        status: m.status,
        createdAt: m.created_at,
      }));
    }

    return {
      branches,
      operationalTeams,
      checklistSubmissions,
      coldStorageSubmissions,
      oilTrackingSubmissions,
      salesTrackingCases,
      maintenanceIssues,
    };
  };

  const dataSourceProvider = options?.dataSourceProvider ?? defaultDataSourceProvider;
  const nowProvider = options?.nowProvider ?? (() => new Date());

  return {
    async getReportPreview(input) {
      const sources = await dataSourceProvider(input.organizationId, input.businessDate, input.actorUserId, null, input.requestId);
      const now = nowProvider();

      // Get authoritative sales tracking period summary
      let salesSummary: ManagementSalesTrackingPeriodSummary | undefined = sources.salesPeriodSummary;
      if (!salesSummary && checklistPersistence?.getManagedSalesTrackingPeriodSummary) {
        const salesSummaryStartedAt = performance.now();
        try {
          salesSummary = (await checklistPersistence.getManagedSalesTrackingPeriodSummary({
            actorUserId: input.actorUserId,
            organizationId: input.organizationId,
            dateFrom: input.businessDate,
            dateTo: input.businessDate,
          })) as ManagementSalesTrackingPeriodSummary;
          diagnosticLogger({
            requestId: input.requestId ?? null,
            source: "sales_tracking_period_summary",
            outcome: "success",
            category: salesSummary.currency_summaries.length === 0 ? "empty_result" : "query",
            durationMs: Math.round((performance.now() - salesSummaryStartedAt) * 100) / 100,
          });
        } catch (error) {
          diagnosticLogger({
            requestId: input.requestId ?? null,
            source: "sales_tracking_period_summary",
            outcome: "failure",
            category: error instanceof DailyBusinessReportAccessError || error instanceof ChecklistAccessError ? "authorization" : "query_error",
            durationMs: Math.round((performance.now() - salesSummaryStartedAt) * 100) / 100,
          });
          if (
            error instanceof DailyBusinessReportError ||
            error instanceof ChecklistAccessError ||
            error instanceof ChecklistConflictError ||
            error instanceof ChecklistInputError ||
            error instanceof ChecklistNotFoundError
          ) {
            throw error;
          }
          throw new DailyBusinessReportUnavailableError("Daily Business Report source unavailable: sales_tracking_period_summary");
        }
      }

      if (!salesSummary) {
        salesSummary = {
          generated_at: now.toISOString(),
          state: "empty",
          scope: {
            organization_id: input.organizationId,
            branch_id: null,
            date_from: input.businessDate,
            date_to: input.businessDate,
          },
          currency_summaries: [],
          branches: [],
        };
      }

      const { payload, isClosed, earliestOpenBranchCloseAt, maintenanceSummary } = buildDailyBusinessReportPayload(
        input.organizationId,
        input.businessDate,
        sources,
        { now, allowOpenPreview: true },
      );

      return {
        organization_id: input.organizationId,
        business_date: input.businessDate,
        schema_version: 1,
        is_closed: isClosed,
        earliest_open_branch_close_at: earliestOpenBranchCloseAt,
        payload,
        sales_summary: salesSummary,
        maintenance_summary: maintenanceSummary,
      };
    },
  };
}
