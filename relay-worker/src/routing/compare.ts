// Shadow comparison: did this Worker answer a request the way the Elixir relay
// did? The rules mirror test/contract/contract.test.ts, the offline version of
// the same question: status first, then JSON compared semantically with the
// same volatile keys ignored, then raw bytes for anything that is not JSON.

// Bodies above this are compared by status only. Parsing two large JSON
// bodies is the one CPU-heavy step in a shadowed request, and a Worker on the
// free plan has 10ms of CPU per invocation for everything, the real request
// included.
export const SHADOW_BODY_CAP = 512 * 1024;

export type ShadowOutcome =
  | "match"
  | "status_mismatch"
  | "body_mismatch"
  | "skipped_large"
  // The origin's body stream failed partway, so there is nothing to compare.
  | "origin_error"
  | "worker_error";

export interface ShadowVerdict {
  outcome: ShadowOutcome;
  // For body_mismatch, where the two first disagree: a JSON path such as
  // `$.results[3].name`, or `bytes` for a non-JSON body.
  diff?: string;
}

export interface CapturedResponse {
  status: number;
  // null when the body was larger than SHADOW_BODY_CAP.
  bytes: Uint8Array | null;
}

// Reads at most `cap` bytes. Past that it cancels the stream (so a tee()'d
// branch stops buffering) and returns null.
export async function readCapped(
  body: ReadableStream<Uint8Array> | null,
  cap: number = SHADOW_BODY_CAP,
): Promise<Uint8Array | null> {
  if (body === null) return new Uint8Array(0);
  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > cap) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

export function compareResponses(origin: CapturedResponse, worker: CapturedResponse): ShadowVerdict {
  if (origin.status !== worker.status) return { outcome: "status_mismatch" };
  if (origin.bytes === null || worker.bytes === null) return { outcome: "skipped_large" };
  if (bytesEqual(origin.bytes, worker.bytes)) return { outcome: "match" };

  const originJson = parseJson(origin.bytes);
  const workerJson = parseJson(worker.bytes);
  if (originJson === NOT_JSON || workerJson === NOT_JSON) {
    return { outcome: "body_mismatch", diff: "bytes" };
  }
  const diff = firstDifference(originJson, workerJson, "$");
  return diff === null ? { outcome: "match" } : { outcome: "body_mismatch", diff };
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.byteLength !== b.byteLength) return false;
  for (let i = 0; i < a.byteLength; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

const NOT_JSON = Symbol("not-json");

function parseJson(bytes: Uint8Array): unknown {
  try {
    return JSON.parse(new TextDecoder().decode(bytes)) as unknown;
  } catch {
    return NOT_JSON;
  }
}

// Same volatile keys as test/contract/contract.test.ts, whose stripVolatile
// applies them at every depth: `version` (each relay reports its own), and
// any bare-string `created`, which MusicBrainz stamps with "now" on every
// search. OpenLibrary's object-shaped `created` is real catalog data and is
// still compared.
function isVolatile(key: string, value: unknown): boolean {
  if (key === "version") return true;
  return key === "created" && typeof value === "string";
}

// The path of the first place the two values disagree, or null if they agree.
// Object key order does not matter; array order does.
export function firstDifference(a: unknown, b: unknown, path: string): string | null {
  if (a === b) return null;
  if (a === null || b === null || typeof a !== "object" || typeof b !== "object") {
    return path;
  }
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b)) return path;
    if (a.length !== b.length) return `${path}.length`;
    for (let i = 0; i < a.length; i++) {
      const diff = firstDifference(a[i], b[i], `${path}[${i}]`);
      if (diff !== null) return diff;
    }
    return null;
  }

  const left = a as Record<string, unknown>;
  const right = b as Record<string, unknown>;
  const keys = [...new Set([...Object.keys(left), ...Object.keys(right)])].sort();
  for (const key of keys) {
    const inLeft = Object.hasOwn(left, key);
    const inRight = Object.hasOwn(right, key);
    if (inLeft && isVolatile(key, left[key])) continue;
    if (inRight && isVolatile(key, right[key])) continue;
    if (!inLeft || !inRight) return `${path}.${key}`;
    const diff = firstDifference(left[key], right[key], `${path}.${key}`);
    if (diff !== null) return diff;
  }
  return null;
}
