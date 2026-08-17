import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { describe, it } from "node:test";

async function filesBelow(directory: string): Promise<string[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(
    entries.map(async (entry) => {
      const target = path.join(directory, entry.name);
      return entry.isDirectory() ? filesBelow(target) : [target];
    }),
  );
  return nested.flat();
}

describe("backend security boundary", () => {
  it("keeps the secret-key admin client inside backend code", async () => {
    const sourceRoot = path.resolve("src");
    const productionApiEntrypoint = path.resolve("src/server.ts");
    const files = (await filesBelow(sourceRoot)).filter((file) =>
      /\.(?:ts|tsx|js|jsx|mjs)$/.test(file),
    );
    const contents = await Promise.all(
      files.map(async (file) => ({
        file,
        source: await readFile(file, "utf8"),
      })),
    );

    const secretClientReferences = contents.filter(
      ({ file, source }) =>
        file !== productionApiEntrypoint &&
        !file.includes(`${path.sep}backend${path.sep}`) &&
        /SUPABASE_SECRET_KEY|serviceRoleKey|createProvisioningAdmin/.test(source),
    );
    const frontendBackendImports = contents.filter(
      ({ file, source }) =>
        file !== productionApiEntrypoint &&
        !file.includes(`${path.sep}backend${path.sep}`) &&
        /(?:from|import)\s*\(?["'][^"']*backend(?:\/|["'])/.test(source),
    );

    assert.deepEqual(secretClientReferences, []);
    assert.deepEqual(frontendBackendImports, []);
    assert.equal(await readFile(productionApiEntrypoint, "utf8"),
      "// Production compatibility entrypoint. API implementation remains isolated in src/backend.\nimport \"./backend/server\";\n");
  });

  it("constructs user data access with publishable key and bearer scope", async () => {
    const [source, configSource] = await Promise.all([
      readFile(path.resolve("src/backend/dependencies.ts"), "utf8"),
      readFile(path.resolve("src/backend/config.ts"), "utf8"),
    ]);

    assert.match(source, /publishableKey/);
    assert.match(source, /Authorization: `Bearer \$\{token\}`/);
    assert.doesNotMatch(source, /serviceRole|getSession/);
    assert.doesNotMatch(configSource, /NEXT_PUBLIC_/);
  });
});
