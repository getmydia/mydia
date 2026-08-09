/// <reference types="@cloudflare/workers-types" />

import { fetchLatestRelease } from '../../src/lib/github-release';
import { buildReleaseSummary } from '../../src/lib/release-assets';

export const onRequestGet: PagesFunction = async () => {
  const release = await fetchLatestRelease();
  const body = release ? buildReleaseSummary(release) : { ok: false };

  return new Response(JSON.stringify(body), {
    headers: {
      'Content-Type': 'application/json',
      // Matches the redirect TTL so the version line and the buttons cannot
      // disagree about which release is current.
      'Cache-Control': 'public, max-age=300',
    },
  });
};
