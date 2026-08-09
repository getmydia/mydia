/**
 * Pure resolution logic behind mydia.dev/download/<platform>.
 *
 * Kept free of I/O so it can be unit tested without a Workers runtime, and
 * kept out of functions/ so Pages cannot mistake it for a route.
 */

/** Where a download lands when we cannot resolve a real asset. */
export const FALLBACK_URL = 'https://github.com/getmydia/mydia/releases/latest';

/** One asset as it appears in the GitHub releases API response. */
export interface ReleaseAsset {
  name: string;
  size: number;
  browser_download_url: string;
}

/** The subset of the GitHub releases API response this module relies on. */
export interface GitHubRelease {
  tag_name: string;
  html_url: string;
  published_at: string;
  assets: ReleaseAsset[];
}

/** Platforms whose download is a file attached to the GitHub release. */
export const ASSET_PLATFORMS = ['android', 'macos', 'windows', 'linux'] as const;
export type AssetPlatform = (typeof ASSET_PLATFORMS)[number];

/** Platforms that always redirect to a fixed external URL. */
export const STATIC_PLATFORMS = ['ios', 'flatpak'] as const;
export type StaticPlatform = (typeof STATIC_PLATFORMS)[number];

export type PlatformSlug = AssetPlatform | StaticPlatform;

/**
 * Prefix plus suffix, never a filename rebuilt from the tag. The suffix says
 * what kind of file it is; the prefix disambiguates against another artifact
 * sharing that extension, such as a future mydia-server-linux-*.tar.gz landing
 * beside the player's. Rebuilding the name would also mean holding a second
 * copy of release.yml's naming scheme here, where nothing would catch drift.
 */
const ASSET_MATCHERS: Record<AssetPlatform, { prefix: string; suffix: string }> = {
  android: { prefix: 'mydia-player-android-', suffix: '.apk' },
  macos: { prefix: 'mydia-player-macos-', suffix: '.dmg' },
  windows: { prefix: 'mydia-player-windows-', suffix: '.exe' },
  linux: { prefix: 'mydia-player-linux-', suffix: '.tar.gz' },
};

const STATIC_DESTINATIONS: Record<StaticPlatform, string> = {
  ios: 'https://testflight.apple.com/join/KFSYxaQP',
  flatpak: 'https://flatpak.mydia.dev/mydia.flatpakrepo',
};

export function isAssetPlatform(slug: string): slug is AssetPlatform {
  return (ASSET_PLATFORMS as readonly string[]).includes(slug);
}

export function isStaticPlatform(slug: string): slug is StaticPlatform {
  return (STATIC_PLATFORMS as readonly string[]).includes(slug);
}

/** Unknown slugs make the Function fall through to static assets. */
export function isPlatformSlug(slug: string): slug is PlatformSlug {
  return isAssetPlatform(slug) || isStaticPlatform(slug);
}

/** The fixed destination for ios and flatpak, null for everything else. */
export function staticDestination(slug: string): string | null {
  return isStaticPlatform(slug) ? STATIC_DESTINATIONS[slug] : null;
}

function findAsset(
  release: GitHubRelease,
  slug: AssetPlatform,
): ReleaseAsset | undefined {
  const { prefix, suffix } = ASSET_MATCHERS[slug];
  return release.assets.find(
    (a) => a.name.startsWith(prefix) && a.name.endsWith(suffix),
  );
}

/**
 * This release's download URL for a platform, or null when it carries none.
 * Callers redirect to FALLBACK_URL on null.
 */
export function findAssetUrl(
  release: GitHubRelease,
  slug: AssetPlatform,
): string | null {
  return findAsset(release, slug)?.browser_download_url ?? null;
}

/** The body /api/player-release returns when the lookup succeeded. */
export interface ReleaseSummary {
  ok: true;
  version: string;
  publishedAt: string;
  releaseUrl: string;
  assets: Partial<Record<AssetPlatform, { size: number }>>;
}

/** Strips the leading v so the page can render the "v" prefix itself. */
export function buildReleaseSummary(release: GitHubRelease): ReleaseSummary {
  const assets: Partial<Record<AssetPlatform, { size: number }>> = {};
  for (const slug of ASSET_PLATFORMS) {
    const found = findAsset(release, slug);
    if (found) assets[slug] = { size: found.size };
  }

  return {
    ok: true,
    version: release.tag_name.replace(/^v/, ''),
    publishedAt: release.published_at,
    releaseUrl: release.html_url,
    assets,
  };
}
