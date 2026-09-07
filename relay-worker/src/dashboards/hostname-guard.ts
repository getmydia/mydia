/**
 * Whether a request to `/admin/*` on this hostname must be refused.
 *
 * Cloudflare Access is the real gate on the maintainer dashboards, and it is
 * configured per hostname. Access CAN cover a workers.dev hostname:
 * Cloudflare documents hostname-based applications on
 * `<worker>.<subdomain>.workers.dev` explicitly, and shipped one-click Access
 * for workers.dev in October 2025. What no per-hostname application covers is
 * the versioned PREVIEW URLs Cloudflare mints alongside every deploy, each on
 * a hostname nobody named in advance.
 *
 * So this is an allowlist of exactly one host. `accessGuardedHostname` is the
 * single workers.dev hostname where an Access application is known to cover
 * `/admin*`, supplied by the `ADMIN_ACCESS_HOSTNAME` var and set on
 * `env.staging` only.
 *
 * It fails closed by construction rather than by a branch: `undefined` and
 * `""` never equal a hostname, so an unset or blank value reproduces the
 * blanket 404 this function replaced. The match is exact and unnormalised, so
 * any typo in the configured value also fails closed. That is deliberate;
 * normalising only case would create false confidence in the other typos.
 *
 * This is not authentication and must never grow into it. It removes
 * unprotected hostnames from reach; Access decides who may look.
 */
export function adminHostnameBlocked(
  hostname: string,
  accessGuardedHostname: string | undefined,
): boolean {
  if (!hostname.endsWith(".workers.dev")) return false;
  return hostname !== accessGuardedHostname;
}
