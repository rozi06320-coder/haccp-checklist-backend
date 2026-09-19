import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, describe, it } from "node:test";
import { createApp } from "./app";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import { createOperationalAdmin } from "./operational";

const ids = {
  manager: "10000000-0000-4000-8000-000000000001",
  unassignedSupervisor: "10000000-0000-4000-8000-000000000002",
  assignedSupervisor: "10000000-0000-4000-8000-000000000003",
  organization: "20000000-0000-4000-8000-000000000001",
  branch: "30000000-0000-4000-8000-000000000001",
  teamVacant: "40000000-0000-4000-8000-000000000001",
  teamAssigned: "40000000-0000-4000-8000-000000000002",
  staff1: "50000000-0000-4000-8000-000000000001",
  assignment1: "60000000-0000-4000-8000-000000000001",
};

describe("Supervisor Lifecycle Phase 1 - Unassigned Supervisor & Primary Vacant", () => {
  let server: Server;
  let baseUrl: string;

  before(async () => {
    const config: BackendConfig = {
      port: 0,
      serviceRoleKey: "test-service-role-key",
      supabaseUrl: "http://127.0.0.1:54321",
    };

    const dependencies: BackendDependencies = {
      checkReadiness: async () => true,
      authVerifier: {
        async verify(token) {
          if (token === "unassigned_supervisor") return { userId: ids.unassignedSupervisor, email: "unassigned@example.invalid" };
          if (token === "assigned_supervisor") return { userId: ids.assignedSupervisor, email: "assigned@example.invalid" };
          if (token === "manager") return { userId: ids.manager, email: "manager@example.invalid" };
          return null;
        },
      },
      createUserContext: (token) => ({
        async getUserContext() {
          if (token === "unassigned_supervisor") {
            return {
              id: ids.unassignedSupervisor,
              full_name: "Unassigned Supervisor",
              disabled: false,
              must_change_password: false,
              branches: [{ id: ids.branch, name: "Branch 1", role: "branch_manager" }],
              managed_organizations: [],
            };
          }
          if (token === "assigned_supervisor") {
            return {
              id: ids.assignedSupervisor,
              full_name: "Assigned Supervisor",
              disabled: false,
              must_change_password: false,
              branches: [{ id: ids.branch, name: "Branch 1", role: "branch_manager" }],
              managed_organizations: [],
            };
          }
          if (token === "manager") {
            return {
              id: ids.manager,
              full_name: "Org Manager",
              disabled: false,
              must_change_password: false,
              branches: [],
              managed_organizations: [{ id: ids.organization, name: "Org 1" }],
            };
          }
          throw new Error("unauthorized");
        },
        async hasOrganizationManagerAccess(orgId) {
          return token === "manager" && orgId === ids.organization;
        },
      }),
      operationalAdmin: {
        async getBranchTimezone() {
          return "Asia/Riyadh";
        },
        async getSupervisorTeam(actorUserId) {
          if (actorUserId === ids.unassignedSupervisor) {
            return { teams: [], unassigned: true };
          }
          return {
            teams: [
              {
                id: ids.teamAssigned,
                name: "Team Alpha",
                active: true,
                can_write: true,
                assignment_role: "primary",
                company_name: "Org 1",
                hygiene_submitted_today: false,
                staff: [
                  {
                    id: ids.staff1,
                    display_name: "Staff 1",
                    company_name: "Org 1",
                    staff_code: "STF-01",
                    country_code: "SA",
                    iqama_number: null,
                    iqama_expiry_date: null,
                    phone_number: null,
                    email: null,
                    employment_status: "active",
                    assignment: { id: ids.assignment1, operational_team_id: ids.teamAssigned, operational_roles: ["kitchen"] },
                    duty_date: "2026-09-19",
                    duty_status: "on_duty",
                  },
                ],
              },
            ],
          };
        },
        async listManagedTeams(actorUserId, organizationId) {
          assert.equal(organizationId, ids.organization);
          return {
            teams: [
              {
                team_id: ids.teamVacant,
                branch_id: ids.branch,
                branch_name: "Branch 1",
                supervisor_user_id: null,
                supervisor_name: null,
                active: true,
                operational_staff_count: 8,
              },
              {
                team_id: ids.teamAssigned,
                branch_id: ids.branch,
                branch_name: "Branch 1",
                supervisor_user_id: ids.assignedSupervisor,
                supervisor_name: "Assigned Supervisor",
                active: true,
                operational_staff_count: 5,
              },
            ],
          };
        },
        async listManagedStaff() { return { staff: [], total: 0 }; },
        async listManagedEmployeeTeam() { return { employees: [], health_cards: [], monthly_evaluations: [] }; },
        async listEligibleSupervisors() { return { supervisors: [] }; },
      } as unknown as BackendDependencies["operationalAdmin"],
    };

    const app = createApp(config, dependencies);
    server = createServer(app);
    await new Promise<void>((resolve) => server.listen(0, resolve));
    const port = (server.address() as AddressInfo).port;
    baseUrl = `http://127.0.0.1:${port}`;
  });

  after(async () => {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  });

  it("1. Unassigned supervisor receives 200 with { teams: [], unassigned: true } from /api/v1/supervisor/branches/:branchId/team", async () => {
    const res = await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branch}/team`, {
      headers: { Authorization: "Bearer unassigned_supervisor" },
    });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.deepEqual(body, { teams: [], unassigned: true });
  });

  it("2. Assigned supervisor receives 200 with team list and staff", async () => {
    const res = await fetch(`${baseUrl}/api/v1/supervisor/branches/${ids.branch}/team`, {
      headers: { Authorization: "Bearer assigned_supervisor" },
    });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.teams.length, 1);
    assert.equal(body.teams[0].id, ids.teamAssigned);
    assert.equal(body.teams[0].staff.length, 1);
  });

  it("3. Manager receives 200 with vacant team having supervisor_user_id: null and accurate staff count", async () => {
    const res = await fetch(`${baseUrl}/api/v1/management/organizations/${ids.organization}/supervisor-teams`, {
      headers: { Authorization: "Bearer manager" },
    });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.teams.length, 2);

    const vacantTeam = body.teams.find((t: { team_id: string }) => t.team_id === ids.teamVacant);
    assert.ok(vacantTeam);
    assert.equal(vacantTeam.supervisor_user_id, null);
    assert.equal(vacantTeam.supervisor_name, null);
    assert.equal(vacantTeam.active, true);
    assert.equal(vacantTeam.operational_staff_count, 8);
  });

  it("4. operationalAdmin.getSupervisorTeam unit logic isolates unassigned supervisor from other branch teams", async () => {
    const rpcServer = createServer(async (req, res) => {
      res.setHeader("content-type", "application/json");
      if (req.url === "/rest/v1/rpc/get_supervisor_operational_team") {
        // Simulation: Branch has an active team, but actor has no assignment (assignment_role is null)
        res.end(JSON.stringify([
          {
            team_id: ids.teamAssigned,
            team_name: "Other Team",
            team_active: true,
            can_write: false,
            assignment_role: null,
            company_name: "Org 1",
            staff_id: ids.staff1,
            display_name: "Staff 1",
            staff_company_name: "Org 1",
            staff_code: "STF-01",
            country_code: "SA",
            iqama_number: null,
            iqama_expiry_date: null,
            phone_number: null,
            email: null,
            employment_status: "active",
            assignment_id: ids.assignment1,
            operational_roles: ["kitchen"],
            duty_status: "on_duty",
          },
        ]));
        return;
      }
      res.end(JSON.stringify([]));
    });
    await new Promise<void>((resolve) => rpcServer.listen(0, "127.0.0.1", resolve));

    try {
      const port = (rpcServer.address() as AddressInfo).port;
      const admin = createOperationalAdmin(`http://127.0.0.1:${port}`, "service-key");
      const result = await admin.getSupervisorTeam(ids.unassignedSupervisor, ids.branch, "2026-09-19") as {
        teams: unknown[];
        unassigned: boolean;
      };

      // Must NOT leak Other Team or its staff! Must return unassigned: true with empty teams.
      assert.deepEqual(result, { teams: [], unassigned: true });
    } finally {
      await new Promise<void>((resolve, reject) => rpcServer.close((err) => err ? reject(err) : resolve()));
    }
  });

  it("5. operationalAdmin.listManagedTeams unit logic parses vacant team with supervisor_user_id: null", async () => {
    const rpcServer = createServer(async (req, res) => {
      res.setHeader("content-type", "application/json");
      if (req.url === "/rest/v1/rpc/list_managed_supervisor_teams") {
        res.end(JSON.stringify([
          {
            team_id: ids.teamVacant,
            branch_id: ids.branch,
            branch_name: "Branch 1",
            supervisor_user_id: null,
            supervisor_name: null,
            active: true,
            operational_staff_count: 8,
          },
        ]));
        return;
      }
      res.end(JSON.stringify([]));
    });
    await new Promise<void>((resolve) => rpcServer.listen(0, "127.0.0.1", resolve));

    try {
      const port = (rpcServer.address() as AddressInfo).port;
      const admin = createOperationalAdmin(`http://127.0.0.1:${port}`, "service-key");
      const result = await admin.listManagedTeams(ids.manager, ids.organization) as {
        teams: Array<{ supervisor_user_id: string | null; active: boolean; operational_staff_count: number }>;
      };

      assert.equal(result.teams.length, 1);
      assert.equal(result.teams[0].supervisor_user_id, null);
      assert.equal(result.teams[0].active, true);
      assert.equal(result.teams[0].operational_staff_count, 8);
    } finally {
      await new Promise<void>((resolve, reject) => rpcServer.close((err) => err ? reject(err) : resolve()));
    }
  });
});
