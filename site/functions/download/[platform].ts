/// <reference types="@cloudflare/workers-types" />

import { fetchLatestRelease } from '../../src/lib/github-release';
import {
  FALLBACK_URL,
  findAssetUrl,
  isAssetPlatform,
  isPlatformSlug,
  staticDestination,
} from '../../src/lib/release-assets';

export const onRequestGet: PagesFunction = async (context) => {
  const slug = String(context.params.platform ?? '');

  // Unknown slug: hand back to static assets, so /download/ still serves the
  // download page and /download/bsd gets an ordinary 404.
  if (!isPlatformSlug(slug)) return context.next();

  const fixed = staticDestination(slug);
  if (fixed) return redirect(fixed);

  if (!isAssetPlatform(slug)) return redirect(FALLBACK_URL);

  const release = await fetchLatestRelease();
  const url = release ? findAssetUrl(release, slug) : null;

  return redirect(url ?? FALLBACK_URL);
};

function redirect(location: string): Response {
  return new Response(null, {
    status: 302,
    headers: {
      Location: location,
      'Cache-Control': 'public, max-age=300',
    },
  });
}
