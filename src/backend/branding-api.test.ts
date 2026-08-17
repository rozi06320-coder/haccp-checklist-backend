import assert from "node:assert/strict";
import { createServer, request as nodeRequest, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, afterEach, before, describe, it } from "node:test";
import { createApp } from "./app";
import { BrandingAccessError, BrandingInputError, BrandingUnavailableError, createBrandingServiceFromClient, MAX_BRANDING_BYTES, type BrandingService } from "./branding";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";
import { inspectEvidenceImage } from "./evidence";

const admin = "12000000-0000-4000-8000-000000000001";
const manager = "12000000-0000-4000-8000-000000000002";
const supervisor = "12000000-0000-4000-8000-000000000003";
const maintenance = "12000000-0000-4000-8000-000000000004";
const organization = "22000000-0000-4000-8000-000000000001";
const otherOrganization = "22000000-0000-4000-8000-000000000002";
const branch = "32000000-0000-4000-8000-000000000001";
const otherBranch = "32000000-0000-4000-8000-000000000002";
const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x00, 0xff, 0xd9]);
const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(4), Buffer.from("IHDR"), Buffer.alloc(9), Buffer.alloc(4), Buffer.from("IEND"), Buffer.alloc(4)]);
const webp = Buffer.concat([Buffer.from("RIFF"), Buffer.alloc(4), Buffer.from("WEBP"), Buffer.alloc(8)]);
webp.writeUInt32LE(webp.length - 8, 4);

const config: BackendConfig = {
  nodeEnv: "test",
  host: "127.0.0.1",
  port: 1,
  trustProxy: false,
  supabase: { url: "http://127.0.0.1", publishableKey: "test", secretKey: "test" },
  dailyAuditGrantSecret: "test-placeholder-long-enough-for-tests",
};
const calls: Array<{ name: string; input: unknown }> = [];
let uploadFailure: Error | null = null;
let signFailure: Error | null = null;
let organizationRows: Array<{ id: string; name: string; active: boolean; logo_path?: string | null }> = [];
let branchRows: Array<{ id: string; name: string; code: string; timezone: string; active: boolean; logo_path?: string | null }> = [];
let supervisorBranchLogoUrl: string | null = null;
let supervisorOrganizationLogoUrl: string | null = "https://storage.example.invalid/org-logo";
const brandingService: BrandingService = {
  async signLogoPath(path) {
    if (signFailure) throw signFailure;
    return path ? `https://storage.example.invalid/sign/${encodeURIComponent(path)}` : null;
  },
  async uploadOrganizationLogo(input) {
    calls.push({ name: "organization", input: { ...input, bytes: Buffer.from(input.bytes) } });
    if (uploadFailure) throw uploadFailure;
    try { inspectEvidenceImage(input.bytes, input.declaredMime); } catch { throw new BrandingInputError(); }
    return { organization_id: input.organizationId, organization_logo_url: "https://storage.example.invalid/org-logo" };
  },
  async uploadBranchLogo(input) {
    calls.push({ name: "branch", input: { ...input, bytes: Buffer.from(input.bytes) } });
    if (input.organizationId === otherOrganization || input.branchId === otherBranch) throw new BrandingAccessError();
    if (uploadFailure) throw uploadFailure;
    try { inspectEvidenceImage(input.bytes, input.declaredMime); } catch { throw new BrandingInputError(); }
    branchRows = [{ id: input.branchId, name: "Branch", code: "BR", timezone: "Asia/Riyadh", active: true, logo_path: `branches/${input.branchId}/logo/42000000-0000-4000-8000-000000000099.jpg` }];
    return { branch_id: input.branchId, branch_logo_url: "https://storage.example.invalid/branch-logo", branch_logo_configured: true };
  },
  async getManagementOrganizationBranding(actorUserId) {
    if (actorUserId !== manager) throw new BrandingAccessError();
    return { organization_logo_url: "https://storage.example.invalid/org-logo" };
  },
  async getMaintenanceOrganizationBranding(actorUserId) {
    if (actorUserId !== maintenance) throw new BrandingAccessError();
    return { organization_logo_url: "https://storage.example.invalid/maintenance-org-logo" };
  },
  async getMaintenanceAccessOrganizationBranding() {
    return { organization_logo_url: "https://storage.example.invalid/maintenance-access-logo" };
  },
  async getSupervisorBranchBranding(actorUserId) {
    if (actorUserId !== supervisor) throw new BrandingAccessError();
    return {
      branch_logo_url: supervisorBranchLogoUrl,
      organization_logo_url: supervisorOrganizationLogoUrl,
      effective_logo_url: supervisorBranchLogoUrl ?? supervisorOrganizationLogoUrl,
    };
  },
};

