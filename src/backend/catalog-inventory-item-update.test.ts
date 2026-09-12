import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, describe, it } from "node:test";
import { createPinCrypto } from "./admin";
import { createApp } from "./app";
import {
  ChecklistAccessError,
  ChecklistConflictError,
  ChecklistInputError,
  ChecklistNotFoundError,
} from "./checklist-persistence";
import type { BackendConfig } from "./config";
import type { BackendDependencies } from "./dependencies";

const supervisor = "17000000-0000-4000-8000-000000000001";
const manager = "17000000-0000-4000-8000-000000000002";
const otherSupervisor = "17000000-0000-4000-8000-000000000003";
const branch = "27000000-0000-4000-8000-000000000001";
const otherBranch = "27000000-0000-4000-8000-000000000002";
const org = "37000000-0000-4000-8000-000000000001";

const activeBreadId = "57000000-0000-4000-8000-000000000001";
const inactiveCheeseId = "57000000-0000-4000-8000-000000000002";
const activeTomatoId = "57000000-0000-4000-8000-000000000003";

type CatalogItemRow = {
  id: string;
  branch_id: string;
  name: string;
  unit: "pcs" | "kg" | "g" | "L" | "ml";
  kind: "ingredient" | "standalone_stock";
  is_active: boolean;
  created_at: string;
  updated_at: string;
};

let inventoryStore: CatalogItemRow[] = [];
const persistenceCalls: Array<{ name: string; input: unknown }> = [];
let forcePersistenceError: "conflict" | "input" | "not_found" | "access" | "raw_sql" | null = null;
let nextCreatedItemId = 100;

function resetStore() {
  persistenceCalls.length = 0;
  forcePersistenceError = null;
  nextCreatedItemId = 100;
  inventoryStore = [
    {
      id: activeBreadId,
      branch_id: branch,
      name: "Bread",
      unit: "pcs",
      kind: "ingredient",
      is_active: true,
      created_at: "2026-09-09T10:00:00.000Z",
      updated_at: "2026-09-09T10:00:00.000Z",
    },
    {
      id: inactiveCheeseId,
      branch_id: branch,
      name: "Sliced Cheese",
      unit: "pcs",
      kind: "ingredient",
      is_active: false,
      created_at: "2026-09-09T10:00:00.000Z",
      updated_at: "2026-09-09T10:00:00.000Z",
    },
    {
      id: activeTomatoId,
      branch_id: branch,
      name: "Fresh Tomato",
      unit: "kg",
      kind: "ingredient",
      is_active: true,
      created_at: "2026-09-09T10:00:00.000Z",
      updated_at: "2026-09-09T10:00:00.000Z",
    },
  ];
}

