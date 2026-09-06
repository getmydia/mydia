import { env, SELF, fetchMock } from "cloudflare:test";
import { describe, it, expect, beforeAll } from "vitest";
import { zipSync, strToU8 } from "fflate";
import { subdlApiKey } from "../../src/proxy/subdl";

beforeAll(() => {
  fetchMock.activate();
  fetchMock.disableNetConnect();
});

// Genuinely incompressible filler: deflate cannot shrink random bytes, so a
// zip built from this stays close to `size` on the wire. Needed so the
// "oversized body" tests below prove the streaming cap specifically --
// a same-byte-repeated buffer would compress to near nothing and, wrapped in
// a real .srt entry, get rejected by extractSubtitle's own unrelated checks
// either way, masking whether the download route's byte cap ever ran.
function randomBytes(size: number): Uint8Array {
  const out = new Uint8Array(size);
  const chunk = 65536;
  for (let offset = 0; offset < size; offset += chunk) {
    crypto.getRandomValues(out.subarray(offset, Math.min(offset + chunk, size)));
  }
  return out;
}

interface SearchResponseBody {
  subtitles: Array<Record<string, unknown>>;
}

interface ErrorBody {
  error: string;
  message?: string;
}

interface DownloadUrlBody {
  download_url: string;
  file_name: string;
  requests_used: unknown;
  requests_remaining: unknown;
}

