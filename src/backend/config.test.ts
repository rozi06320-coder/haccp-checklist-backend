import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  BackendConfigurationError,
  loadBackendConfig,
} from "./config";

const validEnvironment = {
  NODE_ENV: "test",
  SUPABASE_URL: "http://127.0.0.1:54321",
  SUPABASE_PUBLISHABLE_KEY: "test-publishable-placeholder",
  DAILY_AUDIT_GRANT_SECRET: "test-daily-audit-grant-secret-placeholder-32-bytes",
} as const;

describe("backend configuration", () => {
  it("loads bounded defaults and explicit trust-proxy false", () => {
    const config = loadBackendConfig(validEnvironment);

    assert.equal(config.host, "127.0.0.1");
    assert.equal(config.port, 3001);
    assert.equal(config.trustProxy, false);
    assert.equal(config.nodeEnv, "test");
    assert.equal(config.trainingLearnerAuthEnabled, false);
    assert.equal(config.trainingDbCurriculumEnabled, false);
    assert.equal(config.trainingEmployeeDraftPreviewEnabled, false);
    assert.equal(config.trainingLearnerAllowedOrigin, undefined);
    assert.equal(config.supervisorNotificationSchedulerSecret, undefined);
    assert.equal(config.organizationManagerPushWorkerEnabled, false);
    assert.equal(loadBackendConfig({ ...validEnvironment, SUPERVISOR_NOTIFICATION_SCHEDULER_SECRET: "test-supervisor-notification-scheduler-secret" }).supervisorNotificationSchedulerSecret, "test-supervisor-notification-scheduler-secret");
  });

  it("keeps the Organization Manager push worker disabled unless all server credentials exist", () => {
    assert.throws(() => loadBackendConfig({
      ...validEnvironment,
      ORGANIZATION_MANAGER_PUSH_WORKER_ENABLED: "true",
    }), BackendConfigurationError);
    const configured = loadBackendConfig({
      ...validEnvironment,
      ORGANIZATION_MANAGER_PUSH_WORKER_ENABLED: "true",
      SUPABASE_SECRET_KEY: "test-service-key",
      VAPID_PUBLIC_KEY: "test-public-key",
      VAPID_PRIVATE_KEY: "test-private-key",
      VAPID_SUBJECT: "mailto:push@example.invalid",
    });
    assert.equal(configured.organizationManagerPushWorkerEnabled, true);
  });

  it("keeps employee draft preview independently disabled by default",()=>{
    const enabled=loadBackendConfig({...validEnvironment,TRAINING_EMPLOYEE_DRAFT_PREVIEW_ENABLED:"true"});
    assert.equal(enabled.trainingEmployeeDraftPreviewEnabled,true);
    assert.equal(enabled.trainingDbCurriculumEnabled,false);
    assert.equal(enabled.trainingLearnerAuthEnabled,false);
  });

  it("requires the publication signing key, environment audience, and rotation key id together",()=>{
    assert.throws(()=>loadBackendConfig({...validEnvironment,TRAINING_PUBLICATION_AUDIENCE:"haccp.production.training-publication"}),BackendConfigurationError);
    assert.throws(()=>loadBackendConfig({...validEnvironment,TRAINING_PUBLICATION_SIGNING_PRIVATE_KEY_BASE64:"cHJpdmF0ZQ==",TRAINING_PUBLICATION_AUDIENCE:"bad audience",TRAINING_PUBLICATION_SIGNING_KEY_ID:"key-1"}),BackendConfigurationError);
    const configured=loadBackendConfig({...validEnvironment,TRAINING_PUBLICATION_SIGNING_PRIVATE_KEY_BASE64:Buffer.from("private-pem-placeholder").toString("base64"),TRAINING_PUBLICATION_AUDIENCE:"haccp.production.training-publication",TRAINING_PUBLICATION_SIGNING_KEY_ID:"key-2026-10"});
    assert.equal(configured.trainingPublicationAudience,"haccp.production.training-publication");
    assert.equal(configured.trainingPublicationSigningKeyId,"key-2026-10");
  });

  it("keeps database curriculum disabled by default and requires an allowed origin when enabled",()=>{
    assert.throws(()=>loadBackendConfig({...validEnvironment,TRAINING_DB_CURRICULUM_ENABLED:"true"}),BackendConfigurationError);
    const enabled=loadBackendConfig({...validEnvironment,TRAINING_DB_CURRICULUM_ENABLED:"true",TRAINING_LEARNER_ALLOWED_ORIGIN:"https://training.example.invalid"});
    assert.equal(enabled.trainingDbCurriculumEnabled,true);
    assert.equal(enabled.trainingLearnerAuthEnabled,false);
  });

  it("keeps learner authentication disabled by default and requires an exact allowed origin when enabled", () => {
    assert.throws(
      () => loadBackendConfig({ ...validEnvironment, TRAINING_LEARNER_AUTH_ENABLED: "true" }),
      BackendConfigurationError,
    );
    const enabled = loadBackendConfig({
      ...validEnvironment,
      TRAINING_LEARNER_AUTH_ENABLED: "true",
      TRAINING_LEARNER_ALLOWED_ORIGIN: "https://training.example.invalid/path",
    });
    assert.equal(enabled.trainingLearnerAuthEnabled, true);
    assert.equal(enabled.trainingLearnerAllowedOrigin, "https://training.example.invalid");
    for (const invalid of ["1", "yes", "TRUE"]) {
      assert.throws(
        () => loadBackendConfig({ ...validEnvironment, TRAINING_LEARNER_AUTH_ENABLED: invalid }),
        BackendConfigurationError,
      );
    }
  });

  it("accepts only false or the constrained loopback proxy setting", () => {
    assert.equal(
      loadBackendConfig({ ...validEnvironment, API_TRUST_PROXY: "false" })
        .trustProxy,
      false,
    );
    assert.equal(
      loadBackendConfig({ ...validEnvironment, API_TRUST_PROXY: "loopback" })
        .trustProxy,
      "loopback",
    );

    for (const unsafeSetting of ["true", "1", "*", "uniquelocal", "arbitrary"]) {
      assert.throws(
        () =>
          loadBackendConfig({
            ...validEnvironment,
            API_TRUST_PROXY: unsafeSetting,
          }),
        BackendConfigurationError,
      );
    }
  });

  it("rejects missing or invalid required environment", () => {
    const withoutGrantSecret: NodeJS.ProcessEnv = { ...validEnvironment };
    delete withoutGrantSecret.DAILY_AUDIT_GRANT_SECRET;
    assert.throws(
      () => loadBackendConfig(withoutGrantSecret),
      BackendConfigurationError,
    );
    assert.throws(
      () =>
        loadBackendConfig({
          NODE_ENV: "test",
          SUPABASE_PUBLISHABLE_KEY: "test-publishable-placeholder",
        }),
      BackendConfigurationError,
    );
    assert.throws(
      () =>
        loadBackendConfig({
          ...validEnvironment,
          SUPABASE_URL: "file:///not-http",
        }),
      BackendConfigurationError,
    );
    assert.throws(
      () =>
        loadBackendConfig({
          ...validEnvironment,
          API_PORT: "70000",
        }),
      BackendConfigurationError,
    );
    for (const invalidSecret of ["short", "x".repeat(31)]) {
      assert.throws(
        () => loadBackendConfig({ ...validEnvironment, DAILY_AUDIT_GRANT_SECRET: invalidSecret }),
        BackendConfigurationError,
      );
    }
    assert.throws(
      () => loadBackendConfig({ ...validEnvironment, SUPERVISOR_NOTIFICATION_SCHEDULER_SECRET: "short" }),
      BackendConfigurationError,
    );
    assert.throws(
      () =>
        loadBackendConfig({
          ...validEnvironment,
          DAILY_AUDIT_GRANT_SECRET: "production-looking-secret-that-is-not-a-test-placeholder",
        }),
      BackendConfigurationError,
    );
  });

  it("requires a canonical high-diversity base64 secret outside tests", () => {
    const productionSecret = Buffer.from(
      Array.from({ length: 32 }, (_, index) => index),
    ).toString("base64");

    assert.equal(
      loadBackendConfig({
        ...validEnvironment,
        NODE_ENV: "production",
        DAILY_AUDIT_GRANT_SECRET: productionSecret,
      }).dailyAuditGrantSecret,
      productionSecret,
    );

    for (const invalidSecret of [
      "x".repeat(32),
      Buffer.alloc(32).toString("base64"),
      "replace-with-at-least-32-bytes-of-random-backend-only-material",
    ]) {
      assert.throws(
        () =>
          loadBackendConfig({
            ...validEnvironment,
            NODE_ENV: "production",
            DAILY_AUDIT_GRANT_SECRET: invalidSecret,
          }),
        BackendConfigurationError,
      );
    }
  });
});
