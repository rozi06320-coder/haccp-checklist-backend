import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, describe, it } from "node:test";
import { createApp } from "./app";
import { ChecklistAccessError, ChecklistConflictError, ChecklistInputError } from "./checklist-persistence";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const supervisor = "17000000-0000-4000-8000-000000000001";
const manager = "17000000-0000-4000-8000-000000000002";
const other = "17000000-0000-4000-8000-000000000003";
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
    authVerifier: { verify: async (token) => token === "supervisor" ? { userId: supervisor, email: "s@example.invalid" } : token === "manager" ? { userId: manager, email: "m@example.invalid" } : token === "other" ? { userId: other, email: "o@example.invalid" } : null },
    createUserContext: (token) => ({
      getUserContext: async () => token === "supervisor"
        ? { id: supervisor, full_name: "Supervisor", must_change_password: false, disabled: false, branches: [{ id: branch, name: "Branch", organization_id: org, role: "branch_manager" }], managed_organizations: [] }
        : token === "manager"
          ? { id: manager, full_name: "Manager", must_change_password: false, disabled: false, branches: [], managed_organizations: [{ id: org, name: "Org", role: "organization_manager" }] }
          : { id: other, full_name: "Other", must_change_password: false, disabled: false, branches: [], managed_organizations: [] },
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
    assert.deepEqual(calls.at(-1), { name: "save-recipe", input: { actorUserId: supervisor, branchId: branch, productId, recipeRows: [{ ingredient: "Bread", quantity: 2, unit: "pcs" }] } });
    assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/products/${productId}/recipe`, "supervisor", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ recipe_rows: [{ ingredient: "Bread", quantity: 0, unit: "pcs" }] }) })).status, 400);
    mode = "invalid";
    const invalid = await request(`/api/v1/supervisor/branches/${branch}/catalog/products/${productId}/recipe`, "supervisor", { method: "PUT", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ recipe_rows: [{ ingredient: "Bread", quantity: 1, unit: "pcs" }] }) });
    assert.equal(invalid.status, 422);
  });

  it("does not accept cross-branch, manager, or arbitrary client-scoped mutation", async () => {
    assert.equal((await request(`/api/v1/supervisor/branches/${otherBranch}/catalog`, "supervisor")).status, 403);
    assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/products`, "manager", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name: "X", inventory_behavior: "non_stock" }) })).status, 403);
    assert.equal((await request(`/api/v1/supervisor/branches/${branch}/catalog/products`, "supervisor", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ name: "X", inventory_behavior: "non_stock", organization_id: org }) })).status, 400);
  });
});