describe("POST /api/v1/subtitles/search", () => {
  // The route itself can't be driven through this 503 branch via SELF.fetch:
  // vitest.config.ts carries a global SUBDL_API_KEY test binding fixed for the
  // whole pool, and mutating the imported `env` object does not propagate to
  // the bindings the dispatched worker actually reads (verified empirically --
  // the request still carried the real test key). subdlApiKey is exported
  // standalone for exactly this reason, matching tvdb-auth.ts's getTvdbToken.
  describe("subdlApiKey", () => {
    it("is null when the key is absent", () => {
      expect(subdlApiKey({ ...env, SUBDL_API_KEY: undefined })).toBeNull();
    });

    it("is null when the key is blank", () => {
      expect(subdlApiKey({ ...env, SUBDL_API_KEY: "   " })).toBeNull();
    });

    it("returns the key when present", () => {
      expect(subdlApiKey({ ...env, SUBDL_API_KEY: "a-real-key" })).toBe("a-real-key");
    });
  });

  it("returns the transformed wire shape", async () => {
    fetchMock
      .get("https://api.subdl.com")
      .intercept({ method: "GET", path: (p) => p.startsWith("/api/v1/subtitles") })
      .reply(200, {
        status: true,
        subtitles: [
          {
            url: "/subtitle/abc.zip",
            language: "EN",
            release_name: "Fictional.Film.2020",
            author: "some-uploader",
            hi: true,
            season: 2,
            episode: 5,
          },
        ],
        results: [
          {
            type: "movie",
            name: "Fictional Film",
            year: 2020,
            imdb_id: "tt9999999",
            tmdb_id: 12345,
          },
        ],
      });

    const res = await SELF.fetch("https://relay.mydia.dev/api/v1/subtitles/search", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query: "Fictional Film", languages: "en" }),
    });

    expect(res.status).toBe(200);
    const body = await res.json<SearchResponseBody>();
    expect(body.subtitles).toHaveLength(1);
    expect(body.subtitles[0]).toMatchObject({
      source: "SubDL",
      format: "srt",
      rating: null,
      download_count: null,
      release: "Fictional.Film.2020",
      language: "en",
      uploader: "some-uploader",
      hearing_impaired: true,
      foreign_parts_only: false,
      moviehash_match: false,
      season: 2,
      episode: 5,
      feature_type: "movie",
      title: "Fictional Film",
      year: 2020,
      imdb_id: "tt9999999",
      tmdb_id: 12345,
    });
    expect(typeof body.subtitles[0].id).toBe("string");
  });

  it("defaults feature fields to null when the upstream sends no results", async () => {
    fetchMock
      .get("https://api.subdl.com")
      .intercept({ method: "GET", path: (p) => p.startsWith("/api/v1/subtitles") })
      .reply(200, {
        status: true,
        subtitles: [{ url: "/subtitle/no-feature.zip", language: "fr", release_name: "Some.Release" }],
      });

    const res = await SELF.fetch("https://relay.mydia.dev/api/v1/subtitles/search", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query: "No Feature Title" }),
    });

    expect(res.status).toBe(200);
    const body = await res.json<SearchResponseBody>();
    expect(body.subtitles[0]).toMatchObject({
      feature_type: null,
      title: null,
      year: null,
      imdb_id: null,
      tmdb_id: null,
      uploader: "",
      hearing_impaired: false,
      season: null,
      episode: null,
    });
  });

  it("maps a status:false miss to an empty list, not an error", async () => {
    fetchMock
      .get("https://api.subdl.com")
      .intercept({ method: "GET", path: (p) => p.startsWith("/api/v1/subtitles") })
      .reply(200, { status: false, error: "No subtitles" });

    const res = await SELF.fetch("https://relay.mydia.dev/api/v1/subtitles/search", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query: "Unfindable Title" }),
    });

    expect(res.status).toBe(200);
    expect(await res.json<SearchResponseBody>()).toEqual({ subtitles: [] });
  });

  it("returns 502 for an unexpected upstream shape rather than an empty list", async () => {
    // An anomaly cached as "no subtitles exist" would pin that claim on every
    // install for the full search TTL, with nothing to invalidate it.
    fetchMock
      .get("https://api.subdl.com")
      .intercept({ method: "GET", path: (p) => p.startsWith("/api/v1/subtitles") })
      .reply(200, "<html>blocked</html>", {
        headers: { "content-type": "text/html" },
      });

    const res = await SELF.fetch("https://relay.mydia.dev/api/v1/subtitles/search", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query: "Anything" }),
    });

    expect(res.status).toBe(502);
  });

  it("returns 502 for a map response that is neither a hit nor a status:false miss", async () => {
    fetchMock
      .get("https://api.subdl.com")
      .intercept({ method: "GET", path: (p) => p.startsWith("/api/v1/subtitles") })
      .reply(200, { unexpected: "shape" });

    const res = await SELF.fetch("https://relay.mydia.dev/api/v1/subtitles/search", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query: "Anything Else" }),
    });

    expect(res.status).toBe(502);
  });

  it("returns 400 when no search identity is present", async () => {
    const res = await SELF.fetch("https://relay.mydia.dev/api/v1/subtitles/search", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ languages: "en" }),
    });

    expect(res.status).toBe(400);
    const body = await res.json<ErrorBody>();
    expect(body.error).toBe("Insufficient search criteria");
  });

  it("never caches a 502 anomaly: an identical retry hits SubDL again", async () => {
    fetchMock
      .get("https://api.subdl.com")
      .intercept({ method: "GET", path: (p) => p.startsWith("/api/v1/subtitles") })
      .reply(200, "not json at all", { headers: { "content-type": "text/plain" } });

    const first = await SELF.fetch("https://relay.mydia.dev/api/v1/subtitles/search", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query: "Retry Title" }),
    });
    expect(first.status).toBe(502);

    // A second interceptor is required: if the anomaly had been cached, this
    // request would never reach the mock and fetchMock would throw instead.
    fetchMock
      .get("https://api.subdl.com")
      .intercept({ method: "GET", path: (p) => p.startsWith("/api/v1/subtitles") })
      .reply(200, { status: true, subtitles: [] });

    const second = await SELF.fetch("https://relay.mydia.dev/api/v1/subtitles/search", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query: "Retry Title" }),
    });
    expect(second.status).toBe(200);
  });

  it("serves an identical search from cache regardless of JSON key order", async () => {
    fetchMock
      .get("https://api.subdl.com")
      .intercept({ method: "GET", path: (p) => p.startsWith("/api/v1/subtitles") })
      .reply(200, { status: true, subtitles: [] });

    const first = await SELF.fetch("https://relay.mydia.dev/api/v1/subtitles/search", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ query: "Cached Title", year: 2020 }),
    });
    expect(first.status).toBe(200);

    // Only one interceptor, so a second upstream call would throw.
    const second = await SELF.fetch("https://relay.mydia.dev/api/v1/subtitles/search", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ year: 2020, query: "Cached Title" }),
    });
    expect(second.status).toBe(200);
  });
});

