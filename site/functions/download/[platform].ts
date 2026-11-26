/// <reference types="@cloudflare/workers-types" />

import { fetchLatestRelease, fetchReleaseFeed } from '../../src/lib/github-release';
import {
  FALLBACK_URL,
  findAssetUrl,
  isAssetPlatform,
  isPlatformSlug,
  staticDestination,
} from '../../src/lib/release-assets';
import {
  isFeedPlatform,
  isPreReleaseTrack,
  resolveTrackBuild,
  staticPreReleaseDestination,
  type PreReleaseTrack,
} from '../../src/lib/release-feed';

export const onRequestGet: PagesFunction = async (context) => {
  const slug = String(context.params.platform ?? '');

  // Unknown slug: hand back to static assets, so /download/ still serves the
  // download page and /download/bsd gets an ordinary 404.
  if (!isPlatformSlug(slug)) return context.next();

  const track = new URL(context.request.url).searchParams.get('track');
  if (isPreReleaseTrack(track)) return redirect(await preRelease(slug, track), 60);

  const fixed = staticDestination(slug);
  if (fixed) return redirect(fixed);

  if (!isAssetPlatform(slug)) return redirect(FALLBACK_URL);

  const release = await fetchLatestRelease();
  const url = release ? findAssetUrl(release, slug) : null;

  return redirect(url ?? FALLBACK_URL);
};

/**
 * Where ?track=beta or ?track=dev lands. A platform with no build on that
 * track gets the newest build from a less risky one, and anything the feed
 * cannot answer goes back to the download page with that track selected.
 */
async function preRelease(slug: string, track: PreReleaseTrack): Promise<string> {
  const fixed = staticPreReleaseDestination(slug, track);
  if (fixed) return fixed;

  const pageFallback = `/download?track=${track}#${slug === 'flatpak' ? 'linux' : slug}`;
  if (!isFeedPlatform(slug)) return pageFallback;

  const feed = await fetchReleaseFeed();
  return (feed && resolveTrackBuild(feed, slug, track)?.entry.url) ?? pageFallback;
}

// Pre-release redirects pass a shorter TTL: the feed is cached for a minute,
// and a dev build is stale within hours.
function redirect(location: string, maxAge = 300): Response {
  return new Response(null, {
    status: 302,
    headers: {
      Location: location,
      'Cache-Control': `public, max-age=${maxAge}`,
    },
  });
}
