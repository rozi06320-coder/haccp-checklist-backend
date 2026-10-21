const exactPushHosts = new Set([
  "fcm.googleapis.com",
  "push.services.mozilla.com",
  "updates.push.services.mozilla.com",
]);

function hostMatchesSuffix(hostname: string, suffix: string) {
  return hostname === suffix || hostname.endsWith(`.${suffix}`);
}

/**
 * Browser push endpoints are outbound network capabilities. Restricting them
 * to browser-vendor push services prevents callers from turning the backend
 * into an arbitrary HTTPS client. The production network must independently
 * restrict egress to the same providers; application validation cannot pin a
 * DNS answer used later by the HTTP transport.
 */
export function isAllowedBrowserPushEndpoint(endpoint: string): boolean {
  if (endpoint !== endpoint.trim() || endpoint.length < 12 || endpoint.length > 4_096) return false;
  let parsed: URL;
  try {
    parsed = new URL(endpoint);
  } catch {
    return false;
  }
  if (parsed.protocol !== "https:" || parsed.username || parsed.password || parsed.hash) return false;
  if (parsed.port && parsed.port !== "443") return false;
  if (parsed.pathname === "/") return false;
  const hostname = parsed.hostname.toLowerCase();
  return exactPushHosts.has(hostname)
    || hostMatchesSuffix(hostname, "push.apple.com")
    || hostMatchesSuffix(hostname, "notify.windows.com");
}
