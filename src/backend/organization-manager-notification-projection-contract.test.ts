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

  it("supports projection cursor v2 with branch names and fallback", async () => {
    const config = loadBackendConfig({
      NODE_ENV: "test",
      SUPABASE_URL: "http://127.0.0.1:54321",
      SUPABASE_PUBLISHABLE_KEY: "test-publishable-placeholder",
      SUPABASE_SECRET_KEY: "test-secret-placeholder",
      DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
    });
    const v2Notification = {
      ...notification,
      branch_name: "Downtown Branch",
      branch_name_ar: "فرع وسط المدينة",
    };
    let v2Called = false;
    let v1Called = false;
    const serviceWithV2 = createOrganizationManagerNotificationService(config, {
      client: {
        async rpc(name) {
          if (name === "list_organization_manager_notification_projection_cursor_v2") {
            v2Called = true;
            return { data: [v2Notification], error: null };
          }
          if (name === "count_organization_manager_notification_projection") return { data: "1", error: null };
          return { data: [], error: null };
        },
      },
    });
    const pagedV2 = await serviceWithV2.listNotificationProjectionCursor?.({ actorUserId, organizationId, limit: 1 });
    assert.equal(v2Called, true);
    assert.equal(pagedV2?.notifications[0]?.branch_name, "Downtown Branch");
    assert.equal(pagedV2?.notifications[0]?.branch_name_ar, "فرع وسط المدينة");

    // Test fallback when v2 fails
    const serviceFallback = createOrganizationManagerNotificationService(config, {
      client: {
        async rpc(name) {
          if (name === "list_organization_manager_notification_projection_cursor_v2") {
            return { data: null, error: { message: "function does not exist" } };
          }
          if (name === "list_organization_manager_notification_projection_cursor") {
            v1Called = true;
            return { data: [{ ...notification, category_context: { ...notification.category_context, branch_name: "Fallback Branch" } }], error: null };
          }
          if (name === "count_organization_manager_notification_projection") return { data: "1", error: null };
          return { data: [], error: null };
        },
      },
    });
    const pagedFallback = await serviceFallback.listNotificationProjectionCursor?.({ actorUserId, organizationId, limit: 1 });
    assert.equal(v1Called, true);
    assert.equal(pagedFallback?.notifications[0]?.branch_name, "Fallback Branch");

    // Test fail-closed on authorization failure (must NOT fall back to v1)
    let v1CalledOnAuthFailure = false;
    const serviceAuthFailure = createOrganizationManagerNotificationService(config, {
      client: {
        async rpc(name) {
          if (name === "list_organization_manager_notification_projection_cursor_v2") {
            return { data: null, error: { code: "42501", message: "permission denied" } };
          }
          if (name === "list_organization_manager_notification_projection_cursor") {
            v1CalledOnAuthFailure = true;
            return { data: [notification], error: null };
          }
          return { data: null, error: null };
        },
      },
    });
    await assert.rejects(
      () => serviceAuthFailure.listNotificationProjectionCursor?.({ actorUserId, organizationId, limit: 1 }),
      (err: unknown) => err instanceof (require("./organization-manager-notifications").ManagerNotificationAccessError),
    );
    assert.equal(v1CalledOnAuthFailure, false, "Authorization failure on V2 must NOT fall back to V1");

    // Test fail-closed on database error (must NOT fall back to v1)
    let v1CalledOnDbError = false;
    const serviceDbError = createOrganizationManagerNotificationService(config, {
      client: {
        async rpc(name) {
          if (name === "list_organization_manager_notification_projection_cursor_v2") {
            return { data: null, error: { code: "XX000", message: "internal db error" } };
          }
          if (name === "list_organization_manager_notification_projection_cursor") {
            v1CalledOnDbError = true;
            return { data: [notification], error: null };
          }
          return { data: null, error: null };
        },
      },
    });
    await assert.rejects(
      () => serviceDbError.listNotificationProjectionCursor?.({ actorUserId, organizationId, limit: 1 }),
      (err: unknown) => err instanceof (require("./organization-manager-notifications").ManagerNotificationUnavailableError),
    );
    assert.equal(v1CalledOnDbError, false, "Database error on V2 must NOT fall back to V1");

    // Test fail-closed on validation error (must NOT fall back to v1)
    let v1CalledOnValidation = false;
    const serviceValidationError = createOrganizationManagerNotificationService(config, {
      client: {
        async rpc(name) {
          if (name === "list_organization_manager_notification_projection_cursor_v2") {
            return { data: [{ invalid_field: "unexpected" }], error: null };
          }
          if (name === "list_organization_manager_notification_projection_cursor") {
            v1CalledOnValidation = true;
            return { data: [notification], error: null };
          }
          return { data: null, error: null };
        },
      },
    });
    await assert.rejects(
      () => serviceValidationError.listNotificationProjectionCursor?.({ actorUserId, organizationId, limit: 1 }),
      (err: unknown) => (err as { name?: string })?.name === "ZodError",
    );
    assert.equal(v1CalledOnValidation, false, "Validation error on V2 must NOT fall back to V1");
  });

  it("fetches single notification detail via getNotificationDetail", async () => {
    const config = loadBackendConfig({
      NODE_ENV: "test",
      SUPABASE_URL: "http://127.0.0.1:54321",
      SUPABASE_PUBLISHABLE_KEY: "test-publishable-placeholder",
      SUPABASE_SECRET_KEY: "test-secret-placeholder",
      DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
    });
    const detailRow = {
      ...notification,
      branch_name: "Bakery Branch",
      branch_name_ar: "فرع المخبز",
    };
    const service = createOrganizationManagerNotificationService(config, {
      client: {
        async rpc(name, args) {
          if (name === "get_organization_manager_notification_detail") {
            if ((args as { p_notification_id: string }).p_notification_id === notification.id) {
              return { data: [detailRow], error: null };
            }
            return { data: [], error: null };
          }
          return { data: null, error: null };
        },
      },
    });
    const detail = await service.getNotificationDetail?.({ actorUserId, organizationId, notificationId: notification.id });
    assert.equal(detail?.notification.branch_name, "Bakery Branch");
    assert.equal(detail?.notification.id, notification.id);

    // Nonexistent throws ManagerNotificationAccessError
    await assert.rejects(
      () => service.getNotificationDetail?.({ actorUserId, organizationId, notificationId: "f3a00000-0000-4000-8000-000000000099" })
    );
  });
});