const mockPersistence = {
  async listBranchCatalog(actorUserId: string, branchId: string) {
    if (branchId !== branch) throw new ChecklistAccessError();
    return { products: [], inventory_items: inventoryStore, product_usage_mappings: [] };
  },
  async createBranchCatalogInventoryItem(input: {
    actorUserId: string;
    branchId: string;
    payload: { name: string; unit: "pcs" | "kg" | "g" | "L" | "ml" };
  }) {
    persistenceCalls.push({ name: "createBranchCatalogInventoryItem", input });
    if (input.branchId !== branch) throw new ChecklistAccessError();

    const normalizedName = input.payload.name.trim().replace(/\s+/g, " ").toLowerCase();
    const existing = inventoryStore.find(
      (i) => i.branch_id === input.branchId && i.name.trim().replace(/\s+/g, " ").toLowerCase() === normalizedName,
    );
    if (existing) {
      throw new ChecklistConflictError("23505");
    }

    const newItem: CatalogItemRow = {
      id: `57000000-0000-4000-8000-${String(nextCreatedItemId++).padStart(12, "0")}`,
      branch_id: input.branchId,
      name: input.payload.name.trim().replace(/\s+/g, " "),
      unit: input.payload.unit,
      kind: "ingredient",
      is_active: true,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    };
    inventoryStore.push(newItem);
    return { products: [], inventory_items: [...inventoryStore], product_usage_mappings: [] };
  },
  async updateBranchCatalogInventoryItem(input: {
    actorUserId: string;
    branchId: string;
    inventoryItemId: string;
    payload: { name: string; unit: "pcs" | "kg" | "g" | "L" | "ml"; is_active?: boolean };
  }) {
    persistenceCalls.push({ name: "updateBranchCatalogInventoryItem", input });

    if (forcePersistenceError === "conflict") throw new ChecklistConflictError("23505");
    if (forcePersistenceError === "input") throw new ChecklistInputError();
    if (forcePersistenceError === "not_found") throw new ChecklistNotFoundError();
    if (forcePersistenceError === "access") throw new ChecklistAccessError();
    if (forcePersistenceError === "raw_sql") throw new Error("pg_catalog.relation 42P01 syntax error leaked internals");

    if (input.branchId !== branch) throw new ChecklistAccessError();

    const target = inventoryStore.find((i) => i.id === input.inventoryItemId && i.branch_id === input.branchId);
    if (!target) {
      throw new ChecklistNotFoundError();
    }

    const nextIsActive = input.payload.is_active !== undefined ? input.payload.is_active : target.is_active;
    const normalizedName = input.payload.name.trim().replace(/\s+/g, " ").toLowerCase();

    if (nextIsActive) {
      const conflict = inventoryStore.find(
        (i) =>
          i.branch_id === input.branchId &&
          i.id !== target.id &&
          i.is_active &&
          i.name.trim().replace(/\s+/g, " ").toLowerCase() === normalizedName,
      );
      if (conflict) {
        throw new ChecklistConflictError("23505");
      }
    }

    target.name = input.payload.name.trim().replace(/\s+/g, " ");
    target.unit = input.payload.unit;
    target.is_active = nextIsActive;
    target.updated_at = new Date().toISOString();

    return {
      products: [],
      inventory_items: [...inventoryStore],
      product_usage_mappings: [],
    };
  },
  async getOverview() { throw new Error("unused"); },
  async getCurrentState() { throw new Error("unused"); },
  async saveDraft() { throw new Error("unused"); },
  async saveHygieneDraft() { throw new Error("unused"); },
  async submitOpening() { throw new Error("unused"); },
  async submitHygiene() { throw new Error("unused"); },
  async listSupervisor() { throw new Error("unused"); },
  async getReport() { throw new ChecklistAccessError(); },
  async listManagedReports() { return { reports: [], page: 1, page_size: 20, total: 0 }; },
  async listManagedIssues() { return { issues: [], page: 1, page_size: 20, total: 0 }; },
  async getManagedIssue() { throw new Error("unused"); },
} as unknown as BackendDependencies["checklistPersistence"];

function createTestDependencies(): BackendDependencies {
  return {
    checkReadiness: async () => true,
    checklistPersistence: mockPersistence,
    passwordChange: { verifyCurrent: async () => true, updatePassword: async () => {}, finalize: async () => {} },
    provisioningAdmin: { createUser: async () => ({ id: supervisor }), deleteUser: async () => {}, finalize: async () => {} },
    managementAdmin: { listUsers: async () => ({ users: [], total: 0 }) },
    branchManagementAdmin: { listBranches: async () => [], listStaff: async () => [], getPinMetadata: async () => ({ configured: false, updated_at: null, updated_by_name: null }), storePin: async () => ({ configured: false, updated_at: null, updated_by_name: null }), getPinCredential: async () => null },
    pinCrypto: createPinCrypto(testConfig.dailyAuditGrantSecret),
    authVerifier: {
      verify: async (token) => {
        if (token === "supervisor") return { userId: supervisor, email: "s@example.invalid" };
        if (token === "manager") return { userId: manager, email: "m@example.invalid" };
        if (token === "other_supervisor") return { userId: otherSupervisor, email: "os@example.invalid" };
        return null;
      },
    },
    createUserContext: (token) => ({
      getUserContext: async () => {
        if (token === "supervisor") {
          return {
            id: supervisor,
            full_name: "Supervisor User",
            must_change_password: false,
            disabled: false,
            branches: [{ id: branch, name: "Downtown Branch", organization_id: org, role: "branch_manager" }],
            managed_organizations: [],
          };
        }
        if (token === "manager") {
          return {
            id: manager,
            full_name: "Org Manager User",
            must_change_password: false,
            disabled: false,
            branches: [],
            managed_organizations: [{ id: org, name: "Food Corp", role: "organization_manager" }],
          };
        }
        if (token === "other_supervisor") {
          return {
            id: otherSupervisor,
            full_name: "Other Supervisor User",
            must_change_password: false,
            disabled: false,
            branches: [{ id: otherBranch, name: "Uptown Branch", organization_id: org, role: "branch_manager" }],
            managed_organizations: [],
          };
        }
        return {
          id: "anonymous",
          full_name: "Anonymous",
          must_change_password: false,
          disabled: false,
          branches: [],
          managed_organizations: [],
        };
      },
      isInternalAdmin: async () => false,
      hasOrganizationManagerAccess: async () => false,
      validateActiveBranches: async () => false,
      listActiveBranches: async () => [],
    }),
  };
}