describe("GET /api/v1/subtitles/download-url/:id", () => {
  it("returns a relay-hosted download url plus the file name, never SubDL's", async () => {
    const id = btoa("/subtitle/abc-123.zip").replace(/=+$/, "");
    const res = await SELF.fetch(
      `https://relay.mydia.dev/api/v1/subtitles/download-url/${id}`,
    );

    expect(res.status).toBe(200);
    const body = await res.json<DownloadUrlBody>();
    expect(body.download_url).toBe(
      `https://relay.mydia.dev/api/v1/subtitles/download/${id}`,
    );
    expect(body.file_name).toBe("abc-123.srt");
    // SubDL publishes no quota headers; reporting a number would be invention.
    expect(body.requests_used).toBeNull();
    expect(body.requests_remaining).toBeNull();
  });

  it("rejects a file id whose decoded path is not a subtitle zip", async () => {
    const hostile = btoa("/etc/passwd").replace(/=+$/, "");
    const res = await SELF.fetch(
      `https://relay.mydia.dev/api/v1/subtitles/download-url/${hostile}`,
    );
    expect(res.status).toBe(400);
  });
});

describe("GET /api/v1/subtitles/download/:id", () => {
  it("unwraps the archive and returns plain subtitle bytes", async () => {
    const zip = zipSync({ "sub.srt": strToU8("1\n00:00:01,000 --> 00:00:02,000\nline\n") });
    fetchMock
      .get("https://dl.subdl.com")
      .intercept({ method: "GET", path: "/subtitle/abc.zip" })
      // undici's mock reply serializes a bare Uint8Array as JSON (its numeric
      // indices become object keys); wrapping in Buffer is what sends it as
      // the raw bytes a real upstream would.
      .reply(200, Buffer.from(zip));

    const id = btoa("/subtitle/abc.zip").replace(/=+$/, "");
    const res = await SELF.fetch(`https://relay.mydia.dev/api/v1/subtitles/download/${id}`);

    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/octet-stream");
    expect(await res.text()).toContain("00:00:01,000");
  });

  it("rejects a file id whose decoded path is not a subtitle zip", async () => {
    const hostile = btoa("/etc/passwd").replace(/=+$/, "");
    const res = await SELF.fetch(`https://relay.mydia.dev/api/v1/subtitles/download/${hostile}`);
    expect(res.status).toBe(400);
  });

  it("never echoes an upstream body on an upstream error", async () => {
    // api.subdl.com is the one host that could echo the key back, so no
    // upstream body is forwarded on this route, ever.
    fetchMock
      .get("https://dl.subdl.com")
      .intercept({ method: "GET", path: "/subtitle/leak.zip" })
      .reply(403, "api_key=SUPERSECRET rejected");

    const id = btoa("/subtitle/leak.zip").replace(/=+$/, "");
    const res = await SELF.fetch(`https://relay.mydia.dev/api/v1/subtitles/download/${id}`);

    expect(res.status).toBe(502);
    const text = await res.text();
    expect(text).not.toContain("SUPERSECRET");
    expect(text).not.toContain("api_key");
  });

  it("maps a 404 archive to a distinct 404, still without echoing the body", async () => {
    fetchMock
      .get("https://dl.subdl.com")
      .intercept({ method: "GET", path: "/subtitle/gone.zip" })
      .reply(404, "gone");

    const id = btoa("/subtitle/gone.zip").replace(/=+$/, "");
    const res = await SELF.fetch(`https://relay.mydia.dev/api/v1/subtitles/download/${id}`);

    expect(res.status).toBe(404);
    expect(await res.text()).not.toContain("gone");
  });

  it("returns 502 rather than the archive's bytes when the zip holds no subtitle", async () => {
    const zip = zipSync({ "cover.jpg": strToU8("binary") });
    fetchMock
      .get("https://dl.subdl.com")
      .intercept({ method: "GET", path: "/subtitle/no-sub.zip" })
      .reply(200, Buffer.from(zip));

    const id = btoa("/subtitle/no-sub.zip").replace(/=+$/, "");
    const res = await SELF.fetch(`https://relay.mydia.dev/api/v1/subtitles/download/${id}`);

    expect(res.status).toBe(502);
  });

  it("rejects a response whose declared Content-Length is at the download cap, before buffering it", async () => {
    // Cheap early-out ahead of the real streaming cap: the body here is tiny
    // -- if the route buffered it first and only rejected afterward, this
    // would still incidentally pass, so the point is that a real oversized
    // body is never required to prove the header check alone fires.
    fetchMock
      .get("https://dl.subdl.com")
      .intercept({ method: "GET", path: "/subtitle/huge.zip" })
      .reply(200, Buffer.from("short body"), {
        headers: { "content-length": "2000000" },
      });

    const id = btoa("/subtitle/huge.zip").replace(/=+$/, "");
    const res = await SELF.fetch(`https://relay.mydia.dev/api/v1/subtitles/download/${id}`);

    expect(res.status).toBe(502);
    expect(await res.text()).not.toContain("short body");
  });

  // The Content-Length check above is only a cheap early-out for an honest
  // server. These three prove the real bound: a streaming read that counts
  // actual bytes and does not trust the header at all, since it can be
  // absent, non-numeric, or simply a lie -- and dl.subdl.com serves content
  // uploaded by arbitrary third parties, not a cooperating host.
  describe("streaming byte cap (Content-Length is not trusted)", () => {
    it("rejects an oversized body with no Content-Length header at all", async () => {
      // A real (if pointless) zip around 3MB of incompressible content --
      // under the old 20MB expansion cap, so the ONLY thing that can reject
      // this is the download route's own byte cap on the transfer itself.
      const big = Buffer.from(zipSync({ "big.srt": randomBytes(3_000_000) }));
      // undici's mock does not auto-set content-length unless told to
      // (verified: a bare .reply(200, buffer) yields no headers at all), so
      // this reproduces a real "absent header" upstream with no extra work.
      fetchMock
        .get("https://dl.subdl.com")
        .intercept({ method: "GET", path: "/subtitle/nolen.zip" })
        .reply(200, big);

      const id = btoa("/subtitle/nolen.zip").replace(/=+$/, "");
      const res = await SELF.fetch(`https://relay.mydia.dev/api/v1/subtitles/download/${id}`);

      expect(res.status).toBe(502);
    });

    it("rejects an oversized body behind a lying, small Content-Length", async () => {
      const big = Buffer.from(zipSync({ "big.srt": randomBytes(3_000_000) }));
      fetchMock
        .get("https://dl.subdl.com")
        .intercept({ method: "GET", path: "/subtitle/lying.zip" })
        .reply(200, big, { headers: { "content-length": "10" } });

      const id = btoa("/subtitle/lying.zip").replace(/=+$/, "");
      const res = await SELF.fetch(`https://relay.mydia.dev/api/v1/subtitles/download/${id}`);

      expect(res.status).toBe(502);
    });

    it("still succeeds for a normal small archive with no Content-Length header", async () => {
      const zip = zipSync({
        "sub.srt": strToU8("1\n00:00:01,000 --> 00:00:02,000\nno header\n"),
      });
      fetchMock
        .get("https://dl.subdl.com")
        .intercept({ method: "GET", path: "/subtitle/plain.zip" })
        .reply(200, Buffer.from(zip));

      const id = btoa("/subtitle/plain.zip").replace(/=+$/, "");
      const res = await SELF.fetch(`https://relay.mydia.dev/api/v1/subtitles/download/${id}`);

      expect(res.status).toBe(200);
      expect(await res.text()).toContain("00:00:01,000");
    });
  });
});
