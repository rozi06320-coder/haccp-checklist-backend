# Training publication deployment boundary

Phase 3B is intentionally fail-closed until the Phase 3C single-project published-media migration and worker are deployed together. Phase 3C promotes verified bytes to the private `training-published-media` bucket, binds an immutable database manifest, and serves official learner media only while append-only integrity evidence is current.

## Minimal two-service layout

Build one image and deploy it as two separately configured services:

1. **API service** — runs `node dist-api/server.js`. Its secret scope contains the existing Supabase service key and the Ed25519 publication private key. It does not contain the verifier capability secret, verifier Storage token, or publication public-key ring.
2. **Verifier worker** — runs `node dist-api/backend/training-storage-verifier-server.js` with no HTTP route. Its secret scope contains the broker capability secret, a short-lived scoped Storage JWT, and Ed25519 public keys. The JWT may read `training-media` and may read/insert content-addressed objects in `training-published-media`; it has no UPDATE or DELETE policy. The worker has no PostgreSQL URL, Supabase service key, JWT signing key, or publication private key.

The worker reaches PostgreSQL only through PostgREST using the public anon key and digest-backed capability arguments. Verifier broker RPCs are not executable by `service_role`; all direct manifest, queue, and evidence tables remain revoked. The committed Phase 3A completion and publication RPCs remain ungranted and are invoked only inside the guarded Phase 3C finalizer transaction.

Tarout's public product documentation advertises background workers, per-application environment variables and secrets, and one-click rollback. This repository contains no checked-in `.tarout` deployment contract, so it does **not** prove that the current Tarout project has two independently scoped services or non-shared secrets. Before any worker deployment, confirm those properties in the actual Tarout dashboard/CLI output and retain the evidence in the deployment change record.

## Provisioning gates

- Keep the capability table empty until the worker has a separate secret scope and network policy.
- Provision only a SHA-256 capability digest in `private.training_verifier_capabilities`; never place the raw capability in SQL history.
- Mint the source-Storage JWT out of band with `role=authenticated`, `training_storage_verifier=true`, the exact capability ID/audience claims, a short expiry, and no signing material in either application container.
- Keep API and worker key sets environment-specific. A signing key ID remains in the worker public-key ring during in-flight job expiry, then may be removed after all jobs using it are terminal.
- Do not configure the API signing triplet unless the Phase 3C migration, scoped Storage identity, and worker are deployed and operational. Phase 3B alone still finishes successful source inspection as `publication_blocked`; Phase 3C replaces that terminal path with guarded promotion and finalization.

## Single-project published-media boundary

Phase 3C uses a second private bucket in the existing Supabase project. The verifier uploads exact verified WebP bytes with `upsert:false` to `sha256/{prefix}/{digest}.webp`, re-downloads them, and submits a canonical forty-item manifest to the guarded finalizer. Official learner authorization resolves only this manifest and fails closed when the latest full integrity audit failed or is older than the configured freshness interval.

The ordinary API's Supabase service-role credential bypasses Storage RLS and can overwrite or delete objects in either bucket. This is an accepted product limitation. Content-addressed paths, application code, Storage policies, immutable database manifests, and periodic SHA-256 audits prevent ordinary application mutation and detect persistent privileged tampering; they do not provide WORM protection against a compromised service-role key. Never describe this architecture as resistant to service-role compromise.

Publication and program activation remain disabled until the API and worker have separate Tarout secret scopes, scoped Storage policies have been exercised, clean and upgrade-shaped migrations pass, and an end-to-end staging publication plus integrity failure rehearsal succeeds. Draft upload and employee Draft Learning Preview continue to use `training-media`; official learner media must never fall back to it.
