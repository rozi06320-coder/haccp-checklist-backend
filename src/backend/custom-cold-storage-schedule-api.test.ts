import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";
import {
  AdminAccessError,
  AdminConflictError,
  AdminInputError,
  AdminNotFoundError,
  AdminOperationError,
  createManagementAdmin,
  type InternalAdminBranchColdStorageScheduleConfig,
} from "./admin";
import { createApp } from "./app";
import { loadBackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const ids = {
  actor: "10000000-0000-4000-8000-000000000001",
  orgA: "20000000-0000-4000-8000-000000000001",
  orgB: "20000000-0000-4000-8000-000000000002",
  branchA: "30000000-0000-4000-8000-000000000001",
  branchB: "30000000-0000-4000-8000-000000000002",
  assignment1: "40000000-0000-4000-8000-000000000001",
  assignment2: "40000000-0000-4000-8000-000000000002",
  versionStd: "50000000-0000-4000-8000-000000000001",
  versionCustom: "50000000-0000-4000-8000-000000000002",
};

const enabledConfig = loadBackendConfig({
  NODE_ENV: "test",
  SUPABASE_URL: "http://127.0.0.1:54321",
  SUPABASE_PUBLISHABLE_KEY: "publishable-test-placeholder",
  DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
  CUSTOM_COLD_STORAGE_SCHEDULE_ENABLED: "true",
});

const defaultDisabledConfig = loadBackendConfig({
  NODE_ENV: "test",
  SUPABASE_URL: "http://127.0.0.1:54321",
  SUPABASE_PUBLISHABLE_KEY: "publishable-test-placeholder",
  DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
});

function sortBy0400(slots: string[]) {
  return [...slots].sort((a, b) => {
    const [ah, am] = a.split(":").map(Number);
    const [bh, bm] = b.split(":").map(Number);
    const ao = (ah < 4 ? ah + 24 : ah) * 60 + am;
    const bo = (bh < 4 ? bh + 24 : bh) * 60 + bm;
    return ao - bo;
  });
}

function makeScheduleConfig(overrides: Partial<InternalAdminBranchColdStorageScheduleConfig> = {}): InternalAdminBranchColdStorageScheduleConfig {
  return {
    branch_id: ids.branchA,
    organization_id: ids.orgA,
    timezone: "Asia/Riyadh",
    business_date: "2026-11-28",
    next_valid_business_date: "2026-11-29",
    current: {
      assignment_id: ids.assignment1,
      schedule_version_id: ids.versionStd,
      schedule_code: "STANDARD",
      schedule_name: "Standard",
      effective_from_business_date: "2026-01-01",
      effective_to_business_date: null,
      slots: [
        { slot: "12:00", ordinal: 1 },
        { slot: "20:00", ordinal: 2 },
        { slot: "02:00", ordinal: 3 },
      ],
    },
    pending: null,
    history: [
      {
        assignment_id: ids.assignment1,
        schedule_version_id: ids.versionStd,
        schedule_code: "STANDARD",
        schedule_name: "Standard",
        effective_from_business_date: "2026-01-01",
        effective_to_business_date: null,
        slots: [
          { slot: "12:00", ordinal: 1 },
          { slot: "20:00", ordinal: 2 },
          { slot: "02:00", ordinal: 3 },
        ],
      },
    ],
    available: [
      {
        schedule_version_id: ids.versionStd,
        schedule_code: "STANDARD",
        schedule_name: "Standard",
        slots: [
          { slot: "12:00", ordinal: 1 },
          { slot: "20:00", ordinal: 2 },
          { slot: "02:00", ordinal: 3 },
        ],
      },
    ],
    ...overrides,
  };
}

function createDeps(options: {
  internalAdmin?: boolean;
  ready?: boolean | "throw";
  schedules?: Map<string, InternalAdminBranchColdStorageScheduleConfig>;
} = {}): BackendDependencies {
  const schedules = options.schedules ?? new Map([[ids.branchA, makeScheduleConfig()]]);

  return {
    authVerifier: {
      async verify(token) {
        if (token !== "valid") return null;
        return { userId: ids.actor, email: "admin@example.com" };
      },
    },
    async checkReadiness() {
      return true;
    },
    createUserContext() {
      return {
        async getUserContext(userId) {
          return {
            id: userId,
            full_name: "Internal Admin",
            must_change_password: false,
            disabled: false,
            branches: [],
            managed_organizations: [],
          };
        },
        async isInternalAdmin() {
          return options.internalAdmin ?? true;
        },
        async listActiveBranches() {
          return [];
        },
      };
    },
    managementAdmin: {
      async listOrganizationsForInternalAdmin() {
        return [{ id: ids.orgA, name: "Org A", slug: "org-a", active: true, branch_count: 1 }];
      },
      async listBranchesForInternalAdmin(_actorUserId, organizationId) {
        if (organizationId !== ids.orgA) throw new AdminNotFoundError();
        return [{ id: ids.branchA, name: "Branch A", code: "BR-A", timezone: "Asia/Riyadh", country_code: "SA", active: true }];
      },
      async isCustomColdStorageScheduleDatabaseReady() {
        if (options.ready === "throw") throw new Error("db unreachable");
        return options.ready ?? true;
      },
      async getBranchColdStorageScheduleForInternalAdmin(input) {
        if (!(options.internalAdmin ?? true)) throw new AdminAccessError();
        const item = schedules.get(input.branchId);
        if (!item || item.organization_id !== input.organizationId) throw new AdminNotFoundError();
        return structuredClone(item);
      },
      async setBranchCustomColdStorageScheduleForInternalAdmin(input) {
        if (!(options.internalAdmin ?? true)) throw new AdminAccessError();
        const item = schedules.get(input.branchId);
        if (!item || item.organization_id !== input.organizationId) throw new AdminNotFoundError();
        if (input.effectiveFromBusinessDate <= item.business_date) throw new AdminInputError();

        const sorted = sortBy0400(input.slotTimes);
        const name = input.scheduleName ?? `Custom (${sorted.length} checks)`;
        if (item.pending) {
          const sameSlots = item.pending.slots.map((s) => s.slot).join(",") === sorted.join(",");
          if (
            item.pending.effective_from_business_date === input.effectiveFromBusinessDate
            && sameSlots
            && item.pending.schedule_name === name
          ) {
            return structuredClone(item);
          }
          throw new AdminConflictError();
        }

        const pendingAssignment = {
          assignment_id: ids.assignment2,
          schedule_version_id: ids.versionCustom,
          schedule_code: "CUSTOM_TEST",
          schedule_name: name,
          effective_from_business_date: input.effectiveFromBusinessDate,
          effective_to_business_date: null,
          slots: sorted.map((slot, index) => ({ slot, ordinal: index + 1 })),
        };
        const updated: InternalAdminBranchColdStorageScheduleConfig = {
          ...item,
          pending: pendingAssignment,
          history: [pendingAssignment, ...item.history],
        };
        schedules.set(input.branchId, updated);
        return structuredClone(updated);
      },
    } as BackendDependencies["managementAdmin"],
  };
}

let activeServer: ReturnType<ReturnType<typeof createApp>["listen"]> | null = null;
let activeApp: ReturnType<typeof createApp> | null = null;

afterEach(async () => {
  if (activeServer) {
    await new Promise<void>((resolve) => activeServer!.close(() => resolve()));
    activeServer = null;
    activeApp = null;
  }
});

async function dispatch(
  app: ReturnType<ReturnType<typeof createApp> extends infer T ? () => T : never>,
  method: string,
  path: string,
  options: { token?: string; body?: unknown; headers?: Record<string, string> } = {},
) {
  if (activeServer && activeApp !== app) {
    await new Promise<void>((resolve) => activeServer!.close(() => resolve()));
    activeServer = null;
    activeApp = null;
  }
  if (!activeServer || !activeServer.listening) {
    activeApp = app;
    activeServer = app.listen(0, "127.0.0.1");
    await new Promise<void>((resolve) => activeServer!.once("listening", resolve));
  }
  const address = activeServer.address() as { port: number };
  const res = await fetch(`http://127.0.0.1:${address.port}${path}`, {
    method,
    headers: {
      ...(options.token ? { authorization: `Bearer ${options.token}` } : {}),
      ...(options.body !== undefined ? { "content-type": "application/json" } : {}),
      ...(options.headers ?? {}),
    },
    ...(options.body !== undefined ? { body: JSON.stringify(options.body) } : {}),
  });
  const text = await res.text();
  return { status: res.status, json: text ? JSON.parse(text) : null };
}

describe("Custom Cold Storage Schedule Phase 3 Backend API & Contracts", () => {
  it("disables capability by default while keeping organizations, branches, and auth working", async () => {
    assert.equal(defaultDisabledConfig.customColdStorageScheduleEnabled, false);
    const app = createApp(defaultDisabledConfig, createDeps());
    const path = `/api/v1/internal-admin/organizations/${ids.orgA}/branches/${ids.branchA}/cold-storage-schedule`;

    assert.equal((await dispatch(app, "GET", path)).status, 401);
    const getRes = await dispatch(app, "GET", path, { token: "valid" });
    assert.equal(getRes.status, 200);
    assert.equal(getRes.json.enabled, false);
    assert.equal(getRes.json.current, null);

    const putRes = await dispatch(app, "PUT", path, {
      token: "valid",
      body: { slot_times: ["09:00"], effective_from_business_date: "2026-11-29" },
    });
    assert.equal(putRes.status, 503);

    // Existing Internal Admin endpoints remain completely unaffected
    const orgsRes = await dispatch(app, "GET", "/api/v1/internal-admin/organizations", { token: "valid" });
    assert.equal(orgsRes.status, 200);
    assert.equal(orgsRes.json.organizations.length, 1);

    const branchesRes = await dispatch(app, "GET", `/api/v1/internal-admin/organizations/${ids.orgA}/branches`, { token: "valid" });
    assert.equal(branchesRes.status, 200);
    assert.equal(branchesRes.json.branches.length, 1);
  });

  it("fails closed when CUSTOM_COLD_STORAGE_SCHEDULE_ENABLED is true but DB readiness probe is false or throws", async () => {
    for (const mode of [false, "throw"] as const) {
      const app = createApp(enabledConfig, createDeps({ ready: mode }));
      const path = `/api/v1/internal-admin/organizations/${ids.orgA}/branches/${ids.branchA}/cold-storage-schedule`;

      const getRes = await dispatch(app, "GET", path, { token: "valid" });
      assert.equal(getRes.status, 200);
      assert.equal(getRes.json.enabled, false);

      const putRes = await dispatch(app, "PUT", path, {
        token: "valid",
        body: { slot_times: ["09:00"], effective_from_business_date: "2026-11-29" },
      });
      assert.equal(putRes.status, 503);
    }
  });

  it("createManagementAdmin.isCustomColdStorageScheduleDatabaseReady verifies exact RPC denial messages and fails closed", async () => {
    const originalFetch = globalThis.fetch;
    let mode: "ready" | "missing" | "bad_perm" | "bad_contract" | "throw" = "ready";
    globalThis.fetch = (async () => {
      if (mode === "throw") throw new Error("network error");
      if (mode === "missing") {
        return new Response(JSON.stringify({ code: "PGRST202", message: "not found" }), {
          status: 404,
          headers: { "Content-Type": "application/json" },
        });
      }
      if (mode === "bad_perm") {
        return new Response(JSON.stringify({ code: "42501", message: "permission denied for function" }), {
          status: 403,
          headers: { "Content-Type": "application/json" },
        });
      }
      if (mode === "bad_contract") {
        return new Response(JSON.stringify({ ok: true }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }
      return new Response(JSON.stringify({ code: "42501", message: "schedule access denied" }), {
        status: 403,
        headers: { "Content-Type": "application/json" },
      });
    }) as typeof fetch;

    try {
      const admin = createManagementAdmin("http://127.0.0.1:54321", "service-role-placeholder");
      mode = "ready";
      assert.equal(await admin.isCustomColdStorageScheduleDatabaseReady?.(), true);
      mode = "missing";
      assert.equal(await admin.isCustomColdStorageScheduleDatabaseReady?.(), false);
      mode = "bad_perm";
      assert.equal(await admin.isCustomColdStorageScheduleDatabaseReady?.(), false);
      mode = "bad_contract";
      assert.equal(await admin.isCustomColdStorageScheduleDatabaseReady?.(), false);
      mode = "throw";
      assert.equal(await admin.isCustomColdStorageScheduleDatabaseReady?.(), false);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it("enforces auth, validation (1/3/4/12/48, duplicates, invalid times, extra fields), cross-org 404, idempotency, and 409 conflict", async () => {
    const unauthApp = createApp(enabledConfig, createDeps({ internalAdmin: false }));
    const path = `/api/v1/internal-admin/organizations/${ids.orgA}/branches/${ids.branchA}/cold-storage-schedule`;
    assert.equal((await dispatch(unauthApp, "GET", path, { token: "valid" })).status, 403);

    const app = createApp(enabledConfig, createDeps());

    // Invalid payloads
    for (const badBody of [
      { slot_times: [], effective_from_business_date: "2026-11-29" },
      { slot_times: ["09:00", "09:00"], effective_from_business_date: "2026-11-29" },
      { slot_times: ["24:00"], effective_from_business_date: "2026-11-29" },
      { slot_times: ["09:00"], effective_from_business_date: "2026-11-29", actor_user_id: ids.actor },
    ]) {
      const badRes = await dispatch(app, "PUT", path, { token: "valid", body: badBody });
      assert.equal(badRes.status, 400);
    }

    // Cross-organization 404
    const crossOrgPath = `/api/v1/internal-admin/organizations/${ids.orgB}/branches/${ids.branchA}/cold-storage-schedule`;
    assert.equal((await dispatch(app, "GET", crossOrgPath, { token: "valid" })).status, 404);

    // Past/today business date -> 422
    const pastRes = await dispatch(app, "PUT", path, {
      token: "valid",
      body: { slot_times: ["09:00"], effective_from_business_date: "2026-11-28" },
    });
    assert.equal(pastRes.status, 422);

    // Valid 4-slot overnight schedule -> 200 sorted by 04:00 chronology
    const okRes = await dispatch(app, "PUT", path, {
      token: "valid",
      body: {
        slot_times: ["03:30", "10:00", "01:30", "21:00"],
        effective_from_business_date: "2026-11-29",
        schedule_name: "4-Slot Overnight",
      },
    });
    assert.equal(okRes.status, 200);
    assert.equal(okRes.json.enabled, true);
    assert.deepEqual(
      okRes.json.pending.slots.map((s: { slot: string }) => s.slot),
      ["10:00", "21:00", "01:30", "03:30"],
    );

    // Idempotent repeat -> 200
    const repeatRes = await dispatch(app, "PUT", path, {
      token: "valid",
      body: {
        slot_times: ["21:00", "01:30", "10:00", "03:30"],
        effective_from_business_date: "2026-11-29",
        schedule_name: "4-Slot Overnight",
      },
    });
    assert.equal(repeatRes.status, 200);

    // Conflicting future assignment -> 409
    const conflictRes = await dispatch(app, "PUT", path, {
      token: "valid",
      body: { slot_times: ["09:00"], effective_from_business_date: "2026-11-30" },
    });
    assert.equal(conflictRes.status, 409);

    // 48-slot validation passes schema
    const slots48 = Array.from({ length: 48 }, (_, i) => `${String(Math.floor(i / 2)).padStart(2, "0")}:${i % 2 === 0 ? "00" : "30"}`);
    const app48 = createApp(enabledConfig, createDeps({ schedules: new Map([[ids.branchB, makeScheduleConfig({ branch_id: ids.branchB })]]) }));
    const res48 = await dispatch(
      app48,
      "PUT",
      `/api/v1/internal-admin/organizations/${ids.orgA}/branches/${ids.branchB}/cold-storage-schedule`,
      { token: "valid", body: { slot_times: slots48, effective_from_business_date: "2026-11-29" } },
    );
    assert.equal(res48.status, 200);
    assert.equal(res48.json.pending.slots.length, 48);
  });

  it("maps unexpected RPC/adapter errors to 503 without leaking raw SQL details", async () => {
    const deps = createDeps();
    deps.managementAdmin.getBranchColdStorageScheduleForInternalAdmin = async () => {
      throw new AdminOperationError();
    };
    const app = createApp(enabledConfig, deps);
    const res = await dispatch(
      app,
      "GET",
      `/api/v1/internal-admin/organizations/${ids.orgA}/branches/${ids.branchA}/cold-storage-schedule`,
      { token: "valid" },
    );
    assert.equal(res.status, 503);
    assert.equal(res.json.error.code, "service_unavailable");
  });

  it("enforces 4800-reading Express capacity on Cold Storage draft/submit while keeping 100kb global limit", async () => {
    const deps = createDeps();
    let lastDraftCount = 0;
    let lastSubmitCount = 0;
    const eqUuid = "88888888-8888-4888-8888-888888888881";
    const mockCurrent = {
      business_date: "2026-11-28",
      state: "draft",
      revision: 1,
      submission_id: "99999999-9999-4999-8999-999999999991",
      active_slot: "12:00",
      next_slot: "12:30",
      next_transition_at: "2026-11-28T09:30:00Z",
      management_locked: false,
      equipment: [{ equipment_id: eqUuid, equipment_name: "Chiller 1", equipment_type: "refrigerator", active: true }],
      readings: [],
    };
    deps.createUserContext = () => ({
      async getUserContext(userId) {
        return {
          id: userId,
          full_name: "Supervisor",
          must_change_password: false,
          disabled: false,
          branches: [
            {
              id: ids.branchA,
              organization_id: ids.orgA,
              name: "Branch A",
              code: "BR-A",
              city: "Riyadh",
              timezone: "Asia/Riyadh",
              role: "branch_manager",
              active: true,
            },
          ],
          managed_organizations: [],
          maintenance_organizations: [],
          purchasing_organizations: [],
          training_organizations: [],
          internal_admin: false,
        };
      },
    }) as ReturnType<BackendDependencies["createUserContext"]>;
    deps.checklistPersistence = {
      saveColdStorageDraft: async (_actor, _branch, _rev, _eq, readings) => {
        lastDraftCount = readings.length;
        return mockCurrent;
      },
      submitColdStorageSlot: async (input: { readings: unknown[] }) => {
        lastSubmitCount = input.readings.length;
        return { ...mockCurrent, state: "submitted" };
      },
    } as unknown as BackendDependencies["checklistPersistence"];

    const app = createApp(enabledConfig, deps);
    const slots48 = Array.from({ length: 48 }, (_, i) => {
      const hh = String(Math.floor((i * 30) / 60)).padStart(2, "0");
      const mm = String((i * 30) % 60).padStart(2, "0");
      return `${hh}:${mm}`;
    });
    const equipment100 = Array.from({ length: 100 }, (_, i) => ({
      equipment_id: `88888888-8888-4888-8888-${String(i + 1).padStart(12, "0")}`,
      equipment_name: `Unit ${i + 1}`,
      equipment_type: "refrigerator",
    }));
    const readings4800 = equipment100.flatMap((eq) =>
      slots48.map((slot) => ({
        equipment_id: eq.equipment_id,
        slot,
        temperature_c: 3.5,
        status: "pass",
        corrective_action: "",
      })),
    );
    assert.equal(readings4800.length, 4800);
    const payloadBytes = Buffer.byteLength(JSON.stringify({ expected_revision: 0, equipment: equipment100, readings: readings4800 }));
    assert.ok(payloadBytes > 500_000 && payloadBytes < 1_000_000, `Expected >500KB <1MB, got ${payloadBytes}`);

    // 1. 4800-reading PUT draft passes 1MB Express parser + Zod max(4800) (reaches existing draft circuit breaker 503, not 400/413)
    const resDraftOk = await dispatch(
      app,
      "PUT",
      `/api/v1/supervisor/branches/${ids.branchA}/checklists/cold_storage/draft`,
      { token: "valid", body: { expected_revision: 0, equipment: equipment100, readings: readings4800 } },
    );
    assert.equal(resDraftOk.status, 503);
    assert.equal(lastDraftCount, 0);

    // 2. 4800-reading POST submit succeeds through actual Express middleware
    const resSubmitOk = await dispatch(
      app,
      "POST",
      `/api/v1/supervisor/branches/${ids.branchA}/checklists/cold_storage/slots/12:00/submit`,
      {
        token: "valid",
        body: { expected_revision: 0, equipment: equipment100, readings: readings4800 },
        headers: { "Idempotency-Key": "77777777-7777-4777-8777-777777777771" },
      },
    );
    assert.equal(resSubmitOk.status, 201);
    assert.equal(lastSubmitCount, 4800);

    // 3. 4801 readings rejected by schema (400)
    const readings4801 = [...readings4800, { ...readings4800[0], slot: "12:01" }];
    const res4801 = await dispatch(
      app,
      "PUT",
      `/api/v1/supervisor/branches/${ids.branchA}/checklists/cold_storage/draft`,
      { token: "valid", body: { expected_revision: 0, equipment: equipment100, readings: readings4801 } },
    );
    assert.equal(res4801.status, 400);

    // 4. >1MB Cold Storage draft rejected (413)
    const over1MbReadings = readings4800.map((r) => ({ ...r, corrective_action: "x".repeat(220) }));
    const resOver1Mb = await dispatch(
      app,
      "PUT",
      `/api/v1/supervisor/branches/${ids.branchA}/checklists/cold_storage/draft`,
      { token: "valid", body: { expected_revision: 0, equipment: equipment100, readings: over1MbReadings } },
    );
    assert.equal(resOver1Mb.status, 413);

    // 5. Global 100KB limit unchanged for unrelated endpoints (413)
    const resOver100Kb = await dispatch(
      app,
      "PUT",
      `/api/v1/internal-admin/organizations/${ids.orgA}/branches/${ids.branchA}/cold-storage-schedule`,
      {
        token: "valid",
        body: {
          slot_times: ["12:00"],
          effective_from_business_date: "2026-11-29",
          schedule_name: "A".repeat(110_000),
        },
      },
    );
    assert.equal(resOver100Kb.status, 413);
  });
});
