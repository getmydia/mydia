import type { GitHubRelease } from './release-assets';

const RELEASE_API = 'https://api.github.com/repos/getmydia/mydia/releases/latest';

/**
 * One cache entry shared by every download route and the metadata endpoint, so
 * a colo makes at most one upstream call per TTL regardless of which platform
 * buttons get clicked.
 */
const CACHE_KEY = RELEASE_API;
const TTL_SECONDS = 600;

/**
 * The newest non-prerelease. /releases/latest skips prereleases, so this tracks
 * the stable channel exactly the way Docker :latest and the Flatpak stable
 * remote already do, with no extra configuration.
 *
 * Returns null on every failure. Callers redirect to FALLBACK_URL rather than
 * surfacing an error: a button that occasionally lands on the releases page is
 * a nuisance, one that returns 502 is a broken page.
 */
export async function fetchLatestRelease(): Promise<GitHubRelease | null> {
  // caches.default is a Workers global with no DOM equivalent, so it needs a
  // cast to survive the DOM-typed Astro project this file lives in.
  const cache = (caches as unknown as { default: Cache }).default;

  const cached = await cache.match(CACHE_KEY);
  if (cached) return safeParse(await cached.text());

  let response: Response;
  try {
    response = await fetch(RELEASE_API, {
      headers: {
        // GitHub rejects API requests that arrive without a User-Agent.
        'User-Agent': 'mydia.dev-download-resolver',
        Accept: 'application/vnd.github+json',
      },
    });
  } catch {
    return null;
  }

  if (!response.ok) return null;

  const body = await response.text();
  const release = safeParse(body);
  if (!release) return null;

  await cache.put(
    CACHE_KEY,
    new Response(body, {
      headers: {
        'Content-Type': 'application/json',
        'Cache-Control': `public, max-age=${TTL_SECONDS}`,
      },
    }),
  );

  return release;
}

function safeParse(body: string): GitHubRelease | null {
  try {
    const parsed = JSON.parse(body);
    // Without an assets array there is nothing to resolve against.
    return Array.isArray(parsed?.assets) ? (parsed as GitHubRelease) : null;
  } catch {
    return null;
  }
}
