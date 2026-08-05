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
