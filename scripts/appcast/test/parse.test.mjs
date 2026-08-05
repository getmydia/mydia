import test from 'node:test'
import assert from 'node:assert/strict'
import { parseReleaseAppcast } from '../lib/parse.mjs'

/** A per-release appcast in exactly the shape release.yml emits. */
function releaseAppcast({ version = '10123', short = '1.5.0', enclosure } = {}) {
  const enc =
    enclosure ??
    '<enclosure url="https://example.test/a.dmg" sparkle:edSignature="AAAA" length="123" type="application/octet-stream" />'
  return `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Mydia Player</title>
    <item>
      <title>Version ${short}</title>
      <sparkle:version>${version}</sparkle:version>
      <sparkle:shortVersionString>${short}</sparkle:shortVersionString>
      <pubDate>Mon, 04 Aug 2026 12:00:00 +0000</pubDate>
      ${enc}
    </item>
  </channel>
</rss>`
}

test('extracts version, short version and the signed enclosure', () => {
  const result = parseReleaseAppcast(releaseAppcast())

  assert.deepEqual(result, {
    version: '10123',
    shortVersionString: '1.5.0',
    enclosure: {
      url: 'https://example.test/a.dmg',
      signature: 'AAAA',
      length: '123',
    },
  })
})

test('keeps a numeric-looking short version as a string', () => {
  // fast-xml-parser coerces "1.5" to the number 1.5 unless told not to, which
  // would silently rewrite the marketing version shown to users.
  const result = parseReleaseAppcast(releaseAppcast({ short: '1.5' }))

  assert.equal(result.shortVersionString, '1.5')
})

test('rejects a feed with more than one item', () => {
  const two = releaseAppcast().replace('</item>', '</item><item><title>x</title></item>')

  assert.throws(() => parseReleaseAppcast(two), /exactly 1 item/)
})

test('rejects a non-integer sparkle:version', () => {
  assert.throws(() => parseReleaseAppcast(releaseAppcast({ version: '1.5.0' })), /must be an integer/)
})

test('rejects an enclosure with no signature', () => {
  const unsigned = '<enclosure url="https://example.test/a.dmg" length="123" />'

  assert.throws(() => parseReleaseAppcast(releaseAppcast({ enclosure: unsigned })), /edSignature/)
})

test('rejects an enclosure with a non-integer length', () => {
  const bad = '<enclosure url="https://example.test/a.dmg" sparkle:edSignature="AAAA" length="12 34" />'

  assert.throws(() => parseReleaseAppcast(releaseAppcast({ enclosure: bad })), /length must be an integer/)
})