function deps(): BackendDependencies {
  return {
    brandingService,
    checkReadiness: async () => true,
    passwordChange: { verifyCurrent: async () => true, updatePassword: async () => {}, finalize: async () => {} },
    provisioningAdmin: { createUser: async () => ({ id: admin }), deleteUser: async () => {}, finalize: async () => {} },
    managementAdmin: {
      listUsers: async () => ({ users: [], total: 0 }),
      listOrganizationsForInternalAdmin: async () => organizationRows.length
        ? organizationRows
        : [{ id: organization, name: "Org", active: true, logo_path: `organizations/${organization}/logo/42000000-0000-4000-8000-000000000001.png` }],
      listBranchesForInternalAdmin: async () => branchRows.length
        ? branchRows
        : [{ id: branch, name: "Branch", code: "BR", timezone: "Asia/Riyadh", active: true, logo_path: `branches/${branch}/logo/42000000-0000-4000-8000-000000000002.png` }],
    },
    branchManagementAdmin: {
      listBranches: async () => [],
      listStaff: async () => [],
      getPinMetadata: async () => ({ configured: false, updated_at: null, updated_by_name: null }),
      storePin: async () => ({ configured: false, updated_at: null, updated_by_name: null }),
      getPinCredential: async () => null,
    },
    pinCrypto: {
      hash: async () => ({ pin_hash: "x", salt: "x", kdf_version: 1, cost: 1, block_size: 1, parallelization: 1 }),
      verify: async () => false,
      issueGrant: () => "",
      verifyGrant: () => false,
    },
    authVerifier: {
      verify: async (token) => {
        if (token === "admin") return { userId: admin, email: "admin@example.invalid" };
        if (token === "manager") return { userId: manager, email: "manager@example.invalid" };
        if (token === "supervisor") return { userId: supervisor, email: "supervisor@example.invalid" };
        if (token === "maintenance") return { userId: maintenance, email: "maintenance@example.invalid" };
        return null;
      },
    },
    createUserContext: (token) => ({
      getUserContext: async () => ({
        id: token === "admin" ? admin : token === "manager" ? manager : token === "supervisor" ? supervisor : maintenance,
        full_name: "Actor",
        must_change_password: false,
        disabled: false,
        branches: token === "supervisor" ? [{ id: branch, name: "Branch", organization_id: organization, role: "branch_manager" }] : [],
        managed_organizations: token === "manager" ? [{ id: organization, name: "Org", role: "organization_manager" }] : [],
      }),
      isInternalAdmin: async () => token === "admin",
      hasOrganizationManagerAccess: async () => token === "manager",
      validateActiveBranches: async () => token === "supervisor",
      listActiveBranches: async () => [],
    }),
  };
}

let server: Server;
let origin = "";
async function request(path: string, token?: string, init: RequestInit = {}) {
  return fetch(origin + path, { ...init, headers: { ...(token ? { Authorization: `Bearer ${token}` } : { "x-no-auth": "1" }), ...(init.headers ?? {}) } });
}
async function rawStatus(path: string, headers: Record<string, string>) {
  return new Promise<number>((resolve, reject) => {
    const target = new URL(path, origin);
    const req = nodeRequest(target, { method: "POST", headers }, (response) => {
      resolve(response.statusCode ?? 0);
      response.resume();
    });
    req.once("error", reject);
    req.end();
  });
}

