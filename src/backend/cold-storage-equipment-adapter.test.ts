import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { after, before, beforeEach, describe, it } from "node:test";
import { createOperationalAdmin } from "./operational";

const ids = {
  actor: "da100000-0000-4000-8000-000000000001",
  organization: "da200000-0000-4000-8000-000000000001",
  branch: "da300000-0000-4000-8000-000000000001",
  equipment: "da400000-0000-4000-8000-000000000001",
};

type CapturedRequest = { path: string; body: Record<string, unknown> };

describe("Cold Storage equipment master operational adapter", () => {
  let server: Server;
  let origin = "";
  let malformed = false;
  const requests: CapturedRequest[] = [];

  before(async () => {
    server = createServer(async (request, response) => {
      const chunks: Buffer[] = [];
      for await (const chunk of request) chunks.push(Buffer.from(chunk));
      const body = JSON.parse(Buffer.concat(chunks).toString("utf8")) as Record<string, unknown>;
      const path = request.url ?? "";
      requests.push({ path, body });

      const isCreate = path.endsWith("/create_supervisor_cold_storage_equipment");
      const isRename = path.endsWith("/rename_supervisor_cold_storage_equipment");
      const name = isCreate
        ? String(body.equipment_name)
        : isRename
          ? String(body.equipment_name)
          : "Walk-in Freezer";
      const row = {
        id: ids.equipment,
        branch_id: ids.branch,
        name: malformed ? "" : name,
        equipment_type: "freezer",
        active: true,
        updated_at: "2026-08-11T12:00:00.000Z",
        organization_id: ids.organization,
        created_by: ids.actor,
        updated_by: isRename ? ids.actor : null,
        created_at: "2026-08-11T10:00:00.000Z",
      };
      response.statusCode = 200;
      response.setHeader("content-type", "application/json");
      response.end(JSON.stringify([row]));
    });
    await new Promise<void>((resolve, reject) => server.listen(0, "127.0.0.1", resolve).once("error", reject));
    origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });

  after(() => new Promise<void>((resolve, reject) => server.close((error) => error ? reject(error) : resolve())));
  beforeEach(() => {
    malformed = false;
    requests.length = 0;
  });

  it("parses list rows and strips organization and actor metadata", async () => {
    const admin = createOperationalAdmin(origin, "service-key");
    assert.ok(admin.listSupervisorColdStorageEquipment);
    const result = await admin.listSupervisorColdStorageEquipment(ids.actor, ids.branch);
    assert.deepEqual(result, {
      equipment: [{
        id: ids.equipment,
        branch_id: ids.branch,
        name: "Walk-in Freezer",
        equipment_type: "freezer",
        active: true,
        updated_at: "2026-08-11T12:00:00.000Z",
      }],
    });
    assert.deepEqual(requests[0], {
      path: "/rest/v1/rpc/list_supervisor_cold_storage_equipment",
      body: { actor_user_id: ids.actor, target_branch_id: ids.branch },
    });
  });

  it("calls create without browser authority for organization or creator metadata", async () => {
    const admin = createOperationalAdmin(origin, "service-key");
    assert.ok(admin.createSupervisorColdStorageEquipment);
    const result = await admin.createSupervisorColdStorageEquipment({
      actorUserId: ids.actor,
      branchId: ids.branch,
      name: "Walk-in Freezer",
      equipmentType: "freezer",
    });
    assert.equal((result as { equipment: { name: string } }).equipment.name, "Walk-in Freezer");
    assert.deepEqual(requests[0], {
      path: "/rest/v1/rpc/create_supervisor_cold_storage_equipment",
      body: {
        actor_user_id: ids.actor,
        target_branch_id: ids.branch,
        equipment_name: "Walk-in Freezer",
        equipment_type: "freezer",
      },
    });
    assert.doesNotMatch(JSON.stringify(result), /organization_id|created_by|updated_by/);
  });

  it("calls rename with only verified actor/branch scope, equipment id, and name", async () => {
    const admin = createOperationalAdmin(origin, "service-key");
    assert.ok(admin.renameSupervisorColdStorageEquipment);
    const result = await admin.renameSupervisorColdStorageEquipment({
      actorUserId: ids.actor,
      branchId: ids.branch,
      equipmentId: ids.equipment,
      name: "Main Walk-in Freezer",
    });
    assert.equal((result as { equipment: { name: string } }).equipment.name, "Main Walk-in Freezer");
    assert.deepEqual(requests[0], {
      path: "/rest/v1/rpc/rename_supervisor_cold_storage_equipment",
      body: {
        actor_user_id: ids.actor,
        target_branch_id: ids.branch,
        target_equipment_id: ids.equipment,
        equipment_name: "Main Walk-in Freezer",
      },
    });
  });

  it("rejects a malformed RPC equipment row", async () => {
    malformed = true;
    const admin = createOperationalAdmin(origin, "service-key");
    await assert.rejects(() => admin.listSupervisorColdStorageEquipment!(ids.actor, ids.branch));
  });
});
