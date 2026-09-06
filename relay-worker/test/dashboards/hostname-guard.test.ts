import { describe, it, expect } from "vitest";
import { adminHostnameBlocked } from "../../src/dashboards/hostname-guard";

// The guard's whole job is to answer one question: may a request to /admin/*
// on this hostname reach the dashboards? These are unit tests rather than
// SELF.fetch integration tests because the security-relevant case -- the
// variable being unset entirely -- cannot be expressed through the Miniflare
// bindings, which always provide it.
describe("adminHostnameBlocked", () => {
  const STAGING = "mydia-relay-staging.someacct.workers.dev";

  it("blocks every workers.dev hostname when nothing is configured", () => {
    expect(adminHostnameBlocked(STAGING, undefined)).toBe(true);
    expect(adminHostnameBlocked("mydia-relay.someacct.workers.dev", undefined)).toBe(true);
    expect(adminHostnameBlocked("a1b2c3-mydia-relay.someacct.workers.dev", undefined)).toBe(true);
  });

  it("blocks every workers.dev hostname when the configured value is blank", () => {
    expect(adminHostnameBlocked(STAGING, "")).toBe(true);
    expect(adminHostnameBlocked(STAGING, "   ")).toBe(true);
  });

  it("allows the exact configured hostname", () => {
    expect(adminHostnameBlocked(STAGING, STAGING)).toBe(false);
  });

  it("blocks a versioned preview URL derived from the configured hostname", () => {
    expect(adminHostnameBlocked(`a1b2c3-${STAGING}`, STAGING)).toBe(true);
  });

  it("blocks a different Worker on the same account subdomain", () => {
    expect(adminHostnameBlocked("mydia-relay.someacct.workers.dev", STAGING)).toBe(true);
  });

  it("matches exactly, so a case mismatch fails closed", () => {
    expect(adminHostnameBlocked(STAGING, STAGING.toUpperCase())).toBe(true);
  });

  it("never blocks a non-workers.dev hostname, configured or not", () => {
    expect(adminHostnameBlocked("relay.mydia.dev", undefined)).toBe(false);
    expect(adminHostnameBlocked("relay.mydia.dev", STAGING)).toBe(false);
    expect(adminHostnameBlocked("localhost", undefined)).toBe(false);
  });
});
