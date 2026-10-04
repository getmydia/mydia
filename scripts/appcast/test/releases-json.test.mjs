import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'

import {
  buildReleasesModel,
  renderReleasesJson,
  assertReleasesInvariants,
  buildNumber,
} from '../lib/releases-json.mjs'
import { parseDevIndex } from '../dev-builds.mjs'

const asset = (name, size = 1024) => ({
  name,
  size,
  browser_download_url: `https://github.example.invalid/${name}`,
})

const release = (tag, { prerelease = false, assets = [] } = {}) => ({
  tag_name: tag,
  html_url: `https://github.example.invalid/releases/tag/${tag}`,
  name: tag,
  published_at: '2026-09-01T10:00:00Z',
  draft: false,
  prerelease,
  assets,
})

const stable = release('v0.15.0', {
  assets: [
    asset('mydia-player-android-v0.15.0.apk', 68000000),
    asset('mydia-player-windows-v0.15.0.exe', 42000000),
    asset('mydia-player-linux-v0.15.0.tar.gz', 55000000),
    asset('mydia-player-macos-v0.15.0.dmg', 90000000),
  ],
})

const beta = release('v0.16.0-beta.1', {
  prerelease: true,
  assets: [asset('mydia-player-android-v0.16.0-beta.1.apk', 68100000)],
})

const devBuilds = [
  {
    platform: 'android',
    version: '0.16.0-dev.7',
    build: 1600007,
    file: 'android/mydia-player-android-0.16.0-dev.7.apk',
    size: 68200000,
    sha256: 'abc123',
    published_at: '2026-09-15T08:00:00Z',
  },
]

test('picks the newest stable per platform', () => {
  const model = buildReleasesModel([stable], [])
  assert.equal(model.platforms.android.stable.version, '0.15.0')
  assert.equal(model.platforms.android.stable.build, 15090000)
  assert.equal(
    model.platforms.android.stable.url,
    'https://github.example.invalid/mydia-player-android-v0.15.0.apk',
  )
  assert.equal(model.platforms.windows.stable.version, '0.15.0')
  assert.equal(model.platforms.linux.stable.version, '0.15.0')
  assert.equal(model.platforms.macos.stable.version, '0.15.0')
})

test('a prerelease lands on the beta track, not stable', () => {
  const model = buildReleasesModel([beta, stable], [])
  assert.equal(model.platforms.android.beta.version, '0.16.0-beta.1')
  assert.equal(model.platforms.android.stable.version, '0.15.0')
})

test('a platform with no asset in a release is absent from that track', () => {
  const model = buildReleasesModel([beta, stable], [])
  assert.equal(model.platforms.windows.beta, undefined)
})

