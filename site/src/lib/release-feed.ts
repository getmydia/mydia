/**
 * Pure resolution logic behind mydia.dev/download/<platform>?track=beta|dev.
 *
 * Pre-release downloads come from the same feed the player's Release track
 * setting reads (updates.mydia.dev/releases.json), not from the GitHub
 * releases API: dev builds never become GitHub releases, and the feed already
 * names one build per platform and track.
 */

export const FEED_URL = 'https://updates.mydia.dev/releases.json';

/** Tracks in ascending order of risk. Keys match releases.json. */
export const TRACKS = ['stable', 'beta', 'dev'] as const;
export type Track = (typeof TRACKS)[number];

/** Pre-release tracks the download routes accept in ?track=. */
export type PreReleaseTrack = Exclude<Track, 'stable'>;

export function isPreReleaseTrack(value: string | null): value is PreReleaseTrack {
  return value === 'beta' || value === 'dev';
}

/** One build, as releases.json describes it. */
export interface FeedEntry {
  version: string;
  build: number;
  url: string;
  size?: number;
  published_at?: string;
  notes_url?: string;
}

export interface ReleaseFeed {
  platforms: Record<string, Partial<Record<Track, FeedEntry>>>;
}

/** The feed's key for each download slug that has a file per track. */
const FEED_PLATFORMS: Record<string, string> = {
  android: 'android',
  macos: 'macos',
  windows: 'windows',
  linux: 'linux',
};

/** Pre-release destinations that are not files in the feed. */
const STATIC_PRE_RELEASE: Record<string, Partial<Record<PreReleaseTrack, string>>> = {
  ios: { beta: 'https://testflight.apple.com/join/XTvarNBK' },
  flatpak: {
    beta: 'https://flatpak.mydia.dev/mydia-beta.flatpakrepo',
    dev: 'https://flatpak.mydia.dev/mydia-dev.flatpakrepo',
  },
};

export function staticPreReleaseDestination(
  slug: string,
  track: PreReleaseTrack,
): string | null {
  return STATIC_PRE_RELEASE[slug]?.[track] ?? null;
}

export function isFeedPlatform(slug: string): boolean {
  return slug in FEED_PLATFORMS;
}

function isEntry(value: unknown): value is FeedEntry {
  const v = value as FeedEntry | null;
  return (
    typeof v?.version === 'string' &&
    typeof v.build === 'number' &&
    typeof v.url === 'string'
  );
}

/**
 * The newest build a user on [track] can get for [slug]: the track's own
 * build, or a less risky track's when that one is newer. A beta that a stable
 * release has already overtaken is never the better download.
 */
export function resolveTrackBuild(
  feed: ReleaseFeed,
  slug: string,
  track: Track,
): { track: Track; entry: FeedEntry } | null {
  const key = FEED_PLATFORMS[slug];
  const tracks = key ? feed.platforms?.[key] : undefined;
  if (!tracks) return null;

  let best: { track: Track; entry: FeedEntry } | null = null;
  for (const candidate of TRACKS.slice(0, TRACKS.indexOf(track) + 1)) {
    const entry = tracks[candidate];
    if (isEntry(entry) && (!best || entry.build > best.entry.build)) {
      best = { track: candidate, entry };
    }
  }
  return best;
}

export function parseFeed(body: string): ReleaseFeed | null {
  try {
    const parsed = JSON.parse(body);
    return parsed && typeof parsed.platforms === 'object' ? (parsed as ReleaseFeed) : null;
  } catch {
    return null;
  }
}
