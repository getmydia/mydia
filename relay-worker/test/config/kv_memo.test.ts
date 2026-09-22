import { env } from "cloudflare:test";
import { describe, it, expect, vi } from "vitest";
import { kvMemo, KV_CACHE_TTL, KV_MEMO_MS } from "../../src/config/kv_memo";
import type { Env } from "../../src/env";

const T0 = 1_000_000;

// A KV stand-in that answers `values` in order (repeating the last one) and
// counts reads. An Error in `values` is thrown instead of returned.
function countingEnv(values: Array<string | null | Error>): {
  env: Env;
  reads: () => number;
  calls: unknown[][];
} {
  let reads = 0;
  const calls: unknown[][] = [];
  const kv = {
    get: async (...args: unknown[]) => {
      calls.push(args);
      const value = values[Math.min(reads, values.length - 1)];
      reads++;
      if (value instanceof Error) throw value;
      return value;
    },
  } as unknown as KVNamespace;
  return { env: { ...env, CACHE_KV: kv }, reads: () => reads, calls };
}

describe("kvMemo", () => {
  it("reads the key with KV's minimum cacheTtl", async () => {
    const counted = countingEnv(["a"]);
    const memo = kvMemo<string | null>({ key: "k", parse: (raw) => raw, onReadError: () => "error" });

    await memo.load(counted.env, T0);
    expect(counted.calls).toEqual([["k", { cacheTtl: KV_CACHE_TTL }]]);
  });

  it("reads KV once per window, however many loads arrive in it", async () => {
    const counted = countingEnv(["a"]);
    const memo = kvMemo<string | null>({ key: "k", parse: (raw) => raw, onReadError: () => "error" });

    for (let i = 0; i < 20; i++) {
      expect(await memo.load(counted.env, T0 + i * 100)).toBe("a");
    }
    expect(counted.reads()).toBe(1);
  });

  it("reads again once the window has passed", async () => {
    const counted = countingEnv(["a", "b"]);
    const memo = kvMemo<string | null>({ key: "k", parse: (raw) => raw, onReadError: () => "error" });

    expect(await memo.load(counted.env, T0)).toBe("a");
    expect(await memo.load(counted.env, T0 + KV_MEMO_MS - 1)).toBe("a");
    expect(await memo.load(counted.env, T0 + KV_MEMO_MS)).toBe("b");
  });

  it("parses each distinct raw value once", async () => {
    const counted = countingEnv(["a", "a", "b"]);
    const parse = vi.fn((raw: string | null) => raw);
    const memo = kvMemo<string | null>({ key: "k", parse, onReadError: () => "error" });

    await memo.load(counted.env, T0);
    await memo.load(counted.env, T0 + KV_MEMO_MS);
    await memo.load(counted.env, T0 + 2 * KV_MEMO_MS);
    expect(counted.reads()).toBe(3);
    expect(parse).toHaveBeenCalledTimes(2);
  });

  it("holds a failed read for the window, serving onReadError's value", async () => {
    const counted = countingEnv([new Error("KV GET failed: 429 Too Many Requests"), "a"]);
    const onReadError = vi.fn(() => "fallback");
    const memo = kvMemo<string | null>({ key: "k", parse: (raw) => raw, onReadError });

    expect(await memo.load(counted.env, T0)).toBe("fallback");
    expect(await memo.load(counted.env, T0 + KV_MEMO_MS - 1)).toBe("fallback");
    expect(counted.reads()).toBe(1);
    expect(await memo.load(counted.env, T0 + KV_MEMO_MS)).toBe("a");
    expect(onReadError).toHaveBeenCalledTimes(1);
  });

  it("forgets what it read on reset", async () => {
    const counted = countingEnv(["a", "b"]);
    const memo = kvMemo<string | null>({ key: "k", parse: (raw) => raw, onReadError: () => "error" });

    expect(await memo.load(counted.env, T0)).toBe("a");
    memo.reset();
    expect(await memo.load(counted.env, T0 + 1)).toBe("b");
  });

  it("hands parse null for a key that is not there", async () => {
    const memo = kvMemo<string>({
      key: "kv-memo-test:absent",
      parse: (raw) => raw ?? "absent",
      onReadError: () => "error",
    });

    expect(await memo.load(env, T0)).toBe("absent");
  });
});
