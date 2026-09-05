import { XMLParser } from 'fast-xml-parser'

// parseTagValue/parseAttributeValue must stay false. With them on, a short
// version of "1.5" comes back as the number 1.5 and a length of "0123" loses
// its leading zero, both of which corrupt the feed silently.
const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: '@_',
  parseTagValue: false,
  parseAttributeValue: false,
})

/**
 * Reads one release's single-item appcast asset, the artifact release.yml
 * generates and signs, and returns the fields the merged feed reuses verbatim.
 *
 * The enclosure is copied through untouched so the signature Sparkle verifies
 * is always the one produced at build time. Nothing here re-signs anything.
 */
export function parseReleaseAppcast(xml) {
  const doc = parser.parse(xml)
  const channel = doc?.rss?.channel
  if (!channel) {
    throw new Error('appcast has no rss > channel element')
  }

  const items = Array.isArray(channel.item) ? channel.item : channel.item ? [channel.item] : []
  if (items.length !== 1) {
    throw new Error(`expected exactly 1 item in a per-release appcast, got ${items.length}`)
  }
  const item = items[0]

  const version = String(item['sparkle:version'] ?? '')
  if (!/^\d+$/.test(version)) {
    throw new Error(`sparkle:version must be an integer build number, got ${JSON.stringify(version)}`)
  }

  const shortVersionString = String(item['sparkle:shortVersionString'] ?? '')
  if (!shortVersionString) {
    throw new Error('missing sparkle:shortVersionString')
  }

  // Absent on every release published before this field started being
  // emitted, so null (not a default) is the correct value for those items:
  // making no claim about minimum OS is what the legacy feed already does.
  const minimumSystemVersion =
    item['sparkle:minimumSystemVersion'] != null ? String(item['sparkle:minimumSystemVersion']) : null

  const enclosure = item.enclosure
  if (!enclosure) {
    throw new Error('item has no enclosure')
  }

  const url = String(enclosure['@_url'] ?? '')
  const signature = String(enclosure['@_sparkle:edSignature'] ?? '')
  const length = String(enclosure['@_length'] ?? '')

  if (!url) {
    throw new Error('enclosure has no url')
  }
  if (!signature) {
    throw new Error('enclosure has no sparkle:edSignature')
  }
  if (!/^\d+$/.test(length)) {
    throw new Error(`enclosure length must be an integer, got ${JSON.stringify(length)}`)
  }

  return { version, shortVersionString, minimumSystemVersion, enclosure: { url, signature, length } }
}
