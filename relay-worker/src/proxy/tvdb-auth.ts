import type { Env } from "../env";

const LOGIN_URL = "https://api4.thetvdb.com/v4/login";
const KV_KEY = "tvdb:jwt";
const REFRESH_BEFORE_EXPIRY_SECONDS = 3600; // matches @refresh_before_expiry
const FALLBACK_LIFETIME_SECONDS = 30 * 86400;

// How long an isolate reuses the token it last read before reading KV again.
// KV bills every get() and the free plan allows 100,000 a day, which one read
// per TVDB request nearly halved in an hour. The token lasts a month, so this
// window only bounds how long a token deleted or replaced in KV stays in use.
export const TOKEN_MEMO_MS = 5 * 60 * 1000;

interface StoredToken {
  token: string;
  exp: number;
}

let held: { token: StoredToken; readAt: number } | undefined;

export function parseJwtExpiry(token: string): number {
  const fallback = Math.floor(Date.now() / 1000) + FALLBACK_LIFETIME_SECONDS;
  const parts = token.split(".");
  if (parts.length !== 3) return fallback;

  try {
    const base64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
    const payload = JSON.parse(atob(padded)) as { exp?: number };
    return typeof payload.exp === "number" ? payload.exp : fallback;
  } catch {
    return fallback;
  }
}

async function login(env: Env): Promise<StoredToken> {
  const apiKey = env.TVDB_API_KEY;
  if (!apiKey) throw new Error("TVDB_API_KEY is not set");

  const res = await fetch(LOGIN_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ apikey: apiKey }),
  });

  if (!res.ok) {
    throw new Error(`TVDB authentication failed with status ${res.status}`);
  }

  const body = (await res.json()) as { data?: { token?: string } };
  const token = body.data?.token;
  if (!token) throw new Error("TVDB login returned no token");

  return { token, exp: parseJwtExpiry(token) };
}

// No proactive refresh timer exists in a Worker, so this refreshes lazily.
// Several requests racing an expiry may each log in; TVDB login is cheap and
// idempotent and the window is an hour wide, so that is accepted. If duplicate
// logins show up in the logs, serialise the refresh through a D1 row used as
// a lock rather than reaching for a new primitive.
export async function getTvdbToken(env: Env, nowMs: number = Date.now()): Promise<string> {
  if (!env.TVDB_API_KEY) throw new Error("TVDB_API_KEY is not set");

  const now = Math.floor(nowMs / 1000);
  if (held && nowMs - held.readAt < TOKEN_MEMO_MS && usable(held.token, now)) {
    return held.token.token;
  }

  const stored = await env.CACHE_KV.get<StoredToken>(KV_KEY, "json");
  if (usable(stored, now)) {
    held = { token: stored, readAt: nowMs };
    return stored.token;
  }

  const fresh = await login(env);
  await env.CACHE_KV.put(KV_KEY, JSON.stringify(fresh), {
    expirationTtl: Math.max(fresh.exp - now, 60),
  });
  held = { token: fresh, readAt: nowMs };
  return fresh.token;
}

// Test-only: forget the token this isolate holds, so the next call reads KV.
export function resetTvdbTokenMemo(): void {
  held = undefined;
}

function usable(token: StoredToken | null, now: number): token is StoredToken {
  return token !== null && token.exp - now > REFRESH_BEFORE_EXPIRY_SECONDS;
}
