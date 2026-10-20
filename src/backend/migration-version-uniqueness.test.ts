import assert from "node:assert/strict";
import { readdir } from "node:fs/promises";
import { describe, it } from "node:test";

describe("Supabase migration versions", () => {
  it("are unique and place the manager reset after every committed migration", async () => {
    const files = (await readdir(new URL("../../supabase/migrations/", import.meta.url)))
      .filter((file) => /^\d{14}_.+\.sql$/.test(file));
    const versions = files.map((file) => file.slice(0, 14));
    assert.equal(new Set(versions).size, versions.length);
    const reset = files.find((file) => file.endsWith("_organization_manager_secure_password_reset.sql"));
    assert.equal(reset, "20261020140000_organization_manager_secure_password_reset.sql");
    assert.ok(files.filter((file) => file !== reset).every((file) => file.slice(0, 14) < reset.slice(0, 14)));
  });
});
