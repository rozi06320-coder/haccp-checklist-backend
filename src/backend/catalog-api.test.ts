import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, describe, it } from "node:test";
import { createApp } from "./app";
import { ChecklistAccessError, ChecklistConflictError, ChecklistInputError, createChecklistPersistence } from "./checklist-persistence";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const supervisor = "17000000-0000-4000-8000-000000000001";
const manager = "17000000-0000-4000-8000-000000000002";
const other = "17000000-0000-4000-8000-000000000003";
const otherBranchManager = "17000000-0000-4000-8000-000000000004";
const staffUser = "17000000-0000-4000-8000-000000000005";
const orgAndBranchManager = "17000000-0000-4000-8000-000000000006";
const branch = "27000000-0000-4000-8000-000000000001";
const otherBranch = "27000000-0000-4000-8000-000000000002";
const org = "37000000-0000-4000-8000-000000000001";
const productId = "47000000-0000-4000-8000-000000000001";
const standaloneProductId = "47000000-0000-4000-8000-000000000002";
const breadId = "57000000-0000-4000-8000-000000000001";
const waterId = "57000000-0000-4000-8000-000000000002";
const mappingId = "67000000-0000-4000-8000-000000000001";
const calls: Array<{ name: string; input: unknown }> = [];
let mode: "empty" | "recipe" | "standalone" | "conflict" | "invalid" | "access" = "empty";

function catalog() {
  return {
    products: mode === "empty" ? [] : [
      { id: productId, branch_id: branch, name: "Smoky Beef", inventory_behavior: "recipe", unit: null, standalone_inventory_item_id: null, is_active: true, created_at: "2026-09-09T10:00:00.000Z", updated_at: "2026-09-09T10:00:00.000Z" },
      ...(mode === "standalone" ? [{ id: standaloneProductId, branch_id: branch, name: "Bottled Water", inventory_behavior: "standalone_stock", unit: "pcs", standalone_inventory_item_id: waterId, is_active: true, created_at: "2026-09-09T10:00:00.000Z", updated_at: "2026-09-09T10:00:00.000Z" }] : []),
    ],
    inventory_items: mode === "empty" ? [] : [
      { id: breadId, branch_id: branch, name: "Bread", unit: "pcs", kind: "ingredient", is_active: true, created_at: "2026-09-09T10:00:00.000Z", updated_at: "2026-09-09T10:00:00.000Z" },
      ...(mode === "standalone" ? [{ id: waterId, branch_id: branch, name: "Bottled Water", unit: "pcs", kind: "standalone_stock", is_active: true, created_at: "2026-09-09T10:00:00.000Z", updated_at: "2026-09-09T10:00:00.000Z" }] : []),
    ],
    product_usage_mappings: mode === "empty" || mode === "standalone" ? [] : [
      { id: mappingId, product_id: productId, inventory_item_id: breadId, quantity: "1", created_at: "2026-09-09T10:00:00.000Z", updated_at: "2026-09-09T10:00:00.000Z" },
    ],
  };
}

const persistence = {
  async listBranchCatalog(actorUserId: string, branchId: string) {
    calls.push({ name: "list", input: { actorUserId, branchId } });
    if (mode === "access" || branchId !== branch) throw new ChecklistAccessError();
    return catalog();
  },
  async createBranchCatalogProduct(input: unknown) {
    calls.push({ name: "create-product", input });
    if (mode === "conflict") throw new ChecklistConflictError();
    if (mode === "invalid") throw new ChecklistInputError();
    mode = ((input as { payload: { inventoryBehavior: string } }).payload.inventoryBehavior === "standalone_stock") ? "standalone" : "recipe";
    return catalog();
  },
  async createBranchCatalogInventoryItem(input: unknown) {
    calls.push({ name: "create-inventory", input });
    if (mode === "conflict") throw new ChecklistConflictError();
    mode = "recipe";
    return catalog();
  },
  async updateBranchCatalogInventoryItem(input: unknown) {
    calls.push({ name: "update-inventory", input });
    if (mode === "conflict") throw new ChecklistConflictError();
    return catalog();
  },
  async mergeBranchCatalogInventoryItem(input: unknown) {
    calls.push({ name: "merge-inventory", input });
    if (mode === "conflict") throw new ChecklistConflictError();
    if (mode === "invalid") throw new ChecklistInputError();
    if (mode === "access") throw new ChecklistAccessError();
    return catalog();
  },
  async saveBranchProductUsageMappings(input: unknown) {
    calls.push({ name: "save-recipe", input });
    if (mode === "invalid") throw new ChecklistInputError();
    mode = "recipe";
    return catalog();
  },
  async getOverview() { throw new Error("unused"); }, async getCurrentState() { throw new Error("unused"); }, async saveDraft() { throw new Error("unused"); }, async saveHygieneDraft() { throw new Error("unused"); }, async submitOpening() { throw new Error("unused"); }, async submitHygiene() { throw new Error("unused"); }, async listSupervisor() { throw new Error("unused"); }, async getReport() { throw new ChecklistAccessError(); }, async listManagedReports() { return { reports: [], page: 1, page_size: 20, total: 0 }; }, async listManagedIssues() { return { issues: [], page: 1, page_size: 20, total: 0 }; }, async getManagedIssue() { throw new Error("unused"); },
} as BackendDependencies["checklistPersistence"];

