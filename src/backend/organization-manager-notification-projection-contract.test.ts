import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { loadBackendConfig } from "./config";
import { createOrganizationManagerNotificationService } from "./organization-manager-notifications";

const organizationId = "f3a00000-0000-4000-8000-000000000002";
const actorUserId = "f3a00000-0000-4000-8000-000000000001";
const notification = {
  id: "f3a00000-0000-4000-8000-000000000010",
  organization_id: organizationId,
  category: "maintenance_issue",
  branch_id: null,
  business_date: null,
  source_type: null,
  source_id: null,
  legacy_notification_id: "f3a00000-0000-4000-8000-000000000010",
  occurrence_key: "legacy:office:f3",
  category_context: { schema_version: "1", category: "maintenance_issue", scope: "office", legacy: true },
  read_at: null,
  created_at: "2026-10-31T00:00:00.000Z",
};

describe("Manager notification projection API contract", () => {
  it("parses the database projection shape and count", async () => {
    const config = loadBackendConfig({
      NODE_ENV: "test",
      SUPABASE_URL: "http://127.0.0.1:54321",
      SUPABASE_PUBLISHABLE_KEY: "test-publishable-placeholder",
      SUPABASE_SECRET_KEY: "test-secret-placeholder",
      DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
    });
    const service = createOrganizationManagerNotificationService(config, {
      client: {
        async rpc(name) {
          if (name === "list_organization_manager_notification_projection") return { data: [notification], error: null };
          if (name === "list_organization_manager_notification_projection_cursor") return { data: [notification], error: null };
          if (name === "count_organization_manager_notification_projection") return { data: "1", error: null };
          return { data: [], error: null };
        },
      },
    });
    const result = await service.listNotificationProjection({ actorUserId, organizationId, limit: 1 });
    assert.equal(result.unread_count, 1);
    assert.deepEqual(result.notifications[0], notification);
    const cursor = Buffer.from(JSON.stringify({ v: 1, organization_id: organizationId, created_at: "2026-10-31T00:01:00.000Z", id: "f3a00000-0000-4000-8000-000000000011" }), "utf8").toString("base64url");
    const paged = await service.listNotificationProjectionCursor?.({ actorUserId, organizationId, cursor, limit: 1 });
    assert.equal((paged as { unread_count: number } | undefined)?.unread_count, 1);
    await assert.rejects(() => service.listNotificationProjectionCursor?.({
      actorUserId, organizationId: "f3a00000-0000-4000-8000-000000000099", cursor, limit: 1,
    }));
    await assert.rejects(() => service.listNotificationProjectionCursor?.({ actorUserId, organizationId, cursor: "invalid", limit: 1 }));
    const modifiedCursor = Buffer.from(JSON.stringify({ v: 1, organization_id: organizationId, created_at: "not-a-timestamp", id: notification.id }), "utf8").toString("base64url");
    await assert.rejects(() => service.listNotificationProjectionCursor?.({ actorUserId, organizationId, cursor: modifiedCursor, limit: 1 }));
    const mixedVersionCursor = Buffer.from(JSON.stringify({ v: 2, organization_id: organizationId, created_at: notification.created_at, id: notification.id }), "utf8").toString("base64url");
    await assert.rejects(() => service.listNotificationProjectionCursor?.({ actorUserId, organizationId, cursor: mixedVersionCursor, limit: 1 }));
  });
});