describe("branding storage/database compensation", () => {
  it("removes uploaded object if database update fails", async () => {
    const removed: string[][] = [];
    const client = {
      storage: { from: () => ({
        upload: async () => ({ data: { path: "opaque" }, error: null }),
        remove: async (paths: string[]) => { removed.push(paths); return { data: null, error: null }; },
        createSignedUrl: async () => ({ data: { signedUrl: "https://storage.example.invalid/signed" }, error: null }),
      }) },
      rpc: async () => ({ data: null, error: { code: "XX000" } }),
    };
    const service = createBrandingServiceFromClient(client as never);
    await assert.rejects(() => service.uploadOrganizationLogo({
      actorUserId: admin,
      organizationId: organization,
      bytes: png,
      declaredMime: "image/png",
      requestId: "branding-request",
    }), BrandingUnavailableError);
    assert.equal(removed.length, 1);
    assert.match(removed[0][0], new RegExp(`^organizations/${organization}/logo/`));
  });

  it("keeps uploaded object and returns null logo URL if signing fails after database update", async () => {
    const removed: string[][] = [];
    let storedPath = "";
    const client = {
      storage: { from: () => ({
        upload: async (path: string) => {
          storedPath = path;
          return { data: { path }, error: null };
        },
        remove: async (paths: string[]) => {
          removed.push(paths);
          return { data: null, error: null };
        },
        createSignedUrl: async () => ({ data: null, error: { message: "signing unavailable" } }),
      }) },
      rpc: async (_name: string, args: { object_path: string }) => ({
        data: [{ id: organization, logo_path: args.object_path }],
        error: null,
      }),
    };
    const service = createBrandingServiceFromClient(client as never);
    const result = await service.uploadOrganizationLogo({
      actorUserId: admin,
      organizationId: organization,
      bytes: png,
      declaredMime: "image/png",
      requestId: "branding-request",
    });
    assert.match(storedPath, new RegExp(`^organizations/${organization}/logo/`));
    assert.deepEqual(result, { organization_id: organization, organization_logo_url: null });
    assert.equal(removed.length, 0);
  });

  it("keeps organization upload persisted when the database RPC returns its full row shape", async () => {
    const removed: string[][] = [];
    let storedPath = "";
    let storedBytes = Buffer.alloc(0);
    let storedContentType = "";
    const client = {
      storage: { from: (bucket: string) => {
        assert.equal(bucket, "branding-assets");
        return {
          upload: async (path: string, bytes: Buffer, options: { contentType?: string }) => {
            storedPath = path;
            storedBytes = Buffer.from(bytes);
            storedContentType = options.contentType ?? "";
            return { data: { path }, error: null };
          },
          remove: async (paths: string[]) => {
            removed.push(paths);
            return { data: null, error: null };
          },
          createSignedUrl: async (path: string) => ({ data: { signedUrl: `https://storage.example.invalid/sign/${encodeURIComponent(path)}` }, error: null }),
        };
      } },
      rpc: async (name: string, args: { object_path: string }) => {
        assert.equal(name, "update_internal_admin_organization_logo");
        return {
          data: [{ id: organization, name: "Org", logo_path: args.object_path }],
          error: null,
        };
      },
    };
    const service = createBrandingServiceFromClient(client as never);
    const result = await service.uploadOrganizationLogo({
      actorUserId: admin,
      organizationId: organization,
      bytes: png,
      declaredMime: "image/png",
      requestId: "branding-request",
    });
    assert.match(storedPath, new RegExp(`^organizations/${organization}/logo/[0-9a-f-]{36}\\.png$`));
    assert.deepEqual(storedBytes, png);
    assert.equal(storedContentType, "image/png");
    assert.deepEqual(result, {
      organization_id: organization,
      organization_logo_url: `https://storage.example.invalid/sign/${encodeURIComponent(storedPath)}`,
    });
    assert.equal(removed.length, 0);
  });

  it("keeps branch upload persisted when the database RPC returns its full row shape", async () => {
    const removed: string[][] = [];
    let storedPath = "";
    let storedBytes = Buffer.alloc(0);
    let storedContentType = "";
    const client = {
      storage: { from: () => ({
        upload: async (path: string, bytes: Buffer, options: { contentType?: string }) => {
          storedPath = path;
          storedBytes = Buffer.from(bytes);
          storedContentType = options.contentType ?? "";
          return { data: { path }, error: null };
        },
        remove: async (paths: string[]) => {
          removed.push(paths);
          return { data: null, error: null };
        },
        createSignedUrl: async (path: string) => ({ data: { signedUrl: `https://storage.example.invalid/sign/${encodeURIComponent(path)}` }, error: null }),
      }) },
      rpc: async (name: string, args: { object_path: string }) => {
        assert.equal(name, "update_internal_admin_branch_logo");
        return {
          data: [{ id: branch, organization_id: organization, name: "Branch", logo_path: args.object_path }],
          error: null,
        };
      },
    };
    const service = createBrandingServiceFromClient(client as never);
    const result = await service.uploadBranchLogo({
      actorUserId: admin,
      organizationId: organization,
      branchId: branch,
      bytes: jpeg,
      declaredMime: "image/jpeg",
      requestId: "branding-request",
    });
    assert.match(storedPath, new RegExp(`^branches/${branch}/logo/[0-9a-f-]{36}\\.jpg$`));
    assert.deepEqual(storedBytes, jpeg);
    assert.equal(storedContentType, "image/jpeg");
    assert.deepEqual(result, {
      branch_id: branch,
      branch_logo_url: `https://storage.example.invalid/sign/${encodeURIComponent(storedPath)}`,
      branch_logo_configured: true,
    });
    assert.equal(removed.length, 0);
  });

  it("keeps branch upload persisted when signing fails and exposes configured state for refresh", async () => {
    const removed: string[][] = [];
    let storedPath = "";
    const client = {
      storage: { from: () => ({
        upload: async (path: string) => {
          storedPath = path;
          return { data: { path }, error: null };
        },
        remove: async (paths: string[]) => {
          removed.push(paths);
          return { data: null, error: null };
        },
        createSignedUrl: async () => ({ data: null, error: { message: "signing unavailable" } }),
      }) },
      rpc: async (_name: string, args: { object_path: string }) => ({
        data: [{ id: branch, organization_id: organization, name: "Branch", logo_path: args.object_path }],
        error: null,
      }),
    };
    const service = createBrandingServiceFromClient(client as never);
    const result = await service.uploadBranchLogo({
      actorUserId: admin,
      organizationId: organization,
      branchId: branch,
      bytes: jpeg,
      declaredMime: "image/jpeg",
      requestId: "branding-request",
    });
    assert.match(storedPath, new RegExp(`^branches/${branch}/logo/`));
    assert.deepEqual(result, { branch_id: branch, branch_logo_url: null, branch_logo_configured: true });
    assert.equal(removed.length, 0);
  });

  it("returns maintenance organization branding only from an active maintenance membership", async () => {
    const client = {
      storage: { from: () => ({
        upload: async () => ({ data: null, error: null }),
        remove: async () => ({ data: null, error: null }),
        createSignedUrl: async (path: string) => ({ data: { signedUrl: `https://storage.example.invalid/sign/${encodeURIComponent(path)}` }, error: null }),
      }) },
      rpc: async () => ({ data: null, error: null }),
      from: (table: string) => {
        assert.equal(table, "maintenance_memberships");
        return {
          select: (columns: string) => {
            assert.equal(columns, "organizations!inner(logo_path)");
            return {
              eq: () => ({
                eq: () => ({
                  eq: () => ({
                    maybeSingle: async () => ({
                      data: { organizations: { logo_path: `organizations/${organization}/logo/42000000-0000-4000-8000-000000000001.png` } },
                      error: null,
                    }),
                  }),
                }),
              }),
            };
          },
        };
      },
    };
    const service = createBrandingServiceFromClient(client as never);
    assert.deepEqual(await service.getMaintenanceOrganizationBranding(maintenance, organization), {
      organization_logo_url: `https://storage.example.invalid/sign/${encodeURIComponent(`organizations/${organization}/logo/42000000-0000-4000-8000-000000000001.png`)}`,
    });
  });

  it("uses the branch logo before organization fallback for supervisor branding", async () => {
    const branchPath = `branches/${branch}/logo/42000000-0000-4000-8000-000000000002.webp`;
    const organizationPath = `organizations/${organization}/logo/42000000-0000-4000-8000-000000000001.png`;
    const client = {
      storage: { from: () => ({
        upload: async () => ({ data: null, error: null }),
        remove: async () => ({ data: null, error: null }),
        createSignedUrl: async (path: string) => ({ data: { signedUrl: `https://storage.example.invalid/sign/${encodeURIComponent(path)}` }, error: null }),
      }) },
      rpc: async (name: string) => {
        assert.equal(name, "get_supervisor_branch_branding");
        return {
          data: [{ branch_id: branch, organization_id: organization, branch_logo_path: branchPath, organization_logo_path: organizationPath }],
          error: null,
        };
      },
    };
    const service = createBrandingServiceFromClient(client as never);
    assert.deepEqual(await service.getSupervisorBranchBranding(supervisor, branch), {
      branch_logo_url: `https://storage.example.invalid/sign/${encodeURIComponent(branchPath)}`,
      organization_logo_url: `https://storage.example.invalid/sign/${encodeURIComponent(organizationPath)}`,
      effective_logo_url: `https://storage.example.invalid/sign/${encodeURIComponent(branchPath)}`,
    });
  });

  it("falls back to organization logo or null safely for supervisor branding", async () => {
    const organizationPath = `organizations/${organization}/logo/42000000-0000-4000-8000-000000000001.png`;
    const client = {
      storage: { from: () => ({
        upload: async () => ({ data: null, error: null }),
        remove: async () => ({ data: null, error: null }),
        createSignedUrl: async (path: string) => path.startsWith("branches/")
          ? { data: null, error: { message: "branch signing unavailable" } }
          : { data: { signedUrl: `https://storage.example.invalid/sign/${encodeURIComponent(path)}` }, error: null },
      }) },
      rpc: async () => ({
        data: [{ branch_id: branch, organization_id: organization, branch_logo_path: `branches/${branch}/logo/42000000-0000-4000-8000-000000000002.webp`, organization_logo_path: organizationPath }],
        error: null,
      }),
    };
    const service = createBrandingServiceFromClient(client as never);
    assert.deepEqual(await service.getSupervisorBranchBranding(supervisor, branch), {
      branch_logo_url: null,
      organization_logo_url: `https://storage.example.invalid/sign/${encodeURIComponent(organizationPath)}`,
      effective_logo_url: `https://storage.example.invalid/sign/${encodeURIComponent(organizationPath)}`,
    });

    const noLogoClient = {
      ...client,
      rpc: async () => ({
        data: [{ branch_id: branch, organization_id: organization, branch_logo_path: null, organization_logo_path: null }],
        error: null,
      }),
    };
    assert.deepEqual(await createBrandingServiceFromClient(noLogoClient as never).getSupervisorBranchBranding(supervisor, branch), {
      branch_logo_url: null,
      organization_logo_url: null,
      effective_logo_url: null,
    });
  });
});

