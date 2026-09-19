import type { Env } from "../env";
import { ROUTE_GROUPS, type RouteGroup } from "./groups";

// The routing config lives in CACHE_KV under this key, as JSON:
//
//   {"default": "origin", "groups": {"tmdb": "shadow", "tvdb": "split:25"}}
//
// It is KV rather than a wrangler var so a ramp step or a rollback is one
// `wrangler kv key put` and takes effect within about a minute
// (ROUTING_CONFIG_CACHE_TTL plus ROUTING_CONFIG_MEMO_MS), instead of a
// `relay-worker-v*` tag and a production deploy.
export const ROUTING_CONFIG_KEY = "routing:config";

// KV's minimum cacheTtl. A write reaches every colo within about this long.
export const ROUTING_CONFIG_CACHE_TTL = 30;

// How long an isolate serves the config it last read before asking KV again.
// KV bills every get(), including the ones cacheTtl answers from the colo, and
// the free plan allows 100,000 a day. One read per request spent 35,000 of
// them in a single hour of TVDB traffic, so an isolate reads once per window.
export const ROUTING_CONFIG_MEMO_MS = 30_000;

export type RoutingMode =
  // The Elixir relay answers.
  | { kind: "origin" }
  // This Worker answers.
  | { kind: "worker" }
  // The Elixir relay answers; for `percent`% of GET/HEAD requests this Worker
  // also runs the request in the background and logs whether it agreed.
  | { kind: "shadow"; percent: number }
  // `percent`% of client IPs are answered by this Worker, the rest by the
  // Elixir relay. The bucket is a hash of the IP, so an install stays put.
  | { kind: "split"; percent: number }
  // This Worker answers, but a claim lookup it cannot find is retried against
  // the Elixir relay, and deletes go to both. For moving pairing over without
  // losing the claims created on the Elixir relay just before the switch.
  | { kind: "fallback" };

export type RoutingModeKind = RoutingMode["kind"];

export interface RoutingConfig {
  modes: Record<RouteGroup, RoutingMode>;
  warnings: string[];
}

const ORIGIN: RoutingMode = { kind: "origin" };

// Which modes each group may use. Anything else is refused and the group
// stays on the Elixir relay.
//
// - Shadowing runs the request twice, so only groups whose requests are
//   read-only and cheap to repeat may shadow. Subtitles are read-only but
//   their SubDL key carries one 2000/day quota shared by every install.
// - Splitting needs a group whose requests stand alone. A pairing claim is
//   written by the server and read by the player from another IP, so no
//   per-IP bucket can keep both halves on one backend. Crash and feedback
//   ingest would work request by request, but each backend enforces its own
//   hourly budget and keeps its own history, so they move as a unit instead.
const READ_ONLY: readonly RoutingModeKind[] = ["origin", "worker", "shadow", "split"];

const ALLOWED: Record<RouteGroup, readonly RoutingModeKind[]> = {
  tmdb: READ_ONLY,
  tvdb: READ_ONLY,
  music: READ_ONLY,
  openlibrary: READ_ONLY,
  client_config: READ_ONLY,
  health: READ_ONLY,
  subtitles: ["origin", "worker", "split"],
  pairing: ["origin", "worker", "fallback"],
  crashes: ["origin", "worker"],
  feedback: ["origin", "worker"],
  admin: ["origin", "worker"],
  other: ["origin", "worker"],
};

export function allOrigin(warnings: string[] = []): RoutingConfig {
  const modes = Object.fromEntries(ROUTE_GROUPS.map((g) => [g, ORIGIN])) as Record<
    RouteGroup,
    RoutingMode
  >;
  return { modes, warnings };
}

// "origin", "worker", "fallback", "shadow" (100%), "shadow:25", "split:25".
export function parseMode(value: unknown): RoutingMode | null {
  if (typeof value !== "string") return null;
  const [kind, rawPercent, ...rest] = value.trim().split(":");
  if (rest.length > 0) return null;

  if (kind === "origin" || kind === "worker" || kind === "fallback") {
    return rawPercent === undefined ? { kind } : null;
  }
  if (kind === "shadow" || kind === "split") {
    if (rawPercent === undefined) return kind === "shadow" ? { kind, percent: 100 } : null;
    if (!/^\d{1,3}$/.test(rawPercent)) return null;
    const percent = Number(rawPercent);
    return percent <= 100 ? { kind, percent } : null;
  }
  return null;
}

