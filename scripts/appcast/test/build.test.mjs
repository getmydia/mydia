import test from 'node:test'
import assert from 'node:assert/strict'
import {
  buildItems,
  buildDevItems,
  mergeFeedItems,
  assertFeedInvariants,
  toRfc822,
  MAX_ITEMS,
  DEV_CHANNEL,
} from '../lib/build.mjs'

function perReleaseAppcast(version, short) {
  return `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel><item>
    <sparkle:version>${version}</sparkle:version>
    <sparkle:shortVersionString>${short}</sparkle:shortVersionString>
    <enclosure url="https://example.test/${short}.dmg" sparkle:edSignature="SIG${version}" length="99" />
  </item></channel>
</rss>`
}

function release({ tag, short, versionCode, prerelease = false, assets, body = 'notes', draft = false }) {
  return {
    tag_name: tag,
    prerelease,
    draft,
    body,
    published_at: '2026-08-04T12:00:00Z',
    assets: assets ?? [
      { name: `mydia-player-macos-${tag}.dmg`, browser_download_url: `https://example.test/${short}.dmg` },
      { name: 'appcast.xml', browser_download_url: `https://example.test/${short}-appcast.xml` },
    ],
    _appcast: perReleaseAppcast(versionCode, short),
  }
}

/** Serves each release its own appcast body, keyed by download URL. */
function resolverFor(releases) {
  const byUrl = new Map()
  for (const r of releases) {
    const asset = r.assets.find((a) => a.name === 'appcast.xml')
    if (asset) byUrl.set(asset.browser_download_url, r._appcast)
  }
  return async (asset) => {
    if (!byUrl.has(asset.browser_download_url)) throw new Error('404')
    return byUrl.get(asset.browser_download_url)
  }
}

const identityNotes = (markdown) => `<p>${markdown}</p>`

async function build(releases) {
  return buildItems(releases, { loadAppcast: resolverFor(releases), renderNotes: identityNotes })
}

test('formats published_at as RFC 822 in UTC', () => {
  assert.equal(toRfc822('2026-08-04T12:00:00Z'), 'Tue, 04 Aug 2026 12:00:00 +0000')
})

test('rejects a null published_at instead of silently returning the epoch', () => {
  // new Date(null) coerces to 1970-01-01T00:00:00.000Z, so Number.isNaN never
  // fires on its getTime(). GitHub returns an explicit null for published_at
  // on releases that lack one, and that must fail the same way any other bad
  // input does rather than backdating the item by five decades.
  assert.throws(() => toRfc822(null), /invalid published_at/)
})

test('a stable-only repo produces items with no channel', async () => {
  const { items } = await build([release({ tag: 'v1.4.9', short: '1.4.9', versionCode: '10100' })])

  assert.equal(items.length, 1)
  assert.equal(items[0].channel, null)
  assert.equal(items[0].kind, 'stable')
  assert.equal(items[0].title, 'Version 1.4.9')
  assert.equal(items[0].enclosure.signature, 'SIG10100')
})

test('a prerelease newer than the newest stable is tagged beta and sorts first', async () => {
  // This is the case that is broken today: releases/latest/download never
  // resolves to a prerelease, so this item is unreachable without the merge.
  const { items } = await build([
    release({ tag: 'v1.4.9', short: '1.4.9', versionCode: '10100' }),
    release({ tag: 'v1.5.0-beta.2', short: '1.5.0-beta.2', versionCode: '10123', prerelease: true }),
  ])

  assert.deepEqual(
    items.map((i) => [i.shortVersionString, i.channel]),
    [
      ['1.5.0-beta.2', 'beta'],
      ['1.4.9', null],
    ],
  )
})

test('sorts by build number, not by marketing version string', async () => {
  // Build numbers deliberately invert the lexicographic order of the
  // marketing strings: "1.9.0" sorts above "1.10.0" as plain text, so a
  // string sort would return these the other way round.
  const { items } = await build([
    release({ tag: 'v1.10.0', short: '1.10.0', versionCode: '10300' }),
    release({ tag: 'v1.9.0', short: '1.9.0', versionCode: '10200' }),
  ])

  assert.deepEqual(items.map((i) => i.version), ['10300', '10200'])
})

test('skips a release with no macOS DMG', async () => {
  const noDmg = release({ tag: 'v1.4.9', short: '1.4.9', versionCode: '10100' })
  noDmg.assets = [{ name: 'appcast.xml', browser_download_url: 'https://example.test/1.4.9-appcast.xml' }]

  const { items, warnings } = await build([noDmg])

  assert.equal(items.length, 0)
  assert.match(warnings.join('\n'), /v1\.4\.9.*no macOS DMG/)
})

test('skips a release whose appcast asset is missing without failing the run', async () => {
  const good = release({ tag: 'v1.4.9', short: '1.4.9', versionCode: '10100' })
  const broken = release({ tag: 'v1.3.0', short: '1.3.0', versionCode: '10050' })
  broken.assets = broken.assets.filter((a) => a.name !== 'appcast.xml')

  const { items, warnings } = await build([good, broken])

  assert.deepEqual(items.map((i) => i.version), ['10100'])
  assert.match(warnings.join('\n'), /v1\.3\.0/)
})

