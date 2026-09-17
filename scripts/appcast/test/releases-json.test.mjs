import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'

import {
  buildReleasesModel,
  renderReleasesJson,
  assertReleasesInvariants,
  buildNumber,
} from '../lib/releases-json.mjs'

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
  assert.equal(model.platforms.android.stable.build, 1500900)
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
    '0.15.0-dev.4',
    '0.15.0-alpha.3',
    '0.15.0-beta.2',
    '0.15.0-rc.1',
    '0.15.0-beta2',
    'v0.8.1-rc13',
    '0.15.0+refresh.2',
    // Boundary pairs: the highest counter each band accepts before it would
    // overflow into the next one.
    '0.15.0-dev.299',
    '0.15.0-alpha.199',
    '0.15.0-beta.199',
    '0.15.0-rc.199',
    '0.15.0+refresh.99',
  ]

  for (const version of accepted) {
    const shell = execFileSync('../build-number.sh', [version], {
      encoding: 'utf8',
    }).trim()
    assert.equal(String(buildNumber(version)), shell, `mismatch for ${version}`)
  }

  // Inputs both implementations must refuse. execFileSync throws on a
  // non-zero exit, so there is no number to compare here: the assertion is
  // that both sides reject, not that their outputs match. Each of the first
  // five is the first counter that overflows its band; the last is the
  // no-dot refresh form the shell has never accepted (CI's only producer
  // always writes the dot).
  const rejected = [
    '0.15.0-dev.300',
    '0.15.0-alpha.200',
    '0.15.0-beta.200',
    '0.15.0-rc.200',
    '0.15.0+refresh.100',
    '0.15.0+refresh2',
  ]

  for (const version of rejected) {
    assert.throws(
      () => execFileSync('../build-number.sh', [version], { encoding: 'utf8' }),
      `shell should have rejected ${version}`,
    )
    assert.throws(() => buildNumber(version), `buildNumber should have rejected ${version}`)
  }
})