function isRouteGroup(value: string): value is RouteGroup {
  return (ROUTE_GROUPS as readonly string[]).includes(value);
}

// Never throws. A malformed config, an unknown group, a mode a group may not
// use: each is reported in `warnings` and resolves to "origin" for whatever
// it touched, because the Elixir relay is the known-good backend until the
// cutover is finished.
export function parseRoutingConfig(raw: string | null): RoutingConfig {
  if (raw === null) return allOrigin();

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return allOrigin(["routing config is not valid JSON"]);
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    return allOrigin(["routing config is not a JSON object"]);
  }

  const { default: rawDefault, groups: rawGroups } = parsed as {
    default?: unknown;
    groups?: unknown;
  };
  const warnings: string[] = [];

  let fallbackMode: RoutingMode = ORIGIN;
  if (rawDefault !== undefined) {
    const mode = parseMode(rawDefault);
    if (mode) fallbackMode = mode;
    else warnings.push(`default: unrecognised mode ${JSON.stringify(rawDefault)}`);
  }

  const requested = new Map<RouteGroup, RoutingMode>();
  if (rawGroups !== undefined) {
    if (rawGroups === null || typeof rawGroups !== "object" || Array.isArray(rawGroups)) {
      warnings.push("groups is not a JSON object");
    } else {
      for (const [group, value] of Object.entries(rawGroups)) {
        if (!isRouteGroup(group)) {
          warnings.push(`unknown group ${JSON.stringify(group)}`);
          continue;
        }
        const mode = parseMode(value);
        if (mode) requested.set(group, mode);
        else warnings.push(`${group}: unrecognised mode ${JSON.stringify(value)}`);
      }
    }
  }

  const modes = {} as Record<RouteGroup, RoutingMode>;
  for (const group of ROUTE_GROUPS) {
    const explicit = requested.get(group);
    const mode = explicit ?? fallbackMode;
    if (ALLOWED[group].includes(mode.kind)) {
      modes[group] = mode;
    } else {
      modes[group] = ORIGIN;
      // A default that one group cannot take (say "shadow" for pairing) is
      // the expected way to write a broad config, so only an explicit
      // per-group request is worth a warning.
      if (explicit) warnings.push(`${group}: mode ${mode.kind} is not allowed for this group`);
    }
  }
  return { modes, warnings };
}

// Parsing is memoized on the raw string, so a config that has not changed is
// parsed, and its warnings logged, once per isolate rather than once per read.
let memo: { raw: string | null; config: RoutingConfig } | undefined;

// The config this isolate is serving and when it was read. A failed read is
// held for the same window as a good one: once KV is refusing (an outage, or
// the daily read cap), retrying it on every request cannot help.
let held: { config: RoutingConfig; readAt: number } | undefined;

export async function loadRoutingConfig(env: Env, now: number = Date.now()): Promise<RoutingConfig> {
  if (held && now - held.readAt < ROUTING_CONFIG_MEMO_MS) return held.config;
  const config = await readRoutingConfig(env);
  held = { config, readAt: now };
  return config;
}

// Test-only: forget what this isolate has read, so a test's KV write is seen
// by the next load instead of up to ROUTING_CONFIG_MEMO_MS later.
export function resetRoutingConfigMemo(): void {
  memo = undefined;
  held = undefined;
}

async function readRoutingConfig(env: Env): Promise<RoutingConfig> {
  let raw: string | null;
  try {
    raw = await env.CACHE_KV.get(ROUTING_CONFIG_KEY, { cacheTtl: ROUTING_CONFIG_CACHE_TTL });
  } catch (err) {
    console.log(JSON.stringify({ event: "routing_config_error", error: String(err) }));
    return allOrigin(["routing config could not be read"]);
  }

  if (memo && memo.raw === raw) return memo.config;
  const config = parseRoutingConfig(raw);
  memo = { raw, config };
  if (config.warnings.length > 0) {
    console.log(JSON.stringify({ event: "routing_config_warning", warnings: config.warnings }));
  }
  return config;
}