test('skips a release with an unparseable published_at instead of failing the run', async () => {
  const good = release({ tag: 'v1.4.9', short: '1.4.9', versionCode: '10100' })
  const broken = release({ tag: 'v1.3.0', short: '1.3.0', versionCode: '10050' })
  broken.published_at = 'not-a-date'

  const { items, warnings } = await build([good, broken])

  assert.deepEqual(items.map((i) => i.version), ['10100'])
  assert.match(warnings.join('\n'), /v1\.3\.0.*invalid published_at/)
})

test('skips a draft release', async () => {
  const { items } = await build([release({ tag: 'v9.9.9', short: '9.9.9', versionCode: '99999', draft: true })])

  assert.equal(items.length, 0)
})

test('caps the feed at MAX_ITEMS, keeping the newest', async () => {
  const many = Array.from({ length: MAX_ITEMS + 5 }, (_, i) =>
    release({ tag: `v1.0.${i}`, short: `1.0.${i}`, versionCode: String(10000 + i) }),
  )

  const { items } = await build(many)

  assert.equal(items.length, MAX_ITEMS)
  assert.equal(items[0].version, String(10000 + MAX_ITEMS + 4))
})

test('reserves the newest stable items so a long prerelease run cannot evict all of them', async () => {
  // Sparkle filters by allowed channel after fetching the feed, so a
  // stable-channel user only ever sees channel-less items. A bare
  // slice(0, MAX_ITEMS) applied after sorting across both channels would let
  // enough prereleases push the one stable item below the cutoff, leaving
  // stable users with no update offered at all.
  const stable = release({ tag: 'v1.0.0', short: '1.0.0', versionCode: '10000' })
  const betas = Array.from({ length: 30 }, (_, i) =>
    release({
      tag: `v1.1.0-beta.${i}`,
      short: `1.1.0-beta.${i}`,
      versionCode: String(20000 + i),
      prerelease: true,
    }),
  )

  const { items } = await build([stable, ...betas])

  assert.equal(items.length, MAX_ITEMS)
  assert.ok(items.some((item) => item.version === '10000'), 'the stable item must survive the cap')
})

test('assertFeedInvariants rejects an empty feed', () => {
  assert.throws(() => assertFeedInvariants([]), /empty appcast/)
})

test('assertFeedInvariants rejects a beta item missing the beta channel', async () => {
  const { items } = await build([
    release({ tag: 'v1.5.0-beta.2', short: '1.5.0-beta.2', versionCode: '10123', prerelease: true }),
  ])
  items[0].channel = null

  assert.throws(() => assertFeedInvariants(items), /beta item must carry the beta channel/)
})

test('assertFeedInvariants rejects a stable item that acquired a channel', async () => {
  const { items } = await build([release({ tag: 'v1.4.9', short: '1.4.9', versionCode: '10100' })])
  items[0].channel = 'beta'

  assert.throws(() => assertFeedInvariants(items), /stable/)
})

test('assertFeedInvariants accepts a well-formed mixed feed', async () => {
  const { items } = await build([
    release({ tag: 'v1.4.9', short: '1.4.9', versionCode: '10100' }),
    release({ tag: 'v1.5.0-beta.2', short: '1.5.0-beta.2', versionCode: '10123', prerelease: true }),
  ])

  assert.doesNotThrow(() => assertFeedInvariants(items))
})

test('assertFeedInvariants rejects two items sharing the same sparkle:version', async () => {
  // Sparkle would pick between duplicates non-deterministically, so this is a
  // generator bug to fail loudly on, not something to ship and hope resolves
  // itself.
  const { items } = await build([release({ tag: 'v1.4.9', short: '1.4.9', versionCode: '10100' })])
  const duplicate = { ...items[0] }

  assert.throws(() => assertFeedInvariants([...items, duplicate]), /duplicate/)
})

function devBuild(overrides = {}) {
  return {
    platform: 'macos',
    version: '1.2.3-dev.4',
    build: 102300004,
    file: 'macos/mydia-player-macos-v1.2.3-dev.4.dmg',
    size: 5,
    sha256: 'x',
    published_at: '2026-11-26T10:00:00Z',
    ed_signature: 'SIG',
    length: 5,
    minimum_system_version: '13.0',
    ...overrides,
  }
}

test('buildDevItems maps a macos entry to a dev channel item', () => {
  const { items, warnings } = buildDevItems([devBuild()])

  assert.deepEqual(warnings, [])
  assert.equal(items.length, 1)
  const [item] = items
  assert.equal(DEV_CHANNEL, 'dev')
  assert.equal(item.title, 'Dev build 1.2.3-dev.4')
  assert.equal(item.version, '102300004')
  assert.equal(item.shortVersionString, '1.2.3-dev.4')
  assert.equal(item.channel, 'dev')
  assert.equal(item.kind, 'dev')
  assert.equal(item.minimumSystemVersion, '13.0')
  assert.equal(item.pubDate, 'Thu, 26 Nov 2026 10:00:00 +0000')
  assert.deepEqual(item.enclosure, {
    url: 'https://dl.mydia.dev/macos/mydia-player-macos-v1.2.3-dev.4.dmg',
    signature: 'SIG',
    length: 5,
  })
  assert.match(item.descriptionHtml, /https:\/\/github\.com\/getmydia\/mydia\/commits\/master/)
})

