import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

const migration = readFileSync(new URL("../../supabase/migrations/20261113120000_training_question_authoring_api.sql", import.meta.url), "utf8");
const draftMigration = readFileSync(new URL("../../supabase/migrations/20261112120000_training_question_draft_authoring.sql", import.meta.url), "utf8");
const app = readFileSync(new URL("./app.ts", import.meta.url), "utf8");
const admin = readFileSync(new URL("./admin.ts", import.meta.url), "utf8");

describe("Internal Admin training question authoring API boundary", () => {
  it("exposes only the versioned draft CRUD and option-replacement RPCs", () => {
    for (const name of [
      "list_internal_admin_training_question_drafts",
      "create_internal_admin_training_question_draft",
      "update_internal_admin_training_question_draft",
      "delete_internal_admin_training_question_draft",
      "replace_internal_admin_training_question_options",
    ]) assert.match(migration, new RegExp(`create(?: or replace)? function public\\.${name}\\(`));
  });

  it("keeps every authoring function SECURITY DEFINER with an empty search path", () => {
    assert.equal(migration.match(/security definer set search_path = ''/g)?.length, 7);
  });

  it("denies browser and direct service-role table access while granting RPC execution only to service_role", () => {
    assert.match(migration, /revoke all on table public\.training_question_authoring_requests from public, anon, authenticated, service_role;/);
    assert.match(draftMigration, /revoke all on table public\.training_question_drafts from public, anon, authenticated, service_role;/);
    assert.match(migration, /grant execute on function public\.create_internal_admin_training_question_draft\([^;]+\) to service_role;/);
    assert.doesNotMatch(migration, /grant execute on function public\.(?:create|update|delete|replace|list)_internal_admin_training_question_draft[^;]+ to (?:anon|authenticated);/);
  });

  it("locks the target row and rejects stale revisions", () => {
    assert.match(migration, /from public\.training_question_drafts[\s\S]*?for update;/);
    assert.match(migration, /question revision is stale.*errcode='40001'/);
  });

  it("uses idempotency hashes and replays only the same action", () => {
    assert.match(migration, /primary key \(actor_user_id, action_key\)/);
    assert.equal((migration.match(/idempotency conflict/g) ?? []).length, 4);
    assert.match(admin, /createHmac\("sha256", "training-question-authoring"\)/);
  });

  it("uses the non-reserved p_position RPC argument consistently", () => {
    assert.match(migration, /stable_key text, p_position integer/);
    assert.match(migration, /position=[^,;\n]*p_position/);
    assert.equal((admin.match(/p_position: parsed\.position/g) ?? []).length, 2);
  });

  it("qualifies idempotency-table columns to avoid PL/pgSQL argument ambiguity", () => {
    assert.equal((migration.match(/requests\.actor_user_id=/g) ?? []).length, 4);
    assert.equal((migration.match(/requests\.action_key=/g) ?? []).length, 4);
    assert.doesNotMatch(migration, /from public\.training_question_authoring_requests requests where actor_user_id\s*=/);
  });

  it("enforces draft quiz scope through the existing authorization helper", () => {
    assert.equal((migration.match(/private\.assert_internal_admin_training_draft/g) ?? []).length, 5);
    assert.equal((migration.match(/lesson\.lesson_type='quiz'/g) ?? []).length, 2);
  });

  it("validates duplicate option keys/positions and the correct answer at the HTTP boundary", () => {
    assert.match(app, /Duplicate option key/);
    assert.match(app, /Duplicate option position/);
    assert.match(app, /Correct option must exist/);
    assert.match(admin, /Duplicate option key/);
    assert.match(admin, /Duplicate option position/);
  });

  it("maps authorization, not-found, input, conflict, and service failures to distinct HTTP statuses", () => {
    assert.match(app, /AdminInputError\) return new HttpError\(422/);
    assert.match(app, /AdminConflictError\) return new HttpError\(409/);
    assert.match(app, /AdminNotFoundError\) return new HttpError\(404/);
    assert.match(app, /AdminAccessError\) return new HttpError\(403/);
    assert.match(app, /service_unavailable/);
  });

  it("requires authenticated Internal Admin access on each route and prevents caching", () => {
    const routes = app.match(/app\.(?:get|post|patch|delete|put)\("\/api\/v1\/internal-admin\/organizations\/[^;]+/g) ?? [];
    const authoringRoutes = routes.filter((route) => route.includes("training/courses"));
    assert.equal(authoringRoutes.length, 5);
    for (const route of authoringRoutes) assert.match(route, /protectedRateLimit, authenticate/);
    assert.equal((app.match(/await requireInternalAdmin\(request\);/g) ?? []).filter((_, index) => index >= 0).length >= 5, true);
    assert.match(app, /Cache-Control.*private, no-store/);
  });

  it("does not expose draft answer keys through learner-facing code paths", () => {
    assert.doesNotMatch(migration, /grant execute on function public\.training_question_authoring_response/);
    assert.match(draftMigration, /revoke all on table public\.training_question_draft_options from public, anon, authenticated, service_role/);
  });
});