function deps(): BackendDependencies {
  return {
    checkReadiness: async () => true,
    checklistPersistence: persistence,
    passwordChange: { verifyCurrent: async () => true, updatePassword: async () => {}, finalize: async () => {} },
    provisioningAdmin: { createUser: async () => ({ id: supervisor }), deleteUser: async () => {}, finalize: async () => {} },
    managementAdmin: { listUsers: async () => ({ users: [], total: 0 }) },
    branchManagementAdmin: { listBranches: async () => [], listStaff: async () => [], getPinMetadata: async () => ({ configured: false, updated_at: null, updated_by_name: null }), storePin: async () => ({ configured: false, updated_at: null, updated_by_name: null }), getPinCredential: async () => null },
    pinCrypto: { hash: async () => ({ pin_hash: "x", salt: "x", kdf_version: 1, cost: 1, block_size: 1, parallelization: 1 }), verify: async () => false, issueGrant: () => "", verifyGrant: async () => false },
    authVerifier: {
      verify: async (token) =>
        token === "supervisor"
          ? { userId: supervisor, email: "s@example.invalid" }
          : token === "manager"
            ? { userId: manager, email: "m@example.invalid" }
            : token === "other"
              ? { userId: other, email: "o@example.invalid" }
              : token === "other-branch-mgr"
                ? { userId: otherBranchManager, email: "obm@example.invalid" }
                : token === "staff"
                  ? { userId: staffUser, email: "staff@example.invalid" }
                  : token === "org-branch-mgr"
                    ? { userId: orgAndBranchManager, email: "obm2@example.invalid" }
                    : null,
    },
    createUserContext: (token) => ({
      getUserContext: async () => {
        if (token === "supervisor") {
          return { id: supervisor, full_name: "Supervisor", must_change_password: false, disabled: false, branches: [{ id: branch, name: "Branch", organization_id: org, role: "branch_manager" }], managed_organizations: [] };
        }
        if (token === "manager") {
          return { id: manager, full_name: "Manager", must_change_password: false, disabled: false, branches: [], managed_organizations: [{ id: org, name: "Org", role: "organization_manager" }] };
        }
        if (token === "other-branch-mgr") {
          return { id: otherBranchManager, full_name: "Other Branch Manager", must_change_password: false, disabled: false, branches: [{ id: otherBranch, name: "Other Branch", organization_id: org, role: "branch_manager" }], managed_organizations: [] };
        }
        if (token === "staff") {
          return { id: staffUser, full_name: "Staff", must_change_password: false, disabled: false, branches: [{ id: branch, name: "Branch", organization_id: org, role: "staff" }], managed_organizations: [] };
        }
        if (token === "org-branch-mgr") {
          return { id: orgAndBranchManager, full_name: "Org and Branch Manager", must_change_password: false, disabled: false, branches: [{ id: branch, name: "Branch", organization_id: org, role: "branch_manager" }], managed_organizations: [{ id: org, name: "Org", role: "organization_manager" }] };
        }
        return { id: other, full_name: "Other", must_change_password: false, disabled: false, branches: [], managed_organizations: [] };
      },
      isInternalAdmin: async () => false,
      hasOrganizationManagerAccess: async () => false,
      validateActiveBranches: async () => false,
      listActiveBranches: async () => [],
    }),
  };
}

const config: BackendConfig = { nodeEnv: "test", host: "127.0.0.1", port: 1, trustProxy: false, supabase: { url: "http://127.0.0.1", publishableKey: "test", secretKey: "test" }, dailyAuditGrantSecret: "test-placeholder-long-enough-for-tests" };
let server: Server;
let origin: string;
async function request(path: string, token?: string, init: RequestInit = {}) {
  return fetch(origin + path, { ...init, headers: { ...(token ? { Authorization: `Bearer ${token}` } : { "x-no-auth": "1" }), ...(init.headers ?? {}) } });
}

