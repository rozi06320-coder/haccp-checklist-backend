import assert from "node:assert/strict";
import test from "node:test";
import { createApp } from "./app";
import type { BackendDependencies } from "./dependencies";
import { TrainingSupervisorQuizPreviewAccessError, type TrainingSupervisorQuizPreviewService } from "./training-supervisor-quiz-preview";

const actor = "11000000-0000-4000-8000-000000000001";
const credentialVersion = "22000000-0000-4000-8000-000000000001";
const config = {
  nodeEnv: "test" as const, port: 0, host: "127.0.0.1", trustProxy: false as const,
  bodyLimitBytes: 1024 * 1024,
  rateLimit: { windowMs: 60_000, maxRequests: 1000 }, adminRateLimit: { windowMs: 60_000, maxRequests: 1000 },
  pinVerificationRateLimit: { windowMs: 60_000, maxRequests: 1000 }, authCookieName: "sb-access-token",
  corsAllowedOrigins: ["http://127.0.0.1:3000"], supabase: { url: "http://127.0.0.1:54321", publishableKey: "test" },
  sessionSecret: "a".repeat(64),
};

function questions() {
  return Array.from({ length: 27 }, (_, index) => ({
    question_number: index + 1, question_key: `q-${index + 1}`, prompt: `Question ${index + 1}`,
    options: [{ option_key: "a", text: "A" }, { option_key: "b", text: "B" }],
  }));
}

function deps(service: TrainingSupervisorQuizPreviewService, authenticated = true) {
  return {
    authVerifier: { async verify() { return authenticated ? { userId: actor, email: "training@example.com" } : null; } },
    checkReadiness: async () => true,
    createUserContext: () => ({ async getUserContext() { return { id: actor, must_change_password: false, disabled: false, branches: [], managed_organizations: [] }; } }),
    trainingSupervisorQuizPreviewService: service,
  } as unknown as BackendDependencies;
}

async function start(dependencies: BackendDependencies) {
  const server = createApp(config, dependencies).listen(0, "127.0.0.1");
  await new Promise<void>((resolve) => server.once("listening", resolve));
  return { server, origin: `http://127.0.0.1:${(server.address() as { port: number }).port}` };
}

test("Training Supervisor quiz preview is authenticated, credential-bound, and answer-key free", async () => {
  const service: TrainingSupervisorQuizPreviewService = { async getQuizPreview() { return questions(); } };
  const { server, origin } = await start(deps(service));
  try {
    assert.equal((await fetch(`${origin}/api/v1/training-supervisor/preview/baladiyah/questions`)).status, 401);
    assert.equal((await fetch(`${origin}/api/v1/training-supervisor/preview/baladiyah/questions`, { headers: { Authorization: "Bearer token" } })).status, 403);
    const response = await fetch(`${origin}/api/v1/training-supervisor/preview/baladiyah/questions`, { headers: { Authorization: "Bearer token", "x-credential-version": credentialVersion, "accept-language": "ar" } });
    assert.equal(response.status, 200);
    const body = await response.text();
    assert.match(body, /question_count.*27/);
    assert.doesNotMatch(body, /correct_option_key|answer_key|explanation/i);
  } finally { server.close(); }
});

test("Training Supervisor quiz preview fails closed for malformed question counts", async () => {
  const service: TrainingSupervisorQuizPreviewService = { async getQuizPreview() { return questions().slice(0, 26); } };
  const { server, origin } = await start(deps(service));
  try {
    const response = await fetch(`${origin}/api/v1/training-supervisor/preview/baladiyah/questions`, { headers: { Authorization: "Bearer token", "x-credential-version": credentialVersion } });
    assert.equal(response.status, 503);
  } finally { server.close(); }
});

test("Training Supervisor quiz preview maps revoked membership to forbidden", async () => {
  const service: TrainingSupervisorQuizPreviewService = {
    async getQuizPreview() { throw new TrainingSupervisorQuizPreviewAccessError(); },
  };
  const { server, origin } = await start(deps(service));
  try {
    const response = await fetch(`${origin}/api/v1/training-supervisor/preview/baladiyah/questions`, {
      headers: { Authorization: "Bearer token", "x-credential-version": credentialVersion },
    });
    assert.equal(response.status, 403);
  } finally { server.close(); }
});
