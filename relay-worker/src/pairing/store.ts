import type { Env } from "../env";

export async function storeClaim(
  env: Env,
  key: string,
  value: string,
  ttlSeconds: number,
): Promise<void> {
  const expiresAt = Math.floor(Date.now() / 1000) + ttlSeconds;
  await env.DB.prepare(
    `INSERT INTO pairing_claims (key, value, expires_at) VALUES (?, ?, ?)
     ON CONFLICT(key) DO UPDATE SET
       value = excluded.value, expires_at = excluded.expires_at`,
  )
    .bind(key, value, expiresAt)
    .run();
}

// Expiry is enforced on read rather than by a background sweeper, so an expired
// row can never be served even if nothing has cleaned it up yet. A periodic
// delete of expired rows is a housekeeping concern, not a correctness one.
export async function readClaim(env: Env, key: string): Promise<string | null> {
  const row = await env.DB.prepare(
    "SELECT value FROM pairing_claims WHERE key = ? AND expires_at > ?",
  )
    .bind(key, Math.floor(Date.now() / 1000))
    .first<{ value: string }>();

  return row?.value ?? null;
}

export async function deleteClaim(env: Env, key: string): Promise<void> {
  await env.DB.prepare("DELETE FROM pairing_claims WHERE key = ?").bind(key).run();
}

// Not wired to a scheduled trigger yet -- no cron handler exists in this
// Worker as of this task. Kept as the obvious hook for one later, exactly as
// the module-level comment above says: housekeeping, not correctness, since
// readClaim already refuses an expired row on its own.
export async function purgeExpiredClaims(env: Env): Promise<void> {
  await env.DB.prepare("DELETE FROM pairing_claims WHERE expires_at <= ?")
    .bind(Math.floor(Date.now() / 1000))
    .run();
}
