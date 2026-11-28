import assert from "node:assert/strict";
import { IncomingMessage, ServerResponse } from "node:http";
import { Socket } from "node:net";
import { afterEach, describe, it } from "node:test";
import {
  AdminAccessError,
  AdminConflictError,
  AdminInputError,
  AdminNotFoundError,
  createManagementAdmin,
  type InternalAdminBranchClosure,
  type InternalAdminBranchDayOffConfig,
  type InternalAdminBranchWeeklyDayOffSchedule,
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
  branchC: "30000000-0000-4000-8000-000000000003",
  branchOrgB: "30000000-0000-4000-8000-000000000004",
  scheduleA1: "40000000-0000-4000-8000-000000000001",
  scheduleA2: "40000000-0000-4000-8000-000000000002",
  closureA1: "50000000-0000-4000-8000-000000000001",
  closureA2: "50000000-0000-4000-8000-000000000002",
};

const config = loadBackendConfig({
  NODE_ENV: "test",
  SUPABASE_URL: "http://127.0.0.1:54321",
  SUPABASE_PUBLISHABLE_KEY: "publishable-test-placeholder",
  DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
  BRANCH_DAY_OFF_ENABLED: "true",
});

const defaultDisabledConfig = loadBackendConfig({
  NODE_ENV: "test",
  SUPABASE_URL: "http://127.0.0.1:54321",
  SUPABASE_PUBLISHABLE_KEY: "publishable-test-placeholder",
  DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
});

type TestServer = ReturnType<typeof createApp>;
let activeApp: TestServer | null = null;

type InMemoryDayOffStore = {
  configs: Map<string, InternalAdminBranchDayOffConfig>;
  branchOrg: Map<string, string>;
};

function createStore(): InMemoryDayOffStore {
  const branchOrg = new Map<string, string>([
    [ids.branchA, ids.orgA],
    [ids.branchB, ids.orgA],
    [ids.branchC, ids.orgA],
    [ids.branchOrgB, ids.orgB],
  ]);

  const initialConfig = (
    organizationId: string,
    branchId: string,
    timezone = "Asia/Riyadh",
  ): InternalAdminBranchDayOffConfig => ({
    organization_id: organizationId,
    branch_id: branchId,
    timezone,
    current_business_date: "2026-11-23",
    is_day_off_today: false,
    day_off_reason_today: null,
    current_weekly_schedule: null,
    weekly_schedule_history: [],
    closures: [],
  });

  const configs = new Map<string, InternalAdminBranchDayOffConfig>([
    [ids.branchA, initialConfig(ids.orgA, ids.branchA, "Asia/Riyadh")],
    [ids.branchB, initialConfig(ids.orgA, ids.branchB, "Asia/Riyadh")],
    [ids.branchC, initialConfig(ids.orgA, ids.branchC, "Asia/Dubai")],
    [ids.branchOrgB, initialConfig(ids.orgB, ids.branchOrgB, "UTC")],
  ]);

  return { configs, branchOrg };
}

function recomputeTodayStatus(entry: InternalAdminBranchDayOffConfig) {
  const today = entry.current_business_date;
  // 2026-11-23 is Monday (dow = 1)
  const todayDow = 1;
  const activeClosure = entry.closures.find(
    (c) =>
      c.status === "active" &&
      c.start_business_date <= today &&
      today <= c.end_business_date,
  );
  if (activeClosure) {
    entry.is_day_off_today = true;
    entry.day_off_reason_today = activeClosure.reason;
    return;
  }
  const weekly = entry.current_weekly_schedule;
  if (
    weekly &&
    weekly.effective_from_business_date <= today &&
    (weekly.effective_to_business_date === null ||
      weekly.effective_to_business_date > today) &&
    weekly.days_of_week.includes(todayDow)
  ) {
    entry.is_day_off_today = true;
    entry.day_off_reason_today = weekly.reason;
    return;
  }
  entry.is_day_off_today = false;
  entry.day_off_reason_today = null;
}