describe("branding API", () => {
  before(async () => {
    server = createServer(createApp(config, deps()));
    await new Promise<void>((resolve, reject) => server.listen(0, "127.0.0.1", resolve).once("error", reject));
    origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });
  after(() => new Promise<void>((resolve) => server.close(() => resolve())));
  afterEach(() => {
    uploadFailure = null;
    signFailure = null;
    organizationRows = [];
    branchRows = [];
    supervisorBranchLogoUrl = null;
    supervisorOrganizationLogoUrl = "https://storage.example.invalid/org-logo";
  });

  it("lists Internal Admin organizations when logo_path is null or absent", async () => {
    organizationRows = [
      { id: organization, name: "No Logo Org", active: true, logo_path: null },
      { id: otherOrganization, name: "Legacy Org", active: true },
    ];
    const response = await request("/api/v1/internal-admin/organizations", "admin");
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), {
      organizations: [
        { id: organization, name: "No Logo Org", name_ar: null, active: true, logo_url: null },
        { id: otherOrganization, name: "Legacy Org", name_ar: null, active: true, logo_url: null },
      ],
    });
  });

  it("keeps Internal Admin organizations available when logo signing fails", async () => {
    organizationRows = [{ id: organization, name: "Org", active: true, logo_path: `organizations/${organization}/logo/42000000-0000-4000-8000-000000000001.png` }];
    signFailure = new BrandingUnavailableError();
    const response = await request("/api/v1/internal-admin/organizations", "admin");
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), {
      organizations: [{ id: organization, name: "Org", name_ar: null, active: true, logo_url: null }],
    });
  });

  it("enriches Internal Admin organization and branch lists with signed thumbnail URLs", async () => {
    const orgs = await request("/api/v1/internal-admin/organizations", "admin");
    assert.equal(orgs.status, 200);
    const orgBody = await orgs.json();
    assert.equal(orgBody.organizations[0].logo_url.startsWith("https://storage.example.invalid/sign/"), true);
    assert.equal("logo_path" in orgBody.organizations[0], false);
    const branches = await request(`/api/v1/internal-admin/organizations/${organization}/branches`, "admin");
    assert.equal(branches.status, 200);
    const branchBody = await branches.json();
    assert.equal(branchBody.branches[0].logo_url.startsWith("https://storage.example.invalid/sign/"), true);
    assert.equal(branchBody.branches[0].logo_configured, true);
    assert.equal("logo_path" in branchBody.branches[0], false);
  });

  it("uploads valid organization and branch images for Internal Admin only", async () => {
    for (const [path, bytes, mime] of [
      [`/api/v1/internal-admin/organizations/${organization}/logo`, png, "image/png"],
      [`/api/v1/internal-admin/organizations/${organization}/branches/${branch}/logo`, jpeg, "image/jpeg"],
      [`/api/v1/internal-admin/organizations/${organization}/logo`, webp, "image/webp"],
    ] as Array<[string, Buffer, string]>) {
      const response = await request(path, "admin", { method: "POST", headers: { "Content-Type": mime, "Content-Length": String(bytes.length) }, body: bytes as unknown as BodyInit });
      assert.equal(response.status, 200);
      assert.match(response.headers.get("cache-control") ?? "", /no-store/);
      assert.equal(response.headers.get("x-content-type-options"), "nosniff");
    }
    const input = calls.at(-1)?.input as { actorUserId: string; bytes: Buffer; declaredMime: string };
    assert.equal(input.actorUserId, admin);
    assert.deepEqual(input.bytes, webp);
    assert.equal(input.declaredMime, "image/webp");
  });

  it("restores a persisted branch logo from the Internal Admin branch list after upload", async () => {
    const upload = await request(`/api/v1/internal-admin/organizations/${organization}/branches/${branch}/logo`, "admin", {
      method: "POST",
      headers: { "Content-Type": "image/jpeg", "Content-Length": String(jpeg.length) },
      body: jpeg as unknown as BodyInit,
    });
    assert.equal(upload.status, 200);
    assert.deepEqual(await upload.json(), {
      branding: {
        branch_id: branch,
        branch_logo_url: "https://storage.example.invalid/branch-logo",
        branch_logo_configured: true,
      },
    });

    const refreshed = await request(`/api/v1/internal-admin/organizations/${organization}/branches`, "admin");
    assert.equal(refreshed.status, 200);
    const body = await refreshed.json();
    assert.equal(body.branches[0].id, branch);
    assert.equal(body.branches[0].logo_configured, true);
    assert.equal(body.branches[0].logo_url, `https://storage.example.invalid/sign/${encodeURIComponent(`branches/${branch}/logo/42000000-0000-4000-8000-000000000099.jpg`)}`);
    assert.equal("logo_path" in body.branches[0], false);
  });

  it("rejects invalid bytes, unsupported MIME, oversized images, and cross-organization branch uploads", async () => {
    let response = await request(`/api/v1/internal-admin/organizations/${organization}/logo`, "admin", {
      method: "POST",
      headers: { "Content-Type": "image/svg+xml", "Content-Length": "11" },
      body: Buffer.from("<svg></svg>") as unknown as BodyInit,
    });
    assert.equal(response.status, 422);
    response = await request(`/api/v1/internal-admin/organizations/${organization}/logo`, "admin", {
      method: "POST",
      headers: { "Content-Type": "image/png", "Content-Length": String(jpeg.length) },
      body: jpeg as unknown as BodyInit,
    });
    assert.equal(response.status, 422);
    assert.equal(await rawStatus(`/api/v1/internal-admin/organizations/${organization}/logo`, {
      Authorization: "Bearer admin",
      "Content-Type": "image/png",
      "Content-Length": String(MAX_BRANDING_BYTES + 1),
    }), 413);
    response = await request(`/api/v1/internal-admin/organizations/${otherOrganization}/branches/${otherBranch}/logo`, "admin", {
      method: "POST",
      headers: { "Content-Type": "image/png", "Content-Length": String(png.length) },
      body: png as unknown as BodyInit,
    });
    assert.equal(response.status, 403);
  });

  it("denies non-admin upload attempts and supports authorized dashboard branding reads", async () => {
    for (const token of [undefined, "manager", "supervisor", "maintenance"]) {
      const response = await request(`/api/v1/internal-admin/organizations/${organization}/logo`, token, {
        method: "POST",
        headers: { "Content-Type": "image/png", "Content-Length": String(png.length) },
        body: png as unknown as BodyInit,
      });
      assert.equal(response.status, token ? 403 : 401);
    }
    const managerBranding = await request(`/api/v1/management/organizations/${organization}/branding`, "manager");
    assert.equal(managerBranding.status, 200);
    assert.deepEqual(await managerBranding.json(), { branding: { organization_logo_url: "https://storage.example.invalid/org-logo" } });
    const supervisorBranding = await request(`/api/v1/supervisor/branches/${branch}/branding`, "supervisor");
    assert.equal(supervisorBranding.status, 200);
    assert.deepEqual(await supervisorBranding.json(), { branding: {
      branch_logo_url: null,
      organization_logo_url: "https://storage.example.invalid/org-logo",
      effective_logo_url: "https://storage.example.invalid/org-logo",
    } });
    const maintenanceBranding = await request(`/api/v1/maintenance/organizations/${organization}/branding`, "maintenance");
    assert.equal(maintenanceBranding.status, 200);
    assert.deepEqual(await maintenanceBranding.json(), { branding: { organization_logo_url: "https://storage.example.invalid/maintenance-org-logo" } });
    assert.equal((await request(`/api/v1/maintenance/organizations/${organization}/branding`, "manager")).status, 403);
  });

  it("returns supervisor branch logo as effective branding before organization fallback", async () => {
    supervisorBranchLogoUrl = "https://storage.example.invalid/branch-logo";
    let response = await request(`/api/v1/supervisor/branches/${branch}/branding`, "supervisor");
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { branding: {
      branch_logo_url: "https://storage.example.invalid/branch-logo",
      organization_logo_url: "https://storage.example.invalid/org-logo",
      effective_logo_url: "https://storage.example.invalid/branch-logo",
    } });

    supervisorBranchLogoUrl = null;
    response = await request(`/api/v1/supervisor/branches/${branch}/branding`, "supervisor");
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { branding: {
      branch_logo_url: null,
      organization_logo_url: "https://storage.example.invalid/org-logo",
      effective_logo_url: "https://storage.example.invalid/org-logo",
    } });

    supervisorOrganizationLogoUrl = null;
    response = await request(`/api/v1/supervisor/branches/${branch}/branding`, "supervisor");
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { branding: {
      branch_logo_url: null,
      organization_logo_url: null,
      effective_logo_url: null,
    } });
  });

  it("returns safe upload errors without leaking storage diagnostics", async () => {
    uploadFailure = new BrandingInputError();
    const response = await request(`/api/v1/internal-admin/organizations/${organization}/logo`, "admin", {
      method: "POST",
      headers: { "Content-Type": "image/png", "Content-Length": String(png.length) },
      body: png as unknown as BodyInit,
    });
    assert.equal(response.status, 422);
    assert.doesNotMatch(JSON.stringify(await response.json()), /stack|storage|path|bucket|service_role/i);
  });
});
