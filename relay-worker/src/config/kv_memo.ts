import type { Env } from "../env";

// KV's minimum cacheTtl. A write reaches every colo within about this long.
export const KV_CACHE_TTL = 30;

// How long an isolate serves the value it last read before asking KV again.
// KV bills every get(), including the ones cacheTtl answers from the colo, and
// the free plan allows 100,000 a day. One read per request spent 35,000 of
// them in a single hour of TVDB traffic, so an isolate reads once per window.
export const KV_MEMO_MS = 30_000;

export interface KvMemo<T> {
  load(env: Env, now?: number): Promise<T>;
  // Test-only: forget what this isolate has read, so a test's KV write is seen
  // by the next load instead of up to KV_MEMO_MS later.
  reset(): void;
}

// An operator-written KV key, read at most once per KV_MEMO_MS per isolate.
//
// `parse` runs once per distinct raw value (null when the key is absent), so
// anything it logs is logged once per isolate rather than once per read.
// `onReadError` supplies the value to serve when KV refuses, and that value is
// held for the same window as a good one: once KV is refusing (an outage, or
// the daily read cap), retrying it on every request cannot help.
//
// Only the settled value is shared, never the in-flight read. A KV promise
// belongs to the request that started it, and the runtime drops its
// continuations if that request ends first, so a request awaiting another's
// read could hang. Requests that overlap an expiry each read once instead.
export function kvMemo<T>(options: {
  key: string;
  parse: (raw: string | null) => T;
  onReadError: (err: unknown) => T;
}): KvMemo<T> {
  let parsed: { raw: string | null; value: T } | undefined;
  let held: { value: T; readAt: number } | undefined;

  async function read(env: Env): Promise<T> {
    let raw: string | null;
    try {
      raw = await env.CACHE_KV.get(options.key, { cacheTtl: KV_CACHE_TTL });
    } catch (err) {
      return options.onReadError(err);
    }
    if (parsed && parsed.raw === raw) return parsed.value;
    const value = options.parse(raw);
    parsed = { raw, value };
    return value;
  }

  return {
    async load(env: Env, now: number = Date.now()): Promise<T> {
      if (held && now - held.readAt < KV_MEMO_MS) return held.value;
      const value = await read(env);
      held = { value, readAt: now };
      return value;
    },
    reset(): void {
      parsed = undefined;
      held = undefined;
    },
  };
}
