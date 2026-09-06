import { unzipSync } from "fflate";

// Mirrors @path_pattern in subdl/file_id.ex. Anchored, and deliberately
// excludes "/" inside the filename so no path segment can be smuggled in.
const SUBTITLE_PATH_PATTERN = /^\/subtitle\/[A-Za-z0-9._-]+\.zip$/;

const SUBTITLE_EXTENSIONS = [".srt", ".ass", ".ssa", ".sub", ".vtt"];

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
  let entries: Record<string, Uint8Array>;
  try {
    entries = unzipSync(zipBytes);
  } catch {
    return null;
  }

  for (const name of Object.keys(entries)) {
    if (!safeName(name)) return null;
  }

  for (const [name, bytes] of Object.entries(entries)) {
    const lower = name.toLowerCase();
    if (SUBTITLE_EXTENSIONS.some((ext) => lower.endsWith(ext))) {
      return bytes;
    }
  }

  return null;
}
