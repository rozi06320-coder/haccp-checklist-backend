import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { isAllowedBrowserPushEndpoint } from "./push-endpoint";

describe("browser push endpoint validation", () => {
  it("accepts the supported browser push providers", () => {
    for (const endpoint of [
      "https://fcm.googleapis.com/fcm/send/example",
      "https://updates.push.services.mozilla.com/wpush/v2/example",
      "https://web.push.apple.com/QHexample",
      "https://wns2-am3p.notify.windows.com/w/?token=example",
    ]) assert.equal(isAllowedBrowserPushEndpoint(endpoint), true, endpoint);
  });

  it("rejects private, reserved, loopback, credentialed, unsafe-port and lookalike endpoints", () => {
    for (const endpoint of [
      "https://127.0.0.1/push", "https://[::1]/push", "https://10.0.0.1/push",
      "https://169.254.169.254/latest/meta-data", "https://user:pass@fcm.googleapis.com/push",
      "https://fcm.googleapis.com:8443/push", "https://fcm.googleapis.com.evil.invalid/push",
      "https://evil.invalid/push", "http://fcm.googleapis.com/push",
      "https://fcm.googleapis.com/push#fragment", " https://fcm.googleapis.com/push",
    ]) assert.equal(isAllowedBrowserPushEndpoint(endpoint), false, endpoint);
  });
});
