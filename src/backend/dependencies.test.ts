import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { createSupabaseClaimsAuthVerifier } from "./dependencies";

const userId = "10000000-0000-4000-8000-000000000001";
const email = "user@example.invalid";

function verifierForClaims(claims: Record<string, unknown>) {
  return createSupabaseClaimsAuthVerifier({
    auth: {
      async getClaims() {
        return { data: { claims }, error: null };
      },
    },
  });
}

describe("createSupabaseClaimsAuthVerifier", () => {
  it("returns identity from valid verified claims", async () => {
    let checkedToken: string | null = null;
    const verifier = createSupabaseClaimsAuthVerifier({
      auth: {
        async getClaims(token) {
          checkedToken = token;
          return {
            data: {
              claims: { sub: userId, email, role: "authenticated" },
            },
            error: null,
          };
        },
      },
    });

    assert.deepEqual(await verifier.verify("valid-token"), { userId, email });
    assert.equal(checkedToken, "valid-token");
  });

  it("returns null on verification errors", async () => {
    const verifier = createSupabaseClaimsAuthVerifier({
      auth: {
        async getClaims() {
          return { data: null, error: new Error("invalid JWT signature") };
        },
      },
    });

    assert.equal(await verifier.verify("bad-signature-token"), null);
  });

  it("returns null when sub is missing", async () => {
    const verifier = verifierForClaims({
      email,
      role: "authenticated",
    });

    assert.equal(await verifier.verify("missing-sub-token"), null);
  });

  it("returns null when email is missing", async () => {
    const verifier = verifierForClaims({
      sub: userId,
      role: "authenticated",
    });

    assert.equal(await verifier.verify("missing-email-token"), null);
  });

  it("returns null when email is empty", async () => {
    const verifier = verifierForClaims({
      sub: userId,
      email: " ",
      role: "authenticated",
    });

    assert.equal(await verifier.verify("empty-email-token"), null);
  });

  it("returns null for non-authenticated roles", async () => {
    for (const role of ["anon", "service_role", "service_role_jwt"]) {
      const verifier = verifierForClaims({ sub: userId, email, role });

      assert.equal(await verifier.verify(`${role}-token`), null);
    }
  });

  it("returns null for anonymous user claims", async () => {
    const verifier = verifierForClaims({
      sub: userId,
      email,
      role: "authenticated",
      is_anonymous: true,
    });

    assert.equal(await verifier.verify("anonymous-user-token"), null);
  });

  it("returns null when malformed tokens fail the verifier path", async () => {
    const verifier = createSupabaseClaimsAuthVerifier({
      auth: {
        async getClaims(token) {
          assert.equal(token, "not-a-jwt");
          throw new Error("Invalid JWT structure");
        },
      },
    });

    assert.equal(await verifier.verify("not-a-jwt"), null);
  });
});
