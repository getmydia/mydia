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

  // Mirrors scripts/build-number.sh's own magnitude guard: past these values
  // the multiplication below overflows Android's versionCode ceiling, so
  // reject here rather than silently return a number no device can install.
  if (major > 209) {
    throw new Error(`major above 209 overflows Android's versionCode ceiling: ${version}`)
  }
  if (minor > 99) {
    throw new Error(`minor above 99 overflows its field: ${version}`)
  }
  if (patch > 99) {
    throw new Error(`patch above 99 overflows its field: ${version}`)
  }

  // Bands in semver maturity order, each with its own counter space so
  // beta.1 and rc.1 cannot land on the same number. The dot is optional in
  // dev/alpha/beta/rc because 36 existing tags predate it (v0.8.1-rc13,
  // v0.9.0-beta2). refresh has no such history and its only producer (CI)
  // always writes the dot, so refresh requires it, matching
  // scripts/build-number.sh exactly. Each band also mirrors that script's
  // overflow guard: a counter large enough to reach into the next band
  // would silently collide with it, defeating the "own counter space"
  // guarantee this comment makes.
  const BANDS = [
    {
      pattern: /^dev\.?(\d+)$/,
      base: 0,
      validate: (n) => {
        if (n > 299) {
          throw new Error(`dev counter above 299 would collide with the alpha band: ${version}`)
        }
      },
    },
    {
      pattern: /^alpha\.?(\d+)$/,
      base: 300,
      validate: (n) => {
        if (n > 199) {
          throw new Error(`alpha counter above 199 would collide with the beta band: ${version}`)
        }
      },
    },
    {
      pattern: /^beta\.?(\d+)$/,
      base: 500,
      validate: (n) => {
        if (n > 199) {
          throw new Error(`beta counter above 199 would collide with the rc band: ${version}`)
        }
      },
    },
    {
      pattern: /^rc\.?(\d+)$/,
      base: 700,
      validate: (n) => {
        if (n > 199) {
          throw new Error(`rc counter above 199 would collide with the stable slot: ${version}`)
        }
      },
    },
    {
      pattern: /^refresh\.(\d+)$/,
      base: 900,
      validate: (n) => {
        if (n < 1 || n > 99) {
          throw new Error(`refresh counter must be 1..99: ${version}`)
        }
      },
    },
  ]

  let slot = 900
  if (rest.length > 0) {
    const band = BANDS.find(({ pattern }) => pattern.test(suffix))
    if (!band) throw new Error(`unrecognised version suffix: ${version}`)
    const n = Number(suffix.match(band.pattern)[1])
    band.validate(n)
    slot = band.base + n
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

/**
 * True for a value with every field buildReleasesModel and entryFromDevBuild
 * read from it: platform to select the track, build to compare against
 * whatever else is already held, file to build the download url. Shared by
 * dev-builds.mjs, which filters the R2 index through this before anything
 * reaches this module, and by buildReleasesModel's own loop below, which is
 * also called directly (including by its own tests) with hand-built arrays
 * that never pass through that filter. One implementation, so the two call
 * sites cannot drift on what "well-formed" means.
 */
export function isWellFormedDevBuild(entry) {
  return (
    typeof entry === 'object' &&
    entry !== null &&
    typeof entry.platform === 'string' &&
    typeof entry.build === 'number' &&
    typeof entry.file === 'string'
  )
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
    // Defends the same shape parseDevIndex already filters for, rather than
    // trusting that every caller routes through it: this function is also
    // called directly, including by its own tests, with hand-built arrays.
    // Without this, a null or non-object element throws reading .platform
    // below, and an object missing platform, build, or file would install
    // an entry with no build number or a url ending in "undefined".
    if (!isWellFormedDevBuild(devBuild)) continue

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
