import assert from "node:assert/strict";
import test from "node:test";
import { createMutationRateLimiter } from "./mutation-rate-limit";

function request(userId = "user-a", branchId = "branch-a") {
  return { auth: { userId }, params: { branchId } } as never;
}

test("is a no-op when disabled", () => {
  const limiter = createMutationRateLimiter({ enabled: false, limits: { oil_closing_submit: 1 } });
  let calls = 0;
  limiter.middleware("oil_closing_submit")(request(), {} as never, () => { calls += 1; });
  limiter.middleware("oil_closing_submit")(request(), {} as never, () => { calls += 1; });
  assert.equal(calls, 2);
  assert.equal(limiter.size(), 0);
});

test("limits verified actor and branch buckets and exposes retry duration", () => {
  let now = 1_000;
  const rejected: number[] = [];
  const limiter = createMutationRateLimiter({
    enabled: true,
    now: () => now,
    limits: { oil_closing_submit: 2 },
    onRejected: ({ retryAfterSeconds, requestId }) => { rejected.push(retryAfterSeconds); assert.equal(requestId, null); },
  });
  const run = (req = request()) => {
    let nextError: unknown;
    limiter.middleware("oil_closing_submit")(req, {} as never, (error?: unknown) => { nextError = error; });
    return nextError;
  };
  assert.equal(run(), undefined);
  assert.equal(run(), undefined);
  assert.equal((run() as { status: number }).status, 429);
  assert.equal(rejected.length, 1);
  assert.equal(run(request("user-b")), undefined);
  assert.equal(run(request("user-a", "branch-b")), undefined);
  now += 60_001;
  assert.equal(run(), undefined);
});

test("evicts expired and excess entries", () => {
  let now = 0;
  const limiter = createMutationRateLimiter({ enabled: true, now: () => now, maxEntries: 128, windowMs: 10 });
  for (let index = 0; index < 300; index += 1) {
    limiter.middleware("oil_draft")(request(`user-${index}`, "branch-a"), {} as never, () => {});
  }
  assert.ok(limiter.size() <= 128);
  now = 11;
  limiter.middleware("oil_draft")(request("fresh", "branch-a"), {} as never, () => {});
  assert.ok(limiter.size() <= 128);
});
