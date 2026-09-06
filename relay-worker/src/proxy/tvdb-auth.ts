import type { Env } from "../env";

const LOGIN_URL = "https://api4.thetvdb.com/v4/login";
const KV_KEY = "tvdb:jwt";
const REFRESH_BEFORE_EXPIRY_SECONDS = 3600; // matches @refresh_before_expiry
const FALLBACK_LIFETIME_SECONDS = 30 * 86400;

interface StoredToken {
  token: string;
  exp: number;
}

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
export async function getTvdbToken(env: Env): Promise<string> {
  if (!env.TVDB_API_KEY) throw new Error("TVDB_API_KEY is not set");

  const stored = await env.CACHE_KV.get<StoredToken>(KV_KEY, "json");
  const now = Math.floor(Date.now() / 1000);

  if (stored && stored.exp - now > REFRESH_BEFORE_EXPIRY_SECONDS) {
    return stored.token;
  }

  const fresh = await login(env);
  await env.CACHE_KV.put(KV_KEY, JSON.stringify(fresh), {
    expirationTtl: Math.max(fresh.exp - now, 60),
  });
  return fresh.token;
}
