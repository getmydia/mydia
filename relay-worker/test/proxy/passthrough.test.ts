import { SELF, fetchMock } from "cloudflare:test";
import { describe, it, expect, beforeAll, afterEach } from "vitest";

beforeAll(() => {
  fetchMock.activate();
  fetchMock.disableNetConnect();
});

afterEach(() => fetchMock.assertNoPendingInterceptors());

describe("pass-through routes", () => {
  // -- OpenLibrary ---------------------------------------------------------

  it("proxies an openlibrary isbn lookup", async () => {
    fetchMock
      .get("https://openlibrary.org")
      .intercept({ method: "GET", path: (p) => p.includes("9780000000001") })
      .reply(200, { title: "Invented Book" });

    const res = await SELF.fetch(
      "https://relay.mydia.dev/openlibrary/isbn/9780000000001",
    );

    expect(res.status).toBe(200);
    expect(await res.json()).toMatchObject({ title: "Invented Book" });
  });

  // open_library/handler.ex's get_by_isbn/2 does not hit
  // /isbn/:isbn.json (that endpoint does not exist on Open Library) -- it
  // calls the Books API at /api/books with bibkeys=ISBN:<isbn>, jscmd=data
  // and format=json (open_library/handler.ex:8-12).
  it("hits the Open Library Books API, not an /isbn/*.json path", async () => {
    let seenPath = "";
    fetchMock
      .get("https://openlibrary.org")
      .intercept({
        method: "GET",
        path: (p) => {
          seenPath = p;
          return p.startsWith("/api/books");
        },
      })
      .reply(200, { "ISBN:9780000000002": { title: "Another Book" } });

    await SELF.fetch("https://relay.mydia.dev/openlibrary/isbn/9780000000002");

    expect(seenPath).toContain("bibkeys=ISBN%3A9780000000002");
    expect(seenPath).toContain("jscmd=data");
    expect(seenPath).toContain("format=json");
  });

  it("forwards the caller's query params on openlibrary search", async () => {
    let seenPath = "";
    fetchMock
      .get("https://openlibrary.org")
      .intercept({
        method: "GET",
        path: (p) => {
          seenPath = p;
          return p.startsWith("/search.json");
        },
      })
      .reply(200, { docs: [] });

    await SELF.fetch(
      "https://relay.mydia.dev/openlibrary/search?q=invented+title&author=nobody",
    );

    expect(seenPath).toContain("q=invented");
    expect(seenPath).toContain("author=nobody");
  });

  // open_library/handler.ex's get_work/2 and get_author/2 declare `_params`
  // and call Client.get/1 with no :params option, so a caller-supplied query
  // string must not leak upstream.
  it("does not forward query params on the works route", async () => {
    let seenPath = "";
    fetchMock
      .get("https://openlibrary.org")
      .intercept({
        method: "GET",
        path: (p) => {
          seenPath = p;
          return p.startsWith("/works/OL1234W");
        },
      })
      .reply(200, { title: "A Work" });

    await SELF.fetch(
      "https://relay.mydia.dev/openlibrary/works/OL1234W?foo=bar",
    );

    expect(seenPath).toBe("/works/OL1234W.json");
  });

  it("does not forward query params on the authors route", async () => {
    let seenPath = "";
    fetchMock
      .get("https://openlibrary.org")
      .intercept({
        method: "GET",
        path: (p) => {
          seenPath = p;
          return p.startsWith("/authors/OL5678A");
        },
      })
      .reply(200, { name: "An Author" });

    await SELF.fetch(
      "https://relay.mydia.dev/openlibrary/authors/OL5678A?foo=bar",
    );

    expect(seenPath).toBe("/authors/OL5678A.json");
  });

  // -- MusicBrainz -----------------------------------------------------

  it("sends a User-Agent to MusicBrainz, which rejects requests without one", async () => {
    let sawUserAgent = false;
    fetchMock
      .get("https://musicbrainz.org")
      .intercept({
        method: "GET",
        path: (p) => p.startsWith("/ws/2/artist"),
        headers: (h) => {
          sawUserAgent = Boolean(h["user-agent"]);
          return true;
        },
      })
      .reply(200, { id: "abc" });

    await SELF.fetch("https://relay.mydia.dev/music/artist/abc");
    expect(sawUserAgent).toBe(true);
  });

  // The exact string matters: it is what MusicBrainz's rate limiting keys
  // on. Copied verbatim from music/client.ex:9.
  it("sends the exact MusicBrainz User-Agent string", async () => {
    let seenUserAgent: string | undefined;
    fetchMock
      .get("https://musicbrainz.org")
      .intercept({
        method: "GET",
        path: (p) => p.startsWith("/ws/2/artist/def"),
        headers: (h) => {
          seenUserAgent = h["user-agent"] as string | undefined;
          return true;
        },
      })
      .reply(200, { id: "def" });

    await SELF.fetch("https://relay.mydia.dev/music/artist/def");

    expect(seenUserAgent).toBe(
      "MetadataRelay/1.0 ( https://github.com/mydia-org/mydia )",
    );
  });

  // music/client.ex's get_mb/2 always prepends fmt: "json" -- without it
  // MusicBrainz answers with XML, which nothing downstream can parse.
  it("always asks MusicBrainz for JSON via fmt=json", async () => {
    let seenPath = "";
    fetchMock
      .get("https://musicbrainz.org")
      .intercept({
        method: "GET",
        path: (p) => {
          seenPath = p;
          return p.startsWith("/ws/2/artist/ghi");
        },
      })
      .reply(200, { id: "ghi" });

    await SELF.fetch("https://relay.mydia.dev/music/artist/ghi");

    expect(seenPath).toContain("fmt=json");
  });

  // music/handler.ex's get_artist/2, get_release/2, get_release_group/2 and
  // get_recording/2 all declare `_params` and inject their own `inc=` value
  // -- the caller's query string is never forwarded, and dropping the
  // server-chosen inc= would silently thin out every music detail response.
  it("injects the artist inc= value and ignores caller query params", async () => {
    let seenPath = "";
    fetchMock
      .get("https://musicbrainz.org")
      .intercept({
        method: "GET",
        path: (p) => {
          seenPath = p;
          return p.startsWith("/ws/2/artist/jkl");
        },
      })
      .reply(200, { id: "jkl" });

    await SELF.fetch("https://relay.mydia.dev/music/artist/jkl?inc=nothing");

    expect(seenPath).toContain("inc=url-rels%2Bgenres%2Brelease-groups");
    expect(seenPath).not.toContain("inc=nothing");
  });

  it("injects the release inc= value", async () => {
    let seenPath = "";
    fetchMock
      .get("https://musicbrainz.org")
      .intercept({
        method: "GET",
        path: (p) => {
          seenPath = p;
          return p.startsWith("/ws/2/release/mno");
        },
      })
      .reply(200, { id: "mno" });

    await SELF.fetch("https://relay.mydia.dev/music/release/mno");

    expect(seenPath).toContain(
      "inc=recordings%2Bartist-credits%2Blabels%2Brelease-groups%2Bgenres",
    );
  });

  it("injects the release-group inc= value", async () => {
    let seenPath = "";
    fetchMock
      .get("https://musicbrainz.org")
      .intercept({
        method: "GET",
        path: (p) => {
          seenPath = p;
          return p.startsWith("/ws/2/release-group/pqr");
        },
      })
      .reply(200, { id: "pqr" });

    await SELF.fetch("https://relay.mydia.dev/music/release-group/pqr");

    expect(seenPath).toContain("inc=releases%2Bartist-credits%2Bgenres");
  });

  it("injects the recording inc= value", async () => {
    let seenPath = "";
    fetchMock
      .get("https://musicbrainz.org")
      .intercept({
        method: "GET",
        path: (p) => {
          seenPath = p;
          return p.startsWith("/ws/2/recording/stu");
        },
      })
      .reply(200, { id: "stu" });

    await SELF.fetch("https://relay.mydia.dev/music/recording/stu");

    expect(seenPath).toContain("inc=releases%2Bartist-credits%2Bgenres");
  });

  // music/handler.ex's search/1 picks the upstream resource straight from
  // the caller's `type` param (Client.get_mb("/#{type}", ...)) -- it is not
  // a fixed /release-group endpoint.
  it("routes music search to the resource named by the type param", async () => {
    let seenPath = "";
    fetchMock
      .get("https://musicbrainz.org")
      .intercept({
        method: "GET",
        path: (p) => {
          seenPath = p;
          return p.startsWith("/ws/2/recording");
        },
      })
      .reply(200, { recordings: [] });

    await SELF.fetch(
      "https://relay.mydia.dev/music/search?query=Invented+Song&type=recording",
    );

    expect(seenPath.startsWith("/ws/2/recording")).toBe(true);
    expect(seenPath).toContain("query=Invented");
    expect(seenPath).toContain("fmt=json");
  });

  it("rejects a music search missing query or type", async () => {
    const res = await SELF.fetch(
      "https://relay.mydia.dev/music/search?query=only",
    );

    expect(res.status).toBe(400);
    expect(await res.json()).toMatchObject({
      error: "Missing required parameters: query, type",
    });
  });

  // -- Cover Art Archive -----------------------------------------------

  it("gives music cover art the 90 day images TTL", async () => {
    fetchMock
      .get("https://coverartarchive.org")
      .intercept({ method: "GET", path: (p) => p.includes("abc") })
      .reply(200, { images: [] });

    const res = await SELF.fetch("https://relay.mydia.dev/music/cover/abc");
    expect(res.headers.get("cache-control")).toContain("s-maxage=7776000");
  });

  // music/client.ex's get_caa/1 sends only a User-Agent header, no
  // accept -- distinct from the MusicBrainz JSON client.
  it("requests the 500px cover first", async () => {
    let seenPath = "";
    fetchMock
      .get("https://coverartarchive.org")
      .intercept({
        method: "GET",
        path: (p) => {
          seenPath = p;
          return p.includes("vwx");
        },
      })
      .reply(200, "binary-image-bytes");

    await SELF.fetch("https://relay.mydia.dev/music/cover/vwx");

    expect(seenPath).toBe("/release/vwx/front-500");
  });

  // music/handler.ex's get_cover_art/1 falls back to the full-size /front
  // only when the 500px variant is missing (404), and the router serves the
  // successful body back with content-type image/jpeg regardless of upstream
  // content-type (router.ex's handle_image_request/2).
  it("falls back to the full-size cover when the 500px variant is missing", async () => {
    fetchMock
      .get("https://coverartarchive.org")
      .intercept({ method: "GET", path: "/release/yz1/front-500" })
      .reply(404, "not found");

    fetchMock
      .get("https://coverartarchive.org")
      .intercept({ method: "GET", path: "/release/yz1/front" })
      .reply(200, "full-size-bytes");

    const res = await SELF.fetch("https://relay.mydia.dev/music/cover/yz1");

    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("image/jpeg");
    expect(await res.text()).toBe("full-size-bytes");
  });

  it("answers 404 when both cover sizes are missing", async () => {
    fetchMock
      .get("https://coverartarchive.org")
      .intercept({ method: "GET", path: "/release/missing/front-500" })
      .reply(404, "not found");

    fetchMock
      .get("https://coverartarchive.org")
      .intercept({ method: "GET", path: "/release/missing/front" })
      .reply(404, "not found");

    const res = await SELF.fetch(
      "https://relay.mydia.dev/music/cover/missing",
    );

    expect(res.status).toBe(404);
  });
});
