import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { createApp } from "./app";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import { createOperationalAdmin, OperationalAccessError } from "./operational";

const ids = {
  supPrimary: "a1000000-0000-4000-8000-000000000001",
  supBackup: "a1000000-0000-4000-8000-000000000002",
  supOtherOrg: "a1000000-0000-4000-8000-000000000003",
  pwChangeUser: "a1000000-0000-4000-8000-000000000004",
  branch1: "b1000000-0000-4000-8000-000000000001",
  branch2: "b1000000-0000-4000-8000-000000000002",
  team1: "c1000000-0000-4000-8000-000000000001",
  team2: "c1000000-0000-4000-8000-000000000002",
  staff1: "d1000000-0000-4000-8000-000000000001",
  card1: "e1000000-0000-4000-8000-000000000001",
  card2: "e1000000-0000-4000-8000-000000000002",
};

const config: BackendConfig = {
  port: 0,
  serviceRoleKey: "test-service-role-key",
  supabaseUrl: "http://127.0.0.1:54321",
};

const minimalChecklistPersistence = {
  getSupervisorDashboard: async () => ({}),
  submitChecklist: async () => ({}),
  getChecklistDetails: async () => ({}),
  saveDraft: async () => ({}),
  getDraft: async () => null,
  listSubmissions: async () => [],
} as unknown as BackendDependencies["checklistPersistence"];

const minimalManagementReads = {} as unknown as BackendDependencies["managementReads"];
const minimalAdminProvisioning = {} as unknown as BackendDependencies["adminProvisioning"];