test('buildDevItems ignores android entries without a warning', () => {
  const { items, warnings } = buildDevItems([devBuild({ platform: 'android', file: 'android/x.apk' })])

  assert.equal(items.length, 0)
  assert.deepEqual(warnings, [])
})

for (const [name, overrides] of [
  ['an unsigned entry', { ed_signature: undefined }],
  ['an empty signature', { ed_signature: '' }],
  ['a string length', { length: '5' }],
  ['a missing length', { length: undefined }],
  ['a malformed published_at', { published_at: 'not-a-date' }],
  ['a negative length', { length: -1 }],
  ['an unsafe length', { length: Number.MAX_SAFE_INTEGER + 1 }],
  ['a fractional build', { build: 1.5 }],
  ['a negative build', { build: -1 }],
  ['an unsafe build', { build: Number.MAX_SAFE_INTEGER + 1 }],
]) {
  test(`buildDevItems drops ${name} with a warning naming the file`, () => {
    const { items, warnings } = buildDevItems([devBuild(overrides)])

    assert.equal(items.length, 0)
    assert.equal(warnings.length, 1)
    assert.match(warnings[0], /macos\/mydia-player-macos-v1\.2\.3-dev\.4\.dmg/)
  })
}

test('buildDevItems omits a missing minimum system version', () => {
  const { items } = buildDevItems([devBuild({ minimum_system_version: undefined })])

  assert.equal(items[0].minimumSystemVersion, null)
})

test('mergeFeedItems drops a dev item whose build number a release already holds', async () => {
  const { items: releaseItems } = await build([
    release({ tag: 'v1.2.3', short: '1.2.3', versionCode: '102300004' }),
  ])
  const { items: devItems } = buildDevItems([devBuild()])

  const { items, warnings } = mergeFeedItems(releaseItems, devItems)

  assert.deepEqual(items.map((i) => i.kind), ['stable'])
  assert.equal(warnings.length, 1)
  assert.match(warnings[0], /102300004/)
  assert.doesNotThrow(() => assertFeedInvariants(items))
})

test('mergeFeedItems sorts newest first across kinds', async () => {
  const { items: releaseItems } = await build([
    release({ tag: 'v1.2.3', short: '1.2.3', versionCode: '102390000' }),
    release({ tag: 'v1.3.0-beta.1', short: '1.3.0-beta.1', versionCode: '103031000', prerelease: true }),
  ])
  const { items: devItems } = buildDevItems([
    devBuild({ version: '1.3.0-dev.2', build: 103000002, file: 'macos/b.dmg' }),
    devBuild({ version: '1.2.3-dev.4', build: 102300004, file: 'macos/a.dmg' }),
  ])

  const { items } = mergeFeedItems(releaseItems, devItems)

  assert.deepEqual(items.map((i) => i.kind), ['beta', 'dev', 'stable', 'dev'])
  assert.doesNotThrow(() => assertFeedInvariants(items))
})

test('assertFeedInvariants rejects a dev item without the dev channel', () => {
  const { items } = buildDevItems([devBuild()])
  items[0].channel = null

  assert.throws(() => assertFeedInvariants(items), /dev item must carry the dev channel/)
})

test('assertFeedInvariants rejects an item of unknown kind', async () => {
  const { items } = await build([release({ tag: 'v1.4.9', short: '1.4.9', versionCode: '10100' })])
  items[0].kind = 'nightly'

  assert.throws(() => assertFeedInvariants(items), /unknown kind/)
})

test('buildDevItems keeps the newest of two entries sharing a build number', () => {
  // build-number.sh lowercases the prerelease and makes its dot optional, so
  // 1.2.3-rc13 and 1.2.3-rc.13 are different index rows with one build
  // number. Both reaching the feed would fail assertFeedInvariants and stop
  // every feed deploy until five newer builds pruned them.
  const { items, warnings } = buildDevItems([
    devBuild({ version: '1.2.3-rc13', file: 'macos/old.dmg', published_at: '2026-11-25T10:00:00Z' }),
    devBuild({ version: '1.2.3-rc.13', file: 'macos/new.dmg', published_at: '2026-11-26T10:00:00Z' }),
  ])

  assert.equal(items.length, 1)
  assert.equal(items[0].enclosure.url, 'https://dl.mydia.dev/macos/new.dmg')
  assert.equal(warnings.length, 1)
  assert.match(warnings[0], /macos\/old\.dmg/)
  assert.doesNotThrow(() => assertFeedInvariants(items))
})
