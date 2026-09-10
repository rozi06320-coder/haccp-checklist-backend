#!/usr/bin/env node
/**
 * Isolated test runner for Phase 3B1 Product Sales Snapshots.
 *
 * Runs strictly against a local/disposable PostgreSQL database.
 * Explicitly guards against production references and non-local targets.
 */

import { spawnSync } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const ROOT_DIR = resolve(__dirname, '..');

const PRODUCTION_REF = 'cawswpenxhfzbqtvhsng';
const DEFAULT_CONTAINER = 'supabase_db_haccp-and-daily-checklist';
const DISPOSABLE_DB_NAME = 'phase3b1_test_disposable';

// -----------------------------------------------------------------------------
// 1. Production Protection Guards
// -----------------------------------------------------------------------------
const envSources = [
  process.env.DATABASE_URL,
  process.env.TEST_DATABASE_URL,
  process.env.SUPABASE_URL,
  process.env.PGHOST,
  ...process.argv
];

for (const source of envSources) {
  if (source && source.includes(PRODUCTION_REF)) {
    console.error(`\x1b[31mFATAL: Detected production reference "${PRODUCTION_REF}". Execution aborted.\x1b[0m`);
    process.exit(1);
  }
}

// -----------------------------------------------------------------------------
// 2. Identify Target Execution Strategy
// -----------------------------------------------------------------------------
const customDbUrl = process.env.TEST_DATABASE_URL;

if (customDbUrl) {
  // Validate custom test db URL
  try {
    const parsed = new URL(customDbUrl);
    const host = parsed.hostname;
    const isLocalHost = host === 'localhost' || host === '127.0.0.1' || host === '0.0.0.0';
    if (!isLocalHost) {
      console.error(`\x1b[31mFATAL: TEST_DATABASE_URL must target localhost/127.0.0.1. Got "${host}".\x1b[0m`);
      process.exit(1);
    }
    const dbName = parsed.pathname.replace(/^\//, '');
    if (!dbName.includes('test') && !dbName.includes('disposable')) {
      console.error(`\x1b[31mFATAL: Target database name "${dbName}" must contain "test" or "disposable".\x1b[0m`);
      process.exit(1);
    }
  } catch (err) {
    console.error(`\x1b[31mFATAL: Invalid TEST_DATABASE_URL format: ${err.message}\x1b[0m`);
    process.exit(1);
  }
}

// Check Docker availability if no local custom URL with psql
let dockerContainer = null;
if (!customDbUrl) {
  const checkDocker = spawnSync('docker', ['ps', '--filter', `name=${DEFAULT_CONTAINER}`, '--format', '{{.Names}}'], {
    encoding: 'utf8'
  });
  if (checkDocker.status === 0 && checkDocker.stdout.trim().split('\n').includes(DEFAULT_CONTAINER)) {
    dockerContainer = DEFAULT_CONTAINER;
  }
}

function runSqlInDisposableDb(sqlFilePath) {
  const fullPath = resolve(ROOT_DIR, sqlFilePath);
  if (!existsSync(fullPath)) {
    console.error(`\x1b[31mFATAL: SQL file not found: ${fullPath}\x1b[0m`);
    process.exit(1);
  }

  console.log(`\x1b[36m--> Applying ${sqlFilePath}...\x1b[0m`);
  const sqlContent = readFileSync(fullPath, 'utf8');

  if (dockerContainer) {
    const res = spawnSync('docker', ['exec', '-i', dockerContainer, 'psql', '-U', 'postgres', '-d', DISPOSABLE_DB_NAME, '-v', 'ON_ERROR_STOP=1'], {
      input: sqlContent,
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe']
    });

    if (res.status !== 0) {
      console.error(`\x1b[31mError applying ${sqlFilePath}:\x1b[0m\n${res.stderr || res.stdout}`);
      process.exit(1);
    }
    return res.stdout;
  } else if (customDbUrl) {
    const res = spawnSync('psql', [customDbUrl, '-v', 'ON_ERROR_STOP=1'], {
      input: sqlContent,
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe']
    });

    if (res.status !== 0) {
      console.error(`\x1b[31mError applying ${sqlFilePath}:\x1b[0m\n${res.stderr || res.stdout}`);
      process.exit(1);
    }
    return res.stdout;
  } else {
    console.error('\x1b[31mFATAL: Neither local docker container (' + DEFAULT_CONTAINER + ') nor TEST_DATABASE_URL is available.\x1b[0m');
    console.error('Please either start local Supabase docker or export TEST_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/test_db');
    process.exit(1);
  }
}

// -----------------------------------------------------------------------------
// 3. Execution Sequence
// -----------------------------------------------------------------------------
console.log('\x1b[34m====================================================\x1b[0m');
console.log('\x1b[34m  PHASE 3B1 DISPOSABLE TEST RUNNER\x1b[0m');
console.log('\x1b[34m====================================================\x1b[0m');

if (dockerContainer) {
  console.log(`Target: Docker container "${dockerContainer}" -> database "${DISPOSABLE_DB_NAME}"`);
  console.log(`Recreating disposable database "${DISPOSABLE_DB_NAME}"...`);
  const resetSql = `
    select pg_terminate_backend(pid) from pg_stat_activity where datname = '${DISPOSABLE_DB_NAME}' and pid <> pg_backend_pid();
    drop database if exists ${DISPOSABLE_DB_NAME};
    create database ${DISPOSABLE_DB_NAME};
  `;
  const resetRes = spawnSync('docker', ['exec', '-i', dockerContainer, 'psql', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'], {
    input: resetSql,
    encoding: 'utf8'
  });
  if (resetRes.status !== 0) {
    console.error(`\x1b[31mFailed to recreate disposable database:\x1b[0m\n${resetRes.stderr}`);
    process.exit(1);
  }
} else {
  console.log(`Target: Custom TEST_DATABASE_URL -> ${customDbUrl}`);
}

// Step 1: Load baseline fixture
runSqlInDisposableDb('supabase/tests/database/fixtures/phase3b1_minimal_baseline.sql');

// Step 2: Apply Phase 3A
runSqlInDisposableDb('supabase/migrations/20260909100000_product_inventory_recipe_catalogs.sql');

// Step 3: Apply Phase 3B1
runSqlInDisposableDb('supabase/migrations/20260910100000_product_sales_snapshots_phase3b1.sql');

// Step 4: Run pgTAP test suite
console.log('\x1b[36m--> Running pgTAP test suite: supabase/tests/database/product_sales_snapshots_phase3b1.test.sql...\x1b[0m');
const tapOutput = runSqlInDisposableDb('supabase/tests/database/product_sales_snapshots_phase3b1.test.sql');

console.log('\n\x1b[32m=== pgTAP Test Output ===\x1b[0m\n');
console.log(tapOutput);

// Parse TAP output for failure indicators
const tapLines = tapOutput.split('\n');
let failedTests = 0;
let totalTests = 0;

for (const line of tapLines) {
  const trimmed = line.trim();
  if (trimmed.startsWith('ok ')) {
    totalTests++;
  } else if (trimmed.startsWith('not ok ')) {
    totalTests++;
    failedTests++;
  } else if (trimmed.startsWith('Bail out!')) {
    failedTests++;
  }
}

if (failedTests > 0) {
  console.error(`\x1b[31mFAIL: ${failedTests} of ${totalTests} pgTAP assertions failed.\x1b[0m`);
  process.exit(1);
}

console.log(`\x1b[32mSUCCESS: All ${totalTests} pgTAP assertions passed cleanly.\x1b[0m`);
process.exit(0);