describe("Supervisor Health Cards API & Adapter", () => {
  let server: Server;
  let baseUrl: string;
  const originalFetch = globalThis.fetch;
  const rpcCalls: Array<{ name: string; input: Record<string, unknown> }> = [];
  let savedSupCard: Record<string, unknown> | null = null;

  function makeAuthHeader(userId: string) {
    return { Authorization: `Bearer token:${userId}` };
  }

  function handleRpc(name: string, input: Record<string, unknown>): { status: number; body: unknown } {
    rpcCalls.push({ name, input });

    if (name === "list_branch_supervisor_health_cards") {
      if (input.actor_user_id === ids.supOtherOrg || input.target_branch_id === ids.branch2) {
        return { status: 403, body: { code: "42501", message: "health card access denied" } };
      }
      return {
        status: 200,
        body: [
          {
            id: savedSupCard ? ids.card1 : null,
            supervisor_user_id: ids.supPrimary,
            full_name: "Primary Sup",
            full_name_ar: "مشرف أول",
            person_code: "SUP-01",
            assignment_role: "primary",
            operational_team_ids: [ids.team1, ids.team2],
            team_assignment_roles: { [ids.team1]: "primary", [ids.team2]: "backup" },
            certificate_number: savedSupCard ? savedSupCard.certificate_number : null,
            status: savedSupCard ? savedSupCard.status : "not_done",
            place_of_issue: savedSupCard ? savedSupCard.place_of_issue : null,
            expiry_date: savedSupCard ? savedSupCard.expiry_date : null,
            date_issue: savedSupCard ? savedSupCard.date_issue : null,
            occupation: savedSupCard ? savedSupCard.occupation : null,
            company: savedSupCard ? savedSupCard.company : null,
            branch_name_snapshot: savedSupCard ? "Branch One" : null,
            notes: savedSupCard ? savedSupCard.notes : null,
            updated_at: savedSupCard ? "2026-11-26T00:00:00.000Z" : null,
          },
          {
            id: null,
            supervisor_user_id: ids.supBackup,
            full_name: "Backup Sup",
            full_name_ar: null,
            person_code: null,
            assignment_role: "backup",
            operational_team_ids: [ids.team1],
            team_assignment_roles: { [ids.team1]: "backup" },
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
          },
        ],
      };
    }

    if (name === "upsert_supervisor_health_card") {
      if (
        input.actor_user_id === ids.supOtherOrg ||
        input.target_branch_id === ids.branch2 ||
        input.actor_user_id !== input.target_supervisor_user_id
      ) {
        return { status: 403, body: { code: "42501", message: "health card access denied" } };
      }
      const payload = input.payload as Record<string, unknown>;
      const row = {
        id: ids.card1,
        supervisor_user_id: input.target_supervisor_user_id,
        certificate_number: payload.certificate_number ?? null,
        status: payload.status,
        place_of_issue: payload.place_of_issue ?? null,
        expiry_date: payload.expiry_date ?? null,
        date_issue: payload.date_issue ?? null,
        occupation: payload.occupation ?? null,
        company: payload.company ?? null,
        branch_name_snapshot: "Branch One",
        notes: payload.notes ?? null,
        updated_at: "2026-11-26T00:00:00.000Z",
      };
      if (input.target_supervisor_user_id === ids.supPrimary) {
        savedSupCard = row;
      }
      return { status: 200, body: [row] };
    }

    if (name === "list_operational_staff_health_cards") {
      return {
        status: 200,
        body: [
          {
            id: ids.card2,
            operational_staff_id: ids.staff1,
            certificate_number: "EMP-HC-1",
            status: "passed",
            place_of_issue: "Riyadh",
            expiry_date: "2027-01-31",
            date_issue: "2026-01-31",
            occupation: "Kitchen",
            company: "HC Co",
            branch_name_snapshot: "Branch One",
            notes: null,
            updated_at: "2026-11-26T00:00:00.000Z",
          },
        ],
      };
    }

    if (name === "upsert_operational_staff_health_card") {
      const payload = input.payload as Record<string, unknown>;
      return {
        status: 200,
        body: [
          {
            id: ids.card2,
            operational_staff_id: payload.operational_staff_id,
            certificate_number: payload.certificate_number ?? null,
            status: payload.status,
            place_of_issue: payload.place_of_issue ?? null,
            expiry_date: payload.expiry_date ?? null,
            date_issue: payload.date_issue ?? null,
            occupation: payload.occupation ?? null,
            company: payload.company ?? null,
            branch_name_snapshot: "Branch One",
            notes: payload.notes ?? null,
            updated_at: "2026-11-26T00:00:00.000Z",
          },
        ],
      };
    }

    throw new Error(`Unexpected RPC: ${name}`);
  }

  before(async () => {
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
      if (url.startsWith(`${config.supabaseUrl}/rest/v1/rpc/`)) {
        const name = url.slice(`${config.supabaseUrl}/rest/v1/rpc/`.length);
        const body = init?.body ? JSON.parse(String(init.body)) as Record<string, unknown> : {};
        const result = handleRpc(name, body);
        return new Response(JSON.stringify(result.body), {
          status: result.status,
          headers: { "Content-Type": "application/json" },
        });
      }
      return originalFetch(input, init);
    }) as typeof fetch;

    const operationalAdmin = createOperationalAdmin(config.supabaseUrl, config.serviceRoleKey);

    const deps: Partial<BackendDependencies> = {
      authVerifier: {
        async verify(token: string) {
          if (!token.startsWith("token:")) return null;
          const userId = token.slice("token:".length);
          return { userId, email: `${userId}@example.invalid` };
        },
      },
      createUserContext: () => ({
        async getUserContext(userId: string) {
          return {
            id: userId,
            full_name: "Supervisor",
            must_change_password: userId === ids.pwChangeUser,
            disabled: false,
            branches: [{ id: ids.branch1, name: "Branch One", organization_id: "f1000000-0000-4000-8000-000000000001", role: "branch_manager" }],
            managed_organizations: [],
          };
        },
        hasOrganizationManagerAccess: async () => false,
        validateActiveBranches: async () => true,
        listActiveBranches: async () => [],
      }),
      checklistPersistence: minimalChecklistPersistence,
      managementReads: minimalManagementReads,
      adminProvisioning: minimalAdminProvisioning,
      operationalAdmin,
    };

    const app = createApp(config, deps as BackendDependencies);
    server = createServer(app);
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", () => resolve()));
    const address = server.address() as AddressInfo;
    baseUrl = `http://127.0.0.1:${address.port}`;
  });

  after(async () => {
    globalThis.fetch = originalFetch;
    await new Promise<void>((resolve, reject) => server.close((err) => (err ? reject(err) : resolve())));
  });

  it("returns 401 for unauthenticated GET and PUT supervisor health card requests", async () => {
    const getRes = await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branch1}/team/supervisor-health-cards`);
    assert.equal(getRes.status, 401);

    const putRes = await fetch(
      `${baseUrl}/api/v1/supervisor/branches/${ids.branch1}/team/supervisor-health-cards/${ids.supPrimary}`,
      {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ status: "passed" }),
      },
    );
    assert.equal(putRes.status, 401);
  });

  it("lists deduplicated supervisors without saved health cards defaulting to not_done", async () => {
    savedSupCard = null;
    const res = await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branch1}/team/supervisor-health-cards`, {
      headers: makeAuthHeader(ids.supPrimary),
    });
    assert.equal(res.status, 200);
    assert.equal(res.headers.get("cache-control"), "private, no-store");
    const body = (await res.json()) as { supervisor_health_cards: Array<Record<string, unknown>> };
    assert.equal(body.supervisor_health_cards.length, 2);
    assert.equal(body.supervisor_health_cards[0].id, null);
    assert.equal(body.supervisor_health_cards[0].status, "not_done");
    assert.deepEqual(body.supervisor_health_cards[0].operational_team_ids, [ids.team1, ids.team2]);
    assert.equal(body.supervisor_health_cards[0].assignment_role, "primary");
    assert.equal(body.supervisor_health_cards[1].assignment_role, "backup");
  });

  it("updates own health card across all five statuses and nullable fields, then GET returns saved card", async () => {
    for (const status of ["not_done", "pending", "done_waiting_id", "failed", "passed"] as const) {
      const res = await fetch(
        `${baseUrl}/api/v1/supervisor/branches/${ids.branch1}/team/supervisor-health-cards/${ids.supPrimary}`,
        {
          method: "PUT",
          headers: { ...makeAuthHeader(ids.supPrimary), "Content-Type": "application/json" },
          body: JSON.stringify({
            certificate_number: "   ",
            status,
            place_of_issue: "  Riyadh  ",
            expiry_date: null,
            date_issue: "",
            occupation: "Supervisor",
            company: "HC Co",
            notes: null,
          }),
        },
      );
      assert.equal(res.status, 200);
      const body = (await res.json()) as { supervisor_health_card: Record<string, unknown> };
      assert.equal(body.supervisor_health_card.status, status);
      assert.equal(body.supervisor_health_card.certificate_number, null);
      assert.equal(body.supervisor_health_card.expiry_date, null);
      assert.equal(body.supervisor_health_card.date_issue, null);
      assert.equal(body.supervisor_health_card.place_of_issue, "Riyadh");
    }

    const getRes = await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branch1}/team/supervisor-health-cards`, {
      headers: makeAuthHeader(ids.supBackup),
    });
    assert.equal(getRes.status, 200);
    const getBody = (await getRes.json()) as { supervisor_health_cards: Array<Record<string, unknown>> };
    assert.equal(getBody.supervisor_health_cards[0].id, ids.card1);
    assert.equal(getBody.supervisor_health_cards[0].status, "passed");
  });

  it("allows backup supervisor to update their own health card", async () => {
    const res = await fetch(
      `${baseUrl}/api/v1/supervisor/branches/${ids.branch1}/team/supervisor-health-cards/${ids.supBackup}`,
      {
        method: "PUT",
        headers: { ...makeAuthHeader(ids.supBackup), "Content-Type": "application/json" },
        body: JSON.stringify({
          status: "pending",
          certificate_number: "BK-101",
          expiry_date: "2027-05-01",
          date_issue: "2026-05-01",
        }),
      },
    );
    assert.equal(res.status, 200);
    const body = (await res.json()) as { supervisor_health_card: Record<string, unknown> };
    assert.equal(body.supervisor_health_card.supervisor_user_id, ids.supBackup);
    assert.equal(body.supervisor_health_card.status, "pending");
  });

  it("denies cross-supervisor edits with 403 without invoking RPC", async () => {
    const callsBefore = rpcCalls.length;
    const res = await fetch(
      `${baseUrl}/api/v1/supervisor/branches/${ids.branch1}/team/supervisor-health-cards/${ids.supBackup}`,
      {
        method: "PUT",
        headers: { ...makeAuthHeader(ids.supPrimary), "Content-Type": "application/json" },
        body: JSON.stringify({ status: "failed" }),
      },
    );
    assert.equal(res.status, 403);
    assert.equal(rpcCalls.length, callsBefore);
  });

  it("denies cross-branch, cross-organization, and must_change_password requests with 403", async () => {
    const crossOrgGet = await fetch(
      `${baseUrl}/api/v1/supervisor/branches/${ids.branch1}/team/supervisor-health-cards`,
      { headers: makeAuthHeader(ids.supOtherOrg) },
    );
    assert.equal(crossOrgGet.status, 403);

    const crossBranchPut = await fetch(
      `${baseUrl}/api/v1/supervisor/branches/${ids.branch2}/team/supervisor-health-cards/${ids.supPrimary}`,
      {
        method: "PUT",
        headers: { ...makeAuthHeader(ids.supPrimary), "Content-Type": "application/json" },
        body: JSON.stringify({ status: "passed" }),
      },
    );
    assert.equal(crossBranchPut.status, 403);

    const pwChangeGet = await fetch(
      `${baseUrl}/api/v1/supervisor/branches/${ids.branch1}/team/supervisor-health-cards`,
      { headers: makeAuthHeader(ids.pwChangeUser) },
    );
    assert.equal(pwChangeGet.status, 403);
  });

  it("rejects invalid payloads and invalid path params with 400", async () => {
    for (const badBody of [
      { status: "invalid_status" },
      { status: "passed", expiry_date: "2026-02-31" },
      { status: "passed", actor_user_id: ids.supBackup },
    ]) {
      const res = await fetch(
        `${baseUrl}/api/v1/supervisor/branches/${ids.branch1}/team/supervisor-health-cards/${ids.supPrimary}`,
        {
          method: "PUT",
          headers: { ...makeAuthHeader(ids.supPrimary), "Content-Type": "application/json" },
          body: JSON.stringify(badBody),
        },
      );
      assert.equal(res.status, 400);
    }

    const badParamRes = await fetch(
      `${baseUrl}/api/v1/supervisor/branches/${ids.branch1}/team/supervisor-health-cards/not-a-uuid`,
      {
        method: "PUT",
        headers: { ...makeAuthHeader(ids.supPrimary), "Content-Type": "application/json" },
        body: JSON.stringify({ status: "passed" }),
      },
    );
    assert.equal(badParamRes.status, 400);
  });

  it("preserves existing employee health card GET and PUT contracts unchanged", async () => {
    const getEmp = await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branch1}/team/health-cards`, {
      headers: makeAuthHeader(ids.supPrimary),
    });
    assert.equal(getEmp.status, 200);
    const getEmpBody = (await getEmp.json()) as { health_cards: Array<Record<string, unknown>> };
    assert.equal(getEmpBody.health_cards[0].operational_staff_id, ids.staff1);

    const putEmp = await fetch(
      `${baseUrl}/api/v1/supervisor/branches/${ids.branch1}/team/health-cards/${ids.staff1}`,
      {
        method: "PUT",
        headers: { ...makeAuthHeader(ids.supPrimary), "Content-Type": "application/json" },
        body: JSON.stringify({ status: "passed", certificate_number: "EMP-HC-2" }),
      },
    );
    assert.equal(putEmp.status, 200);
    const putEmpBody = (await putEmp.json()) as { health_card: Record<string, unknown> };
    assert.equal(putEmpBody.health_card.operational_staff_id, ids.staff1);
  });

  it("maps 42501 RPC errors to OperationalAccessError in adapter", async () => {
    const admin = createOperationalAdmin(config.supabaseUrl, config.serviceRoleKey);
    await assert.rejects(
      () => admin.listSupervisorHealthCards!(ids.supOtherOrg, ids.branch1),
      OperationalAccessError,
    );
  });
});
