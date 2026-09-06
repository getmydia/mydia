import { describe, it, expect } from "vitest";
import { forwardParams } from "../../src/proxy/forward";

describe("forwardParams", () => {
  it("forwards arbitrary params verbatim, with no allowlist", () => {
    const incoming = new URLSearchParams({
      language: "en-US",
      append_to_response: "credits,keywords,images,videos,recommendations",
      some_future_param: "value",
    });

    const out = forwardParams(incoming, { api_key: "SECRET" });

    expect(out.get("language")).toBe("en-US");
    expect(out.get("append_to_response")).toBe(
      "credits,keywords,images,videos,recommendations",
    );
    expect(out.get("some_future_param")).toBe("value");
  });

  it("injects the credential", () => {
    const out = forwardParams(new URLSearchParams(), { api_key: "SECRET" });
    expect(out.get("api_key")).toBe("SECRET");
  });

  it("drops a caller-supplied api_key so it cannot be sent twice", () => {
    // TMDB resolves a duplicated api_key unpredictably; the relay has always
    // stripped the caller's copy rather than forwarding it.
    const incoming = new URLSearchParams({ api_key: "ATTACKER", language: "fr" });

    const out = forwardParams(incoming, { api_key: "SECRET" });

    expect(out.getAll("api_key")).toEqual(["SECRET"]);
    expect(out.get("language")).toBe("fr");
  });

  it("preserves repeated params", () => {
    const incoming = new URLSearchParams();
    incoming.append("with_genres", "28");
    incoming.append("with_genres", "12");

    const out = forwardParams(incoming, {});

    expect(out.getAll("with_genres")).toEqual(["28", "12"]);
  });
});
