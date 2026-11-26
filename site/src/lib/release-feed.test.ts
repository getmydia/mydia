import { describe, expect, it } from 'vitest';
import {
  isPreReleaseTrack,
  parseFeed,
  resolveTrackBuild,
  staticPreReleaseDestination,
  type ReleaseFeed,
} from './release-feed';

function entry(version: string, build: number) {
  return { version, build, url: `https://dl.example/${version}` };
}

/** Shaped like updates.mydia.dev/releases.json. */
const FEED: ReleaseFeed = {
  platforms: {
    android: {
      stable: entry('0.19.1', 19190000),
      beta: entry('0.20.0-beta.1', 20010000),
      dev: entry('0.20.0-dev.31', 20000031),
    },
    windows: {
      stable: entry('0.19.1', 19190000),
      beta: entry('0.19.0-beta.5', 19035000),
    },
  },
};

describe('resolveTrackBuild', () => {
  it('returns the track’s own build when it is the newest', () => {
    expect(resolveTrackBuild(FEED, 'android', 'beta')).toEqual({
      track: 'beta',
      entry: FEED.platforms.android.beta,
    });
  });

  it('prefers a less risky track that is newer', () => {
    // The dev build is older than the beta that followed it.
    expect(resolveTrackBuild(FEED, 'android', 'dev')?.track).toBe('beta');
    // A beta overtaken by a stable release.
    expect(resolveTrackBuild(FEED, 'windows', 'beta')?.track).toBe('stable');
  });

  it('falls back to lower tracks when the platform has no build on this one', () => {
    expect(resolveTrackBuild(FEED, 'windows', 'dev')?.track).toBe('stable');
  });

  it('returns null for platforms the feed does not carry', () => {
    expect(resolveTrackBuild(FEED, 'macos', 'beta')).toBeNull();
    expect(resolveTrackBuild(FEED, 'ios', 'beta')).toBeNull();
  });

  it('skips malformed entries', () => {
    const feed = {
      platforms: { android: { stable: entry('0.19.1', 1), beta: { version: 'x' } } },
    } as unknown as ReleaseFeed;
    expect(resolveTrackBuild(feed, 'android', 'beta')?.track).toBe('stable');
  });
});

describe('static destinations and parsing', () => {
  it('maps iOS beta to the pre-release TestFlight group and has no iOS dev', () => {
    expect(staticPreReleaseDestination('ios', 'beta')).toContain('testflight.apple.com');
    expect(staticPreReleaseDestination('ios', 'dev')).toBeNull();
    expect(staticPreReleaseDestination('flatpak', 'dev')).toContain('mydia-dev');
  });

  it('accepts only beta and dev as pre-release tracks', () => {
    expect(isPreReleaseTrack('beta')).toBe(true);
    expect(isPreReleaseTrack('dev')).toBe(true);
    expect(isPreReleaseTrack('stable')).toBe(false);
    expect(isPreReleaseTrack(null)).toBe(false);
  });

  it('rejects bodies without a platforms map', () => {
    expect(parseFeed('{"platforms":{}}')).not.toBeNull();
    expect(parseFeed('{}')).toBeNull();
    expect(parseFeed('not json')).toBeNull();
  });
});
