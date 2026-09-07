import { describe, it, expect } from "vitest";
import { parseWindow, WINDOWS, DEFAULT_WINDOW } from "../../src/stats/queries";

describe("parseWindow", () => {
  it("accepts each known key", () => {
    expect(parseWindow("24h")).toBe("24h");
    expect(parseWindow("7d")).toBe("7d");
    expect(parseWindow("30d")).toBe("30d");
  });

  it("falls back to the default for anything unrecognised", () => {
    for (const raw of [undefined, "", "  ", "1d", "7D", "-7d", "1e300", "NaN"]) {
      expect(parseWindow(raw)).toBe(DEFAULT_WINDOW);
    }
  });

  // The lookup must not answer from Object.prototype. A plain `raw in WINDOWS`
  // returns true for "toString" and "constructor", which would hand a
  // WindowKey the rest of the module cannot map to a duration.
  it("does not treat inherited object properties as windows", () => {
    for (const raw of ["toString", "constructor", "hasOwnProperty", "__proto__"]) {
      expect(parseWindow(raw)).toBe(DEFAULT_WINDOW);
    }
  });

  it("maps every key to a distinct positive duration", () => {
    const values = Object.values(WINDOWS);
    expect(values.every((seconds) => Number.isInteger(seconds) && seconds > 0)).toBe(true);
    expect(new Set(values).size).toBe(values.length);
  });

  it("defaults to 7d", () => {
    expect(DEFAULT_WINDOW).toBe("7d");
  });
});
