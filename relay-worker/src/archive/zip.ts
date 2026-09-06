import { unzipSync, type UnzipFileInfo } from "fflate";

// Mirrors @path_pattern in subdl/file_id.ex. Anchored, and deliberately
// excludes "/" inside the filename so no path segment can be smuggled in.
const SUBTITLE_PATH_PATTERN = /^\/subtitle\/[A-Za-z0-9._-]+\.zip$/;

const SUBTITLE_EXTENSIONS = [".srt", ".ass", ".ssa", ".sub", ".vtt"];

// Mirrors @max_total_bytes in metadata_relay/subtitles/archive.ex: 20MB
// expanded is three orders of magnitude of headroom over a feature-length
// subtitle (tens of KB) and still refuses a bomb. Exported so the download
// route can apply the same ceiling to the compressed body before it is ever
// handed to extractSubtitle.
export const MAX_ARCHIVE_BYTES = 20_000_000;

// Mirrors FileId.encode/1's strip_query/1: SubDL appends the API key used for
// the search onto every result url, and dropping the query string here is the
// single point that keeps the relay's key out of the encoded id.
function stripQuery(url: string): string {
  const index = url.indexOf("?");
  return index === -1 ? url : url.slice(0, index);
}

export function encodeFileId(url: string): string {
  return btoa(stripQuery(url))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

export function decodeFileId(id: string): string | null {
  try {
    const base64 = id.replace(/-/g, "+").replace(/_/g, "/");
    const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
    const path = atob(padded);
    return SUBTITLE_PATH_PATTERN.test(path) ? path : null;
  } catch {
    return null;
  }
}

// Entry names are read from the archive as-is and rejected before the bytes
// are used. This is the guard the Elixir version applies by reading names from
// the central directory before OTP's unzip sanitises them; here nothing
// sanitises anything, so the check is the only protection.
function safeName(name: string): boolean {
  if (name.startsWith("/")) return false;
  if (name.split("/").includes("..")) return false;
  return true;
}

export function extractSubtitle(zipBytes: Uint8Array): Uint8Array | null {
  // Mirrors check_declared_size/1 in archive.ex: sum declared (uncompressed)
  // sizes from the central directory, read via fflate's filter callback
  // *before* that entry is inflated, and once the running total would reach
  // or exceed the cap, stop decompressing anything else. A crafted archive
  // can be a few KB on the wire and declare tens of megabytes per entry;
  // checking this before inflate is what keeps that cheap for an attacker and
  // expensive for us from ever happening. Once the cap trips, the whole
  // archive is rejected below -- not just the entry that tipped it over --
  // so nothing already decompressed by that point is ever returned.
  let totalDeclared = 0;
  let overCap = false;

  let entries: Record<string, Uint8Array>;
  try {
    entries = unzipSync(zipBytes, {
      filter(file: UnzipFileInfo): boolean {
        totalDeclared += file.originalSize;
        if (totalDeclared >= MAX_ARCHIVE_BYTES) overCap = true;
        return !overCap;
      },
    });
  } catch {
    return null;
  }

  if (overCap) return null;

  for (const name of Object.keys(entries)) {
    if (!safeName(name)) return null;
  }

  // Post-decompression safety net, mirroring check_total_size/1: a crafted
  // local file header can understate its declared size, so what actually
  // came out is checked too, not just what the header claimed going in.
  let actualTotal = 0;
  for (const bytes of Object.values(entries)) actualTotal += bytes.length;
  if (actualTotal >= MAX_ARCHIVE_BYTES) return null;

  for (const [name, bytes] of Object.entries(entries)) {
    const lower = name.toLowerCase();
    if (SUBTITLE_EXTENSIONS.some((ext) => lower.endsWith(ext))) {
      return bytes;
    }
  }

  return null;
}