function createDeps(
  options: {
    internalAdmin?: boolean;
    store?: InMemoryDayOffStore;
  } = {},
): BackendDependencies {
  const store = options.store ?? createStore();

  return {
    authVerifier: {
      async verify(token) {
        return token === "valid"
          ? { userId: ids.actor, email: "admin@example.invalid" }
          : null;
      },
    },
    async checkReadiness() {
      return true;
    },
    createUserContext() {
      return {
        async getUserContext() {
          return {
            id: ids.actor,
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
        async hasOrganizationManagerAccess() {
          return true;
        },
        async validateActiveBranches() {
          return true;
        },
        async listActiveBranches() {
          return [];
        },
      };
    },
    passwordChange: {
      async verifyCurrent() {
        return true;
      },
      async updatePassword() {},
      async finalize() {},
    },
    provisioningAdmin: {
      async createUser() {
        return { id: ids.actor };
      },
      async finalize() {},
      async deleteUser() {},
    },
    managementAdmin: {
      async listUsers() {
        return { users: [], total: 0 };
      },
      async listBranchesForInternalAdmin(_actor, organizationId) {
        if (organizationId !== ids.orgA) return [];
        return [
          {
            id: ids.branchA,
            name: "Branch A",
            name_ar: null,
            code: "BR-A",
            city: "Riyadh",
            area: null,
            address: null,
            timezone: "Asia/Riyadh",
            country_code: "SA",
            active: true,
            logo_path: null,
          },
          {
            id: ids.branchB,
            name: "Branch B",
            name_ar: null,
            code: "BR-B",
            city: "Riyadh",
            area: null,
            address: null,
            timezone: "Asia/Riyadh",
            country_code: "SA",
            active: true,
            logo_path: null,
          },
          {
            id: ids.branchC,
            name: "Branch C",
            name_ar: null,
            code: "BR-C",
            city: "Dubai",
            area: null,
            address: null,
            timezone: "Asia/Dubai",
            country_code: "AE",
            active: true,
            logo_path: null,
          },
        ];
      },
      async isBranchDayOffDatabaseReady() {
        return true;
      },
      async getBranchDayOffConfigForInternalAdmin(input) {
        if (!(options.internalAdmin ?? true)) throw new AdminAccessError();
        const ownerOrg = store.branchOrg.get(input.branchId);
        const current = store.configs.get(input.branchId);
        if (!ownerOrg || ownerOrg !== input.organizationId || !current) {
          throw new AdminNotFoundError();
        }
        return structuredClone(current);
      },
      async setBranchWeeklyDayOffForInternalAdmin(input) {
        if (!(options.internalAdmin ?? true)) throw new AdminAccessError();
        const ownerOrg = store.branchOrg.get(input.branchId);
        const current = store.configs.get(input.branchId);
        if (!ownerOrg || ownerOrg !== input.organizationId || !current) {
          throw new AdminNotFoundError();
        }
        const effectiveFrom =
          input.effectiveFromBusinessDate ?? current.current_business_date;
        const open = current.current_weekly_schedule;
        if (open && effectiveFrom < open.effective_from_business_date) {
          throw new AdminInputError();
        }
        const sortedDays = [...input.daysOfWeek].sort((a, b) => a - b);
        const updatedAt = "2026-11-23T15:00:00Z";
        let savedId = ids.scheduleA1;

        if (open && open.effective_from_business_date === effectiveFrom) {
          open.days_of_week = sortedDays;
          open.reason = input.reason ?? null;
          open.updated_at = updatedAt;
          savedId = open.id;
        } else {
          if (open) {
            open.effective_to_business_date = effectiveFrom;
            open.updated_at = updatedAt;
            savedId = ids.scheduleA2;
          }
          const nextSchedule = {
            id: savedId,
            days_of_week: sortedDays,
            effective_from_business_date: effectiveFrom,
            effective_to_business_date: null,
            reason: input.reason ?? null,
            updated_at: updatedAt,
          };
          current.current_weekly_schedule = nextSchedule;
          current.weekly_schedule_history = [
            nextSchedule,
            ...current.weekly_schedule_history,
          ];
        }
        recomputeTodayStatus(current);
        const result: InternalAdminBranchWeeklyDayOffSchedule = {
          id: current.current_weekly_schedule!.id,
          organization_id: input.organizationId,
          branch_id: input.branchId,
          days_of_week: current.current_weekly_schedule!.days_of_week,
          effective_from_business_date:
            current.current_weekly_schedule!.effective_from_business_date,
          effective_to_business_date:
            current.current_weekly_schedule!.effective_to_business_date,
          reason: current.current_weekly_schedule!.reason,
          updated_at: current.current_weekly_schedule!.updated_at,
        };
        return result;
      },
      async createBranchClosureForInternalAdmin(input) {
        if (!(options.internalAdmin ?? true)) throw new AdminAccessError();
        const ownerOrg = store.branchOrg.get(input.branchId);
        const current = store.configs.get(input.branchId);
        if (!ownerOrg || ownerOrg !== input.organizationId || !current) {
          throw new AdminNotFoundError();
        }
        if (input.endBusinessDate < input.startBusinessDate) {
          throw new AdminInputError();
        }
        const overlaps = current.closures.some(
          (c) =>
            c.status === "active" &&
            c.start_business_date <= input.endBusinessDate &&
            input.startBusinessDate <= c.end_business_date,
        );
        if (overlaps) throw new AdminConflictError();

        const created = {
          id:
            current.closures.length === 0 ? ids.closureA1 : ids.closureA2,
          start_business_date: input.startBusinessDate,
          end_business_date: input.endBusinessDate,
          reason: input.reason ?? null,
          status: "active" as const,
          reopened_early_at: null,
          cancelled_at: null,
          created_at: "2026-11-23T15:00:00Z",
          updated_at: "2026-11-23T15:00:00Z",
        };
        current.closures = [created, ...current.closures];
        recomputeTodayStatus(current);
        const result: InternalAdminBranchClosure = {
          ...created,
          organization_id: input.organizationId,
          branch_id: input.branchId,
        };
        return result;
      },
      async reopenBranchClosureForInternalAdmin(input) {
        if (!(options.internalAdmin ?? true)) throw new AdminAccessError();
        const ownerOrg = store.branchOrg.get(input.branchId);
        const current = store.configs.get(input.branchId);
        if (!ownerOrg || ownerOrg !== input.organizationId || !current) {
          throw new AdminNotFoundError();
        }
        const target = current.closures.find((c) => c.id === input.closureId);
        if (!target) throw new AdminNotFoundError();
        if (target.status !== "active") throw new AdminInputError();

        const reopenFrom =
          input.reopenFromBusinessDate ?? current.current_business_date;
        if (reopenFrom > target.end_business_date) throw new AdminInputError();

        if (reopenFrom <= target.start_business_date) {
          target.status = "cancelled";
          target.cancelled_at = "2026-11-23T16:00:00Z";
          target.updated_at = "2026-11-23T16:00:00Z";
        } else {
          // Decrement YYYY-MM-DD by 1 day in UTC
          const dt = new Date(`${reopenFrom}T00:00:00Z`);
          dt.setUTCDate(dt.getUTCDate() - 1);
          target.end_business_date = dt.toISOString().slice(0, 10);
          target.reopened_early_at = "2026-11-23T16:00:00Z";
          target.updated_at = "2026-11-23T16:00:00Z";
        }
        recomputeTodayStatus(current);
        return {
          ...target,
          organization_id: input.organizationId,
          branch_id: input.branchId,
        };
      },
    },
  };
}

function origin(app: TestServer): string {
  activeApp = app;
  return "http://127.0.0.1";
}

async function start(dependencies: BackendDependencies): Promise<TestServer> {
  const app = createApp(config, dependencies);
  activeApp = app;
  return app;
}

async function fetch(
  url: string,
  init?: {
    method?: string;
    headers?: Record<string, string>;
    body?: string;
  },
): Promise<{
  status: number;
  json(): Promise<unknown>;
  text(): Promise<string>;
}> {
  const app = activeApp;
  assert.ok(app, "Expected active Express test app");
  const parsedUrl = new URL(url);
  const bodyBuffer = init?.body ? Buffer.from(init.body, "utf8") : Buffer.alloc(0);

  return new Promise((resolve, reject) => {
    const socket = new Socket();
    Object.defineProperty(socket, "remoteAddress", {
      value: "127.0.0.1",
      configurable: true,
    });
    const req = new IncomingMessage(socket);
    req.method = init?.method ?? "GET";
    req.url = `${parsedUrl.pathname}${parsedUrl.search}`;
    req.headers = {};
    for (const [k, v] of Object.entries(init?.headers ?? {})) {
      req.headers[k.toLowerCase()] = v;
    }
    if (init?.body !== undefined) {
      req.headers["content-length"] = String(bodyBuffer.byteLength);
    }

    const res = new ServerResponse(req);
    const chunks: Buffer[] = [];
    const origWrite = res.write.bind(res);
    const origEnd = res.end.bind(res);

    res.write = ((chunk: unknown, encoding?: unknown, cb?: unknown) => {
      if (chunk) {
        chunks.push(
          Buffer.isBuffer(chunk)
            ? chunk
            : Buffer.from(String(chunk), typeof encoding === "string" ? (encoding as BufferEncoding) : "utf8"),
        );
      }
      return origWrite(chunk as never, encoding as never, cb as never);
    }) as typeof res.write;

    res.end = ((chunk?: unknown, encoding?: unknown, cb?: unknown) => {
      if (chunk && typeof chunk !== "function") {
        chunks.push(
          Buffer.isBuffer(chunk)
            ? chunk
            : Buffer.from(String(chunk), typeof encoding === "string" ? (encoding as BufferEncoding) : "utf8"),
        );
      }
      origEnd(chunk as never, encoding as never, cb as never);
      const rawText = Buffer.concat(chunks).toString("utf8");
      resolve({
        status: res.statusCode,
        async text() {
          return rawText;
        },
        async json() {
          return JSON.parse(rawText);
        },
      });
      return res;
    }) as typeof res.end;

    try {
      app(req, res);
      process.nextTick(() => {
        if (bodyBuffer.byteLength > 0) {
          req.push(bodyBuffer);
        }
        req.push(null);
      });
    } catch (err) {
      reject(err);
    }
  });
}

afterEach(async () => {
  activeApp = null;
});

describe("Internal Admin Branch Day Off API & Per-Branch Isolation", () => {
  it("enforces authentication and Internal Admin authorization across all 4 day-off endpoints", async () => {
    const basePath = `/api/v1/internal-admin/organizations/${ids.orgA}/branches/${ids.branchA}/day-off`;

    for (const [method, path, body] of [
      ["GET", basePath, undefined],
      ["PUT", `${basePath}/weekly-schedule`, { days_of_week: [5] }],
      [
        "POST",
        `${basePath}/closures`,
        { start_business_date: "2026-11-25", end_business_date: "2026-11-25" },
      ],
      ["POST", `${basePath}/closures/${ids.closureA1}/reopen`, {}],
    ] as const) {
      const adminServer = await start(createDeps({ internalAdmin: true }));
      const unauth = await fetch(`${origin(adminServer)}${path}`, {
        method,
        headers: {
          Authorization: "Bearer invalid",
          ...(body ? { "Content-Type": "application/json" } : {}),
        },
        body: body ? JSON.stringify(body) : undefined,
      });
      assert.equal(unauth.status, 401);

      const nonAdminServer = await start(createDeps({ internalAdmin: false }));
      const forbidden = await fetch(`${origin(nonAdminServer)}${path}`, {
        method,
        headers: {
          Authorization: "Bearer valid",
          ...(body ? { "Content-Type": "application/json" } : {}),
        },
        body: body ? JSON.stringify(body) : undefined,
      });
      assert.equal(forbidden.status, 403);
    }
  });

  it("validates request payloads and rejects malformed weekday arrays, inverted date ranges, and extra fields", async () => {
    const server = await start(createDeps());
    const basePath = `${origin(server)}/api/v1/internal-admin/organizations/${ids.orgA}/branches/${ids.branchA}/day-off`;

    // Duplicate weekday
    const dupDays = await fetch(`${basePath}/weekly-schedule`, {
      method: "PUT",
      headers: {
        Authorization: "Bearer valid",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ days_of_week: [5, 5] }),
    });
    assert.equal(dupDays.status, 400);

    // Out-of-range weekday
    const outOfRangeDay = await fetch(`${basePath}/weekly-schedule`, {
      method: "PUT",
      headers: {
        Authorization: "Bearer valid",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ days_of_week: [7] }),
    });
    assert.equal(outOfRangeDay.status, 400);

    // Inverted closure dates
    const invertedClosure = await fetch(`${basePath}/closures`, {
      method: "POST",
      headers: {
        Authorization: "Bearer valid",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        start_business_date: "2026-11-28",
        end_business_date: "2026-11-25",
      }),
    });
    assert.equal(invertedClosure.status, 400);

    // Unexpected extra field on reopen
    const extraFieldReopen = await fetch(
      `${basePath}/closures/${ids.closureA1}/reopen`,
      {
        method: "POST",
        headers: {
          Authorization: "Bearer valid",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          reopen_from_business_date: "2026-11-25",
          unexpected: true,
        }),
      },
    );
    assert.equal(extraFieldReopen.status, 400);
  });

  it("configures Day Off strictly per branch: Branch A is Day Off while Branch B and Branch C remain On Duty and active", async () => {
    const store = createStore();
    const server = await start(createDeps({ store }));

    // Configure Branch A with Monday (dow = 1, matching 2026-11-23) weekly day off + a special closure
    const setWeeklyA = await fetch(
      `${origin(server)}/api/v1/internal-admin/organizations/${ids.orgA}/branches/${ids.branchA}/day-off/weekly-schedule`,
      {
        method: "PUT",
        headers: {
          Authorization: "Bearer valid",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          days_of_week: [1, 5],
          effective_from_business_date: "2026-11-23",
          reason: "Branch A Monday & Friday off",
        }),
      },
    );
    assert.equal(setWeeklyA.status, 200);

    const createClosureA = await fetch(
      `${origin(server)}/api/v1/internal-admin/organizations/${ids.orgA}/branches/${ids.branchA}/day-off/closures`,
      {
        method: "POST",
        headers: {
          Authorization: "Bearer valid",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          start_business_date: "2026-11-23",
          end_business_date: "2026-11-23",
          reason: "Branch A deep cleaning",
        }),
      },
    );
    assert.equal(createClosureA.status, 201);

    // Fetch Day Off configs for Branch A, Branch B, and Branch C
    const [resA, resB, resC] = await Promise.all([
      fetch(
        `${origin(server)}/api/v1/internal-admin/organizations/${ids.orgA}/branches/${ids.branchA}/day-off`,
        { headers: { Authorization: "Bearer valid" } },
      ),
      fetch(
        `${origin(server)}/api/v1/internal-admin/organizations/${ids.orgA}/branches/${ids.branchB}/day-off`,
        { headers: { Authorization: "Bearer valid" } },
      ),
      fetch(
        `${origin(server)}/api/v1/internal-admin/organizations/${ids.orgA}/branches/${ids.branchC}/day-off`,
        { headers: { Authorization: "Bearer valid" } },
      ),
    ]);

    assert.equal(resA.status, 200);
    assert.equal(resB.status, 200);
    assert.equal(resC.status, 200);

    const bodyA = (await resA.json()) as { day_off: InternalAdminBranchDayOffConfig };
    const bodyB = (await resB.json()) as { day_off: InternalAdminBranchDayOffConfig };
    const bodyC = (await resC.json()) as { day_off: InternalAdminBranchDayOffConfig };

    // Branch A is Day Off
    assert.equal(bodyA.day_off.branch_id, ids.branchA);
    assert.equal(bodyA.day_off.is_day_off_today, true);
    assert.equal(bodyA.day_off.day_off_reason_today, "Branch A deep cleaning");
    assert.deepEqual(bodyA.day_off.current_weekly_schedule?.days_of_week, [1, 5]);
    assert.equal(bodyA.day_off.closures.length, 1);

    // Branch B remains On Duty with zero schedules or closures
    assert.equal(bodyB.day_off.branch_id, ids.branchB);
    assert.equal(bodyB.day_off.is_day_off_today, false);
    assert.equal(bodyB.day_off.day_off_reason_today, null);
    assert.equal(bodyB.day_off.current_weekly_schedule, null);
    assert.deepEqual(bodyB.day_off.closures, []);

    // Branch C remains On Duty with zero schedules or closures
    assert.equal(bodyC.day_off.branch_id, ids.branchC);
    assert.equal(bodyC.day_off.is_day_off_today, false);
    assert.equal(bodyC.day_off.day_off_reason_today, null);
    assert.equal(bodyC.day_off.current_weekly_schedule, null);
    assert.deepEqual(bodyC.day_off.closures, []);

    // Verify existing GET /branches API still returns all 3 branches as active: true
    const branchesRes = await fetch(
      `${origin(server)}/api/v1/internal-admin/organizations/${ids.orgA}/branches`,
      { headers: { Authorization: "Bearer valid" } },
    );
    assert.equal(branchesRes.status, 200);
    const branchesBody = (await branchesRes.json()) as {
      branches: Array<{ id: string; active: boolean }>;
    };
    assert.equal(branchesBody.branches.length, 3);
    assert.equal(
      branchesBody.branches.every((b) => b.active === true),
      true,
    );
  });

  it("rejects cross-organization branch access and cross-branch closure reopening with 404", async () => {
    const store = createStore();
    const server = await start(createDeps({ store }));

    // Org A trying to access or mutate Org B's branch
    const crossOrgGet = await fetch(
      `${origin(server)}/api/v1/internal-admin/organizations/${ids.orgA}/branches/${ids.branchOrgB}/day-off`,
      { headers: { Authorization: "Bearer valid" } },
    );
    assert.equal(crossOrgGet.status, 404);

    const crossOrgPut = await fetch(
      `${origin(server)}/api/v1/internal-admin/organizations/${ids.orgA}/branches/${ids.branchOrgB}/day-off/weekly-schedule`,
      {
        method: "PUT",
        headers: {
          Authorization: "Bearer valid",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ days_of_week: [5] }),
      },
    );
    assert.equal(crossOrgPut.status, 404);

    // Create closure on Branch A, then try to reopen it under Branch B's URL
    const createRes = await fetch(
      `${origin(server)}/api/v1/internal-admin/organizations/${ids.orgA}/branches/${ids.branchA}/day-off/closures`,
      {
        method: "POST",
        headers: {
          Authorization: "Bearer valid",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          start_business_date: "2026-11-25",
          end_business_date: "2026-11-27",
          reason: "Branch A maintenance",
        }),
      },
    );
    assert.equal(createRes.status, 201);
    const { closure } = (await createRes.json()) as {
      closure: InternalAdminBranchClosure;
    };

    const crossBranchReopen = await fetch(
      `${origin(server)}/api/v1/internal-admin/organizations/${ids.orgA}/branches/${ids.branchB}/day-off/closures/${closure.id}/reopen`,
      {
        method: "POST",
        headers: {
          Authorization: "Bearer valid",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ reopen_from_business_date: "2026-11-26" }),
      },
    );
    assert.equal(crossBranchReopen.status, 404);
  });

  it("supports weekly schedule effective-date transitions, closure conflict rejection (409), early reopening, and cancellation", async () => {
    const store = createStore();
    const server = await start(createDeps({ store }));
    const basePath = `${origin(server)}/api/v1/internal-admin/organizations/${ids.orgA}/branches/${ids.branchA}/day-off`;

    // 1. Configure initial weekly schedule effective 2026-11-20
    const w1 = await fetch(`${basePath}/weekly-schedule`, {
      method: "PUT",
      headers: {
        Authorization: "Bearer valid",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        days_of_week: [5],
        effective_from_business_date: "2026-11-20",
        reason: "Friday schedule",
      }),
    });
    assert.equal(w1.status, 200);

    // 2. Transition to Saturday effective 2026-11-27
    const w2 = await fetch(`${basePath}/weekly-schedule`, {
      method: "PUT",
      headers: {
        Authorization: "Bearer valid",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        days_of_week: [6],
        effective_from_business_date: "2026-11-27",
        reason: "Saturday schedule",
      }),
    });
    assert.equal(w2.status, 200);

    // 3. Reject backward effective date (before 2026-11-27) with 422
    const wBackward = await fetch(`${basePath}/weekly-schedule`, {
      method: "PUT",
      headers: {
        Authorization: "Bearer valid",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        days_of_week: [0],
        effective_from_business_date: "2026-11-24",
      }),
    });
    assert.equal(wBackward.status, 422);

    // 4. Create multi-day closure 2026-11-25..2026-11-27
    const c1 = await fetch(`${basePath}/closures`, {
      method: "POST",
      headers: {
        Authorization: "Bearer valid",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        start_business_date: "2026-11-25",
        end_business_date: "2026-11-27",
        reason: "Equipment upgrade",
      }),
    });
    assert.equal(c1.status, 201);
    const { closure } = (await c1.json()) as {
      closure: InternalAdminBranchClosure;
    };

    // 5. Reject overlapping closure with 409 Conflict
    const cOverlap = await fetch(`${basePath}/closures`, {
      method: "POST",
      headers: {
        Authorization: "Bearer valid",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        start_business_date: "2026-11-27",
        end_business_date: "2026-11-28",
        reason: "Overlap",
      }),
    });
    assert.equal(cOverlap.status, 409);

    // 6. Early reopen on 2026-11-27 -> truncates end_business_date to 2026-11-26
    const reopenEarly = await fetch(
      `${basePath}/closures/${closure.id}/reopen`,
      {
        method: "POST",
        headers: {
          Authorization: "Bearer valid",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ reopen_from_business_date: "2026-11-27" }),
      },
    );
    assert.equal(reopenEarly.status, 200);
    const reopenedBody = (await reopenEarly.json()) as {
      closure: InternalAdminBranchClosure;
    };
    assert.equal(reopenedBody.closure.status, "active");
    assert.equal(reopenedBody.closure.end_business_date, "2026-11-26");
    assert.ok(reopenedBody.closure.reopened_early_at);

    // 7. Reopen from start_business_date (2026-11-25) -> cancels closure
    const cancelRes = await fetch(
      `${basePath}/closures/${closure.id}/reopen`,
      {
        method: "POST",
        headers: {
          Authorization: "Bearer valid",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ reopen_from_business_date: "2026-11-25" }),
      },
    );
    assert.equal(cancelRes.status, 200);
    const cancelledBody = (await cancelRes.json()) as {
      closure: InternalAdminBranchClosure;
    };
    assert.equal(cancelledBody.closure.status, "cancelled");
    assert.ok(cancelledBody.closure.cancelled_at);
  });

  it("disables Day Off write endpoints by default while returning { enabled: false, day_off: null } on GET and preserving auth", async () => {
    const store = createStore();
    let writeAttempted = false;
    const deps = createDeps(store);
    const app = createApp(defaultDisabledConfig, {
      ...deps,
      managementAdmin: {
        ...deps.managementAdmin,
        async setBranchWeeklyDayOffForInternalAdmin() {
          writeAttempted = true;
          throw new Error("should not be called");
        },
        async createBranchClosureForInternalAdmin() {
          writeAttempted = true;
          throw new Error("should not be called");
        },
        async reopenBranchClosureForInternalAdmin() {
          writeAttempted = true;
          throw new Error("should not be called");
        },
      },
    });
    const baseUrl = origin(app);
    const basePath = `${baseUrl}/api/v1/internal-admin/organizations/${ids.orgA}/branches/${ids.branchA}/day-off`;

    assert.equal((await fetch(basePath)).status, 401);
    assert.equal(
      (await fetch(`${basePath}/weekly-schedule`, {
        method: "PUT",
        headers: { Authorization: "Bearer valid", "Content-Type": "application/json" },
        body: JSON.stringify({ days_of_week: [5] }),
      })).status,
      503,
    );
    assert.equal(
      (await fetch(`${basePath}/closures`, {
        method: "POST",
        headers: { Authorization: "Bearer valid", "Content-Type": "application/json" },
        body: JSON.stringify({ start_business_date: "2026-11-25", end_business_date: "2026-11-25" }),
      })).status,
      503,
    );
    assert.equal(
      (await fetch(`${basePath}/closures/${ids.closureA1}/reopen`, {
        method: "POST",
        headers: { Authorization: "Bearer valid", "Content-Type": "application/json" },
        body: JSON.stringify({ reopen_from_business_date: "2026-11-25" }),
      })).status,
      503,
    );
    assert.equal(writeAttempted, false);

    const readRes = await fetch(basePath, {
      headers: { Authorization: "Bearer valid" },
    });
    assert.equal(readRes.status, 200);
    assert.deepEqual(await readRes.json(), { enabled: false, day_off: null });
  });

  it("fails closed when BRANCH_DAY_OFF_ENABLED is true but database capability probe returns false or throws", async () => {
    for (const mode of ["false", "throw"] as const) {
      const store = createStore();
      let writeAttempted = false;
      const deps = createDeps(store);
      const app = createApp(config, {
        ...deps,
        managementAdmin: {
          ...deps.managementAdmin,
          async isBranchDayOffDatabaseReady() {
            if (mode === "throw") {
              throw new Error("probe failed");
            }
            return false;
          },
          async setBranchWeeklyDayOffForInternalAdmin() {
            writeAttempted = true;
            throw new Error("should not be called");
          },
          async createBranchClosureForInternalAdmin() {
            writeAttempted = true;
            throw new Error("should not be called");
          },
          async reopenBranchClosureForInternalAdmin() {
            writeAttempted = true;
            throw new Error("should not be called");
          },
        },
      });
      const baseUrl = origin(app);
      const basePath = `${baseUrl}/api/v1/internal-admin/organizations/${ids.orgA}/branches/${ids.branchA}/day-off`;

      const readRes = await fetch(basePath, {
        headers: { Authorization: "Bearer valid" },
      });
      assert.equal(readRes.status, 200);
      assert.deepEqual(await readRes.json(), { enabled: false, day_off: null });

      assert.equal(
        (await fetch(`${basePath}/weekly-schedule`, {
          method: "PUT",
          headers: { Authorization: "Bearer valid", "Content-Type": "application/json" },
          body: JSON.stringify({ days_of_week: [5] }),
        })).status,
        503,
      );
      assert.equal(
        (await fetch(`${basePath}/closures`, {
          method: "POST",
          headers: { Authorization: "Bearer valid", "Content-Type": "application/json" },
          body: JSON.stringify({ start_business_date: "2026-11-25", end_business_date: "2026-11-25" }),
        })).status,
        503,
      );
      assert.equal(
        (await fetch(`${basePath}/closures/${ids.closureA1}/reopen`, {
          method: "POST",
          headers: { Authorization: "Bearer valid", "Content-Type": "application/json" },
          body: JSON.stringify({ reopen_from_business_date: "2026-11-25" }),
        })).status,
        503,
      );
      assert.equal(writeAttempted, false);
    }
  });

  it("createManagementAdmin.isBranchDayOffDatabaseReady verifies exact RPC denial messages and fails closed on incomplete or unexpected responses", async () => {
    const originalFetch = globalThis.fetch;
    let mode:
      | "ready"
      | "neither"
      | "foundation_only"
      | "unexpected_auth"
      | "invalid_contract"
      | "throw" = "ready";
    globalThis.fetch = (async (input: RequestInfo | URL) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
      const isFoundation = url.includes("get_internal_admin_branch_day_off_config");
      if (mode === "throw") {
        throw new Error("network error");
      }
      if (mode === "neither" || (mode === "foundation_only" && !isFoundation)) {
        return new Response(JSON.stringify({ code: "PGRST202", message: "not found" }), {
          status: 404,
          headers: { "Content-Type": "application/json" },
        });
      }
      if (mode === "unexpected_auth") {
        return new Response(
          JSON.stringify({ code: "42501", message: "permission denied for function get_internal_admin_branch_day_off_config" }),
          { status: 403, headers: { "Content-Type": "application/json" } },
        );
      }
      if (mode === "invalid_contract") {
        return new Response(JSON.stringify({ ok: true }), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }
      return new Response(
        JSON.stringify({
          code: "42501",
          message: isFoundation ? "internal admin access denied" : "branch day off status access denied",
        }),
        { status: 403, headers: { "Content-Type": "application/json" } },
      );
    }) as typeof fetch;

    try {
      const admin = createManagementAdmin("http://127.0.0.1:54321", "service-role-placeholder");
      mode = "ready";
      assert.equal(await admin.isBranchDayOffDatabaseReady?.(), true);

      mode = "neither";
      assert.equal(await admin.isBranchDayOffDatabaseReady?.(), false);

      mode = "foundation_only";
      assert.equal(await admin.isBranchDayOffDatabaseReady?.(), false);

      mode = "unexpected_auth";
      assert.equal(await admin.isBranchDayOffDatabaseReady?.(), false);

      mode = "invalid_contract";
      assert.equal(await admin.isBranchDayOffDatabaseReady?.(), false);

      mode = "throw";
      assert.equal(await admin.isBranchDayOffDatabaseReady?.(), false);
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
});