const testConfig: BackendConfig = {
  nodeEnv: "test",
  host: "127.0.0.1",
  port: 1,
  trustProxy: false,
  supabase: { url: "http://127.0.0.1", publishableKey: "test", secretKey: "test" },
  dailyAuditGrantSecret: "test-placeholder-long-enough-for-tests-secret-32b",
};

let server: Server;
let origin: string;

async function apiRequest(path: string, token?: string, init: RequestInit = {}) {
  return fetch(origin + path, {
    ...init,
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : { "x-no-auth": "1" }),
      ...(init.headers ?? {}),
    },
  });
}

describe("Catalog inventory item update / reactivation backend contract", () => {
  before(async () => {
    server = createServer(createApp(testConfig, createTestDependencies()));
    await new Promise<void>((resolve, reject) => server.listen(0, "127.0.0.1", resolve).once("error", reject));
    origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });

  after(() => new Promise<void>((resolve) => server.close(() => resolve())));
  beforeEach(() => { resetStore(); });

  it("1. inactive item reactivates with same UUID", async () => {
    const response = await apiRequest(
      `/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${inactiveCheeseId}`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "Sliced Cheese", unit: "pcs", is_active: true }),
      },
    );
    assert.equal(response.status, 200);
    const data = await response.json();
    const updated = data.inventory_items.find((i: { id: string }) => i.id === inactiveCheeseId);
    assert.ok(updated, "Item must exist in returned catalog");
    assert.equal(updated.id, inactiveCheeseId, "Must preserve the exact same canonical UUID");
    assert.equal(updated.is_active, true, "Must become active");
  });

  it("2. is_active false -> true persists in catalog state", async () => {
    assert.equal(inventoryStore.find((i) => i.id === inactiveCheeseId)?.is_active, false);
    const response = await apiRequest(
      `/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${inactiveCheeseId}`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "Sliced Cheese", unit: "pcs", is_active: true }),
      },
    );
    assert.equal(response.status, 200);
    assert.equal(inventoryStore.find((i) => i.id === inactiveCheeseId)?.is_active, true);
  });

  it("3. name/unit update persists", async () => {
    const response = await apiRequest(
      `/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${activeBreadId}`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "Brioche Bun", unit: "kg" }),
      },
    );
    assert.equal(response.status, 200);
    const stored = inventoryStore.find((i) => i.id === activeBreadId);
    assert.equal(stored?.name, "Brioche Bun");
    assert.equal(stored?.unit, "kg");
  });

  it("4. actor comes from auth context, not client body", async () => {
    await apiRequest(
      `/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${activeBreadId}`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "Bread", unit: "pcs" }),
      },
    );
    const lastCall = persistenceCalls.at(-1);
    assert.equal(lastCall?.name, "updateBranchCatalogInventoryItem");
    assert.equal((lastCall?.input as { actorUserId: string }).actorUserId, supervisor);
  });

  it("5. arbitrary actor_user_id body rejected with 400", async () => {
    const response = await apiRequest(
      `/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${activeBreadId}`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name: "Bread",
          unit: "pcs",
          actor_user_id: "99999999-9999-4999-8999-999999999999",
        }),
      },
    );
    assert.equal(response.status, 400);
    assert.equal(persistenceCalls.length, 0, "Must not invoke persistence when client sends extra body fields");
  });

  it("6. wrong branch rejected with 403", async () => {
    const response = await apiRequest(
      `/api/v1/supervisor/branches/${otherBranch}/catalog/inventory-items/${activeBreadId}`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "Bread", unit: "pcs", is_active: true }),
      },
    );
    assert.equal(response.status, 403);
  });

  it("7. malformed UUID rejected with 400", async () => {
    const invalidBranch = await apiRequest(
      `/api/v1/supervisor/branches/not-a-uuid/catalog/inventory-items/${activeBreadId}`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "Bread", unit: "pcs" }),
      },
    );
    assert.equal(invalidBranch.status, 400);

    const invalidItem = await apiRequest(
      `/api/v1/supervisor/branches/${branch}/catalog/inventory-items/not-a-uuid`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "Bread", unit: "pcs" }),
      },
    );
    assert.equal(invalidItem.status, 400);
  });

  it("8. duplicate normalized active name -> 409", async () => {
    // Attempting to reactivate inactiveCheeseId with the name "Bread" (which activeBreadId already has)
    const response = await apiRequest(
      `/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${inactiveCheeseId}`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "Bread", unit: "pcs", is_active: true }),
      },
    );
    assert.equal(response.status, 409);
    const body = await response.json();
    assert.equal(body.error.message, "Catalog data conflicts with an existing product or inventory item.");
  });

  it("9. case-insensitive duplicate -> 409", async () => {
    const response = await apiRequest(
      `/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${inactiveCheeseId}`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "bReAd", unit: "pcs", is_active: true }),
      },
    );
    assert.equal(response.status, 409);
  });

  it("10. repeated/trimmed whitespace duplicate -> 409", async () => {
    const response = await apiRequest(
      `/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${inactiveCheeseId}`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "   Bread   ", unit: "pcs", is_active: true }),
      },
    );
    assert.equal(response.status, 409);
  });

  it("11. failed conflict does not create new row and preserves existing rows unchanged", async () => {
    const countBefore = inventoryStore.length;
    const cheeseBefore = { ...inventoryStore.find((i) => i.id === inactiveCheeseId)! };

    const response = await apiRequest(
      `/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${inactiveCheeseId}`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "Bread", unit: "pcs", is_active: true }),
      },
    );
    assert.equal(response.status, 409);
    assert.equal(inventoryStore.length, countBefore, "Row count must remain unchanged");
    const cheeseAfter = inventoryStore.find((i) => i.id === inactiveCheeseId)!;
    assert.equal(cheeseAfter.name, cheeseBefore.name);
    assert.equal(cheeseAfter.is_active, cheeseBefore.is_active);
  });

  it("12. no hard-delete endpoint introduced (DELETE returns 404/405)", async () => {
    const response = await apiRequest(
      `/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${activeBreadId}`,
      "supervisor",
      { method: "DELETE" },
    );
    assert.ok(response.status === 404 || response.status === 405, `DELETE should not exist, got ${response.status}`);
  });

  it("13. raw DB error not leaked (returns generic 503 instead of internals)", async () => {
    forcePersistenceError = "raw_sql";
    const response = await apiRequest(
      `/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${activeBreadId}`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "Bread New", unit: "pcs" }),
      },
    );
    assert.equal(response.status, 503);
    const body = await response.json();
    assert.equal(body.error.message, "The service is unavailable.");
    assert.doesNotMatch(JSON.stringify(body), /pg_catalog|syntax error|relation/i);
  });

  it("14. response returns updated catalog with refreshed inventory_items", async () => {
    const response = await apiRequest(
      `/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${inactiveCheeseId}`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "Provolone", unit: "kg", is_active: true }),
      },
    );
    assert.equal(response.status, 200);
    const body = await response.json();
    assert.ok(Array.isArray(body.inventory_items));
    assert.ok(Array.isArray(body.products));
    assert.ok(Array.isArray(body.product_usage_mappings));
    const item = body.inventory_items.find((i: { id: string }) => i.id === inactiveCheeseId);
    assert.equal(item.name, "Provolone");
    assert.equal(item.unit, "kg");
    assert.equal(item.is_active, true);
  });

  it("15. frontend expected body {name, unit, is_active} is accepted", async () => {
    const response = await apiRequest(
      `/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${inactiveCheeseId}`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name: "Sliced Cheese",
          unit: "pcs",
          is_active: true,
        }),
      },
    );
    assert.equal(response.status, 200);
  });

  it("16. returns 404 when inventory item does not exist", async () => {
    const nonExistent = "57000000-0000-4000-8000-999999999999";
    const response = await apiRequest(
      `/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${nonExistent}`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "Ghost Item", unit: "pcs" }),
      },
    );
    assert.equal(response.status, 404);
    const body = await response.json();
    assert.equal(body.error.message, "The catalog resource was not found.");
  });

  it("17. old payload without is_active keeps active true", async () => {
    assert.equal(inventoryStore.find((i) => i.id === activeBreadId)?.is_active, true);
    const response = await apiRequest(
      `/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${activeBreadId}`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "Sourdough Bread", unit: "pcs" }),
      },
    );
    assert.equal(response.status, 200);
    const stored = inventoryStore.find((i) => i.id === activeBreadId);
    assert.equal(stored?.name, "Sourdough Bread");
    assert.equal(stored?.is_active, true, "Active item must remain active when is_active is omitted");
  });

  it("18. old payload without is_active keeps inactive false", async () => {
    assert.equal(inventoryStore.find((i) => i.id === inactiveCheeseId)?.is_active, false);
    const response = await apiRequest(
      `/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${inactiveCheeseId}`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "Aged Cheddar", unit: "pcs" }),
      },
    );
    assert.equal(response.status, 200);
    const stored = inventoryStore.find((i) => i.id === inactiveCheeseId);
    assert.equal(stored?.name, "Aged Cheddar");
    assert.equal(stored?.is_active, false, "Inactive item must remain inactive when is_active is omitted");
  });

  it("19. explicit false archives same UUID", async () => {
    assert.equal(inventoryStore.find((i) => i.id === activeTomatoId)?.is_active, true);
    const response = await apiRequest(
      `/api/v1/supervisor/branches/${branch}/catalog/inventory-items/${activeTomatoId}`,
      "supervisor",
      {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "Fresh Tomato", unit: "kg", is_active: false }),
      },
    );
    assert.equal(response.status, 200);
    const stored = inventoryStore.find((i) => i.id === activeTomatoId);
    assert.equal(stored?.id, activeTomatoId, "Must preserve the exact same canonical UUID");
    assert.equal(stored?.is_active, false, "Must become inactive");
  });

  it("20. create against active normalized match conflicts (409)", async () => {
    const response = await apiRequest(
      `/api/v1/supervisor/branches/${branch}/catalog/inventory-items`,
      "supervisor",
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "Bread", unit: "pcs" }),
      },
    );
    assert.equal(response.status, 409);
  });

  it("21. create against inactive normalized match conflicts and does not create second UUID", async () => {
    const countBefore = inventoryStore.length;
    const response = await apiRequest(
      `/api/v1/supervisor/branches/${branch}/catalog/inventory-items`,
      "supervisor",
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "Sliced Cheese", unit: "pcs" }),
      },
    );
    assert.equal(response.status, 409);
    assert.equal(inventoryStore.length, countBefore, "Must not create a new UUID for an archived item");
  });

  it("22. case-insensitive archived collision on create rejected with 409", async () => {
    const response = await apiRequest(
      `/api/v1/supervisor/branches/${branch}/catalog/inventory-items`,
      "supervisor",
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "sLiCeD cHeEsE", unit: "pcs" }),
      },
    );
    assert.equal(response.status, 409);
  });

  it("23. whitespace-normalized archived collision on create rejected with 409", async () => {
    const response = await apiRequest(
      `/api/v1/supervisor/branches/${branch}/catalog/inventory-items`,
      "supervisor",
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "   Sliced    Cheese   ", unit: "pcs" }),
      },
    );
    assert.equal(response.status, 409);
  });

  it("24. normal unique create still works with 201 and new canonical item", async () => {
    const countBefore = inventoryStore.length;
    const response = await apiRequest(
      `/api/v1/supervisor/branches/${branch}/catalog/inventory-items`,
      "supervisor",
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "Black Pepper", unit: "g" }),
      },
    );
    assert.equal(response.status, 201);
    assert.equal(inventoryStore.length, countBefore + 1, "New unique item must be created");
    const created = inventoryStore.find((i) => i.name === "Black Pepper");
    assert.ok(created);
    assert.equal(created.unit, "g");
    assert.equal(created.is_active, true);
  });
});

