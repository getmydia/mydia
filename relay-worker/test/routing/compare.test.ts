import { describe, it, expect } from "vitest";
import { compareResponses, firstDifference, readCapped } from "../../src/routing/compare";

const bytes = (value: unknown): Uint8Array =>
  new TextEncoder().encode(typeof value === "string" ? value : JSON.stringify(value));

describe("compareResponses", () => {
  it("matches identical bodies", () => {
    expect(
      compareResponses({ status: 200, bytes: bytes({ a: 1 }) }, { status: 200, bytes: bytes({ a: 1 }) }),
    ).toEqual({ outcome: "match" });
  });

  it("matches JSON that differs only in key order", () => {
    expect(
      compareResponses(
        { status: 200, bytes: bytes('{"a":1,"b":[1,2]}') },
        { status: 200, bytes: bytes('{"b":[1,2],"a":1}') },
      ),
    ).toEqual({ outcome: "match" });
  });

  it("reports a status mismatch before looking at bodies", () => {
    expect(
      compareResponses({ status: 200, bytes: bytes({}) }, { status: 404, bytes: bytes({}) }),
    ).toEqual({ outcome: "status_mismatch" });
  });

  it("points at the first differing JSON path", () => {
    expect(
      compareResponses(
        { status: 200, bytes: bytes({ results: [{ name: "Quantum Harbour" }, { name: "Glass Meridian" }] }) },
        { status: 200, bytes: bytes({ results: [{ name: "Quantum Harbour" }, { name: "Glass Meridan" }] }) },
      ),
    ).toEqual({ outcome: "body_mismatch", diff: "$.results[1].name" });
  });

  it("ignores the same volatile keys as the contract diff", () => {
    expect(
      compareResponses(
        { status: 200, bytes: bytes({ version: "0.16.0", created: "2026-09-18T00:00:00Z", status: "ok" }) },
        { status: 200, bytes: bytes({ version: "1.0.0", created: "2026-09-18T00:00:01Z", status: "ok" }) },
      ),
    ).toEqual({ outcome: "match" });
  });

  it("still compares a nested version and an object-shaped created", () => {
    expect(firstDifference({ a: { version: 1 } }, { a: { version: 2 } }, "$")).toBe("$.a.version");
    expect(
      firstDifference(
        { created: { type: "/type/datetime", value: "2008" } },
        { created: { type: "/type/datetime", value: "2009" } },
        "$",
      ),
    ).toBe("$.created.value");
  });

  it("reports a missing key and a length change", () => {
    expect(firstDifference({ a: 1 }, { a: 1, b: 2 }, "$")).toBe("$.b");
    expect(firstDifference([1, 2], [1], "$")).toBe("$.length");
    expect(firstDifference({ a: [1] }, { a: { 0: 1 } }, "$")).toBe("$.a");
  });

  it("compares non-JSON bodies byte for byte", () => {
    expect(
      compareResponses(
        { status: 200, bytes: new Uint8Array([0xff, 0xd8, 1]) },
        { status: 200, bytes: new Uint8Array([0xff, 0xd8, 2]) },
      ),
    ).toEqual({ outcome: "body_mismatch", diff: "bytes" });
  });

  it("skips bodies over the cap once the statuses agree", () => {
    expect(compareResponses({ status: 200, bytes: null }, { status: 200, bytes: bytes({}) })).toEqual({
      outcome: "skipped_large",
    });
  });
});

describe("readCapped", () => {
  it("reads a body under the cap", async () => {
    expect(await readCapped(new Response("hello").body, 10)).toEqual(bytes("hello"));
  });

  it("returns an empty body for null", async () => {
    expect(await readCapped(null, 10)).toEqual(new Uint8Array(0));
  });

  it("gives up past the cap", async () => {
    expect(await readCapped(new Response("x".repeat(11)).body, 10)).toBeNull();
  });
});
