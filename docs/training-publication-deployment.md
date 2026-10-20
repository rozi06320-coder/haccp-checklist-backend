# Training publication deployment boundary

Phase 3B is intentionally fail-closed. It can verify the mutable review objects and record immutable observations, but it cannot complete the Phase 3A verification run or publish a course. Do not enable official Training or treat a queued request as published until a forward-only migration and worker change add an independently immutable publication store and learner read path.

## Minimal two-service layout

Build one image and deploy it as two separately configured services:

1. **API service** — runs `node dist-api/server.js`. Its secret scope contains the existing Supabase service key and the Ed25519 publication private key. It does not contain the verifier capability secret, verifier Storage token, or publication public-key ring.
2. **Verifier worker** — runs `node dist-api/backend/training-storage-verifier-server.js` with no HTTP route. Its secret scope contains the broker capability secret, a short-lived read-only source-Storage JWT, and Ed25519 public keys. It has no PostgreSQL URL, Supabase service key, JWT signing key, or publication private key.

The worker reaches PostgreSQL only through PostgREST using the public anon key and the digest-backed capability arguments. The three broker RPCs are not executable by `service_role`; all direct tables remain revoked. The source-Storage JWT has one SELECT policy for `training-media` and no write/delete policy.

Tarout's public product documentation advertises background workers, per-application environment variables and secrets, and one-click rollback. This repository contains no checked-in `.tarout` deployment contract, so it does **not** prove that the current Tarout project has two independently scoped services or non-shared secrets. Before any worker deployment, confirm those properties in the actual Tarout dashboard/CLI output and retain the evidence in the deployment change record.

## Provisioning gates

- Keep the capability table empty until the worker has a separate secret scope and network policy.
- Provision only a SHA-256 capability digest in `private.training_verifier_capabilities`; never place the raw capability in SQL history.
- Mint the source-Storage JWT out of band with `role=authenticated`, `training_storage_verifier=true`, the exact capability ID/audience claims, a short expiry, and no signing material in either application container.
- Keep API and worker key sets environment-specific. A signing key ID remains in the worker public-key ring during in-flight job expiry, then may be removed after all jobs using it are terminal.
- Do not configure the API signing triplet unless queued verification is operationally desired. Even when configured, the current database finishes successful source inspection as `publication_blocked`.

## Remaining publication gate

A safe follow-up must add a separate S3-compatible bucket/project whose policy gives the verifier content-addressed create-only access and the API read/sign-only access. It must copy each verified byte stream to a digest-derived key, reject an existing key whose bytes differ, persist the immutable destination identity, switch learner media authorization to that destination, and only then atomically call the existing Phase 3A completion/publication checks. The ordinary API service credential must have no overwrite or delete permission in that store.

Until those properties are demonstrated in provider configuration and tested, publication and program activation must remain disabled. Existing draft upload, Internal Admin preview, employee draft preview, progress, quiz, and prerequisite functions are unchanged by this phase.