describe("Catalog reactivation SQL migration boundary check", () => {
  const migrationUrl = new URL("../../supabase/migrations/20260913100000_catalog_inventory_item_update_reactivation.sql", import.meta.url);

  it("verifies the reactivation migration enforces security and canonical signatures", async () => {
    const sql = await readFile(migrationUrl, "utf8");

    // Check RPC definitions and signatures
    assert.match(sql, /create or replace function public\.update_branch_catalog_inventory_item\s*\(\s*actor_user_id uuid,\s*target_branch_id uuid,\s*target_inventory_item_id uuid,\s*payload jsonb\s*\)/);
    assert.match(sql, /create or replace function public\.create_branch_catalog_inventory_item\s*\(\s*actor_user_id uuid,\s*target_branch_id uuid,\s*payload jsonb\s*\)/);
    assert.match(sql, /returns jsonb/);
    assert.match(sql, /language plpgsql/);
    assert.match(sql, /security definer/);
    assert.match(sql, /set search_path = ''/);

    // Checks branch scope and authorization in both functions
    const scopeMatches = sql.match(/private\.require_branch_catalog_scope\(actor_user_id, target_branch_id\)/g);
    assert.equal(scopeMatches?.length, 2, "Both update and create must verify branch manager scope");

    // Validates allowed canonical units
    assert.match(sql, /clean_unit not in \('pcs','kg','g','L','ml'\)/);

    // Update allows reactivation without restricting target_item to is_active
    assert.match(sql, /select item\.\* into target_item\s*from public\.branch_inventory_catalog_items item\s*where item\.id = target_inventory_item_id and item\.branch_id = target_branch\.id;/);

    // Update preserves existing is_active when is_active is omitted from payload
    assert.match(sql, /else\s+new_is_active := target_item\.is_active;\s+end if;/);

    // Update enforces normalized conflict check when item is or will be active
    assert.match(sql, /if new_is_active then/);
    assert.match(sql, /pg_catalog\.lower\(pg_catalog\.regexp_replace\(pg_catalog\.btrim\(item\.name\), '\[\[:space:\]\]\+', ' ', 'g'\)\) = pg_catalog\.lower\(clean_name\)/);

    // Create checks both active and archived duplicate names across branch
    assert.match(sql, /select item\.\* into existing_item\s*from public\.branch_inventory_catalog_items item\s*where item\.branch_id = target_branch\.id/);
    assert.match(sql, /if existing_item\.is_active then\s+raise exception 'inventory item already exists' using errcode = '23505';\s+else\s+raise exception 'archived inventory item already exists' using errcode = '23505';\s+end if;/);

    // Updates name, unit, and is_active on target_item.id
    assert.match(sql, /update public\.branch_inventory_catalog_items item\s*set name = clean_name,\s*unit = clean_unit,\s*is_active = new_is_active\s*where item\.id = target_item\.id;/);

    // Returns full catalog payload
    assert.match(sql, /return private\.branch_catalog_payload\(target_branch\.id\);/);

    // Revokes and grants for both functions
    assert.match(sql, /revoke all on function public\.update_branch_catalog_inventory_item\(uuid, uuid, uuid, jsonb\) from public, anon, authenticated;/);
    assert.match(sql, /grant execute on function public\.update_branch_catalog_inventory_item\(uuid, uuid, uuid, jsonb\) to service_role;/);
    assert.match(sql, /revoke all on function public\.create_branch_catalog_inventory_item\(uuid, uuid, jsonb\) from public, anon, authenticated;/);
    assert.match(sql, /grant execute on function public\.create_branch_catalog_inventory_item\(uuid, uuid, jsonb\) to service_role;/);

    // Confirms no row mutation, schema destruction, or delete statements occur by applying migration
    assert.doesNotMatch(sql, /\bdelete\s+from\b/i);
    assert.doesNotMatch(sql, /\bdrop\s+table\b/i);
    assert.doesNotMatch(sql, /\balter\s+table\b/i);
    assert.doesNotMatch(sql, /\btruncate\b/i);
  });
});
