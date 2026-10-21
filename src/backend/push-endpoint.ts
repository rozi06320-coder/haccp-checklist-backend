// Keep this expression byte-for-byte equivalent to
// private.browser_push_endpoint_is_allowed(text). Browser-created endpoints
// use canonical lowercase provider hosts without an explicit default port.
const providerLabel = "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?";
const browserPushEndpointPattern = new RegExp(
  `^https://(?:fcm\\.googleapis\\.com|updates\\.push\\.services\\.mozilla\\.com|push\\.services\\.mozilla\\.com|(?:${providerLabel}\\.)*push\\.apple\\.com|(?:${providerLabel}\\.)*notify\\.windows\\.com)/[^@#\\\\\\s\\x00-\\x1f\\x7f]+$`,
);

/**
 * Browser push endpoints are outbound network capabilities. Restricting them
 * to browser-vendor push services prevents callers from turning the backend
 * into an arbitrary HTTPS client. The production network must independently
 * restrict egress to the same providers; application validation cannot pin a
 * DNS answer used later by the HTTP transport.
 */
export function isAllowedBrowserPushEndpoint(endpoint: string): boolean {
  if (endpoint !== endpoint.trim() || endpoint.length < 12 || endpoint.length > 4_096) return false;
  if (!browserPushEndpointPattern.test(endpoint)) return false;
  try {
    const parsed = new URL(endpoint);
    return parsed.protocol === "https:"
      && !parsed.username
      && !parsed.password
      && !parsed.port
      && parsed.pathname !== "/";
  } catch {
    return false;
  }
}
