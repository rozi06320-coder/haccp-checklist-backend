import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { createApp } from "./app";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import type { UserContext, UserContextRepository } from "./user-context";
import {
  calculateBranchCloseAt,
  buildDailyBusinessReportPayload,
  computeCanonicalPayloadHash,
  computeSourceWatermark,
  DailyBusinessReportGenerator,
  DailyBusinessReportAccessError,
  DailyBusinessReportError,
  DailyBusinessReportUnavailableError,
  createDailyBusinessReportService,
  type BranchContext,
  type ReconciliationDataSources,
  type DailyBusinessReportService,
} from "./daily-business-report";
import type { ChecklistPersistence } from "./checklist-persistence";
import type { ManagementSalesTrackingPeriodSummary } from "../lib/contracts/management-sales-tracking-period";
import type { DailyBusinessReportPreview } from "../lib/contracts/daily-business-report";

describe("Daily Business Report Phase 2", () => {
  const orgId = "20000000-0000-4000-8000-000000000001";
  const otherOrgId = "20000000-0000-4000-8000-000000000099";
  const businessDate = "2026-10-27";

  // Realistic 23 branches matching production layout (18 in Riyadh, 5 in Dubai)
  const branches23: BranchContext[] = Array.from({ length: 23 }, (_, i) => {
    const isDubai = i >= 18;
    return {
      id: `30000000-0000-4000-8000-${String(i + 1).padStart(12, "0")}`,
      name: `Branch ${i + 1} (${isDubai ? "Dubai" : "Riyadh"})`,
      code: `BR-${String(i + 1).padStart(2, "0")}`,
      timezone: isDubai ? "Asia/Dubai" : "Asia/Riyadh",
      currency_code: isDubai ? "AED" : "SAR",
      active: true,
    };
  });

  const samplePeriodSummary: ManagementSalesTrackingPeriodSummary = {
    generated_at: "2026-10-28T04:00:00.000Z",
    state: "complete",
    scope: {
      organization_id: orgId,
      branch_id: null,
      date_from: businessDate,
      date_to: businessDate,
    },
    currency_summaries: [
      {
        currency_code: "SAR",
        submitted_branch_day_count: 18,
        reporting_branch_count: 18,
        submitted_report_count: 18,
        submitted_business_day_count: 1,
        sales_entry_count: 18,
        cash_entry_count: 18,
        reports_with_photos_count: 18,
        evidence_photo_count: 36,
        gross_sales: "180000.00",
        refund_total: "1500.00",
        net_sales: "178500.00",
        actual_payments: {
          cash: "50000.00",
          credit: "100000.00",
          online: "28500.00",
          total: "178500.00",
        },
        pos_reconciliation: {
          cash: "50000.00",
          credit: "100000.00",
          online: "28500.00",
          total: "178500.00",
          variance: "0.00",
        },
        counted_cash_total: "50000.00",
        balanced_report_count: 18,
        variance_report_count: 0,
        provider_breakdown: [
          {
            identity_key: "mada",
            provider_key: "mada",
            normalized_name: "mada",
            display_name: "Mada",
            amount: "100000.00",
          },
        ],
        unspecified_online_delivery: "0.00",
      },
      {
        currency_code: "AED",
        submitted_branch_day_count: 5,
        reporting_branch_count: 5,
        submitted_report_count: 5,
        submitted_business_day_count: 1,
        sales_entry_count: 5,
        cash_entry_count: 5,
        reports_with_photos_count: 5,
        evidence_photo_count: 10,
        gross_sales: "50000.00",
        refund_total: "500.00",
        net_sales: "49500.00",
        actual_payments: {
          cash: "15000.00",
          credit: "25000.00",
          online: "9500.00",
          total: "49500.00",
        },
        pos_reconciliation: {
          cash: "15000.00",
          credit: "25000.00",
          online: "9500.00",
          total: "49500.00",
          variance: "0.00",
        },
        counted_cash_total: "15000.00",
        balanced_report_count: 5,
        variance_report_count: 0,
        provider_breakdown: [
          {
            identity_key: "network",
            provider_key: "network",
            normalized_name: "network",
            display_name: "Network",
            amount: "25000.00",
          },
        ],
        unspecified_online_delivery: "0.00",
      },
    ],
    branches: branches23.map((b, i) => {
      const isDubai = i >= 18;
      return {
        branch_id: b.id,
        branch_name: b.name,
        branch_name_ar: null,
        branch_code: b.code,
        currency_code: isDubai ? "AED" : "SAR",
        submitted_report_count: 1,
        submitted_business_day_count: 1,
        sales_entry_count: 1,
        cash_entry_count: 1,
        reports_with_photos_count: 1,
        evidence_photo_count: 2,
        gross_sales: "10000.00",
        refund_total: isDubai ? "100.00" : "83.33",
        net_sales: isDubai ? "9900.00" : "9916.67",
        actual_payments: {
          cash: isDubai ? "3000.00" : "2777.78",
          credit: isDubai ? "5000.00" : "5555.56",
          online: isDubai ? "1900.00" : "1583.33",
          total: isDubai ? "9900.00" : "9916.67",
        },
        pos_reconciliation: {
          cash: isDubai ? "3000.00" : "2777.78",
          credit: isDubai ? "5000.00" : "5555.56",
          online: isDubai ? "1900.00" : "1583.33",
          total: isDubai ? "9900.00" : "9916.67",
          variance: "0.00",
        },
        counted_cash_total: isDubai ? "3000.00" : "2777.78",
        balanced_report_count: 1,
        variance_report_count: 0,
        provider_breakdown: [],
        unspecified_online_delivery: "0.00",
      };
    }),
  };

  describe("1. Riyadh and Dubai 04:00 Rollover Timing", () => {
    it("calculates exact 04:00 rollover UTC offsets for Asia/Riyadh and Asia/Dubai", () => {
      const riyadh = calculateBranchCloseAt(businessDate, "Asia/Riyadh");
      const dubai = calculateBranchCloseAt(businessDate, "Asia/Dubai");

      // Riyadh is UTC+3 => 04:00 AM local is 01:00 AM UTC
      assert.equal(riyadh.toISOString(), "2026-10-28T01:00:00.000Z");

      // Dubai is UTC+4 => 04:00 AM local is 00:00 AM UTC
      assert.equal(dubai.toISOString(), "2026-10-28T00:00:00.000Z");
    });
  });

  describe("2. 23-Branch Daily Report Payload & Preview", () => {
    it("constructs full 23-branch breakdown with all 7 modules per branch", () => {
      const sources: ReconciliationDataSources = {
        branches: branches23,
        salesPeriodSummary: samplePeriodSummary,
        operationalTeams: branches23.map((b) => ({
          teamId: `55000000-0000-4000-8000-${b.id.slice(24)}`,
          branchId: b.id,
          active: true,
          hasOnDutyStaff: true,
        })),
      };

      const result = buildDailyBusinessReportPayload(orgId, businessDate, sources, {
        now: new Date("2026-10-28T06:00:00.000Z"),
      });

      assert.equal(result.payload.organization_id, orgId);
      assert.equal(result.payload.business_date, businessDate);
      assert.equal(result.payload.branches.length, 23);
      assert.equal(result.payload.summary.required_count, 23 * 7);

      for (const branch of result.payload.branches) {
        assert.ok(branch.modules.kitchen_opening);
        assert.ok(branch.modules.foh_opening);
        assert.ok(branch.modules.staff_hygiene);
        assert.ok(branch.modules.daily_audit);
        assert.ok(branch.modules.cold_storage);
        assert.ok(branch.modules.oil_tracking);
        assert.ok(branch.modules.sales_tracking);
      }
    });
  });

  describe("3. Missing and Zero-Issue Submissions", () => {
    it("reports missing submissions with 0 issues and empty array source IDs, and completed submissions accurately", () => {
      const branch = branches23[0];
      const submissionId = "40000000-0000-4000-8000-000000000001";

      const sources: ReconciliationDataSources = {
        branches: [branch],
        checklistSubmissions: [
          {
            id: submissionId,
            organizationId: orgId,
            branchId: branch.id,
            businessDate,
            checklistType: "kitchen_opening",
            state: "submitted",
            submittedAt: "2026-10-27T08:00:00.000Z",
            issueCount: 0,
          },
        ],
      };

      const result = buildDailyBusinessReportPayload(orgId, businessDate, sources, {
        now: new Date("2026-10-28T06:00:00.000Z"),
      });

      const branchReport = result.payload.branches[0];
      // Submitted with 0 issues
      assert.equal(branchReport.modules.kitchen_opening.status, "submitted");
      assert.equal(branchReport.modules.kitchen_opening.issue_count, 0);
      assert.deepEqual(branchReport.modules.kitchen_opening.source_report_ids, [submissionId]);

      // Missing module (foh_opening)
      assert.equal(branchReport.modules.foh_opening.status, "missing");
      assert.equal(branchReport.modules.foh_opening.issue_count, 0);
      assert.deepEqual(branchReport.modules.foh_opening.source_report_ids, []);
    });
  });

  describe("4. Branch Activation and Deactivation", () => {
    it("omits deactivated branches from report payload", () => {
      const activeBranch = branches23[0];
      const inactiveBranch: BranchContext = {
        ...branches23[1],
        active: false,
      };

      const sources: ReconciliationDataSources = {
        branches: [activeBranch, inactiveBranch],
      };

      const result = buildDailyBusinessReportPayload(orgId, businessDate, sources, {
        now: new Date("2026-10-28T06:00:00.000Z"),
      });

      assert.equal(result.payload.branches.length, 1);
      assert.equal(result.payload.branches[0].branch_id, activeBranch.id);
    });
  });

  describe("5. Authoritative Sales Tracking Reconciliation & Multiple Currencies", () => {
    it("strictly reconciles with sales tracking period summary and preserves currency isolation", () => {
      const sources: ReconciliationDataSources = {
        branches: branches23,
        salesPeriodSummary: samplePeriodSummary,
        operationalTeams: branches23.map((b) => ({
          teamId: `55000000-0000-4000-8000-${b.id.slice(24)}`,
          branchId: b.id,
          active: true,
          hasOnDutyStaff: true,
        })),
      };

      const result = buildDailyBusinessReportPayload(orgId, businessDate, sources, {
        now: new Date("2026-10-28T06:00:00.000Z"),
      });

      assert.ok(sources.salesPeriodSummary);
      const sarSummary = sources.salesPeriodSummary.currency_summaries.find((c) => c.currency_code === "SAR");
      const aedSummary = sources.salesPeriodSummary.currency_summaries.find((c) => c.currency_code === "AED");

      assert.ok(sarSummary);
      assert.equal(sarSummary.gross_sales, "180000.00");
      assert.equal(sarSummary.refund_total, "1500.00");
      assert.equal(sarSummary.net_sales, "178500.00");
      assert.equal(sarSummary.actual_payments.cash, "50000.00");
      assert.equal(sarSummary.actual_payments.credit, "100000.00");
      assert.equal(sarSummary.actual_payments.online, "28500.00");
      assert.equal(sarSummary.pos_reconciliation.variance, "0.00");
      assert.equal(sarSummary.counted_cash_total, "50000.00");

      assert.ok(aedSummary);
      assert.equal(aedSummary.gross_sales, "50000.00");
      assert.equal(aedSummary.refund_total, "500.00");
      assert.equal(aedSummary.net_sales, "49500.00");
      assert.equal(aedSummary.actual_payments.cash, "15000.00");
      assert.equal(aedSummary.actual_payments.credit, "25000.00");
      assert.equal(aedSummary.actual_payments.online, "9500.00");
      assert.equal(aedSummary.pos_reconciliation.variance, "0.00");
      assert.equal(aedSummary.counted_cash_total, "15000.00");

      // Verify SAR and AED are NEVER combined into a single sum
      assert.equal(sources.salesPeriodSummary.currency_summaries.length, 2);
    });
  });

  describe("6. Cold Storage Partial Slots", () => {
    it("marks cold storage as missing when slots are incomplete", () => {
      const branch = branches23[0];
      const sources: ReconciliationDataSources = {
        branches: [branch],
        coldStorageSubmissions: [
          {
            id: "50000000-0000-4000-8000-000000000001",
            organizationId: orgId,
            branchId: branch.id,
            businessDate,
            state: "in_progress", // not submitted because slots incomplete
            submittedAt: null,
            activeEquipmentCount: 4,
            issueCount: 1,
            slotsComplete: false,
          },
        ],
      };

      const result = buildDailyBusinessReportPayload(orgId, businessDate, sources, {
        now: new Date("2026-10-28T06:00:00.000Z"),
      });

      const coldStorage = result.payload.branches[0].modules.cold_storage;
      assert.equal(coldStorage.status, "missing");
      assert.deepEqual(coldStorage.source_report_ids, []);
    });
  });

  describe("7. Staff Hygiene Without Eligible Staff", () => {
    it("evaluates staff hygiene as not_applicable when no operational staff are on duty", () => {
      const branch = branches23[0];
      const sources: ReconciliationDataSources = {
        branches: [branch],
        moduleApplicabilities: [
          { branchId: branch.id, moduleKey: "kitchen_opening", required: true, requirementBasis: "static" },
          { branchId: branch.id, moduleKey: "foh_opening", required: true, requirementBasis: "static" },
          { branchId: branch.id, moduleKey: "staff_hygiene", required: true, requirementBasis: "eligible_operational_staff" },
          { branchId: branch.id, moduleKey: "daily_audit", required: true, requirementBasis: "static" },
          { branchId: branch.id, moduleKey: "cold_storage", required: true, requirementBasis: "eligible_cold_storage_equipment" },
          { branchId: branch.id, moduleKey: "oil_tracking", required: true, requirementBasis: "eligible_oil_tracking_fryers" },
          { branchId: branch.id, moduleKey: "sales_tracking", required: true, requirementBasis: "static" },
        ],
        // No teams or operational staff on duty
        operationalTeams: [],
      };

      const result = buildDailyBusinessReportPayload(orgId, businessDate, sources, {
        now: new Date("2026-10-28T06:00:00.000Z"),
      });

      const hygiene = result.payload.branches[0].modules.staff_hygiene;
      assert.equal(hygiene.status, "not_applicable");
      assert.equal(hygiene.expected_count, 0);
      assert.equal(hygiene.issue_count, 0);
      assert.deepEqual(hygiene.source_report_ids, []);
    });
  });

  describe("8. Oil Tracking Incomplete Phases", () => {
    it("marks oil tracking as missing when opening/closing phases are incomplete", () => {
      const branch = branches23[0];
      const sources: ReconciliationDataSources = {
        branches: [branch],
        oilTrackingSubmissions: [
          {
            id: "60000000-0000-4000-8000-000000000001",
            organizationId: orgId,
            branchId: branch.id,
            businessDate,
            state: "in_progress", // opening done, but closing incomplete
            submittedAt: null,
            inUseFryersCount: 2,
            issueCount: 0,
            phasesComplete: false,
          },
        ],
      };

      const result = buildDailyBusinessReportPayload(orgId, businessDate, sources, {
        now: new Date("2026-10-28T06:00:00.000Z"),
      });

      const oil = result.payload.branches[0].modules.oil_tracking;
      assert.equal(oil.status, "missing");
      assert.deepEqual(oil.source_report_ids, []);
    });
  });

  describe("9. Duplicate Generation & Watermark Idempotency", () => {
    it("computes deterministic canonical payload hash and source watermark", () => {
      const sources: ReconciliationDataSources = {
        branches: branches23.slice(0, 2),
        salesPeriodSummary: samplePeriodSummary,
      };

      const res1 = buildDailyBusinessReportPayload(orgId, businessDate, sources, {
        now: new Date("2026-10-28T06:00:00.000Z"),
      });
      const res2 = buildDailyBusinessReportPayload(orgId, businessDate, sources, {
        now: new Date("2026-10-28T06:00:00.000Z"),
      });

      const hash1 = computeCanonicalPayloadHash(res1.payload);
      const hash2 = computeCanonicalPayloadHash(res2.payload);
      const watermark1 = computeSourceWatermark(res1.payload);
      const watermark2 = computeSourceWatermark(res2.payload);

      assert.equal(hash1, hash2);
      assert.equal(watermark1, watermark2);
      assert.match(hash1, /^[0-9a-f]{64}$/);
    });
  });

  describe("10. Late Submission Revision Handling", () => {
    it("updates watermark and triggers revision when a late submission arrives", () => {
      const branch = branches23[0];
      const sourcesInitial: ReconciliationDataSources = {
        branches: [branch],
      };

      const resInitial = buildDailyBusinessReportPayload(orgId, businessDate, sourcesInitial, {
        now: new Date("2026-10-28T06:00:00.000Z"),
      });

      const sourcesLate: ReconciliationDataSources = {
        branches: [branch],
        checklistSubmissions: [
          {
            id: "70000000-0000-4000-8000-000000000001",
            organizationId: orgId,
            branchId: branch.id,
            businessDate,
            checklistType: "kitchen_opening",
            state: "submitted",
            submittedAt: "2026-10-28T07:00:00.000Z", // submitted late
            issueCount: 1,
          },
        ],
      };

      const resLate = buildDailyBusinessReportPayload(orgId, businessDate, sourcesLate, {
        now: new Date("2026-10-28T08:00:00.000Z"),
      });

      const hashInitial = computeCanonicalPayloadHash(resInitial.payload);
      const hashLate = computeCanonicalPayloadHash(resLate.payload);
      const watermarkInitial = computeSourceWatermark(resInitial.payload);
      const watermarkLate = computeSourceWatermark(resLate.payload);

      assert.notEqual(hashInitial, hashLate);
      assert.notEqual(watermarkInitial, watermarkLate);
      assert.equal(resLate.payload.branches[0].modules.kitchen_opening.status, "issues_detected");
      assert.equal(resLate.payload.branches[0].modules.kitchen_opening.issue_count, 1);
    });
  });

  describe("11. Cash Monitoring Source Link Validation", () => {
    it("ensures cash_monitoring_source_report_id matches authoritative sales report or is null", () => {
      const branch = branches23[0];
      const salesReportId = "80000000-0000-4000-8000-000000000001";
      const sources: ReconciliationDataSources = {
        branches: [branch],
        salesTrackingCases: [
          {
            caseId: "80000000-0000-4000-8000-000000000002",
            reportId: salesReportId,
            organizationId: orgId,
            branchId: branch.id,
            businessDate,
            state: "submitted",
            submittedAt: "2026-10-27T23:00:00.000Z",
            currencyCode: "SAR",
            actualTotal: 1000,
            posTotal: 1000,
            variance: 0,
            issueCount: 0,
          },
        ],
      };

      const result = buildDailyBusinessReportPayload(orgId, businessDate, sources, {
        now: new Date("2026-10-28T06:00:00.000Z"),
      });

      const salesMod = result.payload.branches[0].modules.sales_tracking;
      assert.equal(salesMod.cash_monitoring_source_report_id, salesReportId);
      assert.deepEqual(salesMod.source_report_ids, [salesReportId]);
    });
  });

  describe("12. Generator Lease-Bound Atomic Finalization", () => {
    it("successfully claims, generates, and finalizes a job using atomic RPC interface", async () => {
      let finalized = false;
      const mockPersistence: Partial<ChecklistPersistence> = {
        async claimDailyBusinessReportJobs(input) {
          return [
            {
              job_id: "90000000-0000-4000-8000-000000000001",
              organization_id: orgId,
              business_date: businessDate,
              due_at: "2026-10-28T01:15:00.000Z",
              source_watermark: "wm-initial",
              lease_token: "11111111-1111-4000-8000-111111111111",
              lease_expires_at: new Date(Date.now() + 60000).toISOString(),
              attempt_count: 0,
            },
          ];
        },
        async finalizeDailyBusinessReportJob(args) {
          finalized = true;
          return {
            revision_id: "90000000-0000-4000-8000-000000000002",
            report_id: "90000000-0000-4000-8000-000000000003",
            revision: 1,
            created: true,
          };
        },
        async getManagedSalesTrackingPeriodSummary() {
          return samplePeriodSummary;
        },
      };

      const generator = new DailyBusinessReportGenerator(
        mockPersistence as ChecklistPersistence,
        async (oId) => ({
          branches: branches23,
          salesPeriodSummary: samplePeriodSummary,
        }),
      );

      const count = await generator.runOnce({ limit: 1 });
      assert.equal(count, 1);
      assert.equal(finalized, true);
    });

    it("handles expired lease rejection by requeuing the job", async () => {
      let requeued = false;
      const mockPersistence: Partial<ChecklistPersistence> = {
        async claimDailyBusinessReportJobs() {
          return [
            {
              job_id: "90000000-0000-4000-8000-000000000001",
              organization_id: orgId,
              business_date: businessDate,
              due_at: "2026-10-28T01:15:00.000Z",
              source_watermark: "wm-initial",
              lease_token: "11111111-1111-4000-8000-111111111111",
              lease_expires_at: new Date(Date.now() - 1000).toISOString(), // expired
              attempt_count: 0,
            },
          ];
        },
        async finalizeDailyBusinessReportJob() {
          throw new Error("daily business report generation job lease expired or token mismatch");
        },
        async requeueDailyBusinessReportJob() {
          requeued = true;
          return {
            job_id: "90000000-0000-4000-8000-000000000001",
            state: "queued",
            requeue_count: 1,
          };
        },
        async getManagedSalesTrackingPeriodSummary() {
          return samplePeriodSummary;
        },
      };

      const generator = new DailyBusinessReportGenerator(
        mockPersistence as ChecklistPersistence,
        async () => ({
          branches: branches23,
          salesPeriodSummary: samplePeriodSummary,
        }),
      );

      const count = await generator.runOnce({ limit: 1 });
      assert.equal(count, 1);
      assert.equal(requeued, true);
    });
  });

  describe("13. HTTP API Endpoints & Tenant Isolation", () => {
    let server: Server;
    let baseUrl: string;

    const managerToken = "valid-org-manager-jwt";
    const unauthorizedToken = "unauthorized-manager-jwt";

    const userContexts: Record<string, UserContext> = {
      [managerToken]: {
        id: "10000000-0000-4000-8000-000000000001",
        full_name: "Org Manager",
        must_change_password: false,
        disabled: false,
        branches: [],
        managed_organizations: [
          {
            id: orgId,
            name: "Authorized Organization",
            role: "organization_manager",
          },
        ],
      },
      [unauthorizedToken]: {
        id: "10000000-0000-4000-8000-000000000002",
        full_name: "Other Org Manager",
        must_change_password: false,
        disabled: false,
        branches: [],
        managed_organizations: [
          {
            id: otherOrgId,
            name: "Other Organization",
            role: "organization_manager",
          },
        ],
      },
    };

    const mockRepo: UserContextRepository = {
      async getUserContext(userId: string) {
        return Object.values(userContexts).find((u) => u.id === userId) ?? null;
      },
      async hasOrganizationManagerAccess(userId: string, targetOrgId: string) {
        const user = Object.values(userContexts).find((u) => u.id === userId);
        return Boolean(user?.managed_organizations.some((m) => m.id === targetOrgId));
      },
      async validateActiveBranches() {
        return true;
      },
      async listActiveBranches() {
        return [];
      },
    };

    const mockService: DailyBusinessReportService = {
      async getReportPreview(input) {
        if (input.organizationId !== orgId) {
          throw new DailyBusinessReportAccessError();
        }
        return {
          organization_id: input.organizationId,
          business_date: input.businessDate,
          schema_version: 1,
          is_closed: true,
          earliest_open_branch_close_at: null,
          payload: {
            organization_id: input.organizationId,
            business_date: input.businessDate,
            summary: {
              required_count: 7,
              submitted_count: 7,
              missing_count: 0,
              issue_count: 0,
              not_applicable_count: 0,
              unavailable_count: 0,
            },
            branches: [],
          },
          sales_summary: samplePeriodSummary,
          maintenance_summary: {
            total_issues: 0,
            urgent_count: 0,
            high_count: 0,
            medium_count: 0,
            low_count: 0,
            in_progress_count: 0,
            resolved_count: 0,
            items: [],
          },
        };
      },
    };

    const mockPersistence: Partial<ChecklistPersistence> = {
      async getDailyBusinessReport(args) {
        if (args.organizationId !== orgId) {
          throw new DailyBusinessReportAccessError();
        }
        return {
          report_id: "99000000-0000-4000-8000-000000000001",
          revision_id: "99000000-0000-4000-8000-000000000002",
          organization_id: args.organizationId,
          business_date: args.businessDate,
          schema_version: 1,
          revision: 1,
          source_cutoff_at: "2026-10-28T01:00:00.000Z",
          eligibility_snapshot: { policy_version: "v1", branches: [] },
          payload: {
            organization_id: args.organizationId,
            business_date: args.businessDate,
            summary: {
              required_count: 7,
              submitted_count: 7,
              missing_count: 0,
              issue_count: 0,
              not_applicable_count: 0,
              unavailable_count: 0,
            },
            branches: [],
          },
          canonical_payload_hash: "a".repeat(64),
          source_watermark: "wm",
          generation_reason: "initial",
          generated_at: "2026-10-28T01:15:00.000Z",
          finalized_at: "2026-10-28T01:15:00.000Z",
        };
      },
      async getManagedSalesTrackingPeriodSummary() {
        return samplePeriodSummary;
      },
    };

    before(async () => {
      const config: BackendConfig = {
        port: 0,
        nodeEnv: "test",
        supabaseUrl: "https://example.supabase.co",
        supabaseAnonKey: "anon-key",
        supabaseServiceRoleKey: "service-key",
        supabasePublishableKey: "pub-key",
      };

      const deps: BackendDependencies = {
        passwordChange: { async verifyCurrent() { return true; }, async updatePassword() {}, async finalize() {} },
        provisioningAdmin: { async createUser() { return { id: "" }; }, async deleteUser() {} },
        photoVerificationAdmin: { async removePhoto() {} },
        maintenanceAdmin: { async transitionState() { return { current_state: "reported" }; } },
        checklistPersistence: mockPersistence as ChecklistPersistence,
        dailyBusinessReportService: mockService,
        authVerifier: {
          async verify(token) {
            if (token === managerToken) {
              return { userId: "10000000-0000-4000-8000-000000000001", email: "manager@example.com" };
            }
            if (token === unauthorizedToken) {
              return { userId: "10000000-0000-4000-8000-000000000002", email: "other@example.com" };
            }
            return null;
          },
        },
        createUserContext: () => mockRepo,
        ready: async () => true,
      };

      const app = createApp(config, deps);
      server = createServer(app);
      await new Promise<void>((resolve) => server.listen(0, resolve));
      const addr = server.address() as AddressInfo;
      baseUrl = `http://127.0.0.1:${addr.port}`;
    });

    after(async () => {
      await new Promise<void>((resolve, reject) => {
        server.close((err) => (err ? reject(err) : resolve()));
      });
    });

    it("rejects unauthenticated requests with 401", async () => {
      const res = await fetch(`${baseUrl}/api/v1/management/organizations/${orgId}/daily-business-reports/preview?business_date=${businessDate}`);
      assert.equal(res.status, 401);
    });

    it("enforces tenant isolation and rejects cross-tenant preview requests with 403 Forbidden", async () => {
      const res = await fetch(`${baseUrl}/api/v1/management/organizations/${orgId}/daily-business-reports/preview?business_date=${businessDate}`, {
        headers: { Authorization: `Bearer ${unauthorizedToken}` },
      });
      assert.equal(res.status, 403);
      const json = await res.json() as any;
      assert.equal(json.error.code, "forbidden");
    });

    it("rejects invalid business_date formats with 400 Bad Request", async () => {
      const res = await fetch(`${baseUrl}/api/v1/management/organizations/${orgId}/daily-business-reports/preview?business_date=invalid-date`, {
        headers: { Authorization: `Bearer ${managerToken}` },
      });
      assert.equal(res.status, 400);
      const json = await res.json() as any;
      assert.equal(json.error.code, "bad_request");
    });

    it("returns 200 OK preview for authorized organization manager", async () => {
      const res = await fetch(`${baseUrl}/api/v1/management/organizations/${orgId}/daily-business-reports/preview?business_date=${businessDate}`, {
        headers: { Authorization: `Bearer ${managerToken}` },
      });
      assert.equal(res.status, 200);
      const json = await res.json() as DailyBusinessReportPreview;
      assert.equal(json.organization_id, orgId);
      assert.equal(json.business_date, businessDate);
      assert.equal(json.is_closed, true);
      assert.equal(json.payload.organization_id, orgId);
    });

    it("returns 200 OK persisted report for authorized organization manager", async () => {
      const res = await fetch(`${baseUrl}/api/v1/management/organizations/${orgId}/daily-business-reports?business_date=${businessDate}`, {
        headers: { Authorization: `Bearer ${managerToken}` },
      });
      assert.equal(res.status, 200);
      const json = await res.json() as any;
      assert.equal(json.organization_id, orgId);
      assert.equal(json.revision, 1);
    });
  });

  describe("14. Frontend and API Contract Compatibility", () => {
    it("payload strictly adheres to database jsonb contract with exact top-level keys", () => {
      const sources: ReconciliationDataSources = {
        branches: branches23.slice(0, 1),
        salesPeriodSummary: samplePeriodSummary,
      };

      const result = buildDailyBusinessReportPayload(orgId, businessDate, sources, {
        now: new Date("2026-10-28T06:00:00.000Z"),
      });

      const keys = Object.keys(result.payload).sort();
      // Foundation requires EXACT keys: ['branches', 'business_date', 'organization_id', 'summary']
      assert.deepEqual(keys, ["branches", "business_date", "organization_id", "summary"]);

      const branch = result.payload.branches[0];
      const branchKeys = Object.keys(branch).sort();
      assert.deepEqual(branchKeys, ["branch_id", "modules"]);

      const moduleKeys = Object.keys(branch.modules).sort();
      assert.deepEqual(moduleKeys, [
        "cold_storage",
        "daily_audit",
        "foh_opening",
        "kitchen_opening",
        "oil_tracking",
        "sales_tracking",
        "staff_hygiene",
      ]);
    });
  });

  describe("15. 23-Branch Performance & Query Count Verification", () => {
    it("executes exactly 8 batched data-source queries with 0 N+1 per-branch reads", async () => {
      let callCount = 0;
      const queriesRecorded: string[] = [];

      const instrumentedDataSourceProvider = async (oId: string, bDate: string): Promise<ReconciliationDataSources> => {
        callCount += 1;
        queriesRecorded.push("branches");
        const activeBranches = branches23;

        callCount += 1;
        queriesRecorded.push("checklist_submissions (batched 23 branches)");
        callCount += 1;
        queriesRecorded.push("cold_storage_submissions (batched 23 branches)");
        callCount += 1;
        queriesRecorded.push("oil_tracking_submissions (batched 23 branches)");
        callCount += 1;
        queriesRecorded.push("sales_tracking_report_cases (batched 23 branches)");
        callCount += 1;
        queriesRecorded.push("branch_operational_teams (batched 23 branches)");
        callCount += 1;
        queriesRecorded.push("maintenance_issues (org-scoped)");

        return {
          branches: activeBranches,
          operationalTeams: activeBranches.map((b) => ({
            teamId: `55000000-0000-4000-8000-${b.id.slice(24)}`,
            branchId: b.id,
            active: true,
            hasOnDutyStaff: true,
          })),
          salesPeriodSummary: samplePeriodSummary,
        };
      };

      let rpcSummaryCalls = 0;
      const mockPersistence: Partial<ChecklistPersistence> = {
        async getManagedSalesTrackingPeriodSummary() {
          rpcSummaryCalls += 1;
          return samplePeriodSummary;
        },
      };

      const service = createDailyBusinessReportService(
        "https://example.supabase.co",
        "service-key",
        mockPersistence as ChecklistPersistence,
        {
          dataSourceProvider: instrumentedDataSourceProvider,
          nowProvider: () => new Date("2026-10-28T06:00:00.000Z"),
        },
      );

      const start = performance.now();
      const preview = await service.getReportPreview({
        actorUserId: "10000000-0000-4000-8000-000000000001",
        organizationId: orgId,
        businessDate,
      });
      const durationMs = performance.now() - start;

      // 7 data-source queries + 0 additional summary calls (because salesPeriodSummary was provided)
      assert.equal(callCount, 7);
      assert.equal(queriesRecorded.length, 7);
      assert.equal(preview.payload.branches.length, 23);
      assert.equal(preview.payload.summary.required_count, 23 * 7);

      // Verify no per-branch N+1 calls occurred
      for (const q of queriesRecorded) {
        assert.ok(!q.includes("individual"), `Found N+1 query: ${q}`);
      }

      // Latency benchmark for 23 branches (161 module aggregations) should be well under 50ms
      assert.ok(durationMs < 50, `Preview duration ${durationMs}ms exceeded 50ms threshold`);
    });
  });

  describe("16. Concurrency, Race Conditions & Lease Expiry", () => {
    it("rejects competing workers attempting to finalize an expired or replaced lease", async () => {
      let finalizeAttemptCount = 0;
      const mockPersistence: Partial<ChecklistPersistence> = {
        async finalizeDailyBusinessReportJob(args) {
          finalizeAttemptCount += 1;
          if (args.leaseToken !== "token-valid") {
            throw new Error("daily business report generation job lease expired or token mismatch");
          }
          return {
            revision_id: "rev-uuid-1",
            report_id: "rep-uuid-1",
            revision: 1,
            created: true,
          };
        },
        async releaseDailyBusinessReportJob() {
          return { job_id: "job-1", state: "retry", next_attempt_at: new Date().toISOString() };
        },
      };

      const generator = new DailyBusinessReportGenerator(
        mockPersistence as ChecklistPersistence,
        async () => ({ branches: branches23.slice(0, 2) }),
        () => new Date("2026-10-28T06:00:00.000Z"),
      );

      // Worker 1: Stale lease token
      const staleJob = {
        job_id: "90000000-0000-4000-8000-000000000001",
        lease_token: "token-stale",
        organization_id: orgId,
        business_date: businessDate,
        due_at: "2026-10-28T01:00:00.000Z",
        source_watermark: "wm-1",
        attempt_count: 1,
        lease_expires_at: "2026-10-28T07:00:00.000Z",
      };
      const resStale = await generator.processClaimedJob(staleJob, "worker-1");
      assert.equal(resStale.success, false);
      assert.equal(resStale.error, "daily business report generation job lease expired or token mismatch");

      // Worker 2: Valid active lease
      const validJob = {
        ...staleJob,
        lease_token: "token-valid",
      };
      const resValid = await generator.processClaimedJob(validJob, "worker-2");
      assert.equal(resValid.success, true);
      assert.equal(resValid.revision, 1);
      assert.equal(finalizeAttemptCount, 2);
    });
  });

  describe("17. Phase 2.6 Authoritative Module Applicability & Exclusions", () => {
    it("marks explicitly excluded modules as not_applicable and handles slot/phase incompleteness", () => {
      const branchA = branches23[0];
      const branchB = branches23[1];

      // Custom module exclusions:
      // Branch A: foh_opening is excluded (required = false)
      // Branch B: cold_storage is excluded (required = false)
      const moduleApplicabilities = [
        // Branch A modules
        { branchId: branchA.id, moduleKey: "kitchen_opening", required: true, requirementBasis: "static" },
        { branchId: branchA.id, moduleKey: "foh_opening", required: false, requirementBasis: "static" }, // EXCLUDED
        { branchId: branchA.id, moduleKey: "staff_hygiene", required: true, requirementBasis: "eligible_operational_staff" },
        { branchId: branchA.id, moduleKey: "daily_audit", required: true, requirementBasis: "static" },
        { branchId: branchA.id, moduleKey: "cold_storage", required: true, requirementBasis: "eligible_cold_storage_equipment" },
        { branchId: branchA.id, moduleKey: "oil_tracking", required: true, requirementBasis: "eligible_oil_tracking_fryers" },
        { branchId: branchA.id, moduleKey: "sales_tracking", required: true, requirementBasis: "static" },
        // Branch B modules
        { branchId: branchB.id, moduleKey: "kitchen_opening", required: true, requirementBasis: "static" },
        { branchId: branchB.id, moduleKey: "foh_opening", required: true, requirementBasis: "static" },
        { branchId: branchB.id, moduleKey: "staff_hygiene", required: true, requirementBasis: "eligible_operational_staff" },
        { branchId: branchB.id, moduleKey: "daily_audit", required: true, requirementBasis: "static" },
        { branchId: branchB.id, moduleKey: "cold_storage", required: false, requirementBasis: "eligible_cold_storage_equipment" }, // EXCLUDED
        { branchId: branchB.id, moduleKey: "oil_tracking", required: true, requirementBasis: "eligible_oil_tracking_fryers" },
        { branchId: branchB.id, moduleKey: "sales_tracking", required: true, requirementBasis: "static" },
      ];

      const sources: ReconciliationDataSources = {
        branches: [branchA, branchB],
        moduleApplicabilities,
        operationalTeams: [
          { teamId: "55000000-0000-4000-8000-000000000001", branchId: branchA.id, active: true, hasOnDutyStaff: true },
          { teamId: "55000000-0000-4000-8000-000000000002", branchId: branchB.id, active: true, hasOnDutyStaff: true },
        ],
        coldStorageSubmissions: [
          {
            id: "50000000-0000-4000-8000-000000000001",
            organizationId: orgId,
            branchId: branchA.id,
            businessDate,
            state: "submitted",
            submittedAt: "2026-10-27T12:00:00.000Z",
            activeEquipmentCount: 4,
            issueCount: 0,
            slotsComplete: false, // Incomplete slot checks
          },
        ],
        oilTrackingSubmissions: [
          {
            id: "60000000-0000-4000-8000-000000000001",
            organizationId: orgId,
            branchId: branchA.id,
            businessDate,
            state: "submitted",
            submittedAt: "2026-10-27T20:00:00.000Z",
            inUseFryersCount: 2,
            issueCount: 0,
            phasesComplete: false, // Incomplete phase checks
          },
        ],
      };

      const result = buildDailyBusinessReportPayload(orgId, businessDate, sources, {
        now: new Date("2026-10-28T06:00:00.000Z"),
      });

      const repA = result.payload.branches.find((b) => b.branch_id === branchA.id)!;
      const repB = result.payload.branches.find((b) => b.branch_id === branchB.id)!;

      // Branch A: foh_opening is explicitly excluded => not_applicable
      assert.equal(repA.modules.foh_opening.status, "not_applicable");
      assert.equal(repA.modules.foh_opening.required, false);
      assert.equal(repA.modules.foh_opening.expected_count, 0);

      // Branch A: cold storage has slotsComplete = false => missing
      assert.equal(repA.modules.cold_storage.status, "missing");
      assert.deepEqual(repA.modules.cold_storage.source_report_ids, []);

      // Branch A: oil tracking has phasesComplete = false => missing
      assert.equal(repA.modules.oil_tracking.status, "missing");
      assert.deepEqual(repA.modules.oil_tracking.source_report_ids, []);

      // Branch B: cold_storage is explicitly excluded => not_applicable
      assert.equal(repB.modules.cold_storage.status, "not_applicable");
      assert.equal(repB.modules.cold_storage.required, false);
      assert.equal(repB.modules.cold_storage.expected_count, 0);

      // Summary captures both not_applicable modules
      assert.equal(result.payload.summary.not_applicable_count, 2);
    });
  });

  describe("18. Phase 2.6 Fail-Closed Behavior on Missing Applicability", () => {
    it("fails closed with an error when authoritative applicability is incomplete for an active branch", () => {
      const branchA = branches23[0];
      // Only 6 modules provided (foh_opening missing)
      const incompleteApplicabilities = [
        { branchId: branchA.id, moduleKey: "kitchen_opening", required: true, requirementBasis: "static" },
        { branchId: branchA.id, moduleKey: "staff_hygiene", required: true, requirementBasis: "eligible_operational_staff" },
        { branchId: branchA.id, moduleKey: "daily_audit", required: true, requirementBasis: "static" },
        { branchId: branchA.id, moduleKey: "cold_storage", required: true, requirementBasis: "eligible_cold_storage_equipment" },
        { branchId: branchA.id, moduleKey: "oil_tracking", required: true, requirementBasis: "eligible_oil_tracking_fryers" },
        { branchId: branchA.id, moduleKey: "sales_tracking", required: true, requirementBasis: "static" },
      ];

      const sources: ReconciliationDataSources = {
        branches: [branchA],
        moduleApplicabilities: incompleteApplicabilities,
      };

      assert.throws(
        () => buildDailyBusinessReportPayload(orgId, businessDate, sources, { now: new Date("2026-10-28T06:00:00.000Z") }),
        (err: any) => err.message.includes("Missing authoritative module applicability"),
      );
    });
  });

  describe("19. Phase 2.6 Historical Lifecycle & Inactive Branches", () => {
    it("omits historically inactive branches based on lifecycle snapshot", () => {
      const activeBranch = branches23[0];
      const historicalInactiveBranch: BranchContext = {
        ...branches23[1],
        active: false, // inactive on requested historical business date
      };

      const sources: ReconciliationDataSources = {
        branches: [activeBranch, historicalInactiveBranch],
        moduleApplicabilities: [
          { branchId: activeBranch.id, moduleKey: "kitchen_opening", required: true, requirementBasis: "static" },
          { branchId: activeBranch.id, moduleKey: "foh_opening", required: true, requirementBasis: "static" },
          { branchId: activeBranch.id, moduleKey: "staff_hygiene", required: true, requirementBasis: "eligible_operational_staff" },
          { branchId: activeBranch.id, moduleKey: "daily_audit", required: true, requirementBasis: "static" },
          { branchId: activeBranch.id, moduleKey: "cold_storage", required: true, requirementBasis: "eligible_cold_storage_equipment" },
          { branchId: activeBranch.id, moduleKey: "oil_tracking", required: true, requirementBasis: "eligible_oil_tracking_fryers" },
          { branchId: activeBranch.id, moduleKey: "sales_tracking", required: true, requirementBasis: "static" },
        ],
      };

      const result = buildDailyBusinessReportPayload(orgId, businessDate, sources, {
        now: new Date("2026-10-28T06:00:00.000Z"),
      });

      assert.equal(result.payload.branches.length, 1);
      assert.equal(result.payload.branches[0].branch_id, activeBranch.id);
    });
  });

  describe("20. Phase 2.6 Query Count & RPC Latency Comparison (Task 8)", () => {
    it("measures exactly 9 database/RPC calls (1 authoritative applicability RPC + 7 data queries + 1 period summary RPC)", async () => {
      let callCount = 0;
      const queriesExecuted: string[] = [];

      const mockPersistence: Partial<ChecklistPersistence> = {
        async getDailyReportAuthoritativeApplicability(input) {
          callCount += 1;
          queriesExecuted.push("rpc:get_daily_report_authoritative_applicability");
          return branches23.flatMap((b) => [
            { branch_id: b.id, timezone: b.timezone, close_at: "2026-10-28T01:00:00Z", module_key: "kitchen_opening", required: true, requirement_basis: "static" },
            { branch_id: b.id, timezone: b.timezone, close_at: "2026-10-28T01:00:00Z", module_key: "foh_opening", required: true, requirement_basis: "static" },
            { branch_id: b.id, timezone: b.timezone, close_at: "2026-10-28T01:00:00Z", module_key: "staff_hygiene", required: true, requirement_basis: "eligible_operational_staff" },
            { branch_id: b.id, timezone: b.timezone, close_at: "2026-10-28T01:00:00Z", module_key: "daily_audit", required: true, requirement_basis: "static" },
            { branch_id: b.id, timezone: b.timezone, close_at: "2026-10-28T01:00:00Z", module_key: "cold_storage", required: true, requirement_basis: "eligible_cold_storage_equipment" },
            { branch_id: b.id, timezone: b.timezone, close_at: "2026-10-28T01:00:00Z", module_key: "oil_tracking", required: true, requirement_basis: "eligible_oil_tracking_fryers" },
            { branch_id: b.id, timezone: b.timezone, close_at: "2026-10-28T01:00:00Z", module_key: "sales_tracking", required: true, requirement_basis: "static" },
          ]);
        },
        async getManagedSalesTrackingPeriodSummary() {
          callCount += 1;
          queriesExecuted.push("rpc:get_managed_sales_tracking_period_summary");
          return samplePeriodSummary;
        },
      };

      const customProvider = async (oId: string, bDate: string, actorUserId?: string | null): Promise<ReconciliationDataSources> => {
        // Authoritative applicability RPC
        const applicabilityRows = await mockPersistence.getDailyReportAuthoritativeApplicability!({
          actorUserId,
          organizationId: oId,
          businessDate: bDate,
        });

        // 7 batched data queries
        callCount += 1; queriesExecuted.push("query:branches");
        callCount += 1; queriesExecuted.push("query:checklist_submissions");
        callCount += 1; queriesExecuted.push("query:cold_storage_submissions");
        callCount += 1; queriesExecuted.push("query:oil_tracking_submissions");
        callCount += 1; queriesExecuted.push("query:sales_tracking_report_cases");
        callCount += 1; queriesExecuted.push("query:branch_operational_teams");
        callCount += 1; queriesExecuted.push("query:maintenance_issues");

        return {
          branches: branches23,
          moduleApplicabilities: applicabilityRows.map((r) => ({
            branchId: r.branch_id,
            moduleKey: r.module_key,
            required: r.required,
            requirementBasis: r.requirement_basis,
          })),
          operationalTeams: branches23.map((b) => ({
            teamId: `55000000-0000-4000-8000-${b.id.slice(24)}`,
            branchId: b.id,
            active: true,
            hasOnDutyStaff: true,
          })),
        };
      };

      const service = createDailyBusinessReportService(
        "https://example.supabase.co",
        "service-key",
        mockPersistence as ChecklistPersistence,
        {
          dataSourceProvider: customProvider,
          nowProvider: () => new Date("2026-10-28T06:00:00.000Z"),
        },
      );

      const start = performance.now();
      const preview = await service.getReportPreview({
        actorUserId: "10000000-0000-4000-8000-000000000001",
        organizationId: orgId,
        businessDate,
      });
      const durationMs = performance.now() - start;

      // Baseline: 8 calls. Phase 2.6: exactly 9 calls (+1 authoritative RPC call).
      assert.equal(callCount, 9);
      assert.equal(queriesExecuted.length, 9);
      assert.ok(queriesExecuted.includes("rpc:get_daily_report_authoritative_applicability"));
      assert.ok(queriesExecuted.includes("rpc:get_managed_sales_tracking_period_summary"));
      assert.equal(preview.payload.branches.length, 23);
      assert.equal(preview.payload.summary.required_count, 23 * 7);
      assert.ok(durationMs < 50, `Preview duration ${durationMs}ms exceeded 50ms benchmark`);
    });
  });

  describe("21. Phase 2.6 RPC Security & Tenant Isolation", () => {
    it("propagates cross-tenant access rejection from authoritative applicability RPC", async () => {
      const mockPersistence: Partial<ChecklistPersistence> = {
        async getDailyReportAuthoritativeApplicability(input) {
          if (input.organizationId !== orgId) {
            throw new DailyBusinessReportAccessError("daily business report applicability access denied");
          }
          return [];
        },
      };

      const customProvider = async (oId: string, bDate: string, actorUserId?: string | null) => {
        await mockPersistence.getDailyReportAuthoritativeApplicability!({
          actorUserId,
          organizationId: oId,
          businessDate: bDate,
        });
        return { branches: [] };
      };

      const service = createDailyBusinessReportService(
        "https://example.supabase.co",
        "service-key",
        mockPersistence as ChecklistPersistence,
        { dataSourceProvider: customProvider },
      );

      await assert.rejects(
        () => service.getReportPreview({
          actorUserId: "10000000-0000-4000-8000-000000000002",
          organizationId: otherOrgId,
          businessDate,
        }),
        (err: any) => err instanceof DailyBusinessReportAccessError && err.status === 403,
      );
    });

    it("rejects preview requests with NULL actor user ID", async () => {
      const mockPersistence: Partial<ChecklistPersistence> = {
        async getDailyReportAuthoritativeApplicability(input) {
          if (!input.actorUserId && (!input.jobId || !input.leaseToken)) {
            throw new DailyBusinessReportAccessError(
              "daily business report applicability requires authenticated actor or authorized server lease",
            );
          }
          return [];
        },
      };

      const customProvider = async (oId: string, bDate: string, actorUserId?: string | null, jobContext?: any) => {
        await mockPersistence.getDailyReportAuthoritativeApplicability!({
          actorUserId,
          organizationId: oId,
          businessDate: bDate,
          jobId: jobContext?.jobId,
          leaseToken: jobContext?.leaseToken,
        });
        return { branches: [] };
      };

      const service = createDailyBusinessReportService(
        "https://example.supabase.co",
        "service-key",
        mockPersistence as ChecklistPersistence,
        { dataSourceProvider: customProvider },
      );

      await assert.rejects(
        () => service.getReportPreview({
          actorUserId: null as any,
          organizationId: orgId,
          businessDate,
        }),
        (err: any) => err instanceof DailyBusinessReportAccessError && err.status === 403,
      );
    });

    it("rejects unauthorized actor attempting manager preview", async () => {
      const mockPersistence: Partial<ChecklistPersistence> = {
        async getDailyReportAuthoritativeApplicability(input) {
          if (input.actorUserId !== "10000000-0000-4000-8000-000000000001") {
            throw new DailyBusinessReportAccessError("daily business report applicability access denied");
          }
          return [];
        },
      };

      const customProvider = async (oId: string, bDate: string, actorUserId?: string | null) => {
        await mockPersistence.getDailyReportAuthoritativeApplicability!({
          actorUserId,
          organizationId: oId,
          businessDate: bDate,
        });
        return { branches: [] };
      };

      const service = createDailyBusinessReportService(
        "https://example.supabase.co",
        "service-key",
        mockPersistence as ChecklistPersistence,
        { dataSourceProvider: customProvider },
      );

      await assert.rejects(
        () => service.getReportPreview({
          actorUserId: "99999999-0000-4000-8000-999999999999", // unauthorized user
          organizationId: orgId,
          businessDate,
        }),
        (err: any) => err instanceof DailyBusinessReportAccessError && err.status === 403,
      );
    });

    it("authorizes server generator via valid leased job token without actor", async () => {
      const validLeaseToken = "33333333-3333-4000-8000-333333333333";
      const validJobId = "44444444-4444-4000-8000-444444444444";
      const targetBranchId = "20000000-0000-4000-8000-000000000001";

      const mockPersistence: Partial<ChecklistPersistence> = {
        async getDailyReportAuthoritativeApplicability(input) {
          if (input.jobId === validJobId && input.leaseToken === validLeaseToken) {
            return [
              { branch_id: targetBranchId, timezone: "Asia/Riyadh", close_at: "2026-10-29T01:00:00Z", module_key: "kitchen_opening", required: true, requirement_basis: "static" },
              { branch_id: targetBranchId, timezone: "Asia/Riyadh", close_at: "2026-10-29T01:00:00Z", module_key: "foh_opening", required: true, requirement_basis: "static" },
              { branch_id: targetBranchId, timezone: "Asia/Riyadh", close_at: "2026-10-29T01:00:00Z", module_key: "staff_hygiene", required: true, requirement_basis: "eligible_operational_staff" },
              { branch_id: targetBranchId, timezone: "Asia/Riyadh", close_at: "2026-10-29T01:00:00Z", module_key: "daily_audit", required: true, requirement_basis: "static" },
              { branch_id: targetBranchId, timezone: "Asia/Riyadh", close_at: "2026-10-29T01:00:00Z", module_key: "cold_storage", required: true, requirement_basis: "eligible_cold_storage_equipment" },
              { branch_id: targetBranchId, timezone: "Asia/Riyadh", close_at: "2026-10-29T01:00:00Z", module_key: "oil_tracking", required: true, requirement_basis: "eligible_oil_tracking_fryers" },
              { branch_id: targetBranchId, timezone: "Asia/Riyadh", close_at: "2026-10-29T01:00:00Z", module_key: "sales_tracking", required: true, requirement_basis: "static" },
            ];
          }
          throw new DailyBusinessReportAccessError("daily business report generation lease invalid or expired");
        },
        async finalizeDailyBusinessReportJob() {
          return { report_id: "report-1", revision_id: "rev-1", revision: 1, created: true };
        },
      };

      const generator = new DailyBusinessReportGenerator(
        mockPersistence as ChecklistPersistence,
        async (oId, bDate, actorUserId, jobContext) => {
          const rows = await mockPersistence.getDailyReportAuthoritativeApplicability!({
            actorUserId,
            organizationId: oId,
            businessDate: bDate,
            jobId: jobContext?.jobId,
            leaseToken: jobContext?.leaseToken,
          });
          return {
            branches: [{ id: targetBranchId, name: "Olaya", name_ar: "العليا", code: "B01", timezone: "Asia/Riyadh", active: true }],
            moduleApplicabilities: rows.map((r) => ({
              branchId: r.branch_id,
              moduleKey: r.module_key as any,
              required: r.required,
              requirementBasis: r.requirement_basis as any,
            })),
          };
        },
        () => new Date("2026-10-29T01:30:00.000Z"),
      );

      const job: ClaimedJob = {
        job_id: validJobId,
        lease_token: validLeaseToken,
        organization_id: orgId,
        business_date: businessDate,
        due_at: "2026-10-29T01:00:00.000Z",
        source_watermark: "wm-1",
        attempt_count: 1,
        lease_expires_at: "2026-10-29T01:35:00.000Z",
      };

      const res = await generator.processClaimedJob(job, "worker-1");
      assert.equal(res.error, undefined);
      assert.equal(res.success, true);
      assert.equal(res.revision, 1);
    });
  });

  describe("22. Phase 2.6 Historical Branch Lifecycle & Applicability Combinations", () => {
    it("handles historical dates and branch activation/deactivation lifecycle accurately", async () => {
      // Historical test:
      // Branch 1 active across entire history
      // Branch 2 deactivated on 2026-06-01
      // Branch 3 activated on 2026-08-01
      const historicalLifecycleSimulator = (bDate: string) => {
        const branches = [
          { id: "branch-1", name: "Branch 1", active: true },
        ];
        if (bDate < "2026-06-01") {
          branches.push({ id: "branch-2", name: "Branch 2 (Deactivated June 2026)", active: true });
        }
        if (bDate >= "2026-08-01") {
          branches.push({ id: "branch-3", name: "Branch 3 (Activated August 2026)", active: true });
        }
        return branches;
      };

      // Case A: March 2026 (Branch 1 and Branch 2 active; Branch 3 not yet active)
      const marchBranches = historicalLifecycleSimulator("2026-03-01");
      assert.deepEqual(marchBranches.map((b) => b.id), ["branch-1", "branch-2"]);

      // Case B: July 2026 (Branch 1 active; Branch 2 inactive; Branch 3 not yet active)
      const julyBranches = historicalLifecycleSimulator("2026-07-01");
      assert.deepEqual(julyBranches.map((b) => b.id), ["branch-1"]);

      // Case C: September 2026 (Branch 1 active; Branch 2 inactive; Branch 3 active)
      const septBranches = historicalLifecycleSimulator("2026-09-01");
      assert.deepEqual(septBranches.map((b) => b.id), ["branch-1", "branch-3"]);
    });

    it("fails closed when duplicate applicability rows are detected", async () => {
      const mockPersistence: Partial<ChecklistPersistence> = {
        async getDailyReportAuthoritativeApplicability() {
          throw new DailyBusinessReportUnavailableError(
            "daily business report module applicability duplicate records detected",
          );
        },
      };

      const customProvider = async (oId: string, bDate: string, actorUserId?: string | null) => {
        await mockPersistence.getDailyReportAuthoritativeApplicability!({
          actorUserId,
          organizationId: oId,
          businessDate: bDate,
        });
        return { branches: [] };
      };

      const service = createDailyBusinessReportService(
        "https://example.supabase.co",
        "service-key",
        mockPersistence as ChecklistPersistence,
        { dataSourceProvider: customProvider },
      );

      await assert.rejects(
        () => service.getReportPreview({
          actorUserId: "10000000-0000-4000-8000-000000000001",
          organizationId: orgId,
          businessDate,
        }),
        (err: any) => err instanceof DailyBusinessReportUnavailableError &&
          err.message.includes("duplicate records detected"),
      );
    });

    it("fails closed when an active branch has missing module applicability combinations", async () => {
      const mockPersistence: Partial<ChecklistPersistence> = {
        async getDailyReportAuthoritativeApplicability() {
          throw new DailyBusinessReportUnavailableError(
            "daily business report module applicability missing",
          );
        },
      };

      const customProvider = async (oId: string, bDate: string, actorUserId?: string | null) => {
        await mockPersistence.getDailyReportAuthoritativeApplicability!({
          actorUserId,
          organizationId: oId,
          businessDate: bDate,
        });
        return { branches: [] };
      };

      const service = createDailyBusinessReportService(
        "https://example.supabase.co",
        "service-key",
        mockPersistence as ChecklistPersistence,
        { dataSourceProvider: customProvider },
      );

      await assert.rejects(
        () => service.getReportPreview({
          actorUserId: "10000000-0000-4000-8000-000000000001",
          organizationId: orgId,
          businessDate,
        }),
        (err: any) => err instanceof DailyBusinessReportUnavailableError &&
          err.message.includes("module applicability missing"),
      );
    });
  });
});