test('dev builds come from the index, not from releases', () => {
  const model = buildReleasesModel([stable], devBuilds)
  assert.equal(model.platforms.android.dev.version, '0.16.0-dev.7')
  assert.equal(model.platforms.android.dev.build, 1600007)
  assert.equal(model.platforms.android.dev.sha256, 'abc123')
  assert.match(model.platforms.android.dev.url, /^https:\/\/dl\.mydia\.dev\//)
  assert.equal(model.platforms.windows.dev, undefined)
})

test('the newest build wins within a track', () => {
  const older = release('v0.14.0', {
    assets: [asset('mydia-player-android-v0.14.0.apk')],
  })
  // The newer release is listed first, so an implementation that just kept
  // the last one seen (instead of comparing build numbers) would fail this.
  const model = buildReleasesModel([stable, older], [])
  assert.equal(model.platforms.android.stable.version, '0.15.0')
})

test('a draft contributes nothing', () => {
  const model = buildReleasesModel([{ ...stable, draft: true }], [])
  assert.deepEqual(model.platforms.android, {})
})

test('rendering is deterministic and stamps the time it is given', () => {
  const model = buildReleasesModel([stable, beta], devBuilds)
  const once = renderReleasesJson(model, '2026-09-17T00:00:00Z')
  const twice = renderReleasesJson(model, '2026-09-17T00:00:00Z')
  assert.equal(once, twice)
  assert.equal(JSON.parse(once).generated_at, '2026-09-17T00:00:00Z')
  assert.ok(once.endsWith('\n'))
})

test('an empty model is refused rather than deployed', () => {
  assert.throws(() => assertReleasesInvariants(buildReleasesModel([], [])), /no stable/i)
  assert.doesNotThrow(() => assertReleasesInvariants(buildReleasesModel([stable], [])))
})

test('buildNumber agrees with scripts/build-number.sh', () => {
  // Two implementations of one formula, so assert they agree rather than
  // trusting a comment to keep them in step. The shell one is what the
  // workflows call; this one is what the feed stamps into every entry, and a
  // disagreement would publish a number no device could act on.
  const accepted = [
    '0.15.0',
    '0.15.1',
    '1.15.0',
    '0.015.0',
    '0.15.0-dev.4',
    '0.15.0-alpha.3',
    '0.15.0-beta.2',
    '0.15.0-rc.1',
    '0.15.0-beta2',
    'v0.8.1-rc13',
    '0.15.0+refresh.2',
    '0.16.0-beta.2.dev.16',
    '0.16.0-rc13.dev.4',
    // Boundary values: the highest counter each band and dev tail accepts
    // before it would overflow into its neighbour.
    '0.15.0-dev.9999',
    '0.15.0-alpha.19',
    '0.15.0-beta.29',
    '0.15.0-rc.29',
    '0.15.0-alpha.19.dev.999',
    '0.15.0+refresh.99',
    // Boundary values for the major/minor/patch guard.
    '20.0.0',
    '0.99.0',
    '0.0.9',
    '20.99.9+refresh.99',
  ]

  for (const version of accepted) {
    const shell = execFileSync('../build-number.sh', [version], {
      encoding: 'utf8',
    }).trim()
    assert.equal(String(buildNumber(version)), shell, `mismatch for ${version}`)
  }

  // Inputs both implementations must refuse: the first counter past each band
  // and dev tail, a dev tail of 0 (the prerelease itself), a dev tail on a dev
  // build, the no-dot refresh form, and the first value past each version
  // field.
  const rejected = [
    '0.15.0-dev.10000',
    '0.15.0-alpha.20',
    '0.15.0-beta.30',
    '0.15.0-rc.30',
    '0.15.0-beta.2.dev.0',
    '0.15.0-beta.2.dev.1000',
    '0.15.0-beta.2.dev',
    '0.15.0-dev.1.dev.2',
    '0.15.0+refresh.0',
    '0.15.0+refresh.100',
    '0.15.0+refresh2',
    // First value that overflows each of the major/minor/patch fields.
    '21.0.0',
    '0.100.0',
    '0.0.10',
  ]

  for (const version of rejected) {
    assert.throws(
      () => execFileSync('../build-number.sh', [version], { encoding: 'utf8' }),
      `shell should have rejected ${version}`,
    )
    assert.throws(() => buildNumber(version), `buildNumber should have rejected ${version}`)
  }
})

test('buildNumber orders builds by when they were made', () => {
  const ordered = [
    '0.16.0-dev.5',
    '0.16.0-alpha.1',
    '0.16.0-alpha.1.dev.3',
    '0.16.0-beta.2',
    '0.16.0-beta.2.dev.16',
    '0.16.0-beta.2.dev.17',
    '0.16.0-beta.3',
    '0.16.0-rc.1',
    '0.16.0-rc.1.dev.1',
    '0.16.0',
    '0.16.0+refresh.1',
    '0.17.0-dev.1',
  ]
  for (let i = 1; i < ordered.length; i++) {
    assert.ok(
      buildNumber(ordered[i]) > buildNumber(ordered[i - 1]),
      `${ordered[i]} should rank above ${ordered[i - 1]}`,
    )
  }
})

test('the dev index parses to a build list', () => {
  const body = JSON.stringify({
    builds: [
      {
        platform: 'android',
        version: '0.16.0-dev.7',
        build: 1600007,
        file: 'android/x.apk',
        size: 10,
        sha256: 'abc',
        published_at: '2026-09-15T08:00:00Z',
      },
    ],
  })
  assert.equal(parseDevIndex(body)[0].version, '0.16.0-dev.7')
})

test('a missing or broken dev index yields no dev builds', () => {
  assert.deepEqual(parseDevIndex(null), [])
  assert.deepEqual(parseDevIndex(''), [])
  assert.deepEqual(parseDevIndex('not json'), [])
  assert.deepEqual(parseDevIndex('{"builds":"nope"}'), [])
})

test('parseDevIndex drops malformed elements instead of letting them crash buildReleasesModel', () => {
  const wellFormed = {
    platform: 'android',
    version: '0.16.0-dev.7',
    build: 1600007,
    file: 'android/x.apk',
    size: 10,
    sha256: 'abc',
    published_at: '2026-09-15T08:00:00Z',
  }

  const body = JSON.stringify({
    builds: [
      null,
      'not-an-object',
      { ...wellFormed, platform: undefined },
      { ...wellFormed, build: undefined },
      { ...wellFormed, file: undefined },
      wellFormed,
    ],
  })

  const builds = parseDevIndex(body)
  assert.equal(builds.length, 1)
  assert.equal(builds[0].version, '0.16.0-dev.7')
})

test('buildReleasesModel skips a malformed dev build rather than throwing', () => {
  // Exercises the model's own guard directly, since it is also called with
  // hand-built arrays (as every other test in this file does) rather than
  // exclusively through parseDevIndex.
  const model = buildReleasesModel([stable], [null, 'not-an-object', ...devBuilds])
  assert.equal(model.platforms.android.dev.version, '0.16.0-dev.7')
})

test('buildReleasesModel skips a dev build missing platform, build, or file', () => {
  // Each case is otherwise well-formed, isolating exactly the field the
  // model's guard must catch. Without it, a missing build installs an entry
  // with no build number and a missing file installs a url ending in
  // "undefined", rather than being dropped.
  const wellFormed = devBuilds[0]
  const missingPlatform = { ...wellFormed, platform: undefined }
  const missingBuild = { ...wellFormed, build: undefined }
  const missingFile = { ...wellFormed, file: undefined }

  assert.equal(buildReleasesModel([], [missingPlatform]).platforms.android.dev, undefined)
  assert.equal(buildReleasesModel([], [missingBuild]).platforms.android.dev, undefined)
  assert.equal(buildReleasesModel([], [missingFile]).platforms.android.dev, undefined)
})

test('the tarball and the AppImage each fill only their own slot', () => {
  const both = release('v0.17.0', {
    assets: [
      asset('mydia-player-linux-v0.17.0.tar.gz', 55000000),
      asset('mydia-player-linux-v0.17.0-x86_64.AppImage', 140000000),
    ],
  })

  const model = buildReleasesModel([both], [])

  assert.equal(
    model.platforms.linux.stable.url,
    'https://github.example.invalid/mydia-player-linux-v0.17.0.tar.gz',
  )
  assert.equal(
    model.platforms['linux-appimage'].stable.url,
    'https://github.example.invalid/mydia-player-linux-v0.17.0-x86_64.AppImage',
  )
  assert.equal(model.platforms['linux-appimage'].stable.size, 140000000)
})

test('a release with only a tarball leaves the AppImage slot empty', () => {
  const model = buildReleasesModel([stable], [])
  assert.equal(model.platforms['linux-appimage'].stable, undefined)
})
