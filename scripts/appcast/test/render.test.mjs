import test from 'node:test'
import assert from 'node:assert/strict'
import { escapeXml, wrapCdata, renderItem, renderFeed } from '../lib/render.mjs'

function item(overrides = {}) {
  return {
    title: 'Version 1.5.0',
    version: '10123',
    shortVersionString: '1.5.0',
    channel: null,
    minimumSystemVersion: '14.0',
    pubDate: 'Mon, 04 Aug 2026 12:00:00 +0000',
    descriptionHtml: '<p>Hello</p>',
    enclosure: {
      url: 'https://example.test/a.dmg',
      signature: 'AAAA',
      length: '123',
    },
    ...overrides,
  }
}

test('escapes the five XML metacharacters', () => {
  assert.equal(escapeXml(`a&b<c>d"e'f`), 'a&amp;b&lt;c&gt;d&quot;e&apos;f')
})

test('splits a CDATA terminator inside release notes', () => {
  // A CDATA section ends at the first ]]>. Left alone, notes containing one
  // truncate the document mid-item and Sparkle rejects the whole feed.
  const wrapped = wrapCdata('before ]]> after')

  assert.equal(wrapped, '<![CDATA[before ]]<![CDATA[> after]]>')
  assert.ok(!wrapped.slice(9, -3).includes(']]>'))
})

test('omits the channel element for a stable item', () => {
  assert.ok(!renderItem(item()).includes('sparkle:channel'))
})

test('emits the beta channel element for a prerelease item', () => {
  assert.match(renderItem(item({ channel: 'beta' })), /<sparkle:channel>beta<\/sparkle:channel>/)
})

test('escapes an ampersand in the enclosure url', () => {
  const xml = renderItem(item({ enclosure: { url: 'https://x.test/a.dmg?a=1&b=2', signature: 'AAAA', length: '123' } }))

  assert.ok(xml.includes('a=1&amp;b=2'))
  assert.ok(!xml.includes('a=1&b=2'))
})

test('renders a feed with the sparkle namespace and every item', () => {
  const xml = renderFeed([item(), item({ title: 'Version 1.4.9', version: '10100' })])

  assert.match(xml, /^<\?xml version="1\.0" encoding="utf-8"\?>/)
  assert.ok(xml.includes('xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"'))
  assert.equal(xml.match(/<item>/g).length, 2)
  assert.ok(xml.includes('<title>Mydia Player</title>'))
})
