import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  base64urlToBuffer,
  bufferToBase64url,
  decodeCreationOptions,
  decodeRequestOptions,
  deviceName,
  encodeAssertion,
  encodeRegistration,
  errorMessage,
  errorReason,
  passkeysSupported,
} from "../../js/hooks/passkey.mjs";

const bytes = (...xs) => new Uint8Array(xs).buffer;

test("base64url round-trips without padding", () => {
  const buf = bytes(251, 255, 0, 1);
  const encoded = bufferToBase64url(buf);
  assert.equal(encoded, "-_8AAQ");
  assert.deepEqual(new Uint8Array(base64urlToBuffer(encoded)), new Uint8Array(buf));
});

test("creation options decode the binary fields", () => {
  const decoded = decodeCreationOptions({
    challenge: "AQID",
    rp: { id: "mydia.test", name: "Mydia" },
    user: { id: "BAU", name: "viewer", displayName: "viewer" },
    excludeCredentials: [{ type: "public-key", id: "Bg", transports: ["usb"] }],
  });
  assert.deepEqual(new Uint8Array(decoded.challenge), new Uint8Array([1, 2, 3]));
  assert.deepEqual(new Uint8Array(decoded.user.id), new Uint8Array([4, 5]));
  assert.deepEqual(new Uint8Array(decoded.excludeCredentials[0].id), new Uint8Array([6]));
  assert.equal(decoded.rp.id, "mydia.test");
});

test("request options decode the challenge and allow list", () => {
  const decoded = decodeRequestOptions({ challenge: "AQID", rpId: "mydia.test", allowCredentials: [] });
  assert.deepEqual(new Uint8Array(decoded.challenge), new Uint8Array([1, 2, 3]));
  assert.deepEqual(decoded.allowCredentials, []);
});

test("credentials encode to the shape the server expects", () => {
  const registration = encodeRegistration({
    id: "Bg",
    rawId: bytes(6),
    type: "public-key",
    response: {
      attestationObject: bytes(1),
      clientDataJSON: bytes(2),
      getTransports: () => ["internal"],
    },
  });
  assert.deepEqual(registration, {
    id: "Bg",
    rawId: "Bg",
    type: "public-key",
    response: { attestationObject: "AQ", clientDataJSON: "Ag", transports: ["internal"] },
  });

  const assertion = encodeAssertion({
    id: "Bg",
    rawId: bytes(6),
    type: "public-key",
    response: { authenticatorData: bytes(1), clientDataJSON: bytes(2), signature: bytes(3), userHandle: null },
  });
  assert.equal(assertion.response.userHandle, null);
  assert.equal(assertion.response.signature, "Aw");
});

test("support needs a secure context and the API", () => {
  assert.equal(passkeysSupported({ isSecureContext: false, PublicKeyCredential: {}, navigator: { credentials: {} } }), false);
  assert.equal(passkeysSupported({ isSecureContext: true, navigator: { credentials: {} } }), false);
  assert.equal(passkeysSupported({ isSecureContext: true, PublicKeyCredential: {}, navigator: { credentials: {} } }), true);
});

test("device names come from the user agent", () => {
  const firefoxLinux = "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0";
  const chromeMac =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36";
  const safariIphone =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
  const edgeWindows =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36 Edg/130.0";
  const chromeAndroid =
    "Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36";

  assert.equal(deviceName(firefoxLinux), "Passkey on Firefox, Linux");
  assert.equal(deviceName(chromeMac), "Passkey on Chrome, macOS");
  assert.equal(deviceName(safariIphone), "Passkey on Safari, iOS");
  assert.equal(deviceName(edgeWindows), "Passkey on Edge, Windows");
  assert.equal(deviceName(chromeAndroid), "Passkey on Chrome, Android");
  assert.equal(deviceName(""), "Passkey");
});

test("errors map to reasons and copy", () => {
  assert.equal(errorReason({ name: "NotAllowedError" }), "cancelled");
  assert.equal(errorReason({ name: "AbortError" }), "cancelled");
  assert.equal(errorReason({ name: "InvalidStateError" }), "duplicate");
  assert.equal(errorReason(new Error("boom")), "failed");
  assert.equal(errorMessage("duplicate"), "This device already has a passkey for this account");
  assert.equal(errorMessage("failed"), "Passkey not recognised");
});

test("initPasskeyLogin runs at startup, not inside ThemeToggle", () => {
  const src = readFileSync(new URL("../../js/app.js", import.meta.url), "utf8");
  const themeIdx = src.indexOf("const ThemeToggle");
  const connectIdx = src.indexOf("liveSocket.connect()");
  const initIdx = src.indexOf("initPasskeyLogin(document)");
  assert.ok(initIdx > connectIdx, "expected init after liveSocket.connect()");
  const themeBlock = src.slice(themeIdx, initIdx);
  assert.ok(!themeBlock.includes("initPasskeyLogin"), "expected init outside ThemeToggle");
});
