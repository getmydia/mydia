import { describe, expect, it } from 'vitest';
import {
  buildReleaseSummary,
  findAssetUrl,
  isPlatformSlug,
  staticDestination,
  type GitHubRelease,
} from './release-assets';

const DOWNLOAD_BASE = 'https://github.com/getmydia/mydia/releases/download/v0.9.3';

function asset(name: string, size = 1024) {
  return { name, size, browser_download_url: `${DOWNLOAD_BASE}/${name}` };
}

/**
 * Mirrors exactly what release.yml's "Upload release assets" step uploads,
 * appcast.xml included, so the fixture drifts only when the real one does.
 */
const RELEASE: GitHubRelease = {
  tag_name: 'v0.9.3',
  html_url: 'https://github.com/getmydia/mydia/releases/tag/v0.9.3',
  published_at: '2026-08-03T14:22:11Z',
  assets: [
    asset('mydia-player-android-v0.9.3.apk', 64123456),
    asset('mydia-player-macos-v0.9.3.dmg', 51234567),
    asset('mydia-player-windows-v0.9.3.exe', 43210987),
    asset('mydia-player-linux-v0.9.3.tar.gz', 47654321),
    asset('appcast.xml', 1187),
  ],
};

describe('findAssetUrl', () => {
  it('resolves each GitHub-backed platform to its own asset', () => {
    expect(findAssetUrl(RELEASE, 'android')).toBe(
      `${DOWNLOAD_BASE}/mydia-player-android-v0.9.3.apk`,
    );
    expect(findAssetUrl(RELEASE, 'macos')).toBe(
      `${DOWNLOAD_BASE}/mydia-player-macos-v0.9.3.dmg`,
    );
    expect(findAssetUrl(RELEASE, 'windows')).toBe(
      `${DOWNLOAD_BASE}/mydia-player-windows-v0.9.3.exe`,
    );
    expect(findAssetUrl(RELEASE, 'linux')).toBe(
      `${DOWNLOAD_BASE}/mydia-player-linux-v0.9.3.tar.gz`,
    );
  });

  it('returns null when the release has no such asset, so the caller falls back', () => {
    const withoutWindows = {
      ...RELEASE,
      assets: RELEASE.assets.filter((a) => !a.name.endsWith('.exe')),
    };
    expect(findAssetUrl(withoutWindows, 'windows')).toBeNull();
  });

  it('picks the player tarball when another artifact shares the extension', () => {
    // Deliberately listed first: a suffix-only matcher would grab this one.
    const withServer: GitHubRelease = {
      ...RELEASE,
      assets: [asset('mydia-server-linux-v0.9.3.tar.gz'), ...RELEASE.assets],
    };
    expect(findAssetUrl(withServer, 'linux')).toBe(
      `${DOWNLOAD_BASE}/mydia-player-linux-v0.9.3.tar.gz`,
    );
  });
});

describe('staticDestination', () => {
  it('sends iOS to TestFlight without consulting a release', () => {
    expect(staticDestination('ios')).toBe('https://testflight.apple.com/join/KFSYxaQP');
  });

  it('sends flatpak to the repo file without consulting a release', () => {
    expect(staticDestination('flatpak')).toBe('https://flatpak.mydia.dev/mydia.flatpakrepo');
  });

  it('returns null for asset-backed platforms', () => {
    expect(staticDestination('macos')).toBeNull();
  });
});

describe('isPlatformSlug', () => {
  it('accepts all six platforms', () => {
    for (const slug of ['android', 'macos', 'windows', 'linux', 'ios', 'flatpak']) {
      expect(isPlatformSlug(slug)).toBe(true);
    }
  });

  it('rejects unknown slugs so the Function falls through to static assets', () => {
    expect(isPlatformSlug('bsd')).toBe(false);
    expect(isPlatformSlug('')).toBe(false);
  });
});

describe('buildReleaseSummary', () => {
  it('strips the leading v and carries a size per asset', () => {
    expect(buildReleaseSummary(RELEASE)).toEqual({
      ok: true,
      version: '0.9.3',
      publishedAt: '2026-08-03T14:22:11Z',
      releaseUrl: 'https://github.com/getmydia/mydia/releases/tag/v0.9.3',
      assets: {
        android: { size: 64123456 },
        macos: { size: 51234567 },
        windows: { size: 43210987 },
        linux: { size: 47654321 },
      },
    });
  });

  it('omits platforms the release did not ship', () => {
    const withoutMac = {
      ...RELEASE,
      assets: RELEASE.assets.filter((a) => !a.name.endsWith('.dmg')),
    };
    expect(buildReleaseSummary(withoutMac).assets.macos).toBeUndefined();
  });
});