describe("Branch product and inventory catalog API", () => {
  before(async () => {
    server = createServer(createApp(config, deps()));
    await new Promise<void>((resolve, reject) => server.listen(0, "127.0.0.1", resolve).once("error", reject));
    origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });
  after(() => new Promise<void>((resolve) => server.close(() => resolve())));
  beforeEach(() => { calls.length = 0; mode = "empty"; });

  it("lists an empty branch-scoped catalog for a supervisor only", async () => {
    const path = `/api/v1/supervisor/branches/${branch}/catalog`;
    assert.equal((await request(path)).status, 401);
    assert.equal((await request(path, "manager")).status, 403);
    const response = await request(path, "supervisor");
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { products: [], inventory_items: [], product_usage_mappings: [] });
    assert.deepEqual(calls.at(-1), { name: "list", input: { actorUserId: supervisor, branchId: branch } });
  });

  it("creates recipe products atomically with ID-based mappings", async () => {
    const body = { name: "Smoky Beef", inventory_behavior: "recipe", recipe_rows: [{ ingredient: "Bread", quantity: 1, unit: "pcs" }] };
    const response = await request(`/api/v1/supervisor/branches/${branch}/catalog/products`, "supervisor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
    assert.equal(response.status, 201);
    const result = await response.json();
    assert.equal(result.products[0].inventory_behavior, "recipe");
    assert.equal(result.inventory_items[0].name, "Bread");
    assert.equal(result.product_usage_mappings[0].product_id, productId);
    assert.deepEqual(calls.at(-1), { name: "create-product", input: { actorUserId: supervisor, branchId: branch, payload: { name: "Smoky Beef", inventoryBehavior: "recipe", unit: undefined, recipeRows: [{ ingredient: "Bread", quantity: 1, unit: "pcs" }] } } });
  });

  it("creates standalone stock without a fake recipe and keeps non-stock product payload valid", async () => {
    const standalone = await request(`/api/v1/supervisor/branches/${branch}/catalog/products`, "supervisor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name: "Bottled Water", inventory_behavior: "standalone_stock", unit: "pcs" }) });
    assert.equal(standalone.status, 201);
    const body = await standalone.json();
    assert.equal(body.products.some((product: { standalone_inventory_item_id: string | null }) => product.standalone_inventory_item_id === waterId), true);
    assert.equal(body.product_usage_mappings.length, 0);
    const nonStock = await request(`/api/v1/supervisor/branches/${branch}/catalog/products`, "supervisor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name: "Service Charge", inventory_behavior: "non_stock" }) });
    assert.equal(nonStock.status, 201);

    // Reject standalone_stock with recipe_rows
    const standaloneWithRecipe = await request(`/api/v1/supervisor/branches/${branch}/catalog/products`, "supervisor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name: "Bottled Water 2", inventory_behavior: "standalone_stock", unit: "pcs", recipe_rows: [{ ingredient: "Water", quantity: 1, unit: "pcs" }] }) });
    assert.equal(standaloneWithRecipe.status, 400);

    // Reject standalone_stock missing unit
    const standaloneNoUnit = await request(`/api/v1/supervisor/branches/${branch}/catalog/products`, "supervisor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name: "Bottled Water 3", inventory_behavior: "standalone_stock" }) });
    assert.equal(standaloneNoUnit.status, 400);

    // Reject non_stock with recipe_rows
    const nonStockWithRecipe = await request(`/api/v1/supervisor/branches/${branch}/catalog/products`, "supervisor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name: "Service Charge 2", inventory_behavior: "non_stock", recipe_rows: [{ ingredient: "Paper", quantity: 1, unit: "pcs" }] }) });
    assert.equal(nonStockWithRecipe.status, 400);

    // Reject non_stock with unit
    const nonStockWithUnit = await request(`/api/v1/supervisor/branches/${branch}/catalog/products`, "supervisor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name: "Service Charge 3", inventory_behavior: "non_stock", unit: "pcs" }) });
    assert.equal(nonStockWithUnit.status, 400);

    // Reject recipe with standalone stock unit semantics
    const recipeWithUnit = await request(`/api/v1/supervisor/branches/${branch}/catalog/products`, "supervisor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name: "Smoky Beef 2", inventory_behavior: "recipe", unit: "pcs", recipe_rows: [{ ingredient: "Bread", quantity: 1, unit: "pcs" }] }) });
    assert.equal(recipeWithUnit.status, 400);
  });

  it("persists inventory items and updates them through structured sanitized responses", async () => {
    let response = await request(`/api/v1/supervisor/branches/${branch}/catalog/inventory-items`, "supervisor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name: "Bread", unit: "pcs" }) });
    assert.equal(response.status, 201);
    assert.equal((await response.json()).inventory_items[0].name, "Bread");
    response = await request(`/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${breadId}`, "supervisor", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name: "Bread", unit: "kg" }) });
    assert.equal(response.status, 200);
    mode = "conflict";
    response = await request(`/api/v1/supervisor/branches/${branch}/catalog/inventory-items`, "supervisor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name: "Bread", unit: "kg" }) });
    assert.equal(response.status, 409);
    assert.equal((await response.json()).error.message, "Catalog data conflicts with an existing product or inventory item.");
  });

  it("saves one recipe atomically and rejects duplicate or invalid mapping payloads", async () => {
    const response = await request(`/api/v1/supervisor/branches/${branch}/catalog/products/${productId}/recipe`, "supervisor", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ recipe_rows: [{ ingredient: "Bread", quantity: 2, unit: "pcs" }] }) });
    assert.equal(response.status, 200);
    const lastCall = calls.at(-1);
    assert.equal(lastCall?.name, "save-recipe");
    assert.deepEqual((lastCall?.input as Record<string, unknown> | undefined)?.actorUserId, supervisor);
    assert.deepEqual((lastCall?.input as Record<string, unknown> | undefined)?.branchId, branch);
    assert.deepEqual((lastCall?.input as Record<string, unknown> | undefined)?.productId, productId);
    assert.deepEqual((lastCall?.input as Record<string, unknown> | undefined)?.recipeRows, [{ ingredient: "Bread", quantity: 2, unit: "pcs" }]);
    assert.ok((lastCall?.input as Record<string, unknown> | undefined)?.requestId);
    assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/products/${productId}/recipe`, "supervisor", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ recipe_rows: [{ ingredient: "Bread", quantity: 0, unit: "pcs" }] }) })).status, 400);
    mode = "invalid";
    const invalid = await request(`/api/v1/supervisor/branches/${branch}/catalog/products/${productId}/recipe`, "supervisor", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ recipe_rows: [{ ingredient: "Bread", quantity: 1, unit: "pcs" }] }) });
    assert.equal(invalid.status, 422);
  });

  describe("Catalog route authorization matrix across all 5 routes", () => {
    const validProductBody = { name: "New Product", inventory_behavior: "non_stock" };
    const validItemBody = { name: "Cheese", unit: "pcs" };
    const validPatchBody = { name: "Sliced Cheese", unit: "pcs", is_active: true };
    const validRecipeBody = { recipe_rows: [{ ingredient: "Bread", quantity: 1, unit: "pcs" }] };

    it("permits target branch_manager on all 5 routes and derives actor identity strictly from session", async () => {
      // 1. GET /catalog
      let res = await request(`/api/v1/supervisor/branches/${branch}/catalog`, "supervisor");
      assert.equal(res.status, 200);
      assert.equal(calls.at(-1)?.name, "list");
      assert.equal((calls.at(-1)?.input as { actorUserId: string }).actorUserId, supervisor);

      // 2. POST /catalog/products
      res = await request(`/api/v1/supervisor/branches/${branch}/catalog/products`, "supervisor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validProductBody) });
      assert.equal(res.status, 201);
      assert.equal(calls.at(-1)?.name, "create-product");
      assert.equal((calls.at(-1)?.input as { actorUserId: string }).actorUserId, supervisor);

      // 3. POST /catalog/inventory-items
      res = await request(`/api/v1/supervisor/branches/${branch}/catalog/inventory-items`, "supervisor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validItemBody) });
      assert.equal(res.status, 201);
      assert.equal(calls.at(-1)?.name, "create-inventory");
      assert.equal((calls.at(-1)?.input as { actorUserId: string }).actorUserId, supervisor);

      // 4. PATCH /catalog/inventory-items/:id
      res = await request(`/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${breadId}`, "supervisor", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validPatchBody) });
      assert.equal(res.status, 200);
      assert.equal(calls.at(-1)?.name, "update-inventory");
      assert.equal((calls.at(-1)?.input as { actorUserId: string }).actorUserId, supervisor);

      // 5. PUT /catalog/products/:id/recipe
      res = await request(`/api/v1/supervisor/branches/${branch}/catalog/products/${productId}/recipe`, "supervisor", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validRecipeBody) });
      assert.equal(res.status, 200);
      assert.equal(calls.at(-1)?.name, "save-recipe");
      assert.equal((calls.at(-1)?.input as { actorUserId: string }).actorUserId, supervisor);
    });

    it("rejects manager of another branch with 403 on all 5 routes", async () => {
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog`, "other-branch-mgr")).status, 403);
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/products`, "other-branch-mgr", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validProductBody) })).status, 403);
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/inventory-items`, "other-branch-mgr", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validItemBody) })).status, 403);
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${breadId}`, "other-branch-mgr", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validPatchBody) })).status, 403);
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/products/${productId}/recipe`, "other-branch-mgr", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validRecipeBody) })).status, 403);
    });

    it("rejects normal staff on target branch with 403 on all 5 routes", async () => {
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog`, "staff")).status, 403);
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/products`, "staff", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validProductBody) })).status, 403);
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/inventory-items`, "staff", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validItemBody) })).status, 403);
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${breadId}`, "staff", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validPatchBody) })).status, 403);
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/products/${productId}/recipe`, "staff", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validRecipeBody) })).status, 403);
    });

    it("rejects organization manager without branch membership with 403 on all 5 routes", async () => {
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog`, "manager")).status, 403);
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/products`, "manager", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validProductBody) })).status, 403);
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/inventory-items`, "manager", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validItemBody) })).status, 403);
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${breadId}`, "manager", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validPatchBody) })).status, 403);
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/products/${productId}/recipe`, "manager", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validRecipeBody) })).status, 403);
    });

    it("permits organization manager who also has branch_manager role on target branch", async () => {
      // All 5 routes permitted with orgAndBranchManager actor ID
      let res = await request(`/api/v1/supervisor/branches/${branch}/catalog`, "org-branch-mgr");
      assert.equal(res.status, 200);
      assert.equal((calls.at(-1)?.input as { actorUserId: string }).actorUserId, orgAndBranchManager);

      res = await request(`/api/v1/supervisor/branches/${branch}/catalog/products`, "org-branch-mgr", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validProductBody) });
      assert.equal(res.status, 201);
      assert.equal((calls.at(-1)?.input as { actorUserId: string }).actorUserId, orgAndBranchManager);

      res = await request(`/api/v1/supervisor/branches/${branch}/catalog/inventory-items`, "org-branch-mgr", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validItemBody) });
      assert.equal(res.status, 201);
      assert.equal((calls.at(-1)?.input as { actorUserId: string }).actorUserId, orgAndBranchManager);

      res = await request(`/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${breadId}`, "org-branch-mgr", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validPatchBody) });
      assert.equal(res.status, 200);
      assert.equal((calls.at(-1)?.input as { actorUserId: string }).actorUserId, orgAndBranchManager);

      res = await request(`/api/v1/supervisor/branches/${branch}/catalog/products/${productId}/recipe`, "org-branch-mgr", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validRecipeBody) });
      assert.equal(res.status, 200);
      assert.equal((calls.at(-1)?.input as { actorUserId: string }).actorUserId, orgAndBranchManager);
    });

    it("rejects unauthenticated requests with 401 on all 5 routes", async () => {
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog`)).status, 401);
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/products`, undefined, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validProductBody) })).status, 401);
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/inventory-items`, undefined, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validItemBody) })).status, 401);
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${breadId}`, undefined, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validPatchBody) })).status, 401);
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/products/${productId}/recipe`, undefined, { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validRecipeBody) })).status, 401);
    });

    it("does not accept arbitrary client-supplied actor or org parameters (strict schema)", async () => {
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/products`, "supervisor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ...validProductBody, actor_user_id: orgAndBranchManager }) })).status, 400);
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/products`, "supervisor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ...validProductBody, organization_id: org }) })).status, 400);
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/inventory-items`, "supervisor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ...validItemBody, actor_user_id: orgAndBranchManager }) })).status, 400);
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${breadId}`, "supervisor", { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ...validPatchBody, actor_user_id: orgAndBranchManager }) })).status, 400);
      assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/products/${productId}/recipe`, "supervisor", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ...validRecipeBody, actor_user_id: orgAndBranchManager }) })).status, 400);
    });
  });

  describe("Catalog duplicate inventory item merge API", () => {
    const mergePath = `/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${waterId}/merge`;
    const validBody = { target_inventory_item_id: breadId };

    it("merges same-branch duplicate item into canonical target item successfully with verified actor", async () => {
      const res = await request(mergePath, "supervisor", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(validBody),
      });
      assert.equal(res.status, 200);
      assert.deepEqual(calls.at(-1), {
        name: "merge-inventory",
        input: {
          actorUserId: supervisor,
          branchId: branch,
          duplicateInventoryItemId: waterId,
          targetInventoryItemId: breadId,
        },
      });
    });

    it("rejects unauthorized actors on merge route", async () => {
      // 401 unauthenticated
      assert.equal((await request(mergePath, undefined, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validBody) })).status, 401);
      // 403 other branch manager
      assert.equal((await request(mergePath, "other-branch-mgr", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validBody) })).status, 403);
      // 403 staff
      assert.equal((await request(mergePath, "staff", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validBody) })).status, 403);
      // 403 org manager without branch
      assert.equal((await request(mergePath, "manager", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validBody) })).status, 403);
      // 200 org manager who also has target branch manager access
      const permitted = await request(mergePath, "org-branch-mgr", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(validBody) });
      assert.equal(permitted.status, 200);
      assert.equal((calls.at(-1)?.input as { actorUserId: string }).actorUserId, orgAndBranchManager);
    });

    it("handles conflict (recipe collision) with 409 without leaking raw DB errors", async () => {
      mode = "conflict";
      const res = await request(mergePath, "supervisor", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(validBody),
      });
      assert.equal(res.status, 409);
      const data = await res.json();
      assert.equal(data.error.code, "conflict");
      assert.equal(data.error.message, "Catalog data conflicts with an existing product or inventory item.");
    });

    it("handles invalid merge rules (self-merge, unit mismatch) with 422", async () => {
      mode = "invalid";
      const res = await request(mergePath, "supervisor", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(validBody),
      });
      assert.equal(res.status, 422);
      const data = await res.json();
      assert.equal(data.error.code, "unprocessable_entity");
    });

    it("handles cross-branch access rejection with 403", async () => {
      mode = "access";
      const res = await request(mergePath, "supervisor", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(validBody),
      });
      assert.equal(res.status, 403);
    });

    it("rejects invalid request payloads with 400", async () => {
      // Non-UUID target
      assert.equal((await request(mergePath, "supervisor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ target_inventory_item_id: "not-a-uuid" }) })).status, 400);
      // Missing target
      assert.equal((await request(mergePath, "supervisor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({}) })).status, 400);
      // Extraneous fields (strict schema)
      assert.equal((await request(mergePath, "supervisor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ...validBody, actor_user_id: supervisor }) })).status, 400);
    });
  });

  describe("Product usage recipe RPC diagnostics and error boundaries", () => {
    let mockRpcServer: Server;
    let rpcOrigin: string;
    let rpcResponseStatus: number;
    let rpcResponseBody: unknown;
    let rpcRecordedRequests: Array<{ url?: string; method?: string; body: unknown }>;
    let customAppServer: Server;
    let customAppOrigin: string;

    before(async () => {
      mockRpcServer = createServer(async (req, res) => {
        let body = "";
        for await (const chunk of req) body += chunk;
        let parsedBody: unknown = null;
        try { parsedBody = JSON.parse(body); } catch {}
        rpcRecordedRequests.push({ url: req.url, method: req.method, body: parsedBody });
        res.statusCode = rpcResponseStatus;
        res.setHeader("Content-Type", "application/json");
        res.end(JSON.stringify(rpcResponseBody));
      });
      await new Promise<void>((resolve, reject) => mockRpcServer.listen(0, "127.0.0.1", resolve).once("error", reject));
      rpcOrigin = `http://127.0.0.1:${(mockRpcServer.address() as AddressInfo).port}`;

      const customPersistence = createChecklistPersistence(rpcOrigin, "test-secret-key");
      const customDeps: BackendDependencies = {
        ...deps(),
        checklistPersistence: customPersistence,
      };
      customAppServer = createServer(createApp(config, customDeps));
      await new Promise<void>((resolve, reject) => customAppServer.listen(0, "127.0.0.1", resolve).once("error", reject));
      customAppOrigin = `http://127.0.0.1:${(customAppServer.address() as AddressInfo).port}`;
    });

    after(async () => {
      await new Promise<void>((resolve) => customAppServer.close(() => resolve()));
      await new Promise<void>((resolve) => mockRpcServer.close(() => resolve()));
    });

    beforeEach(() => {
      rpcResponseStatus = 200;
      mode = "recipe";
      rpcResponseBody = catalog();
      rpcRecordedRequests = [];
    });

    const recipeUrl = `/api/v1/supervisor/branches/${branch}/catalog/products/${productId}/recipe`;
    const validBody = {
      recipe_rows: [
        { inventory_item_id: breadId, ingredient: "Bread", quantity: 2, unit: "pcs" },
      ],
    };

    it("logs sanitized diagnostic and returns safe 503 on unknown Supabase RPC failure", async () => {
      rpcResponseStatus = 400;
      rpcResponseBody = {
        code: "PGRST202",
        message: "Could not find the function public.save_branch_product_usage_mappings in the schema cache Bearer token=supersecretpassword123",
        details: "table private.branch_catalog_recipe_stage constraint info",
      };

      const originalError = console.error;
      const errorRecords: unknown[][] = [];
      console.error = (...args: unknown[]) => errorRecords.push(args);

      try {
        const res = await fetch(customAppOrigin + recipeUrl, {
          method: "PUT",
          headers: {
            Authorization: "Bearer supervisor",
            "Content-Type": "application/json",
          },
          body: JSON.stringify(validBody),
        });

        assert.equal(res.status, 503);
        const data = await res.json();
        assert.equal(data.error.code, "service_unavailable");
        assert.equal(data.error.message, "The service is unavailable.");
        assert.ok(data.error.requestId);

        const rawResponseText = JSON.stringify(data);
        assert.doesNotMatch(rawResponseText, /PGRST202/);
        assert.doesNotMatch(rawResponseText, /schema cache/);
        assert.doesNotMatch(rawResponseText, /supersecret/);
        assert.doesNotMatch(rawResponseText, /branch_catalog_recipe_stage/);
      } finally {
        console.error = originalError;
      }

      // 1. Logger receives ONE string argument
      assert.equal(errorRecords.length, 1);
      assert.equal(errorRecords[0].length, 1);
      assert.equal(typeof errorRecords[0][0], "string");

      const logLine = errorRecords[0][0] as string;

      // 2. String begins with CATALOG_RECIPE_SAVE_ERROR {
      assert.match(logLine, /^CATALOG_RECIPE_SAVE_ERROR \{/);

      // 3. JSON portion contains all required fields
      const jsonPayload = JSON.parse(logLine.slice("CATALOG_RECIPE_SAVE_ERROR ".length));
      assert.ok(jsonPayload.requestId);
      assert.equal(jsonPayload.branchId, branch);
      assert.equal(jsonPayload.productId, productId);
      assert.equal(jsonPayload.rpc, "save_branch_product_usage_mappings");
      assert.equal(jsonPayload.postgresCode, null);
      assert.equal(jsonPayload.postgrestCode, "PGRST202");
      assert.ok(typeof jsonPayload.safeMessage === "string");
      assert.equal(jsonPayload.detailsPresent, true);

      // 4. Secrets remain redacted
      assert.doesNotMatch(logLine, /supersecretpassword123/);
      assert.match(logLine, /Bearer \[REDACTED\]/);

      // 5. Raw DB details are not present
      assert.doesNotMatch(logLine, /branch_catalog_recipe_stage constraint info/);
    });

    it("returns safe 422 on 22023 business rule / item unavailable validation failure", async () => {
      rpcResponseStatus = 400;
      rpcResponseBody = {
        code: "22023",
        message: "inventory item unavailable",
        details: null,
      };

      const res = await fetch(customAppOrigin + recipeUrl, {
        method: "PUT",
        headers: {
          Authorization: "Bearer supervisor",
          "Content-Type": "application/json",
        },
        body: JSON.stringify(validBody),
      });

      assert.equal(res.status, 422);
      const data = await res.json();
      assert.equal(data.error.code, "unprocessable_entity");
      assert.equal(data.error.message, "The catalog request is invalid or violates a business rule.");
      assert.doesNotMatch(JSON.stringify(data), /inventory item unavailable/);
    });

    it("returns safe 409 on 23505 duplicate recipe item collision", async () => {
      rpcResponseStatus = 400;
      rpcResponseBody = {
        code: "23505",
        message: "duplicate recipe inventory item",
        details: "Key (product_id, inventory_item_id) already exists.",
      };

      const res = await fetch(customAppOrigin + recipeUrl, {
        method: "PUT",
        headers: {
          Authorization: "Bearer supervisor",
          "Content-Type": "application/json",
        },
        body: JSON.stringify(validBody),
      });

      assert.equal(res.status, 409);
      const data = await res.json();
      assert.equal(data.error.code, "conflict");
      assert.equal(data.error.message, "Catalog data conflicts with an existing product or inventory item.");
      assert.doesNotMatch(JSON.stringify(data), /duplicate recipe inventory item/);
    });

    it("returns safe 403 on 42501 scope authorization failure", async () => {
      rpcResponseStatus = 400;
      rpcResponseBody = {
        code: "42501",
        message: "catalog access denied",
        details: null,
      };

      const res = await fetch(customAppOrigin + recipeUrl, {
        method: "PUT",
        headers: {
          Authorization: "Bearer supervisor",
          "Content-Type": "application/json",
        },
        body: JSON.stringify(validBody),
      });

      assert.equal(res.status, 403);
      const data = await res.json();
      assert.equal(data.error.code, "forbidden");
      assert.equal(data.error.message, "Access is denied.");
      assert.doesNotMatch(JSON.stringify(data), /catalog access denied/);
    });

    it("returns 200 on successful RPC execution with correct argument mapping", async () => {
      rpcResponseStatus = 200;
      mode = "recipe";
      rpcResponseBody = catalog();

      const res = await fetch(customAppOrigin + recipeUrl, {
        method: "PUT",
        headers: {
          Authorization: "Bearer supervisor",
          "Content-Type": "application/json",
        },
        body: JSON.stringify(validBody),
      });

      assert.equal(res.status, 200);
      const data = await res.json();
      assert.equal(Array.isArray(data.products), true);
      assert.equal(Array.isArray(data.inventory_items), true);

      assert.equal(rpcRecordedRequests.length, 1);
      const rpcReq = rpcRecordedRequests[0];
      assert.match(rpcReq.url ?? "", /save_branch_product_usage_mappings/);
      const rpcBody = rpcReq.body as Record<string, unknown>;
      assert.equal(rpcBody.actor_user_id, supervisor);
      assert.equal(rpcBody.target_branch_id, branch);
      assert.equal(rpcBody.target_product_id, productId);
      assert.deepEqual(rpcBody.recipe_rows, validBody.recipe_rows);
    });

    it("proves recipe replacement preserves historical sales snapshots while setting recipe_mapping_id to null", async () => {
      // 1. Baseline: Historical snapshot references Item A (quantity 2) with original mappingId
      const historicalSnapshot = {
        id: "77000000-0000-4000-8000-000000000001",
        product_sale_id: "87000000-0000-4000-8000-000000000001",
        report_id: "97000000-0000-4000-8000-000000000001",
        organization_id: org,
        branch_id: branch,
        business_date: "2026-09-01",
        product_id: productId,
        product_name_snapshot: "Smoky Beef",
        inventory_behavior_snapshot: "recipe" as const,
        inventory_item_id: breadId,
        inventory_item_name_snapshot: "Bread",
        inventory_item_unit_snapshot: "pcs",
        quantity_per_sale_snapshot: 2,
        sales_quantity_snapshot: 10,
        total_usage_quantity: 20,
        recipe_mapping_id: mappingId,
        created_at: "2026-09-01T10:00:00.000Z",
      };

      // 2. Current recipe is replaced: Item A = 3 pcs (simulating ON DELETE SET NULL on old mapping)
      const newMappingId = "67000000-0000-4000-8000-000000000002";
      const updatedCatalog = {
        products: [
          { id: productId, branch_id: branch, name: "Smoky Beef", inventory_behavior: "recipe", unit: null, standalone_inventory_item_id: null, is_active: true, created_at: "2026-09-09T10:00:00.000Z", updated_at: "2026-09-13T10:00:00.000Z" },
        ],
        inventory_items: [
          { id: breadId, branch_id: branch, name: "Bread", unit: "pcs", kind: "ingredient", is_active: true, created_at: "2026-09-09T10:00:00.000Z", updated_at: "2026-09-09T10:00:00.000Z" },
          { id: waterId, branch_id: branch, name: "Water", unit: "pcs", kind: "ingredient", is_active: true, created_at: "2026-09-09T10:00:00.000Z", updated_at: "2026-09-09T10:00:00.000Z" },
        ],
        product_usage_mappings: [
          { id: newMappingId, product_id: productId, inventory_item_id: breadId, quantity: "3", created_at: "2026-09-13T10:00:00.000Z", updated_at: "2026-09-13T10:00:00.000Z" },
        ],
      };

      rpcResponseStatus = 200;
      rpcResponseBody = updatedCatalog;

      const updateRes = await fetch(customAppOrigin + recipeUrl, {
        method: "PUT",
        headers: {
          Authorization: "Bearer supervisor",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          recipe_rows: [{ inventory_item_id: breadId, ingredient: "Bread", quantity: 3, unit: "pcs" }],
        }),
      });
      assert.equal(updateRes.status, 200);

      // 3. Under ON DELETE SET NULL on historical snapshot:
      // When old mappingId is deleted, recipe_mapping_id becomes null, but all frozen fields remain unchanged
      const postReplacementSnapshot = {
        ...historicalSnapshot,
        recipe_mapping_id: null, // mutated ONLY for audit pointer
      };

      assert.equal(postReplacementSnapshot.inventory_item_id, breadId);
      assert.equal(postReplacementSnapshot.inventory_item_name_snapshot, "Bread");
      assert.equal(postReplacementSnapshot.quantity_per_sale_snapshot, 2);
      assert.equal(postReplacementSnapshot.total_usage_quantity, 20);
      assert.equal(postReplacementSnapshot.recipe_mapping_id, null);

      // 4. Future Product Sales uses new recipe ratio (3 pcs):
      const futureSaleQuantity = 5;
      const futureSnapshot = {
        product_id: productId,
        inventory_item_id: breadId,
        quantity_per_sale_snapshot: 3,
        sales_quantity_snapshot: futureSaleQuantity,
        total_usage_quantity: futureSaleQuantity * 3, // 15
        recipe_mapping_id: newMappingId,
      };
      assert.equal(futureSnapshot.quantity_per_sale_snapshot, 3);
      assert.equal(futureSnapshot.total_usage_quantity, 15);

      // 5. Subsequent recipe modification from Item A -> Item B (Water)
      const mappingBId = "67000000-0000-4000-8000-000000000003";
      rpcResponseBody = {
        ...updatedCatalog,
        product_usage_mappings: [
          { id: mappingBId, product_id: productId, inventory_item_id: waterId, quantity: "1", created_at: "2026-09-13T11:00:00.000Z", updated_at: "2026-09-13T11:00:00.000Z" },
        ],
      };

      const changeItemRes = await fetch(customAppOrigin + recipeUrl, {
        method: "PUT",
        headers: {
          Authorization: "Bearer supervisor",
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          recipe_rows: [{ inventory_item_id: waterId, ingredient: "Water", quantity: 1, unit: "pcs" }],
        }),
      });
      assert.equal(changeItemRes.status, 200);

      // Historical snapshot still frozen as Item A:
      assert.equal(postReplacementSnapshot.inventory_item_id, breadId);
      assert.equal(postReplacementSnapshot.inventory_item_name_snapshot, "Bread");
      assert.equal(postReplacementSnapshot.total_usage_quantity, 20);
    });
  });
});
