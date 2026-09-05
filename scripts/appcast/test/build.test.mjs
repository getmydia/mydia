import test from 'node:test'
import assert from 'node:assert/strict'
import { buildItems, assertFeedInvariants, toRfc822, MAX_ITEMS } from '../lib/build.mjs'

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
  assert.equal(items[0].prerelease, false)
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

test('assertFeedInvariants rejects a prerelease item missing the beta channel', async () => {
  const { items } = await build([
    release({ tag: 'v1.5.0-beta.2', short: '1.5.0-beta.2', versionCode: '10123', prerelease: true }),
  ])
  items[0].channel = null

  assert.throws(() => assertFeedInvariants(items), /prerelease.*beta/)
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
