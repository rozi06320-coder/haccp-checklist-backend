import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { afterEach, describe, it } from "node:test";
import { AdminAccessError, AdminConflictError, AdminInputError, createPinCrypto, type PinCredential, type TrainingBranchAccessCredential } from "./admin";
import { createApp } from "./app";
import { loadBackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const ids = {
  actor: "61000000-0000-4000-8000-000000000001",
  organization: "61000000-0000-4000-8000-000000000002",
  otherOrganization: "61000000-0000-4000-8000-000000000003",
  branch: "61000000-0000-4000-8000-000000000004",
  otherBranch: "61000000-0000-4000-8000-000000000005",
  version: "61000000-0000-4000-8000-000000000006",
  employee: "61000000-0000-4000-8000-000000000007",
  otherEmployee: "61000000-0000-4000-8000-000000000008",
};
const config = loadBackendConfig({
  NODE_ENV: "test",
  SUPABASE_URL: "http://127.0.0.1:54321",
  SUPABASE_PUBLISHABLE_KEY: "test-placeholder",
  DAILY_AUDIT_GRANT_SECRET: "test-branch-training-secret-placeholder-32-bytes",
  TRAINING_ORGANIZATION_SLUG: "burger-hunch",
});
const credential: PinCredential = { pin_hash: "\\x" + "11".repeat(32), salt: "\\x" + "22".repeat(16), kdf_version: 1, cost: 16384, block_size: 8, parallelization: 1, credential_version: ids.version };
const accessCredential: TrainingBranchAccessCredential = {
  ...credential,
  organization_id: ids.organization,
  organization_name: "Burger Hunch",
  organization_name_ar: null,
  branch_id: ids.branch,
  branch_name: "Burger Hunch Tarout",
  branch_name_ar: null,
  credential_version: ids.version,
};
const servers: ReturnType<typeof createServer>[] = [];

function deps(options: { internalAdmin?: boolean; denied?: boolean; invalid?: boolean; verified?: boolean; noCredential?: boolean; noSession?: boolean; configured?: boolean; noEmployee?: boolean; duplicateEmployeeCode?: boolean; emptyPublicBranches?: boolean; unknownTrainingOrganization?: boolean; calls?: Record<string, unknown> } = {}): BackendDependencies {
  const calls = options.calls ?? {};
  const crypto = createPinCrypto("test-branch-training-secret-placeholder-32-bytes");
  return {
    authVerifier: { async verify(token) { return token === "valid" ? { userId: ids.actor, email: "actor@example.invalid" } : null; } },
    async checkReadiness() { return true; },
    createUserContext() { return { async getUserContext() { return { id: ids.actor, full_name: "Actor", must_change_password: false, disabled: false, branches: [], managed_organizations: [] }; }, async isInternalAdmin() { return options.internalAdmin ?? false; }, async hasOrganizationManagerAccess() { return false; }, async validateActiveBranches() { return false; }, async listActiveBranches() { return []; } }; },
    passwordChange: { async verifyCurrent() { return true; }, async updatePassword() {}, async finalize() {} },
    provisioningAdmin: { async createUser() { return { id: ids.actor }; }, async deleteUser() {}, async finalize() {} },
    managementAdmin: { async listUsers() { return { users: [], total: 0 }; } },
    branchManagementAdmin: { async listBranches() { return []; }, async listStaff() { return []; }, async getPinMetadata() { throw new Error("unused"); }, async storePin() { throw new Error("unused"); }, async getPinCredential() { throw new Error("unused"); } },
    pinCrypto: {
      async hash(pin) { calls.hashedPin = pin; return credential; },
      async verify(pin, checked) { calls.verifiedPin = pin; calls.checkedCredential = checked; return options.verified ?? false; },
      issueTrainingGrant: crypto.issueTrainingGrant,
      verifyTrainingGrant: crypto.verifyTrainingGrant,
      issueGrant() { return "unused"; },
      verifyGrant() { return false; },
    },
    trainingBranchAccessAdmin: {
      async listForInternalAdmin(actorUserId, organizationId) {
        calls.list = { actorUserId, organizationId };
        if (options.denied) throw new AdminAccessError();
        return [
          { branch_id: ids.branch, enabled: true, pin_configured: true, updated_at: "2026-08-26T00:00:00Z" },
          { branch_id: ids.otherBranch, enabled: false, pin_configured: false, updated_at: null },
        ];
      },
      async storeForInternalAdmin(input) {
        calls.store = input;
        calls.stores = [...((calls.stores as unknown[]) ?? []), input];
        if (options.denied) throw new AdminAccessError();
        if (options.invalid) throw new AdminInputError();
        return { branch_id: input.branchId, enabled: input.enabled, pin_configured: Boolean(input.credential) || Boolean(options.configured), updated_at: "2026-08-26T00:01:00Z" };
      },
      async listPublicBranches(organizationSlug) {
        calls.discoverySlug = organizationSlug;
        if (options.unknownTrainingOrganization) return null;
        return {
          organization: { id: ids.organization, name: "Burger Hunch", name_ar: null },
          branches: options.emptyPublicBranches ? [] : [
            { id: ids.branch, name: "Burger Hunch Tarout", name_ar: null },
            { id: ids.otherBranch, name: "Burger Hunch Qatif", name_ar: null },
          ],
        };
      },
      async getCredential(input) {
        calls.credentialLookup = input;
        return options.noCredential ? null : accessCredential;
      },
      async validateSession(input) {
        calls.validateSession = input;
        return options.noSession ? null : {
          organization_id: ids.organization,
          organization_name: "Burger Hunch",
          organization_name_ar: null,
          branch_id: ids.branch,
          branch_name: "Burger Hunch Tarout",
          branch_name_ar: null,
        };
      },
      async listEmployees(input) {
        calls.listEmployees = input;
        return options.noEmployee ? [] : [
          { employee_id: ids.employee, display_name: "Adrian", employee_code: "EMP-001" },
          { employee_id: ids.otherEmployee, display_name: "Ahmed", employee_code: null },
        ];
      },
      async validateEmployee(input) {
        calls.validateEmployee = input;
        if (options.noEmployee || input.employeeId !== ids.employee) return null;
        return { employee_id: ids.employee, display_name: "Adrian", employee_code: "EMP-001" };
      },
      async selectEmployeeByCode(input) {
        calls.selectEmployeeByCode = input;
        if (options.duplicateEmployeeCode) throw new AdminConflictError();
        if (options.noEmployee || input.employeeCode !== "EMP-001") return null;
        return { employee_id: ids.employee, display_name: "Adrian", employee_code: "EMP-001" };
      },
    },
  };
}

async function start(dependencies: BackendDependencies) {
  const server = createServer(createApp(config, dependencies));
  servers.push(server);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
}

afterEach(async () => Promise.all(servers.splice(0).map((server) => new Promise<void>((resolve) => server.close(() => resolve())))));
const authRequest = (origin: string, path: string, init: RequestInit = {}) => fetch(`${origin}${path}`, { ...init, headers: { Authorization: "Bearer valid", ...(init.headers ?? {}) } });

describe("Branch Training Access API", () => {
  it("lets an Internal Admin list and configure own branch access without returning PIN material", async () => {
    const calls: Record<string, unknown> = {};
    const origin = await start(deps({ internalAdmin: true, calls }));
    const list = await authRequest(origin, `/api/v1/internal-admin/organizations/${ids.organization}/training-branch-access`);
    assert.equal(list.status, 200);
    const listText = await list.text();
    assert.match(listText, /branch_access/);
    assert.doesNotMatch(listText, /pin_hash|salt|credential_version|1234/i);
    assert.deepEqual(calls.list, { actorUserId: ids.actor, organizationId: ids.organization });

    const update = await authRequest(origin, `/api/v1/internal-admin/organizations/${ids.organization}/training-branch-access/${ids.branch}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ enabled: true, pin: "1234" }),
    });
    assert.equal(update.status, 200);
    const updateText = await update.text();
    assert.doesNotMatch(updateText, /pin_hash|salt|credential_version|1234/i);
    assert.deepEqual(JSON.parse(updateText), {
      branch_id: ids.branch,
      enabled: true,
      pin_configured: true,
      updated_at: "2026-08-26T00:01:00Z",
    });
    assert.equal(calls.hashedPin, "1234");
    assert.equal((calls.store as { branchId: string; organizationId: string; enabled: boolean }).branchId, ids.branch);
  });

  it("changes PINs, disables access, and preserves configured credentials when PIN is omitted", async () => {
    const calls: Record<string, unknown> = {};
    const origin = await start(deps({ internalAdmin: true, configured: true, calls }));

    const changed = await authRequest(origin, `/api/v1/internal-admin/organizations/${ids.organization}/training-branch-access/${ids.branch}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ enabled: true, pin: "567890" }),
    });
    assert.equal(changed.status, 200);
    assert.equal(calls.hashedPin, "567890");

    const preserved = await authRequest(origin, `/api/v1/internal-admin/organizations/${ids.organization}/training-branch-access/${ids.branch}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ enabled: true }),
    });
    assert.equal(preserved.status, 200);
    assert.deepEqual(await preserved.json(), {
      branch_id: ids.branch,
      enabled: true,
      pin_configured: true,
      updated_at: "2026-08-26T00:01:00Z",
    });

    const disabled = await authRequest(origin, `/api/v1/internal-admin/organizations/${ids.organization}/training-branch-access/${ids.branch}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ enabled: false }),
    });
    assert.equal(disabled.status, 200);
    assert.equal((await disabled.json()).enabled, false);
    assert.equal((calls.stores as { credential: PinCredential | null }[])[1]?.credential, null);
    assert.equal((calls.stores as { credential: PinCredential | null }[])[2]?.credential, null);
  });

  it("rejects non-admins, cross-scope service denials, invalid PINs, and enabling without a configured PIN", async () => {
    const nonAdmin = await start(deps({ internalAdmin: false }));
    assert.equal((await authRequest(nonAdmin, `/api/v1/internal-admin/organizations/${ids.organization}/training-branch-access`)).status, 403);
    const denied = await start(deps({ internalAdmin: true, denied: true }));
    assert.equal((await authRequest(denied, `/api/v1/internal-admin/organizations/${ids.otherOrganization}/training-branch-access/${ids.branch}`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ enabled: true, pin: "1234" }) })).status, 403);
    const invalidPayload = await start(deps({ internalAdmin: true }));
    assert.equal((await authRequest(invalidPayload, `/api/v1/internal-admin/organizations/${ids.organization}/training-branch-access/${ids.branch}`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ enabled: true, pin: "12ab" }) })).status, 400);
    const invalidService = await start(deps({ internalAdmin: true, invalid: true }));
    assert.equal((await authRequest(invalidService, `/api/v1/internal-admin/organizations/${ids.organization}/training-branch-access/${ids.branch}`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ enabled: true }) })).status, 422);
  });

  it("discovers configured-organization branches and verifies PIN into an HttpOnly Training cookie", async () => {
    const calls: Record<string, unknown> = {};
    const origin = await start(deps({ verified: true, calls }));
    const branches = await fetch(`${origin}/api/v1/training/branches`);
    assert.equal(branches.status, 200);
    const branchText = await branches.text();
    assert.match(branchText, /Burger Hunch Tarout/);
    assert.doesNotMatch(branchText, /pin_hash|salt|credential_version|HUN-RUH/i);
    assert.equal(calls.discoverySlug, "burger-hunch");

    const verify = await fetch(`${origin}/api/v1/training/access/verify`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ branch_id: ids.branch, pin: "1234" }),
    });
    assert.equal(verify.status, 200);
    assert.equal(calls.verifiedPin, "1234");
    assert.deepEqual(calls.credentialLookup, { organizationSlug: "burger-hunch", branchId: ids.branch });
    const setCookie = verify.headers.get("set-cookie") ?? "";
    assert.match(setCookie, /^training_access=/);
    assert.match(setCookie, /HttpOnly/);
    assert.match(setCookie, /SameSite=Strict/);
    assert.match(setCookie, /Max-Age=43200; Path=\/;/);
    assert.match(setCookie, /training_access=; Max-Age=0; Path=\/training/);
    assert.doesNotMatch(await verify.text(), /pin_hash|salt|credential_version|1234/i);
  });

  it("distinguishes a valid configured Training organization with zero visible branches from an unknown organization", async () => {
    const emptyCalls: Record<string, unknown> = {};
    const emptyOrigin = await start(deps({ emptyPublicBranches: true, calls: emptyCalls }));
    const empty = await fetch(`${emptyOrigin}/api/v1/training/branches`);
    assert.equal(empty.status, 200);
    assert.deepEqual(await empty.json(), {
      organization: { id: ids.organization, name: "Burger Hunch", name_ar: null },
      branches: [],
    });
    assert.equal(emptyCalls.discoverySlug, "burger-hunch");

    const unknown = await fetch(`${await start(deps({ unknownTrainingOrganization: true }))}/api/v1/training/branches`);
    assert.equal(unknown.status, 404);
  });

  it("rejects wrong PINs, tampered cookies, disabled sessions, and preserves branch ID identity despite duplicate codes", async () => {
    const wrong = await start(deps({ verified: false }));
    assert.equal((await fetch(`${wrong}/api/v1/training/access/verify`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ branch_id: ids.branch, pin: "1234" }) })).status, 403);

    const origin = await start(deps({ verified: true, noSession: true }));
    const verify = await fetch(`${origin}/api/v1/training/access/verify`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ branch_id: ids.branch, pin: "1234" }) });
    const cookie = (verify.headers.get("set-cookie") ?? "").split(";", 1)[0];
    const session = await fetch(`${origin}/api/v1/training/session`, { headers: { Cookie: cookie } });
    assert.equal(session.status, 401);
    assert.match(session.headers.get("set-cookie") ?? "", /^training_access=/);
    assert.match(session.headers.get("set-cookie") ?? "", /Max-Age=0; Path=\/;/);
    assert.match(session.headers.get("set-cookie") ?? "", /Path=\/training/);

    const tampered = await fetch(`${origin}/api/v1/training/session`, { headers: { Cookie: "training_access=tampered" } });
    assert.equal(tampered.status, 401);

    const calls: Record<string, unknown> = {};
    const duplicateCodeOrigin = await start(deps({ verified: true, calls }));
    await fetch(`${duplicateCodeOrigin}/api/v1/training/access/verify`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ branch_id: ids.otherBranch, pin: "1234" }) });
    assert.deepEqual(calls.credentialLookup, { organizationSlug: "burger-hunch", branchId: ids.otherBranch });
  });

  it("selects eligible employees by code from the validated Training branch session only", async () => {
    const calls: Record<string, unknown> = {};
    const origin = await start(deps({ verified: true, calls }));
    const verify = await fetch(`${origin}/api/v1/training/access/verify`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ branch_id: ids.branch, pin: "1234" }),
    });
    const cookie = (verify.headers.get("set-cookie") ?? "").split(";", 1)[0];

    const select = await fetch(`${origin}/api/v1/training/employee/select`, {
      method: "POST",
      headers: { Cookie: cookie, "Content-Type": "application/json" },
      body: JSON.stringify({ employee_code: "EMP-001" }),
    });
    assert.equal(select.status, 200);
    assert.deepEqual(calls.selectEmployeeByCode, { organizationId: ids.organization, branchId: ids.branch, employeeCode: "EMP-001" });
    const selectedCookie = select.headers.get("set-cookie") ?? "";
    assert.match(selectedCookie, /^training_access=/);
    assert.match(selectedCookie, /HttpOnly/);
    assert.match(selectedCookie, /Path=\/;/);
    assert.match(selectedCookie, /training_access=; Max-Age=0; Path=\/training/);
    assert.doesNotMatch(await select.text(), /phone|email|iqama|country|company|supervisor|pin_hash|salt|1234|UNKNOWN/i);

    const session = await fetch(`${origin}/api/v1/training/session`, { headers: { Cookie: selectedCookie.split(";", 1)[0] } });
    assert.equal(session.status, 200);
    const body = await session.json() as { employee: { employee_id: string; display_name: string; employee_code: string | null } | null };
    assert.equal(body.employee?.employee_id, ids.employee);
  });

  it("rejects invalid employee selection and clears only employee binding for Switch Employee", async () => {
    const origin = await start(deps({ verified: true }));
    const verify = await fetch(`${origin}/api/v1/training/access/verify`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ branch_id: ids.branch, pin: "1234" }),
    });
    const cookie = (verify.headers.get("set-cookie") ?? "").split(";", 1)[0];
    const rejected = await fetch(`${origin}/api/v1/training/employee/select`, {
      method: "POST",
      headers: { Cookie: cookie, "Content-Type": "application/json" },
      body: JSON.stringify({ employee_code: "UNKNOWN" }),
    });
    assert.equal(rejected.status, 404);

    const selected = await fetch(`${origin}/api/v1/training/employee/select`, {
      method: "POST",
      headers: { Cookie: cookie, "Content-Type": "application/json" },
      body: JSON.stringify({ employee_code: "EMP-001" }),
    });
    const selectedCookie = (selected.headers.get("set-cookie") ?? "").split(";", 1)[0];
    const cleared = await fetch(`${origin}/api/v1/training/employee/clear`, {
      method: "POST",
      headers: { Cookie: selectedCookie, "Content-Type": "application/json" },
      body: JSON.stringify({}),
    });
    assert.equal(cleared.status, 204);
    const clearedSetCookie = cleared.headers.get("set-cookie") ?? "";
    assert.match(clearedSetCookie, /Path=\/;/);
    assert.match(clearedSetCookie, /training_access=; Max-Age=0; Path=\/training/);
    const clearedCookie = clearedSetCookie.split(";", 1)[0];
    const session = await fetch(`${origin}/api/v1/training/session`, { headers: { Cookie: clearedCookie } });
    assert.equal(session.status, 200);
    assert.equal(((await session.json()) as { employee: unknown }).employee, null);
  });


  it("rejects duplicate eligible employee codes without selecting arbitrarily", async () => {
    const origin = await start(deps({ verified: true, duplicateEmployeeCode: true }));
    const verify = await fetch(`${origin}/api/v1/training/access/verify`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ branch_id: ids.branch, pin: "1234" }),
    });
    const cookie = (verify.headers.get("set-cookie") ?? "").split(";", 1)[0];
    const selected = await fetch(`${origin}/api/v1/training/employee/select`, {
      method: "POST",
      headers: { Cookie: cookie, "Content-Type": "application/json" },
      body: JSON.stringify({ employee_code: "EMP-001" }),
    });
    assert.equal(selected.status, 409);
    assert.doesNotMatch(selected.headers.get("set-cookie") ?? "", /training_access=.*[^;]/);
  });

  it("returns to employee selection when an employee-bound session becomes ineligible but branch Training remains valid", async () => {
    const origin = await start(deps({ verified: true, noEmployee: true }));
    const crypto = createPinCrypto("test-branch-training-secret-placeholder-32-bytes");
    const employeeGrant = crypto.issueTrainingGrant?.(ids.organization, ids.branch, ids.version, Date.now(), ids.employee) ?? "";
    const session = await fetch(`${origin}/api/v1/training/session`, { headers: { Cookie: `training_access=${employeeGrant}` } });
    assert.equal(session.status, 200);
    assert.equal(((await session.json()) as { employee: unknown }).employee, null);

    const disabled = await start(deps({ verified: true, noSession: true }));
    const rejected = await fetch(`${disabled}/api/v1/training/session`, { headers: { Cookie: `training_access=${employeeGrant}` } });
    assert.equal(rejected.status, 401);
  });

  it("rate limits repeated Training PIN guesses per scoped branch and IP", async () => {
    const origin = await start(deps({ verified: false }));
    const statuses: number[] = [];
    for (let index = 0; index < 12; index += 1) {
      statuses.push((await fetch(`${origin}/api/v1/training/access/verify`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ branch_id: ids.branch, pin: "1234" }),
      })).status);
    }
    assert.ok(statuses.includes(429));
  });

  it("retires old Training Account email/password endpoints at runtime", async () => {
    const origin = await start(deps({ internalAdmin: true }));
    assert.equal((await fetch(`${origin}/api/v1/training/account`, { headers: { Authorization: "Bearer valid" } })).status, 410);
    assert.equal((await authRequest(origin, `/api/v1/internal-admin/organizations/${ids.organization}/training-accounts`)).status, 410);
    assert.equal((await authRequest(origin, `/api/v1/internal-admin/organizations/${ids.organization}/training-accounts/${ids.actor}/reset-password`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ temporary_password: "secret1" }) })).status, 410);
  });

  it("keeps the branch training access SQL free of the 42702 ambiguous conflict target", () => {
    const canonical = readFileSync("supabase/migrations/20260826090000_branch_training_access_pin.sql", "utf8");
    const corrective = readFileSync("supabase/migrations/20260826093000_fix_branch_training_access_rpc_ambiguity.sql", "utf8");

    for (const sql of [canonical, corrective]) {
      assert.match(sql, /create or replace function public\.store_internal_admin_branch_training_access/);
      assert.match(sql, /insert into public\.branch_training_access as bta/);
      assert.match(sql, /on conflict on constraint branch_training_access_pkey/);
      assert.doesNotMatch(sql, /on conflict\s*\(\s*organization_id\s*,\s*branch_id\s*\)/i);
      assert.match(sql, /else bta\.pin_hash end/);
      assert.match(sql, /else bta\.credential_version end/);
    }
  });

  it("adds service-role-only SQL for minimal branch Training employee selection", () => {
    const migration = readFileSync("supabase/migrations/20260826100000_training_employee_selection.sql", "utf8");
    assert.match(migration, /create or replace function public\.list_training_branch_employees/);
    assert.match(migration, /create or replace function public\.validate_training_branch_employee/);
    assert.match(migration, /staff\.employment_status = 'active'/);
    assert.match(migration, /assignment\.active/);
    assert.match(migration, /operational_team\.active/);
    assert.match(migration, /revoke all on function public\.list_training_branch_employees\(uuid, uuid\) from public, anon, authenticated/);
    assert.match(migration, /grant execute on function public\.validate_training_branch_employee\(uuid, uuid, uuid\) to service_role/);
    assert.doesNotMatch(migration, /iqama|phone|email|country_code|company_name|supervisor/i);
  });
});
