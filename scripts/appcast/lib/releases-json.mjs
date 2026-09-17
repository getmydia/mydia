/**
 * Builds the platform-and-track feed served at updates.mydia.dev/releases.json.
 *
 * The Sparkle appcast in build.mjs answers "what should a macOS app install
 * next". This answers the same question for every platform and every track,
 * including the dev builds that never become GitHub releases. Both are
 * rendered from the same inputs by generate.mjs so they cannot disagree.
 *
 * No IO here, for the same reason build.mjs has none: the whole model is
 * testable from plain fixtures.
 */

/** Where dev build files are served from. Keep in step with the R2 bucket. */
export const DEV_BASE_URL = 'https://dl.mydia.dev'

/** The release asset each platform installs. */
export const ASSET_PATTERNS = {
  android: /^mydia-player-android-v.*\.apk$/,
  windows: /^mydia-player-windows-v.*\.exe$/,
  linux: /^mydia-player-linux-v.*\.tar\.gz$/,
  macos: /^mydia-player-macos-v.*\.dmg$/,
}

export const PLATFORMS = Object.keys(ASSET_PATTERNS)

/**
 * The build number for a version string.
 *
 * Mirrors scripts/build-number.sh, which is what the workflows call. Both
 * exist because a shell script cannot be imported here and a Node module
 * cannot be called from a `run:` block without paying a Node startup per
 * call. scripts/tests/build-number-test.sh and this module's tests assert
 * the same table of values, which is what keeps them in step.
 */
export function buildNumber(version) {
  const v = String(version).replace(/^v/, '')
  const [core, ...rest] = v.split(/[-+]/)
  const suffix = v.slice(core.length + 1)

  const [major, minor, patch] = core.split('.').map((part) => Number(part))
  if (![major, minor, patch].every((n) => Number.isInteger(n) && n >= 0)) {
    throw new Error(`unparseable version: ${version}`)
  }

  // Bands in semver maturity order, each with its own counter space so
  // beta.1 and rc.1 cannot land on the same number. The dot is optional
  // because 36 existing tags predate it (v0.8.1-rc13, v0.9.0-beta2).
  const BANDS = [
    [/^dev\.?(\d+)$/, 0],
    [/^alpha\.?(\d+)$/, 300],
    [/^beta\.?(\d+)$/, 500],
    [/^rc\.?(\d+)$/, 700],
    [/^refresh\.?(\d+)$/, 900],
  ]

  let slot = 900
  if (rest.length > 0) {
    const band = BANDS.find(([pattern]) => pattern.test(suffix))
    if (!band) throw new Error(`unrecognised version suffix: ${version}`)
    const [pattern, base] = band
    slot = base + Number(suffix.match(pattern)[1])
  }

  return major * 10000000 + minor * 100000 + patch * 1000 + slot
}

function entryFromRelease(release, platform) {
  const pattern = ASSET_PATTERNS[platform]
  const match = (release.assets ?? []).find((a) => pattern.test(a.name))
  if (!match) return null

  const version = String(release.tag_name ?? '').replace(/^v/, '')
  if (!version) return null

  return {
    version,
    build: buildNumber(version),
    url: match.browser_download_url,
    size: match.size,
    sha256: null,
    notes_url: release.html_url,
    published_at: release.published_at,
  }
}

function entryFromDevBuild(devBuild) {
  return {
    version: devBuild.version,
    build: devBuild.build,
    url: `${DEV_BASE_URL}/${devBuild.file}`,
    size: devBuild.size,
    sha256: devBuild.sha256,
    notes_url: 'https://github.com/getmydia/mydia/commits/master',
    published_at: devBuild.published_at,
  }
}

/**
 * The newest entry per platform per track.
 *
 * A release whose version cannot be parsed is skipped rather than throwing:
 * one bad historical tag must not block every future feed update, which is the
 * same call buildItems makes for a release with no DMG.
 */
export function buildReleasesModel(releases, devBuilds) {
  const platforms = Object.fromEntries(PLATFORMS.map((p) => [p, {}]))

  for (const release of releases ?? []) {
    if (release.draft) continue
    const track = release.prerelease ? 'beta' : 'stable'

    for (const platform of PLATFORMS) {
      let entry
      try {
        entry = entryFromRelease(release, platform)
      } catch {
        continue
      }
      if (!entry) continue

      const held = platforms[platform][track]
      if (!held || entry.build > held.build) {
        platforms[platform][track] = entry
      }
    }
  }

  for (const devBuild of devBuilds ?? []) {
    const platform = devBuild.platform
    if (!PLATFORMS.includes(platform)) continue

    const entry = entryFromDevBuild(devBuild)
    const held = platforms[platform].dev
    if (!held || entry.build > held.build) {
      platforms[platform].dev = entry
    }
  }

  return { generated_at: null, platforms }
}

/**
 * Throws before anything is written, so a failed run leaves the deployed feed
 * live. A feed with no stable entry anywhere reads to every client as "there
 * are no releases", which is far worse than a stale one.
 */
export function assertReleasesInvariants(model) {
  const withStable = PLATFORMS.filter((p) => model.platforms[p]?.stable)
  if (withStable.length === 0) {
    throw new Error('releases.json has no stable entry for any platform')
  }
}

export function renderReleasesJson(model, generatedAt) {
  return `${JSON.stringify({ ...model, generated_at: generatedAt }, null, 2)}\n`
}
