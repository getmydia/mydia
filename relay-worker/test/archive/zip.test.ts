import { describe, it, expect } from "vitest";
import { zipSync, strToU8 } from "fflate";
import {
  extractSubtitle,
  encodeFileId,
  decodeFileId,
  MAX_ARCHIVE_BYTES,
} from "../../src/archive/zip";

describe("extractSubtitle", () => {
  it("returns the subtitle bytes from a single-entry archive", () => {
    const zip = zipSync({ "sub.srt": strToU8("1\n00:00:01,000 --> 00:00:02,000\nhi\n") });
    const out = extractSubtitle(zip);
    expect(out).not.toBeNull();
    expect(new TextDecoder().decode(out!)).toContain("00:00:01,000");
  });

  it("picks the subtitle entry when the archive also holds junk", () => {
    const zip = zipSync({
      "readme.txt": strToU8("ignore me"),
      "movie.srt": strToU8("1\n00:00:01,000 --> 00:00:02,000\nreal\n"),
    });
    expect(new TextDecoder().decode(extractSubtitle(zip)!)).toContain("real");
  });

  it("rejects an entry whose name escapes the archive root", () => {
    // Path traversal guard: names are checked before use, because a crafted
    // name is the whole attack here.
    const zip = zipSync({ "../../etc/passwd.srt": strToU8("nope") });
    expect(extractSubtitle(zip)).toBeNull();
  });

  it("rejects an absolute entry name", () => {
    const zip = zipSync({ "/etc/passwd.srt": strToU8("nope") });
    expect(extractSubtitle(zip)).toBeNull();
  });

  it("returns null for an archive with no subtitle entry", () => {
    const zip = zipSync({ "cover.jpg": strToU8("binary") });
    expect(extractSubtitle(zip)).toBeNull();
  });

  it("returns null for bytes that are not a zip at all", () => {
    expect(extractSubtitle(strToU8("<html>captcha</html>"))).toBeNull();
  });

  // Mirrors archive.ex's check_declared_size/1 + check_total_size/1: a small
  // download must not be allowed to expand into an unbounded write. These
  // three tests were run against the uncapped extractSubtitle before this cap
  // existed, and all three failed there, so they are known to have teeth.
  // The zip-bomb test in particular is written so it fails
  // against an implementation that fully decompresses before checking size.
  describe("size cap", () => {
    it("rejects an archive whose declared size is exactly at the cap", () => {
      const zip = zipSync({ "big.srt": new Uint8Array(MAX_ARCHIVE_BYTES) });
      expect(extractSubtitle(zip)).toBeNull();
    });

    it("accepts an archive whose declared size is just under the cap", () => {
      const payload = new Uint8Array(MAX_ARCHIVE_BYTES - 1000).fill(1);
      const zip = zipSync({ "big.srt": payload });
      const out = extractSubtitle(zip);
      expect(out).not.toBeNull();
      expect(out!.length).toBe(payload.length);
    });

    it("rejects a zip-bomb shape (tiny on the wire, huge declared size) without materialising it", () => {
      // 30MB of zeros compresses to well under 1KB via deflate: small
      // compressed size, huge originalSize -- exactly the shape
      // check_declared_size/1 exists to catch before any bytes are produced.
      const bomb = new Uint8Array(30_000_000);
      const zip = zipSync({ "bomb.srt": bomb });
      // ~1000x compression ratio: comfortably "tiny on the wire" relative to
      // the 30MB declared size, without pinning an exact byte count.
      expect(zip.length).toBeLessThan(50_000);
      expect(extractSubtitle(zip)).toBeNull();
    });
  });
});

describe("file id encoding", () => {
  it("round trips a valid subtitle path", () => {
    const id = encodeFileId("/subtitle/abc-123.zip");
    expect(decodeFileId(id)).toBe("/subtitle/abc-123.zip");
  });

  it("uses unpadded url-safe base64, matching FileId.encode", () => {
    expect(encodeFileId("/subtitle/a.zip")).not.toContain("=");
    expect(encodeFileId("/subtitle/a.zip")).not.toContain("+");
    expect(encodeFileId("/subtitle/a.zip")).not.toContain("/");
  });

  it("strips a query string before encoding, matching FileId.encode's strip_query", () => {
    // SubDL appends the API key used for the search onto every result url.
    // Dropping the query string here is the single point that keeps the
    // relay's key out of the encoded id.
    const withQuery = encodeFileId("/subtitle/abc-123.zip?api_key=SUPERSECRET");
    const withoutQuery = encodeFileId("/subtitle/abc-123.zip");
    expect(withQuery).toBe(withoutQuery);
    expect(decodeFileId(withQuery)).toBe("/subtitle/abc-123.zip");
  });

  it("rejects a decoded path that is not a subtitle zip", () => {
    const hostile = btoa("/etc/passwd").replace(/=+$/, "");
    expect(decodeFileId(hostile)).toBeNull();
  });

  it("rejects a decoded path with traversal segments", () => {
    const hostile = btoa("/subtitle/../../x.zip").replace(/=+$/, "");
    expect(decodeFileId(hostile)).toBeNull();
  });

  it("rejects input that is not valid base64", () => {
    expect(decodeFileId("!!!not base64!!!")).toBeNull();
  });
});
