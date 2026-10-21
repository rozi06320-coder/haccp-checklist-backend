# Organization Manager push delivery

Organization Manager delivery is fail-closed behind two independent gates.
The database producer gate defaults disabled, so migration application neither
creates backlog nor sends requests. The server-only worker gate also defaults
disabled. Do not enable either gate until the production preflight has passed.

## Delivery guarantees

- Delivery is at-least-once. A worker crash after provider acceptance and
  before database completion can produce a duplicate notification.
- The notification UUID is sent as a stable Web Push `Topic`, allowing browser
  push providers to collapse duplicate pending messages when supported.
- Every send requires a current lease-bound database authorization check.
  Disabled subscriptions and ineligible managers are not sent to.
- Payloads contain generic copy and a notification identifier. They do not
  contain issue descriptions, employee names, checklist answers, or financial
  data.
- DNS and endpoint preparation happens before the final authorization. The
  final authorization is the last awaited operation before socket creation.
  A process-local authorization-to-socket race cannot be eliminated, so
  immediate revocation is best-effort at that final boundary.

## Production preflight

1. Apply and verify migration
   `20261021130000_organization_manager_push_delivery_worker.sql` before
   starting a worker built from the matching release.
2. Confirm the Tarout application runs continuously, delivers termination
   signals, and allows enough shutdown time for the worker's bounded requests.
   If that cannot be guaranteed, keep the feature disabled until a separate
   bounded command entry point can be added and invoked by a Tarout scheduled
   command task.
3. Configure the existing Supabase service credential and VAPID credentials as
   server-only secrets. They must never be exposed to a browser build.
4. Confirm `NODE_USE_ENV_PROXY`, `--use-env-proxy`, and
   `NODE_TLS_REJECT_UNAUTHORIZED=0` are absent. The worker refuses to start
   under those unsafe settings and uses its own direct HTTPS agent; ordinary
   `HTTP_PROXY`/`HTTPS_PROXY` values are not inherited by that agent.
5. Enforce platform/network egress rules for TCP 443 to the approved FCM,
   Mozilla, Apple, and Windows push provider host families. The worker validates
   and pins public DNS results, but application checks are not a substitute for
   an independently enforced egress policy. Keep delivery disabled if Tarout
   cannot enforce or explicitly guarantee this boundary.
6. Verify outbound TLS, DNS, request timeout, replica count, deployment
   shutdown behavior, and sanitized worker diagnostics in a non-production
   environment.
7. Review the migration's count of active subscriptions disabled by the
   corrected endpoint validator before production application.
8. As the database owner (never through the ordinary service-role API), call
   `private.configure_organization_manager_push_producer(true, statement_timestamp())`
   in a controlled change window. The cutoff terminalizes any older unsent
   Maintenance manager deliveries instead of releasing a stale backlog. Set it
   back to `false` to stop production and terminalize its unsent backlog. Only
   after this explicit producer activation should the separate worker runtime
   gate be considered.

Read-only preflight query (uses the new migration's exact SQL acceptance
expression without returning endpoints or key material):

```sql
select count(*) as active_subscriptions_that_would_be_disabled
from public.push_subscriptions subscription
where subscription.disabled_at is null
  and not (
    subscription.endpoint = pg_catalog.btrim(subscription.endpoint)
    and pg_catalog.length(subscription.endpoint) between 12 and 4096
    and subscription.endpoint ~ '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|push\.services\.mozilla\.com|([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)*push\.apple\.com|([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)*notify\.windows\.com)/[^@#\\[:space:][:cntrl:]]+$'
  );
```

No separate paid service is required by the implementation. Tarout documents
background workers and scheduled command/HTTP jobs, but this repository has no
checked-in Tarout deployment contract proving which capability or egress policy
is enabled for the current application.
